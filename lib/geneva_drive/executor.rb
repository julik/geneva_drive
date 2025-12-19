# frozen_string_literal: true

# Executes a single step within a workflow context.
# Handles flow control signals, exception handling, and state transitions.
#
# The Executor owns the step execution and workflow during execution,
# using pessimistic locking to ensure atomicity of state transitions.
#
# Execution phases:
# 1. Acquire locks, validate states, transition to executing/performing
# 2. Release locks, execute user code (step block)
# 3. Acquire locks, handle flow control result, transition to final states
#
# @api private
module GenevaDrive::Executor
  # Valid state transitions for step executions
  STEP_TRANSITIONS = {
    "scheduled" => %w[scheduled in_progress canceled skipped failed completed],
    "in_progress" => %w[in_progress completed failed canceled skipped]
  }.freeze

  # Valid state transitions for workflows
  WORKFLOW_TRANSITIONS = {
    "ready" => %w[ready performing canceled paused finished],
    "performing" => %w[ready performing canceled paused finished]
  }.freeze

  class << self
    # Executes a step execution with full flow control and exception handling.
    #
    # @param step_execution [GenevaDrive::StepExecution] the step to execute
    # @return [void]
    def execute!(step_execution)
      workflow = step_execution.workflow

      # Phase 1: Acquire locks, validate, and prepare for execution
      step_execution.logger.debug("Preparing execution context")
      execution_context = prepare_execution(step_execution, workflow)
      return unless execution_context

      step_def = execution_context[:step_def]

      # Phase 2: Execute step block (locks released)
      step_execution.logger.debug("Running before step blocks")
      workflow.before_step_starts(step_def.name)

      flow_result = instrument_step_execution(step_execution, workflow, step_def)
      step_execution.logger.info("Finished step with outcome #{flow_result.inspect}")

      # Phase 3: Acquire locks and handle result
      instrument_finalize(step_execution, workflow, flow_result)
    end

    # Executes the step block with instrumentation.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @param step_def [StepDefinition]
    # @return [Symbol, FlowControlSignal, Hash] the execution result
    def instrument_step_execution(step_execution, workflow, step_def)
      payload = instrumentation_payload(step_execution, workflow)
      payload[:step_name] = step_def.name

      ActiveSupport::Notifications.instrument("step.geneva_drive", payload) do |p|
        result = catch(:flow_control) do
          step_def.execute_in_context(workflow)
          :completed
        rescue => e
          step_execution.logger.error("Encountered #{e.class}, cleaning up and re-raising")
          # Don't transition here - just capture the error info
          capture_exception(e, step_def)
        end

        p[:outcome] = case result
        when :completed then :completed
        when GenevaDrive::FlowControlSignal then result.action
        when Hash then :exception
        end
        p[:exception] = result[:error] if result.is_a?(Hash)

        result
      end
    end

    # Finalizes execution with instrumentation.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @param flow_result [Symbol, FlowControlSignal, Hash]
    # @return [void]
    def instrument_finalize(step_execution, workflow, flow_result)
      payload = instrumentation_payload(step_execution, workflow)
      payload[:step_name] = step_execution.step_name

      ActiveSupport::Notifications.instrument("finalize.geneva_drive", payload) do |p|
        finalize_execution(step_execution, workflow, flow_result)

        # Add outcome based on final workflow state after finalization
        p[:workflow_state] = workflow.state
        p[:step_state] = step_execution.state
      end
    end

    # Builds the common instrumentation payload.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @return [Hash]
    def instrumentation_payload(step_execution, workflow)
      {
        execution_id: step_execution.id,
        workflow_id: workflow.id,
        workflow_class: workflow.class.name
      }
    end

    private

    # Phase 1: Validates states and transitions to executing.
    # Returns execution context hash or nil if execution should abort.
    # May raise StepNotDefinedError or PreconditionError after transaction commits.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @return [Hash, nil] execution context or nil to abort
    # @raise [StepNotDefinedError] if step is not defined
    # @raise [PreconditionError] if cancel_if/skip_if raises exception
    def prepare_execution(step_execution, workflow)
      exception_to_raise = nil

      result = with_execution_lock(step_execution, workflow) do
        # Validate step execution can start
        unless step_execution.state == "scheduled"
          step_execution.logger.info("Step execution is in #{step_execution.state.inspect} and can't be stepped, dropping through")

          next nil
        end

        # Validate workflow is in a state that allows execution
        unless %w[ready performing].include?(workflow.state)
          step_execution.logger.info("Workflow is in #{workflow.state.inspect} state and can't be stepped, canceling and dropping through")

          step_execution.update!(
            state: "canceled",
            canceled_at: Time.current,
            finished_at: Time.current,
            outcome: "canceled"
          )
          next nil
        end

        # Check hero exists (unless workflow opts out)
        if workflow.hero.blank? && !workflow.class._may_proceed_without_hero
          step_execution.logger.info("No hero present and this workflow is not set to run without one. Canceling and dropping through")
          transition_step!(step_execution, "canceled", outcome: "canceled")
          transition_workflow!(workflow, "canceled")
          next nil
        end

        # Get step definition (needed for exception handling policy)
        step_def = step_execution.step_definition

        # Check step definition exists
        unless step_def
          error_message = "Step '#{step_execution.step_name}' is not defined in #{workflow.class.name}"
          step_execution.logger.error(error_message)

          step_execution.update!(error_message: error_message)
          transition_step!(step_execution, "failed", outcome: "failed")
          transition_workflow!(workflow, "paused")
          exception_to_raise = GenevaDrive::StepNotDefinedError.new(
            error_message,
            step_execution: step_execution,
            workflow: workflow
          )
          next nil
        end

        # Evaluate preconditions with instrumentation
        precondition_result = instrument_preconditions(step_execution, workflow, step_def)
        if precondition_result[:abort]
          exception_to_raise = precondition_result[:exception]
          next nil
        end

        # All checks passed - transition to in_progress
        step_execution.logger.debug("Step may be performed - changing state flags and proceeding to perform")

        transition_step!(step_execution, "in_progress")
        transition_workflow!(workflow, "performing") if workflow.ready?

        # Set current_step_name to the step being executed,
        # and next_step_name to what comes after
        following_step = workflow.steps.next_after(step_def.name)
        workflow.update!(
          current_step_name: step_def.name,
          next_step_name: following_step&.name
        )

        {step_def: step_def}
      end

      raise exception_to_raise if exception_to_raise
      result
    end

    # Evaluates preconditions (cancel_if and skip_if) with instrumentation.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @param step_def [StepDefinition]
    # @return [Hash] result with :abort and optional :exception keys
    def instrument_preconditions(step_execution, workflow, step_def)
      payload = instrumentation_payload(step_execution, workflow)
      payload[:step_name] = step_def.name

      ActiveSupport::Notifications.instrument("precondition.geneva_drive", payload) do |p|
        # Check blanket cancel_if conditions (with exception handling)
        begin
          step_execution.logger.debug("Evaluating cancel_if conditions")
          if should_cancel_workflow?(workflow)
            step_execution.logger.info("cancel_if condition matched, canceling workflow")
            transition_step!(step_execution, "canceled", outcome: "canceled")
            transition_workflow!(workflow, "canceled")
            p[:outcome] = :canceled
            return {abort: true}
          end
        rescue => e
          step_execution.logger.error("Exception in cancel_if evaluation: #{e.class} - #{e.message}")
          p[:outcome] = :exception
          p[:exception] = e
          return {abort: true, exception: handle_precondition_exception(e, step_def, step_execution, workflow)}
        end

        # Check skip_if condition (with exception handling)
        begin
          step_execution.logger.debug("Evaluating skip_if condition for step")
          if step_def.should_skip?(workflow)
            step_execution.logger.info("skip_if condition matched, skipping step")
            transition_step!(step_execution, "skipped", outcome: "skipped")
            transition_workflow!(workflow, "ready")
            workflow.schedule_next_step!
            p[:outcome] = :skipped
            return {abort: true}
          end
        rescue => e
          step_execution.logger.error("Exception in skip_if evaluation: #{e.class} - #{e.message}")
          p[:outcome] = :exception
          p[:exception] = e
          return {abort: true, exception: handle_precondition_exception(e, step_def, step_execution, workflow)}
        end

        p[:outcome] = :passed
        {abort: false}
      end
    end

    # Phase 3: Handles the execution result and performs final state transitions.
    # Re-raises original exception after the transaction commits.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @param flow_result [Symbol, FlowControlSignal, Hash] the execution result
    # @return [void]
    def finalize_execution(step_execution, workflow, flow_result)
      exception_to_raise = nil

      with_execution_lock(step_execution, workflow) do
        # Verify step is still in_progress (guard against external changes)
        unless step_execution.in_progress?
          step_execution.logger.warn(
            "Step execution #{step_execution.id} state changed during execution: #{step_execution.state}"
          )
          next
        end

        # Verify workflow is still in performing state
        unless workflow.performing?
          step_execution.logger.warn(
            "Workflow #{workflow.id} state unexpectedly changed during execution: #{workflow.state}"
          )
          transition_step!(step_execution, "canceled", outcome: "canceled")
          next
        end

        case flow_result
        when :completed
          handle_completion(step_execution, workflow)
        when GenevaDrive::FlowControlSignal
          handle_flow_control_signal(flow_result, workflow, step_execution)
        when Hash
          # Exception was captured - handle it and capture for re-raising
          exception_to_raise = handle_captured_exception(flow_result, workflow, step_execution)
        end

        # Clear current_step_name - the step is no longer executing
        workflow.update!(current_step_name: nil)
      end

      raise exception_to_raise if exception_to_raise
    end

    # Acquires locks on both step_execution and workflow in a consistent order.
    # Locks are released when the block returns.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @yield block to execute with locks held
    # @return [Object] result of the block
    def with_execution_lock(step_execution, workflow)
      # Lock in consistent order (workflow first) to prevent deadlocks
      # with_lock automatically reloads the record before yielding
      workflow.with_lock do
        step_execution.with_lock do
          yield
        end
      end
    end

    # Transitions step execution to a new state with validation.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param new_state [String]
    # @param outcome [String, nil]
    # @raise [InvalidStateTransition] if transition is not allowed
    # @return [void]
    def transition_step!(step_execution, new_state, outcome: nil)
      current_state = step_execution.state
      allowed = STEP_TRANSITIONS[current_state] || []

      unless allowed.include?(new_state)
        raise GenevaDrive::InvalidStateTransition,
          "Cannot transition step execution from '#{current_state}' to '#{new_state}'"
      end

      outcome_msg = outcome ? " (outcome: #{outcome})" : ""
      step_execution.logger.debug("Step execution state: #{current_state} -> #{new_state}#{outcome_msg}")

      attrs = {state: new_state}
      attrs[:outcome] = outcome if outcome

      case new_state
      when "in_progress"
        attrs[:started_at] = Time.current
      when "completed"
        attrs[:completed_at] = Time.current
        attrs[:finished_at] = Time.current
      when "failed"
        attrs[:failed_at] = Time.current
        attrs[:finished_at] = Time.current
      when "skipped"
        attrs[:skipped_at] = Time.current
        attrs[:finished_at] = Time.current
      when "canceled"
        attrs[:canceled_at] = Time.current
        attrs[:finished_at] = Time.current
      end

      step_execution.update!(attrs)
    end

    # Transitions workflow to a new state with validation.
    # No-op if already in the target state.
    #
    # @param workflow [GenevaDrive::Workflow]
    # @param new_state [String]
    # @raise [InvalidStateTransition] if transition is not allowed
    # @return [void]
    def transition_workflow!(workflow, new_state)
      current_state = workflow.state
      return if current_state == new_state # No-op for same state

      allowed = WORKFLOW_TRANSITIONS[current_state] || []

      unless allowed.include?(new_state)
        raise GenevaDrive::InvalidStateTransition,
          "Cannot transition workflow from '#{current_state}' to '#{new_state}'"
      end

      attrs = {state: new_state}
      if %w[finished canceled paused].include?(new_state)
        attrs[:transitioned_at] = Time.current
      end

      workflow.update!(attrs)
    end

    # Checks if any blanket cancel conditions are true.
    #
    # @param workflow [GenevaDrive::Workflow]
    # @return [Boolean]
    def should_cancel_workflow?(workflow)
      workflow.class._cancel_conditions.any? do |condition|
        evaluate_condition(condition, workflow)
      end
    end

    # Evaluates a condition in the workflow context.
    #
    # @param condition [Symbol, Proc, Object]
    # @param workflow [GenevaDrive::Workflow]
    # @return [Boolean]
    def evaluate_condition(condition, workflow)
      case condition
      when Symbol
        workflow.send(condition)
      when Proc
        workflow.instance_exec(&condition)
      else
        !!condition
      end
    end

    # Captures exception info without performing transitions.
    #
    # @param error [Exception]
    # @param step_def [StepDefinition]
    # @return [Hash] captured exception context
    def capture_exception(error, step_def)
      Rails.error.report(error)
      {
        type: :exception,
        error: error,
        on_exception: step_def.on_exception
      }
    end

    # Handles exceptions that occur during pre-condition evaluation (cancel_if, skip_if).
    # Uses the step's on_exception policy to determine how to handle the exception.
    # Returns the original exception to be re-raised after the transaction commits.
    #
    # @param error [Exception] the exception that occurred
    # @param step_def [StepDefinition] the step definition
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @return [Exception] the original exception to be re-raised
    def handle_precondition_exception(error, step_def, step_execution, workflow)
      step_execution.logger.error("Pre-condition evaluation failed: #{error.class} - #{error.message}")
      Rails.error.report(error)

      on_exception = step_def.on_exception
      step_execution.logger.info("Precondition exception handling with on_exception: #{on_exception.inspect}")

      case on_exception
      when :reattempt!
        step_execution.logger.info("Precondition exception policy: reattempt! - rescheduling step")
        transition_step!(step_execution, "completed", outcome: "reattempted")
        transition_workflow!(workflow, "ready")
        workflow.reschedule_current_step!

      when :cancel!
        step_execution.logger.info("Precondition exception policy: cancel! - canceling workflow")
        step_execution.update!(
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
        transition_step!(step_execution, "failed", outcome: "canceled")
        transition_workflow!(workflow, "canceled")

      when :skip!
        step_execution.logger.info("Precondition exception policy: skip! - skipping to next step")
        transition_step!(step_execution, "skipped", outcome: "skipped")
        transition_workflow!(workflow, "ready")
        workflow.schedule_next_step!

      when :pause!
        step_execution.logger.info("Precondition exception policy: pause! - pausing workflow")
        step_execution.update!(
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
        transition_step!(step_execution, "failed", outcome: "failed")
        transition_workflow!(workflow, "paused")

      else
        # Default: pause
        step_execution.logger.info("Precondition exception policy: default (pause!) - pausing workflow")
        step_execution.update!(
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
        transition_step!(step_execution, "failed", outcome: "failed")
        transition_workflow!(workflow, "paused")
      end

      # Return original exception to be re-raised after transaction commits
      error
    end

    # Handles successful step completion.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @return [void]
    def handle_completion(step_execution, workflow)
      step_execution.logger.info("Step completed successfully, scheduling next step")
      transition_step!(step_execution, "completed", outcome: "success")
      transition_workflow!(workflow, "ready")
      workflow.schedule_next_step!
    end

    # Handles a captured exception based on the step's on_exception configuration.
    # Returns the original exception to be re-raised after the transaction commits.
    #
    # @param context [Hash] captured exception context
    # @param workflow [GenevaDrive::Workflow]
    # @param step_execution [GenevaDrive::StepExecution]
    # @return [Exception] the original exception to be re-raised
    def handle_captured_exception(context, workflow, step_execution)
      error = context[:error]
      on_exception = context[:on_exception]

      step_execution.logger.info("Handling exception with on_exception: #{on_exception.inspect}")

      case on_exception
      when :reattempt!
        step_execution.logger.info("Exception policy: reattempt! - rescheduling step")
        transition_step!(step_execution, "completed", outcome: "reattempted")
        transition_workflow!(workflow, "ready")
        workflow.reschedule_current_step!

      when :cancel!
        step_execution.logger.info("Exception policy: cancel! - canceling workflow")
        step_execution.update!(
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
        transition_step!(step_execution, "failed", outcome: "canceled")
        transition_workflow!(workflow, "canceled")

      when :skip!
        step_execution.logger.info("Exception policy: skip! - skipping to next step")
        transition_step!(step_execution, "skipped", outcome: "skipped")
        transition_workflow!(workflow, "ready")
        workflow.schedule_next_step!

      when :pause!
        step_execution.logger.info("Exception policy: pause! - pausing workflow")
        step_execution.update!(
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
        transition_step!(step_execution, "failed", outcome: "failed")
        transition_workflow!(workflow, "paused")

      else
        # Default: pause
        step_execution.logger.info("Exception policy: default (pause!) - pausing workflow")
        step_execution.update!(
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
        transition_step!(step_execution, "failed", outcome: "failed")
        transition_workflow!(workflow, "paused")
      end

      # Return original exception to be re-raised after transaction commits
      error
    end

    # Handles a flow control signal.
    #
    # @param signal [FlowControlSignal]
    # @param workflow [GenevaDrive::Workflow]
    # @param step_execution [GenevaDrive::StepExecution]
    # @return [void]
    def handle_flow_control_signal(signal, workflow, step_execution)
      step_execution.logger.debug("Handling flow control signal: #{signal.action}")

      case signal.action
      when :cancel
        step_execution.logger.info("Processing cancel signal: canceling workflow")
        transition_step!(step_execution, "canceled", outcome: "canceled")
        transition_workflow!(workflow, "canceled")

      when :pause
        step_execution.logger.info("Processing pause signal: pausing workflow")
        transition_step!(step_execution, "canceled", outcome: "canceled")
        transition_workflow!(workflow, "paused")

      when :reattempt
        wait_msg = signal.options[:wait] ? " after #{signal.options[:wait].inspect}" : ""
        step_execution.logger.info("Processing reattempt signal: rescheduling step#{wait_msg}")
        transition_step!(step_execution, "completed", outcome: "reattempted")
        transition_workflow!(workflow, "ready")
        workflow.reschedule_current_step!(wait: signal.options[:wait])

      when :skip
        step_execution.logger.info("Processing skip signal: scheduling next step")
        transition_step!(step_execution, "skipped", outcome: "skipped")
        transition_workflow!(workflow, "ready")
        workflow.schedule_next_step!

      when :finished
        step_execution.logger.info("Processing finished signal: finishing workflow")
        transition_step!(step_execution, "completed", outcome: "success")
        transition_workflow!(workflow, "finished")
      end
    end
  end
end

# Raised when an invalid state transition is attempted.
class GenevaDrive::InvalidStateTransition < StandardError; end
