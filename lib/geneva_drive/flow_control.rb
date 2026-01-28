# frozen_string_literal: true

# Signal object used for flow control via throw/catch mechanism.
# Contains the action to take and any additional options.
#
# @api private
class GenevaDrive::FlowControlSignal
  # @return [Symbol] the action to take (:cancel, :pause, :reattempt, :skip, :finished)
  attr_reader :action

  # @return [Hash] additional options for the flow control action
  attr_reader :options

  # Creates a new flow control signal.
  #
  # @param action [Symbol] the flow control action
  # @param options [Hash] additional options (e.g., wait: for reattempt)
  def initialize(action, **options)
    @action = action
    @options = options
  end
end

# Raised when an operation is attempted on a workflow in an invalid state.
#
# @example
#   raise InvalidStateError, "Cannot resume a finished workflow"
class GenevaDrive::InvalidStateError < StandardError; end

# Raised when a step definition has invalid configuration.
#
# @example
#   raise StepConfigurationError, "Step requires either a block or method name"
class GenevaDrive::StepConfigurationError < StandardError; end

# Base class for errors that occur during step execution.
# These errors are raised after recovery actions have been performed,
# so the workflow/step states are already updated when the exception propagates.
#
# @example Rescuing step execution errors
#   begin
#     GenevaDrive::Executor.execute!(step_execution)
#   rescue GenevaDrive::StepExecutionError => e
#     Rails.logger.error("Step failed: #{e.message}")
#     Rails.logger.error("Original error: #{e.cause}")
#   end
class GenevaDrive::StepExecutionError < StandardError
  # @return [GenevaDrive::StepExecution] the step execution that failed
  attr_reader :step_execution

  # @return [GenevaDrive::Workflow] the workflow
  attr_reader :workflow

  # Creates a new StepExecutionError.
  #
  # @param message [String] the error message
  # @param step_execution [GenevaDrive::StepExecution] the step execution
  # @param workflow [GenevaDrive::Workflow] the workflow
  def initialize(message, step_execution:, workflow:)
    @step_execution = step_execution
    @workflow = workflow
    super(message)
  end
end

# Raised when a step execution references a step that doesn't exist in the workflow class.
# This can happen if the workflow class definition changed after the step was scheduled.
class GenevaDrive::StepNotDefinedError < GenevaDrive::StepExecutionError; end

# Raised when an exception occurs during step execution.
# The original exception is available via the standard `cause` method.
class GenevaDrive::StepFailedError < GenevaDrive::StepExecutionError; end

# Raised when an exception occurs during pre-condition evaluation (cancel_if, skip_if).
# The original exception is available via the standard `cause` method.
class GenevaDrive::PreconditionError < GenevaDrive::StepExecutionError; end

