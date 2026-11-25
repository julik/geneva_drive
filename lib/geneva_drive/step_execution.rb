# frozen_string_literal: true

# Represents a single step execution attempt within a workflow, on
# ActiveRecord. Serves as both an audit record and an idempotency key.
#
# Each step execution tracks:
# - The step being executed
# - The current state of execution
# - When the step was scheduled, started, and completed
# - Any errors that occurred
# - The outcome of the execution
#
# The shared logic lives in {GenevaDrive::StepExecutionBehavior}; this class
# carries the table, enum, associations and the SQL-specific pieces.
#
# @example Querying step executions
#   workflow.step_executions.completed.each do |exec|
#     puts "#{exec.step_name}: #{exec.outcome}"
#   end
#
class GenevaDrive::StepExecution < ActiveRecord::Base
  self.table_name = "geneva_drive_step_executions"

  require_relative "step_execution/metadata_accessor"
  include MetadataAccessor
  include GenevaDrive::JsonColumn

  # Step execution states as enum with string values
  # Provides: scheduled?, in_progress?, etc. predicates
  # Provides: scheduled, in_progress, etc. scopes
  enum :state, {
    scheduled: "scheduled",
    waiting: "waiting",
    in_progress: "in_progress",
    completed: "completed",
    failed: "failed",
    canceled: "canceled",
    skipped: "skipped"
  }

  # Associations
  belongs_to :workflow,
    class_name: "GenevaDrive::Workflow",
    foreign_key: :workflow_id,
    inverse_of: :step_executions

  # For chained resumable step executions
  belongs_to :continues_from,
    class_name: "GenevaDrive::StepExecution",
    foreign_key: :continues_from_id,
    optional: true,
    inverse_of: :successor

  has_one :successor,
    class_name: "GenevaDrive::StepExecution",
    foreign_key: :continues_from_id,
    inverse_of: :continues_from

  # The signal this execution is processing (the "attachment pin"). Set once,
  # at the gate or by dispatch, and copied to successor executions so the
  # payload stays stable across a whole resumable chain.
  belongs_to :signal,
    class_name: "GenevaDrive::Signal",
    foreign_key: :signal_id,
    optional: true

  include GenevaDrive::StepExecutionBehavior

  # Find executions that are ready to run
  scope :ready_to_execute, -> {
    scheduled.where("scheduled_for <= ?", Time.current)
  }

  # State-set filter the shared orchestration uses (an array equality would
  # mean something else on MongoDB, hence a scope per backend).
  scope :in_states, ->(states) { where(state: states) }

  # Chronological orderings with a stable tiebreaker (the Mongoid backend
  # tiebreaks on _id).
  scope :oldest_first, -> { order(created_at: :asc, id: :asc) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  class << self
    # Lazily checks whether the resumable-step columns (cursor and
    # continues_from_id) have been migrated. Never hits the database at
    # class definition time — only on the first runtime call.
    #
    # Deployments usually ship the gem update before running migrations,
    # so all cursor/chaining behavior must degrade safely when the columns
    # are absent: reads return nil, writes are no-ops, and executing an
    # actual resumable_step raises a clear configuration error instead.
    #
    # @return [Boolean]
    def resumable_columns?
      if defined?(@_resumable_columns)
        return @_resumable_columns
      end

      @_resumable_columns = table_exists? &&
        column_names.include?("cursor") &&
        column_names.include?("continues_from_id")
    end

    # Clears the cached detection result. Call this in tests or after
    # running migrations in-process so the next access re-checks.
    #
    # @return [void]
    def reset_resumable_columns_cache!
      remove_instance_variable(:@_resumable_columns) if defined?(@_resumable_columns)
    end

    # Lazily checks whether the signal columns (signal_id and
    # waiting_since) have been migrated, mirroring resumable_columns?.
    # Never hits the database at class definition time.
    #
    # Everything unrelated to signals keeps working without them; a step
    # declaring wait_for: fails loudly with a "run the install generator"
    # message instead of silently running without its event.
    #
    # @return [Boolean]
    def signal_columns?
      if defined?(@_signal_columns)
        return @_signal_columns
      end

      @_signal_columns = table_exists? &&
        column_names.include?("signal_id") &&
        column_names.include?("waiting_since")
    end

    # Clears the cached signal column detection result. Call this in tests or
    # after running migrations in-process so the next access re-checks.
    #
    # @return [void]
    def reset_signal_columns_cache!
      remove_instance_variable(:@_signal_columns) if defined?(@_signal_columns)
    end

    # Whether the error_class_name column has been migrated. mark_failed!
    # degrades to the error_message/error_backtrace columns without it.
    #
    # @return [Boolean]
    def error_class_name_column?
      if defined?(@_error_class_name_column)
        return @_error_class_name_column
      end

      @_error_class_name_column = table_exists? && column_names.include?("error_class_name")
    end

    # Clears the cached error_class_name column detection result.
    #
    # @return [void]
    def reset_error_class_name_column_cache!
      remove_instance_variable(:@_error_class_name_column) if defined?(@_error_class_name_column)
    end

    # Counts the consecutive exception-policy reattempts of a step, looking
    # back from the most recent execution to the last completion that was not
    # a reattempt. The query shape is per-backend because of the primary-key
    # comparison; the Executor calls it through step_execution.class.
    #
    # @param workflow [GenevaDrive::Workflow]
    # @param step_name [String]
    # @return [Integer]
    def consecutive_reattempt_count(workflow, step_name)
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

      count_error_reattempts(scope)
    end

    # Step executions stuck in "in_progress" since before the cutoff, for
    # housekeeping recovery.
    #
    # @param cutoff_time [Time]
    # @return [ActiveRecord::Relation]
    def stuck_in_progress(cutoff_time)
      in_progress.where("started_at < ?", cutoff_time)
    end

    # Step executions stuck in "scheduled" past their scheduled_for time,
    # for housekeeping recovery.
    #
    # @param cutoff_time [Time]
    # @return [ActiveRecord::Relation]
    def stuck_scheduled(cutoff_time)
      scheduled.where("scheduled_for < ?", cutoff_time)
    end

    # Step executions parked waiting since before the given time, for the
    # waiting-overdue gauge.
    #
    # @param since_time [Time]
    # @return [ActiveRecord::Relation]
    def waiting_overdue(since_time)
      waiting.where(waiting_since: ..since_time)
    end

    # Counts the step executions in the scope per workflow type, for the
    # housekeeping gauges.
    #
    # @param scope [ActiveRecord::Relation]
    # @return [Hash{String => Integer}]
    def counts_by_workflow_type(scope)
      scope.joins(:workflow).group("#{GenevaDrive::Workflow.table_name}.type").count
    end

    # How the serialized cursor is stored: through the JSON column shim,
    # which encodes to a JSON string on databases without a JSON type.
    #
    # @param serialized [Object] the ActiveJob-serialized cursor
    # @return [Object] the storable value
    def encode_cursor(serialized)
      encode_json_column(:cursor, serialized)
    end
  end

  private

  # Reads the stored cursor back into its ActiveJob-serialized form.
  #
  # @return [Object, nil]
  def raw_cursor_for_deserialization
    return nil if cursor.blank?
    self.class.decode_json_column(:cursor, cursor)
  end
end
