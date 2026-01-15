# frozen_string_literal: true

# Represents a single step execution attempt within a workflow.
# Serves as both an audit record and an idempotency key.
#
# Each step execution tracks:
# - The step being executed
# - The current state of execution
# - When the step was scheduled, started, and completed
# - Any errors that occurred
# - The outcome of the execution
#
# @example Querying step executions
#   workflow.step_executions.completed.each do |exec|
#     puts "#{exec.step_name}: #{exec.outcome}"
#   end
#
class GenevaDrive::StepExecution < ActiveRecord::Base
  self.table_name = "geneva_drive_step_executions"

  # Step execution states as enum with string values
  # Provides: scheduled?, in_progress?, etc. predicates
  # Provides: scheduled, in_progress, etc. scopes
  enum :state, {
    scheduled: "scheduled",
    in_progress: "in_progress",
    suspended: "suspended",
    completed: "completed",
    failed: "failed",
    canceled: "canceled",
    skipped: "skipped"
  }

  # Outcome values for audit purposes
  OUTCOMES = %w[
    success
    reattempted
    skipped
    canceled
    failed
    recovered
    workflow_paused
  ].freeze

  # Associations
  belongs_to :workflow,
    class_name: "GenevaDrive::Workflow",
    foreign_key: :workflow_id,
    inverse_of: :step_executions

  # Validations
  validates :step_name, presence: true
  validates :scheduled_for, presence: true
  validates :outcome, inclusion: {in: OUTCOMES}, allow_nil: true

  # Find executions that are ready to run
  scope :ready_to_execute, -> {
    scheduled.where("scheduled_for <= ?", Time.current)
  }

  # Transitions the step execution to 'in_progress' state.
  # Uses pessimistic locking to prevent double execution.
  #
  # @return [Boolean] true if transition succeeded, false if already executed
  def start!
    with_lock do
      return false unless scheduled?
      update!(
        state: "in_progress",
        started_at: Time.current
      )
    end
    true
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
      attrs[:error_class_name] = error.class.name if has_attribute?(:error_class_name)
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

  # Marks the step execution as suspended (for resumable steps).
  # The cursor is persisted separately via fast checkpoint updates.
  #
  # @return [void]
  def mark_suspended!
    with_lock do
      update!(state: "suspended")
    end
  end

  # Returns the deserialized cursor value for resumable steps.
  # Uses ActiveJob serializers to handle Date, Time, and other types.
  #
  # @return [Object, nil] the cursor value
  def cursor_value
    return nil if cursor.blank?
    ActiveJob::Arguments.deserialize([cursor]).first
  end

  # Sets the cursor value for resumable steps.
  # Uses ActiveJob serializers to handle Date, Time, and other types.
  #
  # @param value [Object] the cursor value to store
  # @return [void]
  def cursor_value=(value)
    self.cursor = if value.nil?
      nil
    else
      ActiveJob::Arguments.serialize([value]).first
    end
  end

  # Resets the cursor and iteration count for a full rewind.
  #
  # @return [void]
  def rewind_cursor!
    with_lock do
      update!(cursor: nil, completed_iterations: 0)
    end
  end

  # Returns the step definition for this execution.
  #
  # @return [StepDefinition, nil] the step definition
  def step_definition
    workflow.class.steps.named(step_name)
  end

  # Executes this step using the Executor.
  #
  # @param interrupt_configuration [InterruptConfiguration] controls interruption behavior
  # @return [void]
  def execute!(interrupt_configuration: GenevaDrive::InterruptConfiguration.default)
    GenevaDrive::Executor.execute!(self, interrupt_configuration: interrupt_configuration)
  end

  # Same as ActiveRecord::Base#logger but supplemented with tags for step and workflow
  #
  # @return [Logger]
  def logger
    @logger ||= begin
      workflow_tagged_logger = workflow.logger
      workflow_tagged_logger.tagged("execution_id=#{id} step_name=#{step_name}")
    end
  end
end
