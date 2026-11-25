# frozen_string_literal: true

# Base class for all durable workflows in GenevaDrive, on ActiveRecord.
#
# Provides a DSL for defining multi-step workflows that execute asynchronously,
# with strong guarantees around idempotency, concurrency control, and state management.
#
# The DSL lives in {GenevaDrive::WorkflowDsl} and the orchestration in
# {GenevaDrive::WorkflowBehavior} - both shared with the Mongoid backend
# ({GenevaDrive::MongoidWorkflow}). This class carries what is specific to
# ActiveRecord: the table, the enum, the associations and the SQL shapes of
# the persistence template methods.
#
# @example Basic workflow definition
#   class SignupWorkflow < GenevaDrive::Workflow
#     step :send_welcome_email do
#       WelcomeMailer.welcome(hero).deliver_later
#     end
#
#     step :send_reminder, wait: 2.days do
#       ReminderMailer.remind(hero).deliver_later
#     end
#   end
#
# @example Creating and starting a workflow
#   SignupWorkflow.create!(hero: current_user)
#
class GenevaDrive::Workflow < ActiveRecord::Base
  self.table_name = "geneva_drive_workflows"

  require_relative "workflow/metadata_accessor"
  include MetadataAccessor

  # Workflow states as enum with string values
  # Provides: ready?, performing?, etc. predicates
  # Provides: ready, performing, etc. scopes
  enum :state, {
    ready: "ready",
    performing: "performing",
    finished: "finished",
    canceled: "canceled",
    paused: "paused"
  }

  # Associations
  belongs_to :hero, polymorphic: true, optional: true
  has_many :step_executions,
    class_name: "GenevaDrive::StepExecution",
    foreign_key: :workflow_id,
    inverse_of: :workflow,
    dependent: :delete_all
  has_many :signals,
    class_name: "GenevaDrive::Signal",
    foreign_key: :workflow_id,
    inverse_of: :workflow,
    dependent: :delete_all

  include GenevaDrive::WorkflowDsl
  include GenevaDrive::WorkflowBehavior

  # Additional scopes
  scope :ongoing, -> { where.not(state: %w[finished canceled]) }
  scope :for_hero, ->(hero) { where(hero: hero) }

  class << self
    # The step execution model this backend persists to. Shared code routes
    # every model reference through this.
    #
    # @return [Class]
    def step_execution_class
      GenevaDrive::StepExecution
    end

    # The signal model this backend persists to.
    #
    # @return [Class]
    def signal_class
      GenevaDrive::Signal
    end

    # Returns the names of this workflow's removed steps that step execution
    # rows still reference, so a `removed_step` gravestone is only deleted
    # once nothing can land on it any more.
    #
    # Each name maps to the number of rows still referencing it. An empty
    # hash means every in-flight workflow has drained past the removal and
    # the `removed_step` lines can go.
    #
    # Rows belonging to finished and canceled workflows are ignored - they
    # will never execute again.
    #
    # @return [Hash{String => Integer}] removed step names to referencing row counts
    #
    # @example
    #   PaymentWorkflow.removed_steps_in_flight
    #   # => {"capture_payment" => 3}
    def removed_steps_in_flight
      removed_names = steps.removed.map(&:name)
      return {} if removed_names.empty?

      GenevaDrive::StepExecution
        .where(step_name: removed_names)
        .where(workflow_id: where.not(state: %w[finished canceled]).select(:id))
        .group(:step_name)
        .count
    end

    # Whether this backend's storage is reachable, so HousekeepingJob knows
    # to sweep it. In an app where ActiveRecord is loaded but GenevaDrive's
    # tables were never migrated (a Mongoid-only app, say), the sweep is
    # skipped instead of erroring.
    #
    # @return [Boolean]
    def housekeeping_available?
      table_exists?
    rescue
      false
    end

    # Workflow counts grouped by (state, workflow type), for the housekeeping
    # gauges.
    #
    # @return [Hash{Array(String, String) => Integer}]
    def housekeeping_state_type_counts
      group(:state, :type).count
    end

    # Deletes terminal (finished/canceled) workflows that transitioned before
    # the cutoff, along with their step executions and signals, in batches.
    # Uses efficient batched SQL DELETEs - step executions are deleted first
    # via INNER JOIN, then signals, then workflows.
    #
    # @param cutoff_time [Time] workflows transitioned before this time are eligible
    # @param batch_size [Integer] maximum records to delete per batch
    # @param logger [Logger]
    # @return [Hash{Symbol => Integer}] deleted counts
    def sweep_terminal_workflows!(cutoff_time, batch_size, logger:)
      totals = {workflows: 0, step_executions: 0, signals: 0}

      # First pass: delete all step executions for old workflows using INNER JOIN
      loop do
        deleted_count = delete_step_executions_batch(cutoff_time, batch_size)
        logger.info("Deleted #{deleted_count} step executions")
        totals[:step_executions] += deleted_count
        break if deleted_count < batch_size
      end

      # Second pass: delete the signals delivered to old workflows
      if GenevaDrive::Signal.table_available?
        loop do
          deleted_count = delete_signals_batch(cutoff_time, batch_size)
          logger.info("Deleted #{deleted_count} signals")
          totals[:signals] += deleted_count
          break if deleted_count < batch_size
        end
      end

      # Third pass: delete the workflows themselves
      loop do
        deleted_count = delete_workflows_batch(cutoff_time, batch_size)
        logger.info("Deleted #{deleted_count} workflows")
        totals[:workflows] += deleted_count
        break if deleted_count < batch_size
      end

      totals
    end

    private

    # Deletes a batch of signals belonging to old workflows.
    #
    # @param cutoff_time [Time] workflows transitioned before this time are eligible
    # @param batch_size [Integer] maximum records to delete in this batch
    # @return [Integer] number of records deleted
    def delete_signals_batch(cutoff_time, batch_size)
      GenevaDrive::Signal.connection_pool.with_connection do |conn|
        signals_table = conn.quote_table_name(GenevaDrive::Signal.table_name)
        workflows_table = conn.quote_table_name(table_name)
        limit = batch_size.to_i

        # MySQL doesn't support LIMIT in subqueries with IN, so we wrap it in another SELECT
        # Also, MySQL doesn't handle bind parameters for LIMIT properly, so we interpolate directly
        sql = <<~SQL.squish
          DELETE FROM #{signals_table}
          WHERE id IN (
            SELECT id FROM (
              SELECT s.id
              FROM #{signals_table} s
              INNER JOIN #{workflows_table} w ON w.id = s.workflow_id
              WHERE w.state IN ('finished', 'canceled')
              AND w.transitioned_at < ?
              LIMIT #{limit}
            ) AS batch_to_delete
          )
        SQL

        conn.delete(GenevaDrive::Signal.sanitize_sql([sql, cutoff_time]))
      end
    end

    # Deletes a batch of step executions belonging to old workflows.
    #
    # @param cutoff_time [Time] workflows transitioned before this time are eligible
    # @param batch_size [Integer] maximum records to delete in this batch
    # @return [Integer] number of records deleted
    def delete_step_executions_batch(cutoff_time, batch_size)
      GenevaDrive::StepExecution.connection_pool.with_connection do |conn|
        step_executions_table = conn.quote_table_name(GenevaDrive::StepExecution.table_name)
        workflows_table = conn.quote_table_name(table_name)
        limit = batch_size.to_i

        # MySQL doesn't support LIMIT in subqueries with IN, so we wrap it in another SELECT
        # Also, MySQL doesn't handle bind parameters for LIMIT properly, so we interpolate directly
        sql = <<~SQL.squish
          DELETE FROM #{step_executions_table}
          WHERE id IN (
            SELECT id FROM (
              SELECT se.id
              FROM #{step_executions_table} se
              INNER JOIN #{workflows_table} w ON w.id = se.workflow_id
              WHERE w.state IN ('finished', 'canceled')
              AND w.transitioned_at < ?
              LIMIT #{limit}
            ) AS batch_to_delete
          )
        SQL

        conn.delete(GenevaDrive::StepExecution.sanitize_sql([sql, cutoff_time]))
      end
    end

    # Deletes a batch of old workflows.
    #
    # @param cutoff_time [Time] workflows transitioned before this time are eligible
    # @param batch_size [Integer] maximum records to delete in this batch
    # @return [Integer] number of records deleted
    def delete_workflows_batch(cutoff_time, batch_size)
      connection_pool.with_connection do |conn|
        workflows_table = conn.quote_table_name(table_name)
        limit = batch_size.to_i

        # MySQL doesn't support LIMIT in subqueries with IN, so we wrap it in another SELECT
        # Also, MySQL doesn't handle bind parameters for LIMIT properly, so we interpolate directly
        sql = <<~SQL.squish
          DELETE FROM #{workflows_table}
          WHERE id IN (
            SELECT id FROM (
              SELECT id FROM #{workflows_table}
              WHERE state IN ('finished', 'canceled')
              AND transitioned_at < ?
              LIMIT #{limit}
            ) AS batch_to_delete
          )
        SQL

        conn.delete(sanitize_sql([sql, cutoff_time]))
      end
    end

    # Implement fallback for removed ActiveRecord subclasses. When we try to examine a Workflow
    # which exists in our database - but its class has been removed - this would otherwise fail
    # with an ActiveRecord::SubclassNotFound. We need to avoid this because even if a class has
    # been removed - we should still be able to examine a workflow that was using it.
    #
    # @return [self]
    def find_sti_class(_type_name)
      super
    rescue ActiveRecord::SubclassNotFound
      self
    end
  end

  private

  # Validates that no other ongoing workflow exists for the same (type, hero).
  # Mirrors the database unique index on (type, hero_type, hero_id) for ongoing workflows.
  #
  # @return [void]
  def validate_unique_ongoing_workflow
    scope = self.class.base_class.where(type: self.class.sti_name, hero_type: hero_type, hero_id: hero_id)
      .where.not(state: %w[finished canceled])
      .where(allow_multiple: false)
    scope = scope.where.not(id: id) if persisted?
    if scope.exists?
      errors.add(:base, "An ongoing workflow of this type already exists for this hero")
    end
  end

  # Points a signal's workflow association at this instance, so matcher
  # blocks - which are instance_exec'd on it - see the live object.
  #
  # @param signal [GenevaDrive::Signal]
  # @return [GenevaDrive::Signal] the same signal
  def adopt_signal(signal)
    signal.association(:workflow).target = self
    signal
  end

  # Persists a new signal row, honoring the dedup unique index. Called by the
  # shared signal! with the workflow lock held.
  #
  # A savepoint keeps hitting the dedup index from poisoning the transaction -
  # the caller's, if they had one open, or ours.
  #
  # @param name [String] the signal name
  # @param dedup_key [String, nil] the idempotency key
  # @param serialized_payload [Object, nil] the pre-serialized payload
  # @return [Array(GenevaDrive::Signal, Boolean)] the signal and whether it
  #   was an existing row (a duplicate delivery)
  def insert_signal_with_dedup!(name, dedup_key, serialized_payload)
    signal = nil
    transaction(requires_new: true) do
      record = signals.new(name: name, idempotency_key: dedup_key, state: "pending")
      record[:payload] = serialized_payload
      record.save!
      signal = record
    end
    [signal, false]
  rescue ActiveRecord::RecordNotUnique
    signal = signals.find_by!(name: name, idempotency_key: dedup_key)
    logger.info("Signal #{name.inspect} is a duplicate delivery of signal #{signal.id}, not dispatching")
    [signal, true]
  end

  # The savepoint in insert_signal_with_dedup! settles every dedup race on
  # ActiveRecord, so there is never anything to recover here.
  #
  # @return [nil]
  def recover_signal_from_dedup_race(_error, _name, _dedup_key)
    nil
  end

  # Cancels any scheduled or parked step executions so that the execution
  # about to be created is the only one that will run. In-progress executions
  # are left alone - they are being executed.
  #
  # Safe to use update_all because the caller holds the workflow lock, which
  # blocks any executor that would try to start these steps. Parked executions
  # are swept for the same reason: no legitimate path creates a new execution
  # past one that is waiting.
  #
  # @return [Integer] the number of executions canceled
  def cancel_stray_executions!
    canceled_count = step_executions.where(state: %w[scheduled waiting]).update_all(
      state: "canceled",
      outcome: "canceled",
      canceled_at: Time.current
    )
    logger.debug("Canceled #{canceled_count} previously scheduled step execution(s)") if canceled_count > 0
    canceled_count
  end

  # Runs a block either after all transactions commit or immediately.
  #
  # The behavior depends on GenevaDrive.enqueues_deferred?, which checks:
  # - Whether we're inside a GenevaDrive.with_inline_enqueue block
  # - The GenevaDrive.enqueue_after_commit global setting
  #
  # In production (enqueue_after_commit = true), deferring to
  # after_all_transactions_commit ensures that records written inside the
  # transaction are visible to job workers.
  #
  # In tests (enqueue_after_commit = false), or inside a
  # with_inline_enqueue block, the block runs immediately.
  #
  # @yield the block to run (typically hands a step to the dispatcher)
  # @return [void]
  def run_after_commit(&block)
    if GenevaDrive.enqueues_deferred?
      ActiveRecord.after_all_transactions_commit(&block)
    else
      yield
    end
  end

  # The logger to tag when none was injected - ActiveRecord's own.
  #
  # @return [Logger]
  def default_base_logger
    self.class.logger
  end
end
