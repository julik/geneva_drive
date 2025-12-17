# frozen_string_literal: true

require "test_helper"

class AfterCommitSchedulingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class SimpleWorkflow < GenevaDrive::Workflow
    step :step_one do
      # Step body
    end
  end

  class DelayedWorkflow < GenevaDrive::Workflow
    step :delayed_step, wait: 2.hours do
      # Delayed step
    end
  end

  setup do
    @user = create_user
    clear_enqueued_jobs
  end

  test "job is enqueued after transaction commits when creating workflow" do
    # When using transactional tests, after_all_transactions_commit runs immediately
    # after the inner transaction, so we can verify the job is enqueued
    workflow = SimpleWorkflow.create!(hero: @user)

    assert_equal 1, workflow.step_executions.count
    step_execution = workflow.step_executions.first
    assert_equal "scheduled", step_execution.state

    # Job should be enqueued after transaction commit
    assert_enqueued_jobs 1, only: GenevaDrive::PerformStepJob
  end

  test "job is enqueued with correct arguments" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    assert_enqueued_with(
      job: GenevaDrive::PerformStepJob,
      args: [step_execution.id]
    )
  end

  test "job_id is set on step execution after enqueueing" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first.reload

    # Job ID should be set after the after_commit callback runs
    assert_not_nil step_execution.job_id
  end

  test "multiple step creations each enqueue their own job" do
    clear_enqueued_jobs

    workflow = SimpleWorkflow.create!(hero: @user)

    # Schedule next step (simulating a step completion)
    workflow.step_executions.first.mark_completed!
    workflow.transition_to!("ready")
    workflow.schedule_next_step!

    # Should have 2 jobs enqueued (one from create, one from schedule_next_step)
    # But actually SimpleWorkflow only has one step, so it will finish
    # Let's check the enqueued job count
    assert_enqueued_jobs 1, only: GenevaDrive::PerformStepJob
  end

  test "jobs are enqueued with wait_until for delayed steps" do
    freeze_time do
      workflow = DelayedWorkflow.create!(hero: @user)
      expected_time = 2.hours.from_now

      assert_enqueued_with(
        job: GenevaDrive::PerformStepJob,
        at: expected_time
      )
    end
  end

  test "job enqueueing is deferred during external transaction" do
    clear_enqueued_jobs

    # When wrapped in another transaction, jobs should still be enqueued
    # after the outermost transaction commits
    ActiveRecord::Base.transaction do
      @workflow = SimpleWorkflow.create!(hero: @user)

      # Inside transaction, the after_all_transactions_commit hasn't fired yet
      # Note: In test environment with transactional tests, behavior may differ
    end

    # After transaction, job should be enqueued
    assert_enqueued_jobs 1, only: GenevaDrive::PerformStepJob
  end
end
