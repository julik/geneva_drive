# frozen_string_literal: true

require "test_helper"

class HousekeepingJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class SimpleWorkflow < GenevaDrive::Workflow
    step :step_one do
      # Step body
    end

    step :step_two do
      # Step body
    end
  end

  setup do
    @user = create_user
    @original_delete_after = GenevaDrive.delete_completed_workflows_after
    @original_stuck_in_progress = GenevaDrive.stuck_in_progress_threshold
    @original_stuck_scheduled = GenevaDrive.stuck_scheduled_threshold
    @original_recovery_action = GenevaDrive.stuck_recovery_action
    @original_batch_size = GenevaDrive.housekeeping_batch_size
  end

  teardown do
    GenevaDrive.delete_completed_workflows_after = @original_delete_after
    GenevaDrive.stuck_in_progress_threshold = @original_stuck_in_progress
    GenevaDrive.stuck_scheduled_threshold = @original_stuck_scheduled
    GenevaDrive.stuck_recovery_action = @original_recovery_action
    GenevaDrive.housekeeping_batch_size = @original_batch_size
  end

  # Cleanup tests

  test "does not cleanup when delete_completed_workflows_after is nil" do
    GenevaDrive.delete_completed_workflows_after = nil

    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.transition_to!("finished")
    workflow.update!(transitioned_at: 1.year.ago)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 0, result[:workflows_cleaned_up]
    assert GenevaDrive::Workflow.exists?(workflow.id)
  end

  test "cleans up finished workflows older than threshold" do
    GenevaDrive.delete_completed_workflows_after = 30.days

    # Create a finished workflow older than threshold
    old_workflow = SimpleWorkflow.create!(hero: @user)
    old_workflow.transition_to!("finished")
    old_workflow.update!(transitioned_at: 31.days.ago)
    old_step_count = old_workflow.step_executions.count

    # Create a recent finished workflow (should not be cleaned)
    recent_workflow = SimpleWorkflow.create!(hero: @user, allow_multiple: true)
    recent_workflow.transition_to!("finished")
    recent_workflow.update!(transitioned_at: 1.day.ago)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, result[:workflows_cleaned_up]
    assert_equal old_step_count, result[:step_executions_cleaned_up]
    assert_not GenevaDrive::Workflow.exists?(old_workflow.id)
    assert GenevaDrive::Workflow.exists?(recent_workflow.id)
  end

  test "cleans up canceled workflows older than threshold" do
    GenevaDrive.delete_completed_workflows_after = 30.days

    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.transition_to!("canceled")
    workflow.update!(transitioned_at: 31.days.ago)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, result[:workflows_cleaned_up]
    assert_not GenevaDrive::Workflow.exists?(workflow.id)
  end

  test "does not cleanup ongoing workflows" do
    GenevaDrive.delete_completed_workflows_after = 30.days

    # Create ongoing workflows
    ready_workflow = SimpleWorkflow.create!(hero: @user)
    ready_workflow.update!(created_at: 31.days.ago)

    paused_workflow = SimpleWorkflow.create!(hero: @user, allow_multiple: true)
    paused_workflow.transition_to!("paused")
    paused_workflow.update!(transitioned_at: 31.days.ago)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 0, result[:workflows_cleaned_up]
    assert GenevaDrive::Workflow.exists?(ready_workflow.id)
    assert GenevaDrive::Workflow.exists?(paused_workflow.id)
  end

  test "respects batch size for cleanup" do
    GenevaDrive.delete_completed_workflows_after = 30.days
    GenevaDrive.housekeeping_batch_size = 2

    3.times do |i|
      workflow = SimpleWorkflow.create!(hero: @user, allow_multiple: true)
      workflow.transition_to!("finished")
      workflow.update!(transitioned_at: 31.days.ago)
    end

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 2, result[:workflows_cleaned_up]
    assert_equal 1, GenevaDrive::Workflow.where(state: "finished").count
  end

  test "deletes step executions with delete_all for efficiency" do
    GenevaDrive.delete_completed_workflows_after = 30.days

    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_completed!
    workflow.schedule_next_step!
    workflow.transition_to!("finished")
    workflow.update!(transitioned_at: 31.days.ago)

    step_execution_ids = workflow.step_executions.pluck(:id)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 2, result[:step_executions_cleaned_up]
    step_execution_ids.each do |id|
      assert_not GenevaDrive::StepExecution.exists?(id)
    end
  end

  # Recovery tests - stuck in_progress

  test "recovers step executions stuck in in_progress state with reattempt" do
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :reattempt

    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Simulate stuck in in_progress
    step_execution.update!(
      state: "in_progress",
      started_at: 2.hours.ago
    )
    workflow.update!(state: "performing")

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, result[:stuck_in_progress_recovered]

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "recovered", step_execution.outcome
    assert_equal "ready", workflow.state
    # A new step execution should be scheduled
    assert_equal 2, workflow.step_executions.count
  end

  test "recovers step executions stuck in in_progress state with cancel" do
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :cancel

    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    step_execution.update!(
      state: "in_progress",
      started_at: 2.hours.ago
    )
    workflow.update!(state: "performing")

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, result[:stuck_in_progress_recovered]

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "recovered", step_execution.outcome
    assert_equal "canceled", workflow.state
  end

  test "does not recover recently in_progress step executions" do
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :reattempt

    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    step_execution.update!(
      state: "in_progress",
      started_at: 30.minutes.ago
    )
    workflow.update!(state: "performing")

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 0, result[:stuck_in_progress_recovered]

    step_execution.reload
    assert_equal "in_progress", step_execution.state
  end

  # Recovery tests - stuck scheduled

  test "recovers step executions stuck in scheduled state with reattempt" do
    GenevaDrive.stuck_scheduled_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :reattempt

    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Simulate stuck in scheduled (job never picked it up)
    step_execution.update!(scheduled_for: 2.hours.ago)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, result[:stuck_scheduled_recovered]

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "recovered", step_execution.outcome
    assert_equal "ready", workflow.state
    # A new step execution should be scheduled
    assert_equal 2, workflow.step_executions.count
  end

  test "recovers step executions stuck in scheduled state with cancel" do
    GenevaDrive.stuck_scheduled_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :cancel

    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    step_execution.update!(scheduled_for: 2.hours.ago)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, result[:stuck_scheduled_recovered]

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
  end

  test "does not recover step executions scheduled for the future" do
    GenevaDrive.stuck_scheduled_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :reattempt

    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # This is scheduled for the future
    step_execution.update!(scheduled_for: 1.hour.from_now)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 0, result[:stuck_scheduled_recovered]

    step_execution.reload
    assert_equal "scheduled", step_execution.state
  end

  test "does not recover recently scheduled step executions" do
    GenevaDrive.stuck_scheduled_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :reattempt

    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Scheduled 30 minutes ago (within threshold)
    step_execution.update!(scheduled_for: 30.minutes.ago)

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 0, result[:stuck_scheduled_recovered]

    step_execution.reload
    assert_equal "scheduled", step_execution.state
  end

  # Combined tests

  test "performs both cleanup and recovery in one run" do
    GenevaDrive.delete_completed_workflows_after = 30.days
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :reattempt

    # Create old finished workflow
    old_workflow = SimpleWorkflow.create!(hero: @user)
    old_workflow.transition_to!("finished")
    old_workflow.update!(transitioned_at: 31.days.ago)

    # Create stuck workflow
    stuck_workflow = SimpleWorkflow.create!(hero: @user, allow_multiple: true)
    stuck_step = stuck_workflow.step_executions.first
    stuck_step.update!(state: "in_progress", started_at: 2.hours.ago)
    stuck_workflow.update!(state: "performing")

    result = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, result[:workflows_cleaned_up]
    assert_equal 1, result[:stuck_in_progress_recovered]
    assert_not GenevaDrive::Workflow.exists?(old_workflow.id)
    assert_equal "ready", stuck_workflow.reload.state
  end

  test "handles errors gracefully during recovery" do
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :reattempt

    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    step_execution.update!(state: "in_progress", started_at: 2.hours.ago)
    workflow.update!(state: "performing")

    # Delete the workflow to cause an error during recovery
    workflow_id = workflow.id
    GenevaDrive::Workflow.where(id: workflow_id).update_all(state: "canceled")

    # Should not raise, but log error
    assert_nothing_raised do
      GenevaDrive::HousekeepingJob.perform_now
    end
  end

  test "returns summary of actions taken" do
    GenevaDrive.delete_completed_workflows_after = 30.days
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_scheduled_threshold = 1.hour

    result = GenevaDrive::HousekeepingJob.perform_now

    assert result.key?(:workflows_cleaned_up)
    assert result.key?(:step_executions_cleaned_up)
    assert result.key?(:stuck_in_progress_recovered)
    assert result.key?(:stuck_scheduled_recovered)
  end
end
