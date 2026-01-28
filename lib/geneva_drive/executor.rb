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
class GenevaDrive::Executor
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

  # Executes a step execution with full flow control and exception handling.
  #
  # @param step_execution [GenevaDrive::StepExecution] the step to execute
  # @return [void]
  def self.execute!(step_execution)
    new.call(step_execution)
  end

  # Performs the step execution.
  #
  # @param step_execution [GenevaDrive::StepExecution] the step to execute
  # @return [void]
  def call(step_execution)
    @step_execution = step_execution
    @workflow = step_execution.workflow
    @logger = step_execution.logger
    # Phase 1: Acquire locks, validate, and prepare for execution
    @logger.debug("Preparing execution context")
    step_def = prepare_execution
    return unless step_def

    # Phase 2: Execute step block (locks released)
    @logger.debug("Running before_step_execution hook")
    @workflow.before_step_execution(@step_execution)

    @logger.debug("Running the actual step code")
    flow_result = @workflow.around_step_execution(@step_execution) do
      execute_step(step_def)
    end

    @logger.debug("Running after_step_execution hook")
    @workflow.after_step_execution(@step_execution)

    # Phase 3: Acquire locks and handle result
    @logger.info("Finished step with outcome #{flow_result.inspect}")
    finalize_execution(flow_result)
  end

  private

  attr_reader :step_execution, :workflow, :logger

  # Executes the step block with instrumentation.
  #
  # @param step_def [StepDefinition]
  # @return [Symbol, FlowControlSignal, Hash] the execution result
  def execute_step(step_def)
    payload = instrumentation_payload
    payload[:step_name] = step_def.name

    ActiveSupport::Notifications.instrument("step.geneva_drive", payload) do |p|
      result = catch(:flow_control) do
        step_def.execute_in_context(workflow)
        :completed
      rescue => e
        logger.error("Encountered #{e.class}, cleaning up and re-raising")
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
  # @param flow_result [Symbol, FlowControlSignal, Hash]
  # @return [void]
  def finalize_execution(flow_result)
    payload = instrumentation_payload
    payload[:step_name] = step_execution.step_name

    ActiveSupport::Notifications.instrument("finalize.geneva_drive", payload) do |p|
      finalize_with_lock(flow_result)

      # Add outcome based on final workflow state after finalization
      p[:workflow_state] = workflow.state
      p[:step_state] = step_execution.state
    end
  end

  # Builds the common instrumentation payload.
  #
  # @return [Hash]
  def instrumentation_payload
    {
      execution_id: step_execution.id,
      workflow_id: workflow.id,
      workflow_class: workflow.class.name
    }
  end

  # Phase 1: Validates states and transitions to executing.
  # Returns step definition or nil if execution should abort.
  # May raise StepNotDefinedError or PreconditionError after transaction commits.
  #
  # @return [StepDefinition, nil] step definition or nil to abort
  # @raise [StepNotDefinedError] if step is not defined
  # @raise [PreconditionError] if cancel_if/skip_if raises exception
  def prepare_execution
    exception_to_raise = nil

    result = with_execution_lock do
      begin
        # Validate step execution can start
        unless step_execution.state == "scheduled"
          logger.info("Step execution is in #{step_execution.state.inspect} and can't be stepped, dropping through")

          next nil
        end

        # Validate workflow is in a state that allows execution
        unless %w[ready performing].include?(workflow.state)
          logger.info("Workflow is in #{workflow.state.inspect} state and can't be stepped, canceling and dropping through")

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
          logger.info("No hero present and this workflow is not set to run without one. Canceling and dropping through")
          transition_step!("canceled", outcome: "canceled")
          transition_workflow!("canceled")
          next nil
        end

        # Get step definition (needed for exception handling policy)
        step_def = step_execution.step_definition

        # Check step definition exists
        unless step_def
          error_message = "Step '#{step_execution.step_name}' is not defined in #{workflow.class.name}"
          logger.error(error_message)

          step_execution.update!(error_message: error_message)
          transition_step!("failed", outcome: "failed")
          transition_workflow!("paused")
          exception_to_raise = GenevaDrive::StepNotDefinedError.new(
            error_message,
            step_execution: step_execution,
            workflow: workflow
          )
          next nil
        end

        # Evaluate preconditions with instrumentation
        precondition_result = evaluate_preconditions(step_def)
        if precondition_result[:abort]
          exception_to_raise = precondition_result[:exception]
          next nil
        end

        # All checks passed - transition to in_progress
        logger.debug("Step may be performed - changing state flags and proceeding to perform")

        transition_step!("in_progress")
        transition_workflow!("performing") if workflow.ready?

        # Set current_step_name to the step being executed.
        # Don't advance next_step_name here - it already points to this step
        # (set by create_step_execution). We only advance it after successful
        # completion, so that resume! on a failed step will retry it.
        workflow.update!(current_step_name: step_def.name)

        step_def
      rescue StandardError => e
        exception_to_raise = handle_prepare_exception(e)
        nil
      end
    end

    raise exception_to_raise if exception_to_raise
    result
  end

  # Evaluates preconditions (cancel_if and skip_if) with instrumentation.
  #
  # @param step_def [StepDefinition]
  # @return [Hash] result with :abort and optional :exception keys
  def evaluate_preconditions(step_def)
    payload = instrumentation_payload
    payload[:step_name] = step_def.name

    ActiveSupport::Notifications.instrument("precondition.geneva_drive", payload) do |p|
      # Check blanket cancel_if conditions (with exception handling)
      begin
        logger.debug("Evaluating cancel_if conditions")
        if should_cancel_workflow?
          logger.info("cancel_if condition matched, canceling workflow")
          transition_step!("canceled", outcome: "canceled")
          transition_workflow!("canceled")
          p[:outcome] = :canceled
          return {abort: true}
        end
      rescue => e
        logger.error("Exception in cancel_if evaluation: #{e.class} - #{e.message}")
        p[:outcome] = :exception
        p[:exception] = e
        return {abort: true, exception: handle_precondition_exception(e, step_def)}
      end

      # Check skip_if condition (with exception handling)
      begin
        logger.debug("Evaluating skip_if condition for step")
        if step_def.should_skip?(workflow)
          logger.info("skip_if condition matched, skipping step")
          transition_step!("skipped", outcome: "skipped")
          transition_workflow!("ready")
          workflow.schedule_next_step!
          p[:outcome] = :skipped
          return {abort: true}
        end
      rescue => e
        logger.error("Exception in skip_if evaluation: #{e.class} - #{e.message}")
        p[:outcome] = :exception
        p[:exception] = e
        return {abort: true, exception: handle_precondition_exception(e, step_def)}
      end

      p[:outcome] = :passed
      {abort: false}
    end
  end

  # Phase 3: Handles the execution result and performs final state transitions.
  # Re-raises original exception after the transaction commits.
  #
  # @param flow_result [Symbol, FlowControlSignal, Hash] the execution result
  # @return [void]
  def finalize_with_lock(flow_result)
    exception_to_raise = nil

    with_execution_lock do
      # Verify step is still in_progress (guard against external changes)
      unless step_execution.in_progress?
        logger.warn(
          "Step execution #{step_execution.id} state changed during execution: #{step_execution.state}"
        )
        next
      end

      # Verify workflow is still in performing state
      unless workflow.performing?
        logger.warn(
          "Workflow #{workflow.id} state unexpectedly changed during execution: #{workflow.state}"
        )
        transition_step!("canceled", outcome: "canceled")
        next
      end

      case flow_result
      when :completed
        handle_completion
      when GenevaDrive::FlowControlSignal
        handle_flow_control_signal(flow_result)
      when Hash
        # Exception was captured - handle it and capture for re-raising
        exception_to_raise = handle_captured_exception(flow_result)
      end

      # Clear current_step_name - the step is no longer executing
      workflow.update!(current_step_name: nil)
    end

    raise exception_to_raise if exception_to_raise
  end

  # Acquires locks on both step_execution and workflow in a consistent order.
  # Locks are released when the block returns.
  #
  # @yield block to execute with locks held
  # @return [Object] result of the block
  def with_execution_lock
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
  # @param new_state [String]
  # @param outcome [String, nil]
  # @raise [InvalidStateTransition] if transition is not allowed
  # @return [void]
  def transition_step!(new_state, outcome: nil)
    current_state = step_execution.state
    allowed = STEP_TRANSITIONS[current_state] || []

    unless allowed.include?(new_state)
      raise GenevaDrive::InvalidStateTransition,
        "Cannot transition step execution from '#{current_state}' to '#{new_state}'"
    end

    outcome_msg = outcome ? " (outcome: #{outcome})" : ""
    logger.debug("Step execution state: #{current_state} -> #{new_state}#{outcome_msg}")

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
  # @param new_state [String]
  # @raise [InvalidStateTransition] if transition is not allowed
  # @return [void]
  def transition_workflow!(new_state)
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
  # @return [Boolean]
  def should_cancel_workflow?
    workflow.class._cancel_conditions.any? do |condition|
      evaluate_condition(condition)
    end
  end

  # Evaluates a condition in the workflow context.
  #
  # @param condition [Symbol, Proc, Object]
  # @return [Boolean]
  def evaluate_condition(condition)
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
      step_def: step_def,
      on_exception: step_def.on_exception
    }
  end

  # Handles exceptions that occur during pre-condition evaluation (cancel_if, skip_if).
  # Uses the step's on_exception policy to determine how to handle the exception.
  # Returns the original exception to be re-raised after the transaction commits.
  #
  # @param error [Exception] the exception that occurred
  # @param step_def [StepDefinition] the step definition
  # @return [Exception] the original exception to be re-raised
  def handle_precondition_exception(error, step_def)
    logger.error("Pre-condition evaluation failed: #{error.class} - #{error.message}")
    Rails.error.report(error)

    on_exception = step_def.on_exception
    logger.info("Precondition exception handling with on_exception: #{on_exception.inspect}")

    case on_exception
    when :reattempt!
      if reattempt_limit_exceeded?(step_def)
        logger.warn("Max reattempts (#{step_def.max_reattempts}) exceeded - pausing workflow instead")
        step_execution.update!(error_attributes_for(error))
        transition_step!("failed", outcome: "failed")
        transition_workflow!("paused")
      else
        logger.info("Precondition exception policy: reattempt! - rescheduling step")
        transition_step!("completed", outcome: "reattempted")
        transition_workflow!("ready")
        workflow.reschedule_current_step!
      end

    when :cancel!
      logger.info("Precondition exception policy: cancel! - canceling workflow")
      step_execution.update!(error_attributes_for(error))
      transition_step!("failed", outcome: "canceled")
      transition_workflow!("canceled")

    when :skip!
      logger.info("Precondition exception policy: skip! - skipping to next step")
      transition_step!("skipped", outcome: "skipped")
      transition_workflow!("ready")
      workflow.schedule_next_step!

    when :pause!
      logger.info("Precondition exception policy: pause! - pausing workflow")
      step_execution.update!(error_attributes_for(error))
      transition_step!("failed", outcome: "failed")
      transition_workflow!("paused")

    else
      # Default: pause
      logger.info("Precondition exception policy: default (pause!) - pausing workflow")
      step_execution.update!(error_attributes_for(error))
      transition_step!("failed", outcome: "failed")
      transition_workflow!("paused")
    end

    # Return original exception to be re-raised after transaction commits
    error
  end

  # Handles unexpected exceptions that occur during prepare_execution before
  # the step actually runs (e.g., NameError when hero_type references a
  # non-existent class). Uses the step's on_exception policy if available,
  # otherwise defaults to :pause!.
  # Returns the original exception to be re-raised after the transaction commits.
  #
  # @param error [Exception] the exception that occurred
  # @return [Exception] the original exception to be re-raised
  def handle_prepare_exception(error)
    logger.error("Unexpected exception during prepare_execution: #{error.class} - #{error.message}")
    Rails.error.report(error)

    # Try to get step_def for on_exception policy, but it may not be available yet
    step_def = begin
      step_execution.step_definition
    rescue
      nil
    end
    on_exception = step_def&.on_exception || :pause!

    logger.info("Prepare exception handling with on_exception: #{on_exception.inspect}")

    step_execution.update!(error_attributes_for(error))
    transition_step!("failed", outcome: "failed")

    case on_exception
    when :reattempt!
      if step_def && reattempt_limit_exceeded?(step_def)
        logger.warn("Max reattempts (#{step_def.max_reattempts}) exceeded - pausing workflow instead")
        transition_workflow!("paused")
      else
        logger.info("Prepare exception policy: reattempt! - rescheduling step")
        transition_workflow!("ready")
        workflow.reschedule_current_step!
      end

    when :cancel!
      logger.info("Prepare exception policy: cancel! - canceling workflow")
      transition_workflow!("canceled")

    when :skip!
      logger.info("Prepare exception policy: skip! - skipping to next step")
      transition_workflow!("ready")
      workflow.schedule_next_step!

    when :pause!
      logger.info("Prepare exception policy: pause! - pausing workflow")
      transition_workflow!("paused")

    else
      # Default: pause
      logger.info("Prepare exception policy: default (pause!) - pausing workflow")
      transition_workflow!("paused")
    end

    # Return original exception to be re-raised after transaction commits
    error
  end

  # Handles successful step completion.
  #
  # @return [void]
  def handle_completion
    logger.info("Step completed successfully, scheduling next step")
    transition_step!("completed", outcome: "success")
    transition_workflow!("ready")
    workflow.schedule_next_step!
  end

  # Handles a captured exception based on the step's on_exception configuration.
  # Returns the original exception to be re-raised after the transaction commits.
  #
  # @param context [Hash] captured exception context
  # @return [Exception] the original exception to be re-raised
  def handle_captured_exception(context)
    error = context[:error]
    step_def = context[:step_def]
    on_exception = context[:on_exception]

    logger.info("Handling exception with on_exception: #{on_exception.inspect}")

    case on_exception
    when :reattempt!
      if reattempt_limit_exceeded?(step_def)
        logger.warn("Max reattempts (#{step_def.max_reattempts}) exceeded - pausing workflow instead")
        step_execution.update!(error_attributes_for(error))
        transition_step!("failed", outcome: "failed")
        transition_workflow!("paused")
      else
        logger.info("Exception policy: reattempt! - rescheduling step")
        transition_step!("completed", outcome: "reattempted")
        transition_workflow!("ready")
        workflow.reschedule_current_step!
      end

    when :cancel!
      logger.info("Exception policy: cancel! - canceling workflow")
      step_execution.update!(error_attributes_for(error))
      transition_step!("failed", outcome: "canceled")
      transition_workflow!("canceled")

    when :skip!
      logger.info("Exception policy: skip! - skipping to next step")
      transition_step!("skipped", outcome: "skipped")
      transition_workflow!("ready")
      workflow.schedule_next_step!

    when :pause!
      logger.info("Exception policy: pause! - pausing workflow")
      step_execution.update!(error_attributes_for(error))
      transition_step!("failed", outcome: "failed")
      transition_workflow!("paused")

    else
      # Default: pause
      logger.info("Exception policy: default (pause!) - pausing workflow")
      step_execution.update!(error_attributes_for(error))
      transition_step!("failed", outcome: "failed")
      transition_workflow!("paused")
    end

    # Return original exception to be re-raised after transaction commits
    error
  end

  # Builds the attributes hash for storing error information on a step execution.
  # Conditionally includes error_class_name if the column exists (migration may not have run yet).
  #
  # @param error [Exception]
  # @return [Hash]
  def error_attributes_for(error)
    attrs = {
      error_message: error.message,
      error_backtrace: error.backtrace&.join("\n")
    }
    attrs[:error_class_name] = error.class.name if step_execution.has_attribute?(:error_class_name)
    attrs
  end

  # Counts consecutive reattempts for the current step since the last successful execution.
  # This is used to enforce the max_reattempts limit.
  #
  # @param step_name [String] the step name to count reattempts for
  # @return [Integer] the number of consecutive reattempts
  def consecutive_reattempt_count(step_name)
    # Find the most recent non-reattempt completion for this step
    # (success, skipped, canceled, failed - anything that isn't a reattempt)
    last_non_reattempt_id = workflow.step_executions
      .where(step_name: step_name, state: "completed")
      .where.not(outcome: "reattempted")
      .order(created_at: :desc)
      .pick(:id)

    # Count reattempts after that point (or all reattempts if no prior success)
    scope = workflow.step_executions.where(step_name: step_name, outcome: "reattempted")
    scope = scope.where("id > ?", last_non_reattempt_id) if last_non_reattempt_id
    scope.count
  end

  # Checks if the max reattempts limit has been exceeded for the current step.
  # Returns true if we should fall back to :pause! instead of reattempting.
  #
  # @param step_def [StepDefinition] the step definition
  # @return [Boolean] true if limit exceeded, false otherwise
  def reattempt_limit_exceeded?(step_def)
    max_reattempts = step_def.max_reattempts
    return false if max_reattempts.nil? # Limit disabled

    count = consecutive_reattempt_count(step_def.name)
    count >= max_reattempts
  end

  # Handles a flow control signal.
  #
  # @param signal [FlowControlSignal]
  # @return [void]
  def handle_flow_control_signal(signal)
    logger.debug("Handling flow control signal: #{signal.action}")

    case signal.action
    when :cancel
      logger.info("Processing cancel signal: canceling workflow")
      transition_step!("canceled", outcome: "canceled")
      transition_workflow!("canceled")

    when :pause
      logger.info("Processing pause signal: pausing workflow")
      transition_step!("canceled", outcome: "canceled")
      transition_workflow!("paused")

    when :reattempt
      wait_msg = signal.options[:wait] ? " after #{signal.options[:wait].inspect}" : ""
      logger.info("Processing reattempt signal: rescheduling step#{wait_msg}")
      transition_step!("completed", outcome: "reattempted")
      transition_workflow!("ready")
      workflow.reschedule_current_step!(wait: signal.options[:wait])

    when :skip
      logger.info("Processing skip signal: scheduling next step")
      transition_step!("skipped", outcome: "skipped")
      transition_workflow!("ready")
      workflow.schedule_next_step!

    when :finished
      logger.info("Processing finished signal: finishing workflow")
      transition_step!("completed", outcome: "success")
      transition_workflow!("finished")
    end
  end
end

# Raised when an invalid state transition is attempted.
class GenevaDrive::InvalidStateTransition < StandardError; end
