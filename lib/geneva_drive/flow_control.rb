# frozen_string_literal: true

module GenevaDrive
  # Signal object used for flow control via throw/catch mechanism.
  # Contains the action to take and any additional options.
  #
  # @api private
  class FlowControlSignal
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
  class InvalidStateError < StandardError; end

  # Module providing flow control methods for use within workflow steps.
  # These methods use throw/catch to interrupt step execution and signal
  # the executor how to proceed.
  #
  # @example Using flow control in a step
  #   step :process_payment do
  #     result = PaymentGateway.charge(hero)
  #     cancel! if result.declined?
  #     skip! if result.already_processed?
  #   end
  module FlowControl
    # Cancels the workflow immediately.
    # The current step is marked as canceled and the workflow transitions to 'canceled' state.
    #
    # @return [void]
    # @raise [UncaughtThrowError] if called outside of step execution context
    def cancel!
      throw :flow_control, FlowControlSignal.new(:cancel)
    end

    # Pauses the workflow for manual intervention.
    # The current step is marked as canceled and the workflow transitions to 'paused' state.
    # Can be resumed later with {Workflow#resume!}.
    #
    # @return [void]
    # @raise [UncaughtThrowError] if called outside of step execution context
    def pause!
      throw :flow_control, FlowControlSignal.new(:pause)
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
      throw :flow_control, FlowControlSignal.new(:reattempt, wait: wait)
    end

    # Skips the current step and proceeds to the next one.
    # The current step is marked as skipped.
    #
    # @return [void]
    # @raise [UncaughtThrowError] if called outside of step execution context
    def skip!
      throw :flow_control, FlowControlSignal.new(:skip)
    end

    # Marks the workflow as finished immediately.
    # Useful for early termination when no further steps are needed.
    #
    # @return [void]
    # @raise [UncaughtThrowError] if called outside of step execution context
    def finished!
      throw :flow_control, FlowControlSignal.new(:finished)
    end
  end
end
