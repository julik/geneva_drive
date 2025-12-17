# frozen_string_literal: true

module GenevaDrive
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
  class StepExecution < ActiveRecord::Base
    self.table_name = "geneva_drive_step_executions"

    # Valid execution states
    STATES = %w[scheduled executing completed failed canceled skipped].freeze

    # Outcome values for audit purposes
    OUTCOMES = %w[
      success
      reattempted
      skipped
      canceled
      failed
    ].freeze

    # Associations
    belongs_to :workflow,
      class_name: "GenevaDrive::Workflow",
      foreign_key: :workflow_id,
      inverse_of: :step_executions

    # Validations
    validates :state, presence: true, inclusion: {in: STATES}
    validates :step_name, presence: true
    validates :scheduled_for, presence: true
    validates :outcome, inclusion: {in: OUTCOMES}, allow_nil: true

    # Scopes for querying by state
    scope :scheduled, -> { where(state: "scheduled") }
    scope :executing, -> { where(state: "executing") }
    scope :completed, -> { where(state: "completed") }
    scope :failed, -> { where(state: "failed") }
    scope :skipped, -> { where(state: "skipped") }
    scope :canceled, -> { where(state: "canceled") }

    # Find executions that are ready to run
    scope :ready_to_execute, -> {
      where(state: "scheduled")
        .where("scheduled_for <= ?", Time.current)
    }

    # Transitions the step execution to 'executing' state.
    # Uses pessimistic locking to prevent double execution.
    #
    # @return [Boolean] true if transition succeeded, false if already executed
    def start_executing!
      with_lock do
        return false unless state == "scheduled"
        update!(
          state: "executing",
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
        update!(
          state: "failed",
          failed_at: Time.current,
          outcome: outcome,
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
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

    # Returns the step definition for this execution.
    #
    # @return [StepDefinition, nil] the step definition
    def step_definition
      workflow.class.step_collection.find_by_name(step_name)
    end

    # Executes this step using the Executor.
    #
    # @return [void]
    def execute!
      Executor.execute!(self)
    end
  end
end
