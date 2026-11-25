# frozen_string_literal: true

# The ActiveRecord flavour of the concurrency proof pack. Deliberately kept
# out of the default suite (which stays fast and transactional): these tests
# run real threads against real committed transactions, so run them through
# the rake task that sets the environment up -
#
#   bundle exec rake test:proofs
#
# - against whatever engine DATABASE_URL selects, exactly like the main suite.
return unless ENV["GENEVA_DRIVE_PROOFS"]
return if ENV["GENEVA_DRIVE_ORM"] == "mongoid"

require "test_helper"
require "proofs/concurrency_proofs"

class ActiveRecordConcurrencyProofsTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers
  include ConcurrencyProofs

  # The racing threads must see each other's commits, so the transactional
  # wrapper is off; the purge below is the isolation instead.
  self.use_transactional_tests = false

  class RaceWorkflow < GenevaDrive::Workflow
    step :one do
    end

    step :two do
    end

    step :three do
    end
  end

  setup do
    purge!
    # Production semantics: enqueues deferred to after-commit. That is the
    # deferral path the crash proof (d) exercises - a rollback must discard
    # the pending enqueues along with the rows.
    @previous_enqueue_after_commit = GenevaDrive.enqueue_after_commit
    GenevaDrive.enqueue_after_commit = true
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  teardown do
    GenevaDrive.enqueue_after_commit = @previous_enqueue_after_commit
    purge!
  end

  private

  def purge!
    GenevaDrive::StepExecution.delete_all
    GenevaDrive::Signal.delete_all
    GenevaDrive::Workflow.delete_all
    User.delete_all
  end

  def race_workflow_class
    RaceWorkflow
  end

  def workflow_model
    GenevaDrive::Workflow
  end

  def create_hero
    create_user
  end

  # Every thread gets its own connection; the pool size is raised by the
  # test:proofs task (RAILS_MAX_THREADS) so the racers can all hold one.
  def with_thread_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def count_active_executions(workflow_id)
    GenevaDrive::StepExecution
      .where(workflow_id: workflow_id, state: %w[scheduled in_progress])
      .count
  end

  def execution_outcomes
    GenevaDrive::StepExecution::OUTCOMES
  end

  def transition_race_errors
    [
      GenevaDrive::InvalidStateError,
      GenevaDrive::InvalidStateTransition,
      GenevaDrive::StepExecutionError,
      ActiveRecord::RecordNotFound
    ]
  end

  def duplicate_key_error_classes
    [ActiveRecord::RecordNotUnique]
  end

  def duplicate_key_error?(error)
    error.is_a?(ActiveRecord::RecordNotUnique)
  end

  # insert_all! skips validations and callbacks: this is a raw INSERT that
  # only the partial unique index (or its generated-column emulation on
  # MySQL/MariaDB) can stop.
  def raw_insert_duplicate_active_execution(workflow)
    now = Time.current
    GenevaDrive::StepExecution.insert_all!([{
      workflow_id: workflow.id,
      step_name: "one",
      state: "scheduled",
      scheduled_for: now,
      created_at: now,
      updated_at: now
    }])
  end

  def raw_insert_duplicate_ongoing_workflow(_workflow, hero)
    now = Time.current
    GenevaDrive::Workflow.insert_all!([{
      type: RaceWorkflow.name,
      state: "ready",
      hero_type: hero.class.name,
      hero_id: hero.id,
      allow_multiple: false,
      created_at: now,
      updated_at: now
    }])
  end

  def acceptable_create_loser?(error)
    error.is_a?(ActiveRecord::RecordInvalid) || error.is_a?(ActiveRecord::RecordNotUnique)
  end

  def ongoing_workflow_count_for(hero)
    GenevaDrive::Workflow.ongoing.where(hero: hero).count
  end

  def total_workflow_count_for(hero)
    GenevaDrive::Workflow.where(hero: hero).count
  end

  # SQLite has no row locks: under write contention it aborts one contender
  # with SQLITE_BUSY instead of blocking it. The aborted transaction wrote
  # nothing - no increment is lost, one is re-run - so retrying the whole
  # read-modify-write preserves the guarantee under proof. Engines with real
  # row locks (PostgreSQL, MySQL, MariaDB) get no retry: a deadlock or a
  # lock-wait timeout there would be a genuine finding.
  def retryable_serialization_error?(error)
    return false unless GenevaDrive::Workflow.connection_db_config.adapter.include?("sqlite")
    error.is_a?(ActiveRecord::StatementInvalid) && error.cause.class.name.start_with?("SQLite3::Busy")
  end
end
