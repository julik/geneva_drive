# frozen_string_literal: true

# The ORM-independent logic of a step execution record, shared by
# {GenevaDrive::StepExecution} (ActiveRecord) and
# {GenevaDrive::MongoidStepExecution} (Mongoid): state transitions, cursor
# serialization, step definition resolution and logging.
#
# Persistence-specific pieces are template methods each backend implements:
#
# - +.encode_cursor+ / +#raw_cursor_for_deserialization+ - how the serialized
#   cursor is stored and read back
# - +.resumable_columns?+ / +.signal_columns?+ / +.error_class_name_column?+ -
#   schema availability (always true on schemaless backends)
# - +#with_lock+ - the row/document lock
#
# @api private
module GenevaDrive::StepExecutionBehavior
  extend ActiveSupport::Concern

  # Outcome values for audit purposes
  OUTCOMES = %w[
    success
    continued
    reattempted
    skipped
    canceled
    failed
    recovered
    workflow_paused
  ].freeze

  included do
    # Validations
    validates :step_name, presence: true
    validates :scheduled_for, presence: true
    validates :outcome, inclusion: {in: OUTCOMES}, allow_nil: true
  end

  class_methods do
    # Serializes a cursor value using ActiveJob serializers (handles Date,
    # Time, and other types) and enforces GenevaDrive.max_cursor_size on
    # the serialized JSON. The single serialization path for cursor writes.
    #
    # @param value [Object, nil] the cursor value
    # @return [Object, nil] the serialized cursor
    # @raise [CursorTooLargeError] if the serialized JSON exceeds the limit
    def serialize_cursor(value)
      return nil if value.nil?

      serialized = ActiveJob::Arguments.serialize([value]).first

      limit = GenevaDrive.max_cursor_size
      if limit
        bytesize = JSON.generate(serialized).bytesize
        if bytesize > limit
          raise GenevaDrive::CursorTooLargeError,
            "Serialized cursor is #{bytesize} bytes, exceeding GenevaDrive.max_cursor_size " \
            "(#{limit} bytes). The cursor is a position marker (an id, page number, or token), " \
            "not a place to store the data being processed. Set GenevaDrive.max_cursor_size to " \
            "nil to disable this check."
        end
      end

      encode_cursor(serialized)
    end
  end

  # Transitions the step execution to 'in_progress' state.
  # Uses pessimistic locking to prevent double execution.
  #
  # @return [Boolean] true if transition succeeded, false if already executed
  def start!
    # No `return` inside the lock: on MongoDB a non-local exit out of the
    # lock transaction aborts it instead of committing.
    took_it = with_lock do
      if scheduled?
        update!(
          state: "in_progress",
          started_at: Time.current
        )
        true
      else
        false
      end
    end
    !!took_it
  end

  # Marks the step execution as completed.
  #
  # @param outcome [String] the outcome ('success' or 'reattempted')
  # @return [void]
  def mark_completed!(outcome: "success")
    with_lock do
      update!(
        state: "completed",
        completed_at: Time.current,
        outcome: outcome
      )
    end
  end

  # Marks the step execution as failed and records the error.
  #
  # @param error [Exception] the error that occurred
  # @param outcome [String] the outcome ('failed' or 'canceled')
  # @return [void]
  def mark_failed!(error, outcome: "failed")
    with_lock do
      attrs = {
        state: "failed",
        failed_at: Time.current,
        outcome: outcome,
        error_message: error.message,
        error_backtrace: error.backtrace&.join("\n")
      }
      attrs[:error_class_name] = error.class.name if self.class.error_class_name_column?
      update!(attrs)
    end
  end

  # Marks the step execution as skipped.
  #
  # @param outcome [String] the outcome (defaults to 'skipped')
  # @return [void]
  def mark_skipped!(outcome: "skipped")
    with_lock do
      update!(
        state: "skipped",
        skipped_at: Time.current,
        outcome: outcome
      )
    end
  end

  # Marks the step execution as canceled.
  #
  # @param outcome [String] the outcome (defaults to 'canceled')
  # @return [void]
  def mark_canceled!(outcome: "canceled")
    with_lock do
      update!(
        state: "canceled",
        canceled_at: Time.current,
        outcome: outcome
      )
    end
  end

  # Returns the deserialized cursor value for resumable steps.
  # Uses ActiveJob serializers to handle Date, Time, and other types.
  # Returns nil when the cursor column has not been migrated yet.
  #
  # @return [Object, nil] the cursor value
  def cursor_value
    return nil unless self.class.resumable_columns?
    raw = raw_cursor_for_deserialization
    return nil if raw.nil?
    ActiveJob::Arguments.deserialize([raw]).first
  end

  # Sets the cursor value for resumable steps.
  # Uses ActiveJob serializers to handle Date, Time, and other types.
  # Silent no-op when the cursor column has not been migrated yet.
  #
  # @param value [Object] the cursor value to store
  # @raise [CursorTooLargeError] if the serialized JSON exceeds GenevaDrive.max_cursor_size
  # @return [void]
  def cursor_value=(value)
    return unless self.class.resumable_columns?
    self.cursor = self.class.serialize_cursor(value)
  end

  # Returns true if this execution is resuming from a prior execution.
  # Always false when the continues_from_id column has not been migrated yet.
  #
  # @return [Boolean]
  def resuming?
    self.class.resumable_columns? && continues_from_id.present?
  end

  # Returns the step definition for this execution.
  #
  # @return [StepDefinition, nil] the step definition
  def step_definition
    workflow.class.steps.named(step_name)
  end

  # Executes this step using the Executor.
  #
  # @param interruptible [Boolean] whether resumable steps respect interruption conditions
  # @param max_iterations [Integer, nil] per-execution override of the step's max_iterations
  # @return [void]
  def execute!(interruptible: true, max_iterations: nil)
    GenevaDrive::Executor.execute!(self, interruptible: interruptible, max_iterations: max_iterations)
  end

  # The model logger supplemented with tags for step and workflow
  #
  # @return [Logger]
  def logger
    @logger ||= begin
      workflow_tagged_logger = workflow.logger
      workflow_tagged_logger.tagged("execution_id=#{id} step_name=#{step_name}")
    end
  end

  # Temporarily overrides the step execution's logger for the duration of the block.
  # The passed logger is used directly - it should already include step-specific tags.
  # The original logger is restored after the block completes.
  #
  # @param logger [Logger] the logger to use (already fully tagged)
  # @yield the block to execute with the injected logger
  # @return [Object] the result of the block
  # @api private
  def with_logger(logger)
    previous_logger = @logger
    @logger = logger
    yield
  ensure
    @logger = previous_logger
  end
end
