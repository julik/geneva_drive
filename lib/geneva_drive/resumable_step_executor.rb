# frozen_string_literal: true

# Executes resumable steps with cursor-based iteration support.
# Handles suspend/resume semantics and interruption conditions.
#
# Resumable steps can be interrupted and resumed across job executions,
# maintaining their cursor position in the database.
#
# @api private
class GenevaDrive::ResumableStepExecutor
  # Valid state transitions for resumable step executions
  STEP_TRANSITIONS = {
    "scheduled" => %w[in_progress canceled skipped failed completed],
    "in_progress" => %w[completed failed canceled skipped]
  }.freeze

  # Valid state transitions for workflows
  WORKFLOW_TRANSITIONS = {
    "ready" => %w[performing canceled paused finished],
    "performing" => %w[ready canceled paused finished]
  }.freeze

  # Executes a resumable step execution.
  #
  # @param step_execution [GenevaDrive::StepExecution] the step to execute
  # @param interrupt_configuration [InterruptConfiguration] controls interruption behavior
  # @return [void]
  def self.execute!(step_execution, interrupt_configuration: GenevaDrive::InterruptConfiguration.default)
    new.call(step_execution, interrupt_configuration: interrupt_configuration)
  end

  # Performs the resumable step execution.
  #
  # @param step_execution [GenevaDrive::StepExecution] the step to execute
  # @param interrupt_configuration [InterruptConfiguration] controls interruption behavior
  # @return [void]
  def call(step_execution, interrupt_configuration: GenevaDrive::InterruptConfiguration.default)
    @step_execution = step_execution
    @workflow = step_execution.workflow
    @logger = step_execution.logger
    @interrupt_configuration = interrupt_configuration
    @start_time = nil

    # Phase 1: Acquire locks, validate, and prepare for execution
    @logger.debug("Preparing resumable execution context")
    step_def = prepare_execution
    return unless step_def

    @step_definition = step_def
    @start_time = Time.current

    # Phase 2: Execute step block with IterableStep (locks released)
    @logger.debug("Running before_step_execution hook")
    @workflow.before_step_execution(@step_execution)

    @logger.debug("Running resumable step code")
    flow_result = @workflow.around_step_execution(@step_execution) do
      execute_resumable_step(step_def)
    end

    @logger.debug("Running after_step_execution hook")
    @workflow.after_step_execution(@step_execution)

    # Phase 3: Acquire locks and handle result
    @logger.info("Finished resumable step with result #{flow_result.inspect}")
    finalize_execution(flow_result)
  end

  # Checks if the step should be interrupted.
  # Called by IterableStep during checkpoint.
  #
  # @return [Boolean]
  def should_interrupt?
    # If interruption is disabled (e.g., in tests), never interrupt
    return false unless @interrupt_configuration.respects_interruptions?

    return true if max_runtime_exceeded?
    return true if job_should_exit?
    return true if workflow_interrupted?
    false
  end

  private

  attr_reader :step_execution, :workflow, :logger, :step_definition, :start_time

  # Executes the resumable step block with an IterableStep.
  #
  # @param step_def [ResumableStepDefinition]
  # @return [Symbol, ActiveSupport::Duration, Numeric, Hash] the execution result
  def execute_resumable_step(step_def)
    payload = instrumentation_payload
    payload[:step_name] = step_def.name

    ActiveSupport::Notifications.instrument("step.geneva_drive", payload) do |p|
      iter = GenevaDrive::IterableStep.new(
        step_def.name,
        step_execution.cursor_value,
        execution: step_execution,
        resumed: step_execution.resuming?,
        interrupter: self
      )

      # catch(:interrupt) returns:
      # - :completed if block finishes normally
      # - nil if throw :interrupt (immediate re-enqueue)
      # - Duration/Numeric if throw :interrupt, wait (delayed re-enqueue)
      result = catch(:interrupt) do
        catch(:flow_control) do
          step_def.execute_in_context(workflow, iter)
          :completed
        rescue => e
          logger.error("Encountered #{e.class} in resumable step, capturing")
          capture_exception(e, step_def)
        end
      end

      # Handle flow control signals first
      if result.is_a?(GenevaDrive::FlowControlSignal)
        p[:outcome] = result.action
        return result
      end

      # Handle exceptions
      if result.is_a?(Hash) && result[:type] == :exception
        p[:outcome] = :exception
        p[:exception] = result[:error]
        return result
      end

      # Handle interrupt vs completion
      case result
      when :completed
        p[:outcome] = :completed
      when ActiveSupport::Duration, Numeric
        p[:outcome] = :interrupted
        p[:wait] = result
      when nil
        p[:outcome] = :interrupted
      end

      result
    end
  end

  # Finalizes execution with instrumentation.
  #
  # @param flow_result [Symbol, ActiveSupport::Duration, Numeric, FlowControlSignal, Hash]
  # @return [void]
  def finalize_execution(flow_result)
    payload = instrumentation_payload
    payload[:step_name] = step_execution.step_name

    ActiveSupport::Notifications.instrument("finalize.geneva_drive", payload) do |p|
      finalize_with_lock(flow_result)

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
      workflow_class: workflow.class.name,
      resumable: true
    }
  end

  # Phase 1: Validates states and transitions to in_progress.
  # Returns step definition or nil if execution should abort.
  #
  # @return [ResumableStepDefinition, nil] step definition or nil to abort
  def prepare_execution
    exception_to_raise = nil

    result = with_execution_lock do
      # Validate step execution can start
      unless step_execution.scheduled?
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

      # Get step definition
      step_def = step_execution.step_definition

      # Verify it's a resumable step
      unless step_def.is_a?(GenevaDrive::ResumableStepDefinition)
        logger.error("Step '#{step_execution.step_name}' is not a resumable step")
        transition_step!("failed", outcome: "failed")
        transition_workflow!("paused")
        next nil
      end

      # Evaluate preconditions (only on first run, not resume)
      unless step_execution.resuming?
        precondition_result = evaluate_preconditions(step_def)
        if precondition_result[:abort]
          exception_to_raise = precondition_result[:exception]
          next nil
        end
      end

      # All checks passed - transition to in_progress
      logger.debug("Resumable step may be performed - transitioning to in_progress")

      transition_step!("in_progress")
      transition_workflow!("performing") if workflow.ready?

      # Set current_step_name to the step being executed
      following_step = workflow.steps.next_after(step_def.name)
      workflow.update!(
        current_step_name: step_def.name,
        next_step_name: following_step&.name
      )

      logger.info("Resuming from cursor: #{step_execution.cursor_value.inspect}") if step_execution.resuming?

      step_def
    end

    raise exception_to_raise if exception_to_raise
    result
  end

  # Evaluates preconditions (cancel_if and skip_if).
  #
  # @param step_def [ResumableStepDefinition]
  # @return [Hash] result with :abort and optional :exception keys
  def evaluate_preconditions(step_def)
    # Check blanket cancel_if conditions
    begin
      logger.debug("Evaluating cancel_if conditions")
      if should_cancel_workflow?
        logger.info("cancel_if condition matched, canceling workflow")
        transition_step!("canceled", outcome: "canceled")
        transition_workflow!("canceled")
        return {abort: true}
      end
    rescue => e
      logger.error("Exception in cancel_if evaluation: #{e.class} - #{e.message}")
      return {abort: true, exception: handle_precondition_exception(e, step_def)}
    end

    # Check skip_if condition
    begin
      logger.debug("Evaluating skip_if condition for step")
      if step_def.should_skip?(workflow)
        logger.info("skip_if condition matched, skipping step")
        transition_step!("skipped", outcome: "skipped")
        transition_workflow!("ready")
        workflow.schedule_next_step!
        return {abort: true}
      end
    rescue => e
      logger.error("Exception in skip_if evaluation: #{e.class} - #{e.message}")
      return {abort: true, exception: handle_precondition_exception(e, step_def)}
    end

    {abort: false}
  end

  # Phase 3: Handles the execution result and performs final state transitions.
  #
  # @param flow_result [Symbol, ActiveSupport::Duration, Numeric, FlowControlSignal, Hash]
  # @return [void]
  def finalize_with_lock(flow_result)
    exception_to_raise = nil

    with_execution_lock do
      # Verify step is still in_progress
      unless step_execution.in_progress?
        logger.warn("Step execution state changed during execution: #{step_execution.state}")
        next
      end

      # Verify workflow is still in performing state
      unless workflow.performing?
        logger.warn("Workflow state unexpectedly changed during execution: #{workflow.state}")
        transition_step!("canceled", outcome: "canceled")
        next
      end

      case flow_result
      when :completed
        handle_completion
      when ActiveSupport::Duration, Numeric
        handle_suspension(wait: flow_result)
      when nil
        handle_suspension
      when GenevaDrive::FlowControlSignal
        handle_flow_control_signal(flow_result)
      when Hash
        exception_to_raise = handle_captured_exception(flow_result)
      end

      # Clear current_step_name
      workflow.update!(current_step_name: nil)
    end

    raise exception_to_raise if exception_to_raise
  end

  # Acquires locks on both step_execution and workflow in a consistent order.
  #
  # @yield block to execute with locks held
  # @return [Object] result of the block
  def with_execution_lock
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
      attrs[:started_at] ||= Time.current
    when "completed"
      attrs[:completed_at] = Time.current
      attrs[:finished_at] = Time.current
      # Keep cursor for historical record (shows where execution ended)
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
  #
  # @param new_state [String]
  # @return [void]
  def transition_workflow!(new_state)
    current_state = workflow.state
    return if current_state == new_state

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
  # @param step_def [ResumableStepDefinition]
  # @return [Hash] captured exception context
  def capture_exception(error, step_def)
    Rails.error.report(error)
    {
      type: :exception,
      error: error,
      on_exception: step_def.on_exception
    }
  end

  # Handles exceptions that occur during pre-condition evaluation.
  #
  # @param error [Exception] the exception that occurred
  # @param step_def [ResumableStepDefinition] the step definition
  # @return [Exception] the original exception to be re-raised
  def handle_precondition_exception(error, step_def)
    logger.error("Pre-condition evaluation failed: #{error.class} - #{error.message}")
    Rails.error.report(error)

    on_exception = step_def.on_exception
    logger.info("Precondition exception handling with on_exception: #{on_exception.inspect}")

    case on_exception
    when :reattempt!
      transition_step!("completed", outcome: "reattempted")
      transition_workflow!("ready")
      create_successor_execution!
    when :cancel!
      step_execution.update!(
        error_message: error.message,
        error_backtrace: error.backtrace&.join("\n")
      )
      transition_step!("failed", outcome: "canceled")
      transition_workflow!("canceled")
    when :skip!
      transition_step!("skipped", outcome: "skipped")
      transition_workflow!("ready")
      workflow.schedule_next_step!
    else
      step_execution.update!(
        error_message: error.message,
        error_backtrace: error.backtrace&.join("\n")
      )
      transition_step!("failed", outcome: "failed")
      transition_workflow!("paused")
    end

    error
  end

  # Handles successful step completion.
  #
  # @return [void]
  def handle_completion
    logger.info("Resumable step completed successfully, scheduling next step")
    transition_step!("completed", outcome: "success")
    transition_workflow!("ready")
    workflow.schedule_next_step!
  end

  # Handles step suspension by completing current execution and creating a successor.
  #
  # @param wait [ActiveSupport::Duration, Numeric, nil] optional delay before re-enqueue
  # @return [void]
  def handle_suspension(wait: nil)
    wait_msg = wait ? " (re-enqueue after #{wait.inspect})" : ""
    logger.info("Resumable step suspended at cursor #{step_execution.cursor_value.inspect}#{wait_msg}")

    # Complete current execution
    transition_step!("completed", outcome: "success")
    transition_workflow!("ready")

    # Create successor execution to continue from the cursor
    create_successor_execution!(wait: wait)
  end

  # Handles a captured exception based on the step's on_exception configuration.
  #
  # @param context [Hash] captured exception context
  # @return [Exception] the original exception to be re-raised
  def handle_captured_exception(context)
    error = context[:error]
    on_exception = context[:on_exception]

    logger.info("Handling exception with on_exception: #{on_exception.inspect}")

    case on_exception
    when :reattempt!
      # For resumable steps, reattempt continues from cursor via successor
      logger.info("Exception policy: reattempt! - completing and creating successor")
      transition_step!("completed", outcome: "reattempted")
      transition_workflow!("ready")
      create_successor_execution!
    when :cancel!
      step_execution.update!(
        error_message: error.message,
        error_backtrace: error.backtrace&.join("\n")
      )
      transition_step!("failed", outcome: "canceled")
      transition_workflow!("canceled")
    when :skip!
      transition_step!("skipped", outcome: "skipped")
      transition_workflow!("ready")
      workflow.schedule_next_step!
    else
      step_execution.update!(
        error_message: error.message,
        error_backtrace: error.backtrace&.join("\n")
      )
      transition_step!("failed", outcome: "failed")
      transition_workflow!("paused")
    end

    error
  end

  # Handles a flow control signal.
  #
  # @param signal [FlowControlSignal]
  # @return [void]
  def handle_flow_control_signal(signal)
    logger.debug("Handling flow control signal: #{signal.action}")

    case signal.action
    when :cancel
      transition_step!("canceled", outcome: "canceled")
      transition_workflow!("canceled")
    when :pause
      # Complete this execution, workflow will schedule new execution on resume
      transition_step!("completed", outcome: "workflow_paused")
      transition_workflow!("paused")
    when :reattempt
      # Check for rewind option
      if signal.options[:rewind]
        logger.info("Rewinding cursor for reattempt")
        step_execution.update!(cursor: nil)
      end
      wait = signal.options[:wait]
      transition_step!("completed", outcome: "reattempted")
      transition_workflow!("ready")
      create_successor_execution!(wait: wait)
    when :skip
      transition_step!("skipped", outcome: "skipped")
      transition_workflow!("ready")
      workflow.schedule_next_step!
    when :finished
      transition_step!("completed", outcome: "success")
      transition_workflow!("finished")
    when :suspend
      # Explicit suspend signal - complete and create successor
      wait = signal.options[:wait]
      transition_step!("completed", outcome: "success")
      transition_workflow!("ready")
      create_successor_execution!(wait: wait)
    end
  end

  # Creates a successor step execution to continue from the current cursor.
  #
  # @param wait [ActiveSupport::Duration, Numeric, nil] optional delay
  # @return [void]
  def create_successor_execution!(wait: nil)
    scheduled_for = wait ? wait.from_now : Time.current

    # Create successor execution that continues from this one
    successor = GenevaDrive::StepExecution.create!(
      workflow: workflow,
      step_name: step_execution.step_name,
      state: "scheduled",
      scheduled_for: scheduled_for,
      continues_from_id: step_execution.id,
      cursor: step_execution.cursor  # Copy the handoff cursor
    )

    job_options = workflow.class._step_job_options.dup
    job_options[:wait_until] = scheduled_for if wait

    successor_id = successor.id
    workflow_logger = logger

    ActiveRecord.after_all_transactions_commit do
      job = GenevaDrive::PerformStepJob
        .set(**job_options)
        .perform_later(successor_id)

      workflow_logger.debug("Enqueued PerformStepJob with job_id=#{job.job_id} for successor execution ##{successor_id}")

      GenevaDrive::StepExecution
        .where(id: successor_id)
        .update_all(job_id: job.job_id)
    end
  end

  # Checks if max runtime has been exceeded.
  #
  # @return [Boolean]
  def max_runtime_exceeded?
    return false unless step_definition&.max_runtime
    return false unless start_time
    Time.current - start_time > step_definition.max_runtime
  end

  # Checks if the job should exit (e.g., Sidekiq shutdown).
  #
  # @return [Boolean]
  def job_should_exit?
    Thread.current[:geneva_drive_should_exit] ||
      (defined?(Sidekiq) && Sidekiq.const_defined?(:CLI) &&
       Sidekiq::CLI.instance&.stopping?)
  end

  # Checks if workflow has been externally paused or canceled.
  #
  # @return [Boolean]
  def workflow_interrupted?
    workflow.reload
    workflow.paused? || workflow.canceled?
  end
end
