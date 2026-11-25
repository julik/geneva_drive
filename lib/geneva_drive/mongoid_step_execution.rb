# frozen_string_literal: true

# Represents a single step execution attempt within a workflow, on Mongoid
# (MongoDB). Serves as both an audit record and an idempotency key.
#
# The shared logic lives in {GenevaDrive::StepExecutionBehavior}; this class
# carries the fields, the indexes (with the derived active_key uniqueness
# key), the document lock and the Mongo-specific pieces.
#
# @example Querying step executions
#   workflow.step_executions.completed.each do |exec|
#     puts "#{exec.step_name}: #{exec.outcome}"
#   end
#
class GenevaDrive::MongoidStepExecution
  include Mongoid::Document
  include Mongoid::Timestamps
  include GenevaDrive::EnumField

  store_in collection: "geneva_drive_step_executions"

  field :step_name, type: String
  field :outcome, type: String
  field :scheduled_for, type: Time
  field :started_at, type: Time
  field :completed_at, type: Time
  field :failed_at, type: Time
  field :canceled_at, type: Time
  field :skipped_at, type: Time
  field :finished_at, type: Time
  field :error_class_name, type: String
  field :error_message, type: String
  field :error_backtrace, type: String
  field :job_id, type: String
  field :metadata, type: Hash
  field :cursor
  field :waiting_since, type: Time
  # Derived uniqueness key: equals workflow_id while this execution is active
  # (scheduled or in_progress - NOT waiting, mirroring the SQL partial index
  # exactly); absent otherwise. Backed by a partial unique index, enforcing
  # "one active execution per workflow".
  field :active_key

  include GenevaDrive::MongoidMetadataAccessor

  # Step execution states as enum with string values
  # Provides: scheduled?, in_progress?, etc. predicates
  # Provides: scheduled, in_progress, etc. scopes
  enum_field :state, %w[scheduled waiting in_progress completed failed canceled skipped], default: "scheduled"

  # Associations
  belongs_to :workflow,
    class_name: "GenevaDrive::MongoidWorkflow",
    foreign_key: :workflow_id,
    inverse_of: :step_executions

  # For chained resumable step executions
  belongs_to :continues_from,
    class_name: "GenevaDrive::MongoidStepExecution",
    foreign_key: :continues_from_id,
    optional: true,
    inverse_of: :successor

  has_one :successor,
    class_name: "GenevaDrive::MongoidStepExecution",
    foreign_key: :continues_from_id,
    inverse_of: :continues_from

  # The signal this execution is processing (the "attachment pin"). Set once,
  # at the gate or by dispatch, and copied to successor executions so the
  # payload stays stable across a whole resumable chain.
  belongs_to :signal,
    class_name: "GenevaDrive::MongoidSignal",
    foreign_key: :signal_id,
    optional: true

  index({workflow_id: 1})
  index({workflow_id: 1, state: 1})
  index({workflow_id: 1, created_at: 1})
  index({state: 1})
  index({state: 1, scheduled_for: 1})
  index({scheduled_for: 1})
  index({finished_at: 1})
  index({continues_from_id: 1})
  index({signal_id: 1})
  # One active (scheduled or in_progress) execution per workflow. active_key
  # holds the workflow_id while active; the $type filter keeps both absent
  # and explicit-null values out of the index (an explicit null *exists* in
  # MongoDB, so $exists would make nulls collide).
  index({active_key: 1}, {unique: true, partial_filter_expression: {active_key: {"$type" => "objectId"}}})

  include GenevaDrive::StepExecutionBehavior

  # Callbacks
  before_save :maintain_active_key

  # Find executions that are ready to run
  scope :ready_to_execute, -> {
    scheduled.where(:scheduled_for.lte => Time.current)
  }

  # State-set filter the shared orchestration uses (an array equality would
  # mean "the field equals this array" in MongoDB, hence a scope per backend).
  scope :in_states, ->(states) { where(:state.in => states) }

  # Chronological orderings with a stable tiebreaker. ObjectIds are
  # time-prefixed, so the _id tiebreak keeps the meaning the SQL id had.
  scope :oldest_first, -> { order(created_at: :asc, _id: :asc) }
  scope :newest_first, -> { order(created_at: :desc, _id: :desc) }

  class << self
    # MongoDB is schemaless: the resumable-step fields (cursor and
    # continues_from_id) are always available. The method is kept so shared
    # code and tests keep working.
    #
    # @return [Boolean]
    def resumable_columns?
      true
    end

    # Kept as a no-op for API compatibility with the SQL implementation.
    #
    # @return [void]
    def reset_resumable_columns_cache!
    end

    # MongoDB is schemaless: the signal fields (signal_id and waiting_since)
    # are always available.
    #
    # @return [Boolean]
    def signal_columns?
      true
    end

    # Kept as a no-op for API compatibility with the SQL implementation.
    #
    # @return [void]
    def reset_signal_columns_cache!
    end

    # MongoDB is schemaless: the error_class_name field is always available.
    #
    # @return [Boolean]
    def error_class_name_column?
      true
    end

    # Kept as a no-op for API compatibility with the SQL implementation.
    #
    # @return [void]
    def reset_error_class_name_column_cache!
    end

    # Counts reattempted step executions in the given scope, excluding
    # flow-control reattempts.
    #
    # @param scope [Mongoid::Criteria] a criteria of step executions
    #   already filtered to outcome: "reattempted"
    # @return [Integer]
    def count_error_reattempts(scope)
      scope.pluck(:metadata).count do |meta|
        reason = meta.is_a?(Hash) ? meta["reattempt_reason"] : nil
        reason != "flow_control"
      end
    end

    # Counts the consecutive exception-policy reattempts of a step, looking
    # back from the most recent execution to the last completion that was not
    # a reattempt. ObjectIds are time-prefixed, so the _id comparison keeps
    # the "after that row" meaning the SQL id comparison had.
    #
    # @param workflow [GenevaDrive::MongoidWorkflow]
    # @param step_name [String]
    # @return [Integer]
    def consecutive_reattempt_count(workflow, step_name)
      # Find the most recent non-reattempt completion for this step
      # (success, skipped, canceled, failed - anything that isn't a reattempt)
      last_non_reattempt_id = workflow.step_executions
        .where(step_name: step_name, state: "completed")
        .where(:outcome.ne => "reattempted")
        .order(created_at: :desc, _id: :desc)
        .limit(1)
        .pluck(:_id)
        .first

      # Count reattempts after that point (or all reattempts if no prior success)
      scope = workflow.step_executions.where(step_name: step_name, outcome: "reattempted")
      scope = scope.where(:_id.gt => last_non_reattempt_id) if last_non_reattempt_id

      count_error_reattempts(scope)
    end

    # Step executions stuck in "in_progress" since before the cutoff, for
    # housekeeping recovery.
    #
    # @param cutoff_time [Time]
    # @return [Mongoid::Criteria]
    def stuck_in_progress(cutoff_time)
      in_progress.where(:started_at.lt => cutoff_time)
    end

    # Step executions stuck in "scheduled" past their scheduled_for time,
    # for housekeeping recovery.
    #
    # @param cutoff_time [Time]
    # @return [Mongoid::Criteria]
    def stuck_scheduled(cutoff_time)
      scheduled.where(:scheduled_for.lt => cutoff_time)
    end

    # Step executions parked waiting since before the given time, for the
    # waiting-overdue gauge.
    #
    # @param since_time [Time]
    # @return [Mongoid::Criteria]
    def waiting_overdue(since_time)
      waiting.where(:waiting_since.lte => since_time)
    end

    # Counts the step executions in the scope per workflow type, for the
    # housekeeping gauges. No joins in MongoDB: resolve the workflow types
    # with a second query.
    #
    # @param scope [Mongoid::Criteria]
    # @return [Hash{String => Integer}]
    def counts_by_workflow_type(scope)
      workflow_ids = scope.pluck(:workflow_id)
      types_by_id = GenevaDrive::MongoidWorkflow.where(:_id.in => workflow_ids.uniq)
        .pluck(:_id, :_type).to_h
      workflow_ids.map { |id| types_by_id[id] }.tally
    end

    # The serialized cursor is stored natively - MongoDB holds the structure
    # as-is.
    #
    # @param serialized [Object] the ActiveJob-serialized cursor
    # @return [Object] the storable value
    def encode_cursor(serialized)
      serialized
    end
  end

  # Returns the reattempt reason from metadata.
  # Possible values: "flow_control", "exception_policy", "precondition", or nil.
  #
  # @return [String, nil]
  def reattempt_reason
    read_metadata("reattempt_reason")
  end

  # Returns the exception info hash from metadata, if recorded.
  # Keys: "class", "message", "backtrace" (backtrace is an Array of strings).
  #
  # @return [Hash, nil]
  def exception_info
    read_metadata("exception")
  end

  # Runs the block under the owning workflow's document lock, reloading this
  # execution first - the replacement for ActiveRecord's row-level with_lock.
  # The workflow document is the one lock for the whole aggregate: when the
  # caller (the Executor, housekeeping) already holds it, this reduces to
  # reload-and-yield; writes to this document inside the transaction are
  # conflict-protected either way.
  #
  # @yield the critical section
  # @return [Object] the block's return value
  def with_lock(&block)
    GenevaDrive::DocumentLock.with_workflow_lock(workflow) do
      reload
      block.call
    end
  end

  private

  # Reads the stored cursor back into its ActiveJob-serialized form - which
  # is how it is stored, natively.
  #
  # @return [Object, nil]
  def raw_cursor_for_deserialization
    cursor
  end

  # Maintains the derived active_key field on every save, so the partial
  # unique index always reflects the current state. update_all call sites
  # (which bypass callbacks) clear it explicitly.
  #
  # @return [void]
  def maintain_active_key
    self.active_key = if %w[scheduled in_progress].include?(state)
      workflow_id
    end
  end
end
