# frozen_string_literal: true

# Base class for all durable workflows in GenevaDrive, on Mongoid (MongoDB).
#
# The DSL lives in {GenevaDrive::WorkflowDsl} and the orchestration in
# {GenevaDrive::WorkflowBehavior} - both shared with the ActiveRecord backend
# ({GenevaDrive::Workflow}). This class carries what is specific to MongoDB:
# the fields, the indexes (with the derived uniqueness keys), the document
# lock and the Mongo shapes of the persistence template methods.
#
# A MongoDB **replica set** (single-node is fine) with majority write concern
# is a hard requirement - the transactional guarantees rest on multi-document
# transactions. Never connect with `directConnection=true`.
#
# @example Basic workflow definition
#   class SignupWorkflow < GenevaDrive::MongoidWorkflow
#     step :send_welcome_email do
#       WelcomeMailer.welcome(hero).deliver_later
#     end
#   end
#
# @example Creating and starting a workflow
#   SignupWorkflow.create!(hero: current_user)
#
class GenevaDrive::MongoidWorkflow
  include Mongoid::Document
  include Mongoid::Timestamps
  include GenevaDrive::EnumField

  store_in collection: "geneva_drive_workflows"

  field :current_step_name, type: String
  field :next_step_name, type: String
  field :allow_multiple, type: Mongoid::Boolean, default: false
  field :metadata, type: Hash
  field :started_at, type: Time
  field :transitioned_at, type: Time
  # The field the document lock's first-write `$inc` lands on. Never read -
  # its whole purpose is to be written first inside every lock transaction.
  field :lock_version, type: Integer, default: 0
  # Derived uniqueness key: "<type>|<hero_type>|<hero_id>" while the workflow
  # is ongoing and allow_multiple is false; absent otherwise. Backed by a
  # partial unique index - the MongoDB equivalent of the SQL partial index on
  # (type, hero_type, hero_id) WHERE state NOT IN (finished, canceled).
  field :ongoing_key, type: String

  include GenevaDrive::MongoidMetadataAccessor

  # Workflow states as enum with string values
  # Provides: ready?, performing?, etc. predicates
  # Provides: ready, performing, etc. scopes
  enum_field :state, %w[ready performing finished canceled paused], default: "ready"

  # Associations
  belongs_to :hero, polymorphic: true, optional: true
  has_many :step_executions,
    class_name: "GenevaDrive::MongoidStepExecution",
    foreign_key: :workflow_id,
    inverse_of: :workflow,
    dependent: :delete_all
  has_many :signals,
    class_name: "GenevaDrive::MongoidSignal",
    foreign_key: :workflow_id,
    inverse_of: :workflow,
    dependent: :delete_all

  index({_type: 1})
  index({state: 1})
  index({hero_type: 1, hero_id: 1})
  # `$type: "string"` (rather than `$exists`) is deliberate: an explicit null
  # *does* exist in MongoDB, so an `$exists` partial index would make null
  # keys collide. Typed on string, both absent and null keys stay unindexed.
  index({ongoing_key: 1}, {unique: true, partial_filter_expression: {ongoing_key: {"$type" => "string"}}})

  include GenevaDrive::WorkflowDsl
  include GenevaDrive::WorkflowBehavior

  # Additional scopes
  scope :ongoing, -> { where(:state.nin => %w[finished canceled]) }
  scope :for_hero, ->(hero) { where(hero_type: hero.class.name, hero_id: hero.id) }

  # Callbacks
  before_save :maintain_ongoing_key

  class << self
    # The step execution model this backend persists to. Shared code routes
    # every model reference through this.
    #
    # @return [Class]
    def step_execution_class
      GenevaDrive::MongoidStepExecution
    end

    # The signal model this backend persists to.
    #
    # @return [Class]
    def signal_class
      GenevaDrive::MongoidSignal
    end

    # Returns the names of this workflow's removed steps that step execution
    # rows still reference, so a `removed_step` gravestone is only deleted
    # once nothing can land on it any more. See the ActiveRecord twin for the
    # full story; no joins in MongoDB, so this resolves in two queries.
    #
    # @return [Hash{String => Integer}] removed step names to referencing row counts
    def removed_steps_in_flight
      removed_names = steps.removed.map(&:name)
      return {} if removed_names.empty?

      ongoing_ids = where(:state.nin => %w[finished canceled]).pluck(:_id)
      return {} if ongoing_ids.empty?

      GenevaDrive::MongoidStepExecution
        .where(:step_name.in => removed_names, :workflow_id.in => ongoing_ids)
        .pluck(:step_name)
        .tally
    end

    # MongoDB needs no migrations - the collections appear on first write -
    # so the backend is sweepable as soon as it is loaded.
    #
    # @return [Boolean]
    def housekeeping_available?
      true
    end

    # Workflow counts grouped by (state, workflow type), for the housekeeping
    # gauges.
    #
    # @return [Hash{Array(String, String) => Integer}]
    def housekeeping_state_type_counts
      collection.aggregate([
        {"$group" => {"_id" => {"state" => "$state", "type" => "$_type"}, "count" => {"$sum" => 1}}}
      ]).each_with_object({}) do |doc, acc|
        acc[[doc["_id"]["state"], doc["_id"]["type"]]] = doc["count"]
      end
    end

    # Deletes terminal (finished/canceled) workflows that transitioned before
    # the cutoff, along with their step executions and signals. Batches by
    # workflow: pick a page of eligible workflow ids, then delete their step
    # executions, their signals, and the workflows themselves.
    #
    # @param cutoff_time [Time] workflows transitioned before this time are eligible
    # @param batch_size [Integer] maximum workflows to delete per batch
    # @param logger [Logger]
    # @return [Hash{Symbol => Integer}] deleted counts
    def sweep_terminal_workflows!(cutoff_time, batch_size, logger:)
      totals = {workflows: 0, step_executions: 0, signals: 0}

      loop do
        workflow_ids = where(:state.in => %w[finished canceled], :transitioned_at.lt => cutoff_time)
          .limit(batch_size)
          .pluck(:_id)
        break if workflow_ids.empty?

        deleted_executions = GenevaDrive::MongoidStepExecution.where(:workflow_id.in => workflow_ids).delete_all
        logger.info("Deleted #{deleted_executions} step executions")
        totals[:step_executions] += deleted_executions

        deleted_signals = GenevaDrive::MongoidSignal.where(:workflow_id.in => workflow_ids).delete_all
        logger.info("Deleted #{deleted_signals} signals")
        totals[:signals] += deleted_signals

        deleted_workflows = where(:_id.in => workflow_ids).delete_all
        logger.info("Deleted #{deleted_workflows} workflows")
        totals[:workflows] += deleted_workflows

        break if workflow_ids.size < batch_size
      end

      totals
    end
  end

  # Fallback for removed Workflow subclasses. When we try to examine a
  # Workflow which exists in our database - but its class has been removed -
  # Mongoid::Factory would otherwise fail with Mongoid::Errors::UnknownModel.
  # We need to avoid this because even if a class has been removed - we
  # should still be able to examine a workflow that was using it. Installed
  # onto Mongoid::Factory by geneva_drive/mongoid.rb.
  #
  # @api private
  module FactoryFallback
    def from_db(klass, attributes = nil, criteria = nil, selected_fields = nil)
      super
    rescue Mongoid::Errors::UnknownModel
      raise unless klass <= GenevaDrive::MongoidWorkflow
      # Demote to the queried class, keeping the stored _type value readable
      # on the instance, the way ActiveRecord keeps the type column value.
      # instantiate_document is how Factory itself turns stored attributes
      # into a document on both Mongoid 8 and 9: it sets the attributes,
      # applies defaults and runs the find/initialize callbacks.
      klass.instantiate_document(attributes, selected_fields)
    end
  end

  # Runs the block holding this workflow's document lock inside a MongoDB
  # transaction - the direct replacement for ActiveRecord's `with_lock`
  # row lock. Reentrant per thread; reloads the workflow before yielding.
  #
  # @yield the critical section
  # @return [Object] the block's return value
  def with_lock(&block)
    GenevaDrive::DocumentLock.with_workflow_lock(self, &block)
  end

  # The stored workflow type name - what ActiveRecord kept in the `type`
  # column lives in `_type` here.
  #
  # @return [String]
  def sti_type_name
    (respond_to?(:_type) && _type.presence) || self.class.name
  end

  # ActiveRecord called the discriminator column `type`; keep that name
  # readable and writable for compatibility.
  #
  # @return [String]
  def type
    sti_type_name
  end

  # @param value [String]
  # @return [void]
  def type=(value)
    self._type = value
  end

  # Sets per-instance step job options in metadata. Overrides the shared
  # implementation because Mongoid stores the metadata Hash natively: symbol
  # values would come back as symbols where the SQL implementation's JSON
  # round-trip returned strings, so normalize them here to keep readers
  # seeing the same shapes on every backend.
  #
  # @param options [Hash, nil] job options to store
  # @return [void]
  def step_job_options=(options)
    if options.present?
      validated = GenevaDrive::JobOptions.validate!(options, context: "#{self.class.name}#step_job_options=")
      validated = validated.stringify_keys.transform_values { |value| value.is_a?(Symbol) ? value.to_s : value }
      write_metadata("step_job_options", validated)
    else
      write_metadata("step_job_options", nil)
    end
  end

  private

  # Validates that no other ongoing workflow exists for the same (type, hero).
  # Mirrors the partial unique index on ongoing_key.
  #
  # @return [void]
  def validate_unique_ongoing_workflow
    scope = GenevaDrive::MongoidWorkflow.where(_type: sti_type_name, hero_type: hero_type, hero_id: hero_id)
      .where(:state.nin => %w[finished canceled])
      .where(allow_multiple: false)
    scope = scope.where(:_id.ne => id) if persisted?
    if scope.exists?
      errors.add(:base, "An ongoing workflow of this type already exists for this hero")
    end
  end

  # Maintains the derived ongoing_key field on every save, so the partial
  # unique index always reflects the current state. Runs inside the ambient
  # lock transaction, like every other callback write.
  #
  # @return [void]
  def maintain_ongoing_key
    self.ongoing_key = if !allow_multiple && ongoing?
      [sti_type_name, hero_type, hero_id].join("|")
    end
  end

  # Points a signal's workflow association at this instance, so matcher
  # blocks - which are instance_exec'd on it - see the live object.
  #
  # @param signal [GenevaDrive::MongoidSignal]
  # @return [GenevaDrive::MongoidSignal] the same signal
  def adopt_signal(signal)
    signal.set_relation(:workflow, self)
    signal
  end

  # Persists a new signal row, honoring the dedup unique index. Called by the
  # shared signal! with the workflow lock held.
  #
  # MongoDB has no savepoints, so instead of insert-and-catch the dedup is a
  # read-before-insert. That is race-free here because every signal! holds
  # the workflow lock: two racing deliveries are serialized, and the second
  # one's fresh snapshot sees the first's row. The unique index stays as a
  # backstop (recover_signal_from_dedup_race).
  #
  # @param name [String] the signal name
  # @param dedup_key [String, nil] the idempotency key
  # @param serialized_payload [Object, nil] the pre-serialized payload
  # @return [Array(GenevaDrive::MongoidSignal, Boolean)] the signal and
  #   whether it was an existing row (a duplicate delivery)
  def insert_signal_with_dedup!(name, dedup_key, serialized_payload)
    if dedup_key && (existing = signals.where(name: name, idempotency_key: dedup_key).first)
      logger.info("Signal #{name.inspect} is a duplicate delivery of signal #{existing.id}, not dispatching")
      return [existing, true]
    end

    attrs = {name: name, state: "pending"}
    attrs[:idempotency_key] = dedup_key if dedup_key
    record = signals.new(**attrs)
    record[:payload] = serialized_payload
    record.save!
    [record, false]
  end

  # The unique-index backstop: if the read-before-insert ever misses (it
  # should not, under the lock), the index aborts the transaction with a
  # DuplicateKey - which is not transient, so it surfaces here. Re-enter the
  # duplicate path.
  #
  # @param error [Exception]
  # @param name [String]
  # @param dedup_key [String, nil]
  # @return [GenevaDrive::MongoidSignal, nil]
  def recover_signal_from_dedup_race(error, name, dedup_key)
    return nil unless dedup_key && GenevaDrive::DocumentLock.duplicate_key_error?(error)

    signal = signals.where(name: name, idempotency_key: dedup_key).first
    return nil unless signal

    logger.info("Signal #{name.inspect} hit the dedup index, returning existing signal #{signal.id}")
    signal
  end

  # Cancels any scheduled or parked step executions so that the execution
  # about to be created is the only one that will run. In-progress executions
  # are left alone - they are being executed.
  #
  # @return [Integer] the number of executions canceled
  def cancel_stray_executions!
    # pluck (unlike count) rides the ambient transaction session, so this
    # sees - and sweeps - executions written earlier in the same transaction.
    stray_ids = step_executions.where(:state.in => %w[scheduled waiting]).pluck(:_id)
    canceled_count = stray_ids.size
    if canceled_count > 0
      # update_all bypasses callbacks, so the derived active_key has to be
      # cleared here explicitly (null stays out of the $type-filtered index).
      GenevaDrive::MongoidStepExecution.where(:_id.in => stray_ids).update_all(
        state: "canceled",
        outcome: "canceled",
        canceled_at: Time.current,
        active_key: nil
      )
      logger.debug("Canceled #{canceled_count} previously scheduled step execution(s)")
    end
    canceled_count
  end

  # Runs a block after the transaction it was registered under commits, or
  # immediately when no transaction is open.
  #
  # Inside any transaction the deferral is mandatory on this backend -
  # `GenevaDrive.with_inline_enqueue` and `GenevaDrive.enqueue_after_commit`
  # only govern enqueues made outside a transaction (where there is nothing
  # to defer to anyway). Honoring them inside one would enqueue a job for a
  # row that is not committed yet - and keep it enqueued if the transaction
  # aborts - which is exactly what this method exists to prevent.
  #
  # @yield the block to run (typically hands a step to the dispatcher)
  # @return [void]
  def run_after_commit(&block)
    if (deferred = GenevaDrive::DocumentLock.deferred_callbacks)
      # A lock transaction owned by GenevaDrive is open on this thread: queue
      # the callback on it. The lock wrapper flushes the queue only after a
      # successful commit and discards it when an attempt rolls back or is
      # retried - a rolled-back transition can never enqueue.
      deferred << block
    elsif (session = GenevaDrive::DocumentLock.ambient_session(self.class)) && session.in_transaction?
      # The caller owns the open transaction (the lock joined their ambient
      # session). Queue the callback on the session itself; the
      # SessionAfterCommit prepend flushes it when the caller's
      # commit_transaction succeeds and discards it on abort_transaction.
      GenevaDrive::DocumentLock.defer_on_session(session, block)
    else
      # No transaction is open, so there is nothing to wait for. This
      # mirrors ActiveRecord.after_all_transactions_commit, which also runs
      # the block immediately outside a transaction.
      yield
    end
  end

  # The logger to tag when none was injected.
  #
  # @return [Logger]
  def default_base_logger
    Rails.logger || Mongoid.logger
  end
end