# Module providing flow control methods for use within workflow steps.
# These methods use throw/catch to interrupt step execution and signal
# the executor how to proceed.
#
# When called outside of a step execution context (e.g., from a controller),
# pause! and skip! will directly modify the workflow state.
#
# @example Using flow control in a step
#   step :process_payment do
#     result = PaymentGateway.charge(hero)
#     cancel! if result.declined?
#     skip! if result.already_processed?
#   end
#
# @example External flow control
#   workflow = MyWorkflow.find(id)
#   workflow.pause!  # Pauses workflow from outside a step
module GenevaDrive::FlowControl
  # Cancels the workflow immediately.
  # The current step is marked as canceled and the workflow transitions to 'canceled' state.
  #
  # @return [void]
  # @raise [UncaughtThrowError] if called outside of step execution context
  def cancel!
    logger.info("Flow control: cancel! called from step")
    throw :flow_control, GenevaDrive::FlowControlSignal.new(:cancel)
  end

  # Pauses the workflow for manual intervention.
  #
  # When called inside a step (workflow state is 'performing'): interrupts execution via throw/catch.
  # When called outside a step (workflow state is 'ready'): directly pauses the workflow.
  #
  # Can be resumed later with {Workflow#resume!}.
  #
  # @return [void]
  # @raise [InvalidStateError] if called on a non-ready/non-performing workflow
  def pause!
    if state == "performing"
      logger.info("Flow control: pause! called from step")
      throw :flow_control, GenevaDrive::FlowControlSignal.new(:pause)
    else
      external_pause!
    end
  end

  # Reschedules the current step for another attempt.
  # Useful for handling temporary failures or rate limiting.
  #
  # @param wait [ActiveSupport::Duration, nil] optional delay before retry
  # @return [void]
  # @raise [UncaughtThrowError] if called outside of step execution context
  #
  # @example Retry after rate limit
  #   reattempt!(wait: 5.minutes)
  def reattempt!(wait: nil)
    wait_msg = wait ? " with wait #{wait.inspect}" : ""
    logger.info("Flow control: reattempt! called from step#{wait_msg}")
    throw :flow_control, GenevaDrive::FlowControlSignal.new(:reattempt, wait: wait)
  end

  # Skips the current step and proceeds to the next one.
  #
  # When called inside a step (workflow state is 'performing'): interrupts execution via throw/catch.
  # When called outside a step (workflow state is 'ready'): directly skips current step.
  #
  # @return [void]
  # @raise [InvalidStateError] if called on a non-ready/non-performing workflow
  def skip!
    if state == "performing"
      logger.info("Flow control: skip! called from step")
      throw :flow_control, GenevaDrive::FlowControlSignal.new(:skip)
    else
      external_skip!
    end
  end

  # Marks the workflow as finished immediately.
  # Useful for early termination when no further steps are needed.
  #
  # @return [void]
  # @raise [UncaughtThrowError] if called outside of step execution context
  def finished!
    logger.info("Flow control: finished! called from step")
    throw :flow_control, GenevaDrive::FlowControlSignal.new(:finished)
  end

  private

  # Pauses the workflow from outside a step execution.
  # Leaves any scheduled step execution intact (does NOT cancel it).
  #
  # This allows seeing that a step was scheduled, became overdue during pause,
  # and when it actually ran - providing better timeline visibility.
  #
  # @raise [InvalidStateError] if workflow is not in 'ready' state
  # @return [void]
  def external_pause!
    raise GenevaDrive::InvalidStateError, "Cannot pause a #{state} workflow" unless state == "ready"

    logger.info("Pausing workflow (preserving scheduled execution for step #{next_step_name.inspect})")
    with_lock do
      # with_lock reloads automatically; re-check state in case it changed
      raise GenevaDrive::InvalidStateError, "Cannot pause a #{state} workflow" unless state == "ready"

      update!(state: "paused", transitioned_at: Time.current)
    end
    logger.info("Workflow paused")
  end

  # Skips the current step from outside a step execution.
  # Marks step as skipped and schedules next step (or finishes if last).
  #
  # When called on a 'ready' workflow: marks the scheduled step as skipped.
  # When called on a 'paused' workflow: skips the failed step (which caused the pause)
  # and resumes execution with the next step.
  #
  # @raise [InvalidStateError] if workflow is not in 'ready' or 'paused' state
  # @return [void]
  def external_skip!
    unless %w[ready paused].include?(state)
      raise GenevaDrive::InvalidStateError, "Cannot skip on a #{state} workflow"
    end

    logger.info("Flow control: skip! called externally on step #{next_step_name.inspect}")
    with_lock do
      # with_lock reloads automatically; re-check state in case it changed
      unless %w[ready paused].include?(state)
        raise GenevaDrive::InvalidStateError, "Cannot skip on a #{state} workflow"
      end

      if state == "paused"
        # Workflow was paused (e.g., due to failed step). Resume and skip to next step.
        update!(state: "ready", transitioned_at: nil)
      else
        # Workflow is ready with a scheduled step - mark it as skipped
        current_execution&.mark_skipped!(outcome: "skipped")
      end

      schedule_next_step!
    end
  end
end
