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

  class ThreeStepWorkflow < GenevaDrive::Workflow
    step :first do
    end

    step :second do
    end

    step :third do
    end
  end

  class WaitingWorkflow < GenevaDrive::Workflow
    step :immediate_step do
    end

    step :delayed_step, wait: 2.days do
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

  test "processes all workflows in multiple batches during cleanup" do
    GenevaDrive.delete_completed_workflows_after = 30.days
    GenevaDrive.housekeeping_batch_size = 2

    # Create 5 old finished workflows - should all be cleaned up in multiple batches
    5.times do |i|
      workflow = SimpleWorkflow.create!(hero: @user, allow_multiple: true)
      workflow.transition_to!("finished")
      workflow.update!(transitioned_at: 31.days.ago)
    end

    result = GenevaDrive::HousekeepingJob.perform_now

    # All 5 should be cleaned up despite batch size of 2
    assert_equal 5, result[:workflows_cleaned_up]
    assert_equal 0, GenevaDrive::Workflow.where(state: "finished").count
  end

  test "deletes step executions with efficient SQL DELETE" do
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

  test "processes all stuck in_progress executions in multiple batches" do
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :cancel
    GenevaDrive.housekeeping_batch_size = 3

    # Create 7 stuck workflows - should all be recovered in multiple batches
    7.times do |i|
      workflow = SimpleWorkflow.create!(hero: @user, allow_multiple: true)
      step_execution = workflow.step_executions.first
      step_execution.update!(state: "in_progress", started_at: 2.hours.ago)
      workflow.update!(state: "performing")
    end

    result = GenevaDrive::HousekeepingJob.perform_now

    # All 7 should be recovered despite batch size of 3
    assert_equal 7, result[:stuck_in_progress_recovered]
    assert_equal 0, GenevaDrive::StepExecution.in_progress.count
  end

  test "processes all stuck scheduled executions in multiple batches" do
    GenevaDrive.stuck_scheduled_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :cancel
    GenevaDrive.housekeeping_batch_size = 3

    # Create 7 stuck scheduled workflows - should all be recovered
    7.times do |i|
      workflow = SimpleWorkflow.create!(hero: @user, allow_multiple: true)
      step_execution = workflow.step_executions.first
      step_execution.update!(scheduled_for: 2.hours.ago)
    end

    result = GenevaDrive::HousekeepingJob.perform_now

    # All 7 should be recovered despite batch size of 3
    assert_equal 7, result[:stuck_scheduled_recovered]
  end

  # Large-scale tests with deterministic random data

  test "large scale cleanup: processes 2000+ workflows with varied ages" do
    GenevaDrive.delete_completed_workflows_after = 30.days
    GenevaDrive.housekeeping_batch_size = 100

    rng = Random.new(42) # Fixed seed for deterministic test
    workflow_classes = [SimpleWorkflow, ThreeStepWorkflow, WaitingWorkflow]
    terminal_states = %w[finished canceled]

    created_old_workflows = 0
    created_recent_workflows = 0

    # Create 2500 workflows with random ages
    # Roughly 80% old (should be deleted), 20% recent (should be kept)
    2500.times do |i|
      workflow_class = workflow_classes[rng.rand(workflow_classes.size)]
      workflow = workflow_class.create!(hero: @user, allow_multiple: true)
      state = terminal_states[rng.rand(terminal_states.size)]
      workflow.transition_to!(state)

      # Generate random age: 80% chance of being 31-180 days old, 20% chance of being 1-29 days old
      if rng.rand < 0.8
        days_ago = rng.rand(31..180)
        created_old_workflows += 1
      else
        days_ago = rng.rand(1..29)
        created_recent_workflows += 1
      end

      workflow.update!(transitioned_at: days_ago.days.ago)
    end

    GenevaDrive::Workflow.count
    GenevaDrive::StepExecution.count

    result = GenevaDrive::HousekeepingJob.perform_now

    # Verify all old workflows were cleaned up
    assert_equal created_old_workflows, result[:workflows_cleaned_up],
      "Expected #{created_old_workflows} workflows to be cleaned up"

    # Verify recent workflows are still present
    remaining_count = GenevaDrive::Workflow.count
    assert_equal created_recent_workflows, remaining_count,
      "Expected #{created_recent_workflows} recent workflows to remain"

    # Verify step executions were also cleaned up
    assert result[:step_executions_cleaned_up] > 0,
      "Expected step executions to be cleaned up"

    # Verify remaining workflows are all recent
    GenevaDrive::Workflow.find_each do |workflow|
      assert workflow.transitioned_at > 30.days.ago,
        "Workflow #{workflow.id} should have been deleted (transitioned_at: #{workflow.transitioned_at})"
    end
  end

  test "large scale recovery: processes 1000+ stuck in_progress workflows" do
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :cancel
    GenevaDrive.housekeeping_batch_size = 50

    rng = Random.new(123) # Fixed seed for deterministic test
    workflow_classes = [SimpleWorkflow, ThreeStepWorkflow, WaitingWorkflow]

    created_stuck_count = 0
    created_recent_count = 0

    # Create 1200 workflows with random stuck durations
    # 85% should be stuck (>1 hour), 15% should be recent (<1 hour)
    1200.times do |i|
      workflow_class = workflow_classes[rng.rand(workflow_classes.size)]
      workflow = workflow_class.create!(hero: @user, allow_multiple: true)
      step_execution = workflow.step_executions.first

      if rng.rand < 0.85
        # Stuck: 61 minutes to 24 hours ago
        minutes_ago = rng.rand(61..1440)
        created_stuck_count += 1
      else
        # Recent: 1 to 59 minutes ago
        minutes_ago = rng.rand(1..59)
        created_recent_count += 1
      end

      step_execution.update!(
        state: "in_progress",
        started_at: minutes_ago.minutes.ago
      )
      workflow.update!(state: "performing")
    end

    result = GenevaDrive::HousekeepingJob.perform_now

    # Verify all stuck workflows were recovered
    assert_equal created_stuck_count, result[:stuck_in_progress_recovered],
      "Expected #{created_stuck_count} stuck in_progress executions to be recovered"

    # Verify recent ones are still in_progress
    still_in_progress = GenevaDrive::StepExecution.in_progress.count
    assert_equal created_recent_count, still_in_progress,
      "Expected #{created_recent_count} recent in_progress executions to remain"
  end

  test "large scale recovery: processes 1000+ stuck scheduled workflows" do
    GenevaDrive.stuck_scheduled_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :cancel
    GenevaDrive.housekeeping_batch_size = 50

    rng = Random.new(456) # Fixed seed for deterministic test
    workflow_classes = [SimpleWorkflow, ThreeStepWorkflow, WaitingWorkflow]

    created_stuck_count = 0
    created_recent_count = 0
    created_future_count = 0

    # Create 1200 workflows with random scheduled times
    # 70% stuck (>1 hour ago), 15% recent (<1 hour ago), 15% future
    1200.times do |i|
      workflow_class = workflow_classes[rng.rand(workflow_classes.size)]
      workflow = workflow_class.create!(hero: @user, allow_multiple: true)
      step_execution = workflow.step_executions.first

      category = rng.rand
      if category < 0.70
        # Stuck: 61 minutes to 48 hours ago
        minutes_ago = rng.rand(61..2880)
        step_execution.update!(scheduled_for: minutes_ago.minutes.ago)
        created_stuck_count += 1
      elsif category < 0.85
        # Recent: 1 to 59 minutes ago
        minutes_ago = rng.rand(1..59)
        step_execution.update!(scheduled_for: minutes_ago.minutes.ago)
        created_recent_count += 1
      else
        # Future: 1 minute to 24 hours from now
        minutes_from_now = rng.rand(1..1440)
        step_execution.update!(scheduled_for: minutes_from_now.minutes.from_now)
        created_future_count += 1
      end
    end

    result = GenevaDrive::HousekeepingJob.perform_now

    # Verify all stuck workflows were recovered
    assert_equal created_stuck_count, result[:stuck_scheduled_recovered],
      "Expected #{created_stuck_count} stuck scheduled executions to be recovered"

    # Verify recent and future ones are still scheduled
    still_scheduled = GenevaDrive::StepExecution.scheduled.count
    expected_remaining = created_recent_count + created_future_count
    assert_equal expected_remaining, still_scheduled,
      "Expected #{expected_remaining} non-stuck scheduled executions to remain"
  end

  test "large scale combined: cleanup and recovery together" do
    GenevaDrive.delete_completed_workflows_after = 30.days
    GenevaDrive.stuck_in_progress_threshold = 1.hour
    GenevaDrive.stuck_scheduled_threshold = 1.hour
    GenevaDrive.stuck_recovery_action = :reattempt
    GenevaDrive.housekeeping_batch_size = 75

    rng = Random.new(789) # Fixed seed for deterministic test
    workflow_classes = [SimpleWorkflow, ThreeStepWorkflow, WaitingWorkflow]

    old_finished_count = 0
    recent_finished_count = 0
    stuck_in_progress_count = 0
    stuck_scheduled_count = 0
    active_count = 0

    # Create 3000 workflows in various states
    3000.times do |i|
      workflow_class = workflow_classes[rng.rand(workflow_classes.size)]
      workflow = workflow_class.create!(hero: @user, allow_multiple: true)

      category = rng.rand
      if category < 0.35
        # Old finished/canceled workflow (should be deleted)
        state = %w[finished canceled][rng.rand(2)]
        workflow.transition_to!(state)
        days_ago = rng.rand(31..365)
        workflow.update!(transitioned_at: days_ago.days.ago)
        old_finished_count += 1

      elsif category < 0.45
        # Recent finished workflow (should NOT be deleted)
        workflow.transition_to!("finished")
        days_ago = rng.rand(1..29)
        workflow.update!(transitioned_at: days_ago.days.ago)
        recent_finished_count += 1

      elsif category < 0.60
        # Stuck in_progress (should be recovered)
        step_execution = workflow.step_executions.first
        minutes_ago = rng.rand(61..1440)
        step_execution.update!(state: "in_progress", started_at: minutes_ago.minutes.ago)
        workflow.update!(state: "performing")
        stuck_in_progress_count += 1

      elsif category < 0.75
        # Stuck scheduled (should be recovered)
        step_execution = workflow.step_executions.first
        minutes_ago = rng.rand(61..2880)
        step_execution.update!(scheduled_for: minutes_ago.minutes.ago)
        stuck_scheduled_count += 1

      else
        # Active workflow (should NOT be touched)
        # Just leave it in its default state
        active_count += 1
      end
    end

    result = GenevaDrive::HousekeepingJob.perform_now

    # Verify cleanup
    assert_equal old_finished_count, result[:workflows_cleaned_up],
      "Expected #{old_finished_count} old workflows to be cleaned up"
    assert result[:step_executions_cleaned_up] > 0

    # Verify stuck recovery
    assert_equal stuck_in_progress_count, result[:stuck_in_progress_recovered],
      "Expected #{stuck_in_progress_count} stuck in_progress executions to be recovered"
    assert_equal stuck_scheduled_count, result[:stuck_scheduled_recovered],
      "Expected #{stuck_scheduled_count} stuck scheduled executions to be recovered"

    # Verify remaining workflows: recent finished + recovered + active
    # Note: recovered workflows transition to "ready" with reattempt action
    remaining_count = GenevaDrive::Workflow.count
    expected_remaining = recent_finished_count + stuck_in_progress_count + stuck_scheduled_count + active_count
    assert_equal expected_remaining, remaining_count,
      "Expected #{expected_remaining} workflows to remain"
  end

  test "deterministic random seed produces consistent results" do
    GenevaDrive.delete_completed_workflows_after = 30.days
    GenevaDrive.housekeeping_batch_size = 50

    # Run twice with same seed - should get identical distributions
    [1, 2].each do |run|
      GenevaDrive::Workflow.destroy_all

      rng = Random.new(999)
      workflow_classes = [SimpleWorkflow, ThreeStepWorkflow]

      100.times do
        workflow_class = workflow_classes[rng.rand(workflow_classes.size)]
        workflow = workflow_class.create!(hero: @user, allow_multiple: true)
        workflow.transition_to!("finished")
        days_ago = rng.rand(1..60)
        workflow.update!(transitioned_at: days_ago.days.ago)
      end

      result = GenevaDrive::HousekeepingJob.perform_now

      # With seed 999 and this distribution, we should always get the same count
      # (exact count depends on random distribution, but should be consistent)
      if run == 1
        @first_run_cleaned = result[:workflows_cleaned_up]
      else
        assert_equal @first_run_cleaned, result[:workflows_cleaned_up],
          "Second run should clean same number of workflows as first run with same seed"
      end
    end
  end
end
