# frozen_string_literal: true

# Mongoid tests run only under `rake test:mongoid` (or `rake test:proofs`
# under a mongoid_* appraisal), which boots the dummy app against MongoDB
# (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"
require "proofs/concurrency_proofs"

# The proof obligations from MONGOID_DESIGN.md: the shared concurrency proof
# pack (test/proofs/concurrency_proofs.rb) runs real threads against the live
# replica set and demonstrates that the document-lock transaction wrapper
# preserves the SQL implementation's transactional guarantees. This file
# provides the Mongoid backend's side of the proofs: the models, the raw
# insert helpers that bypass the application code, and the lock bookkeeping
# that must roll back with everything else.
class AtomicTransitionsTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers
  include ConcurrencyProofs

  class RaceWorkflow < GenevaDrive::MongoidWorkflow
    step :one do
    end

    step :two do
    end

    step :three do
    end
  end

  private

  def race_workflow_class
    RaceWorkflow
  end

  def workflow_model
    GenevaDrive::MongoidWorkflow
  end

  def create_hero
    create_user
  end

  def count_active_executions(workflow_id)
    GenevaDrive::MongoidStepExecution
      .where(:workflow_id => workflow_id, :state.in => %w[scheduled in_progress])
      .count
  end

  def execution_outcomes
    GenevaDrive::MongoidStepExecution::OUTCOMES
  end

  def transition_race_errors
    [
      GenevaDrive::InvalidStateError,
      GenevaDrive::InvalidStateTransition,
      GenevaDrive::StepExecutionError,
      Mongoid::Errors::DocumentNotFound
    ]
  end

  def duplicate_key_error_classes
    [Mongo::Error::OperationFailure]
  end

  def duplicate_key_error?(error)
    GenevaDrive::DocumentLock.duplicate_key_error?(error)
  end

  # insert_one bypasses the models entirely: only the partial unique index on
  # active_key can stop this row.
  def raw_insert_duplicate_active_execution(workflow)
    GenevaDrive::MongoidStepExecution.collection.insert_one(
      workflow_id: workflow.id,
      step_name: "one",
      state: "scheduled",
      scheduled_for: Time.current,
      active_key: workflow.id
    )
  end

  def raw_insert_duplicate_ongoing_workflow(workflow, hero)
    GenevaDrive::MongoidWorkflow.collection.insert_one(
      _type: RaceWorkflow.name,
      state: "ready",
      hero_type: hero.class.name,
      hero_id: hero.id,
      allow_multiple: false,
      ongoing_key: workflow.reload.ongoing_key
    )
  end

  def acceptable_create_loser?(error)
    error.is_a?(Mongoid::Errors::Validations) ||
      (error.is_a?(Mongo::Error::OperationFailure) && GenevaDrive::DocumentLock.duplicate_key_error?(error))
  end

  def ongoing_workflow_count_for(hero)
    GenevaDrive::MongoidWorkflow
      .where(:state.nin => %w[finished canceled], :hero_id => hero.id)
      .count
  end

  def total_workflow_count_for(hero)
    GenevaDrive::MongoidWorkflow.where(hero_id: hero.id).count
  end

  # The document lock bumps lock_version on every locked write; a rollback
  # must discard even that bookkeeping write.
  def extra_rollback_state(workflow)
    {lock_version: workflow.lock_version}
  end
end
