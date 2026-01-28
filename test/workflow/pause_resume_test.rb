# frozen_string_literal: true

require "test_helper"

# Tests for pause!/resume! behavior.
#
# BEHAVIOR:
# - pause!: Leaves scheduled execution intact (visible as "overdue" if time passes)
# - resume!: Re-enqueues job for EXISTING execution (or creates new if executor canceled it)
#
# KEY INSIGHT: The executor (PerformStepJob) already handles the case where a job
# runs while the workflow is paused - it cancels the execution with outcome "canceled"
# and exits. This means if a job runs during pause, the execution gets canceled anyway.
# This improves the common case (pause/resume before scheduled time) while
# gracefully handling the edge case (job runs while paused) by creating a new execution.
#
class PauseResumeTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  # Workflow with a waiting step for testing pause/resume
  class WaitingWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_one_ran] = true
    end

    step :step_two, wait: 2.hours do
      Thread.current[:step_two_ran] = true
    end

    step :step_three do
      Thread.current[:step_three_ran] = true
    end
  end

  # Workflow with immediate steps (no wait) for testing edge cases
  class ImmediateWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_one_ran] = true
    end

    step :step_two do
      Thread.current[:step_two_ran] = true
    end
  end

  setup do
    @user = create_user
    reset_thread_tracking!
  end

  teardown do
    reset_thread_tracking!
  end

  def reset_thread_tracking!
    Thread.current[:step_one_ran] = nil
    Thread.current[:step_two_ran] = nil
    Thread.current[:step_three_ran] = nil
  end

  # ===========================================
  # PAUSE! SCENARIOS
  # ===========================================

  # Scenario: Workflow "ready", scheduled execution in the FUTURE
  #
  # This is the normal case - a step has wait: 2.hours, execution is scheduled
  # for later, job is enqueued with wait_until.
  #
  # Expected: Execution stays "scheduled" with original scheduled_for time.
  # The execution record is preserved, making the timeline accurate.
  #
  test "pause! with future scheduled execution leaves it intact" do
    workflow = WaitingWorkflow.create!(hero: @user)

    # Execute step_one - this schedules step_two for 2 hours from now
    perform_next_step(workflow)
    assert_equal "step_two", workflow.next_step_name

    original_execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    assert original_execution, "Should have a scheduled step_two execution"
    original_id = original_execution.id
    original_scheduled_for = original_execution.scheduled_for

    # Pause the workflow
    workflow.pause!

    assert_equal "paused", workflow.state

    # The execution should still be scheduled, NOT canceled
    original_execution.reload
    assert_equal "scheduled", original_execution.state,
      "Execution should remain 'scheduled', not be canceled"
    assert_equal original_scheduled_for, original_execution.scheduled_for,
      "scheduled_for should be unchanged"
    assert_equal original_id, original_execution.id,
      "Should be the same execution record"

    # Verify no canceled executions were created
    canceled_count = workflow.step_executions.where(step_name: "step_two", state: "canceled").count
    assert_equal 0, canceled_count, "No executions should be canceled"
  end

  # Scenario: Workflow "ready", scheduled execution in the PAST (overdue)
  #
  # The step was scheduled for 2pm, it's now 3pm, but the job hasn't run yet
  # (queue backlog, worker issues, etc.). The execution is "overdue".
  #
  # Expected: Execution stays "scheduled" - it's already overdue, pause just
  # changes workflow state. The overdue status is visible in the timeline.
  #
  test "pause! with overdue scheduled execution leaves it intact" do
    start_time = Time.current
    workflow = nil

    travel_to(start_time) do
      workflow = WaitingWorkflow.create!(hero: @user)
      perform_next_step(workflow)

      execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
      assert_in_delta (start_time + 2.hours).to_f, execution.scheduled_for.to_f, 1.0
    end

    # Fast forward past the scheduled time (execution is now overdue)
    travel_to(start_time + 3.hours) do
      execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
      assert execution.scheduled_for < Time.current, "Execution should be overdue"

      # Pause while overdue
      workflow.pause!

      assert_equal "paused", workflow.state

      # Execution should still be scheduled (overdue but not canceled)
      execution.reload
      assert_equal "scheduled", execution.state
    end
  end

  # Scenario: Workflow "ready", with first step scheduled (just created)
  #
  # Workflow was just created, first step is scheduled. This is the normal
  # initial state - workflows auto-schedule their first step on create.
  #
  # Expected: Execution stays scheduled, workflow transitions to paused.
  #
  test "pause! on freshly created workflow leaves first step scheduled" do
    workflow = WaitingWorkflow.create!(hero: @user)

    # Workflow auto-schedules first step on create
    assert_equal "step_one", workflow.next_step_name
    assert_equal 1, workflow.step_executions.count

    execution = workflow.step_executions.first
    assert_equal "step_one", execution.step_name
    assert_equal "scheduled", execution.state

    workflow.pause!

    assert_equal "paused", workflow.state

    # Execution should still be scheduled
    execution.reload
    assert_equal "scheduled", execution.state
  end

  # Scenario: Workflow "ready", step with NO wait time (immediate)
  #
  # The step has no wait: option, so scheduled_for is "now".
  # By the time pause! runs, the execution might already be overdue.
  #
  # Expected: Same as overdue case - execution stays scheduled.
  #
  test "pause! with immediate step (no wait) leaves execution scheduled" do
    workflow = ImmediateWorkflow.create!(hero: @user)

    # step_one has no wait, so step_two will be scheduled for "now"
    perform_next_step(workflow)

    execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    assert execution, "Should have a scheduled execution"
    # scheduled_for should be very close to now
    assert_in_delta Time.current.to_f, execution.scheduled_for.to_f, 2.0

    workflow.pause!

    execution.reload
    assert_equal "scheduled", execution.state
  end

  # Scenario: pause! does not create "workflow_paused" outcome
  #
  # The old behavior created canceled executions with outcome "workflow_paused".
  # The new behavior does NOT do this.
  #
  test "pause! does not create workflow_paused outcome" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    workflow.pause!

    paused_executions = workflow.step_executions.where(outcome: "workflow_paused")
    assert_equal 0, paused_executions.count,
      "Should not have any executions with 'workflow_paused' outcome"
  end

  # Scenario: pause! on already paused workflow
  #
  # Expected: Raises InvalidStateError
  #
  test "pause! raises error for already paused workflow" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.pause!

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.pause!
    end
    assert_match(/Cannot pause a paused workflow/, error.message)
  end

  # Scenario: pause! on finished workflow
  #
  # Expected: Raises InvalidStateError
  #
  test "pause! raises error for finished workflow" do
    workflow = WaitingWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)
    assert_equal "finished", workflow.state

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.pause!
    end
    assert_match(/Cannot pause a finished workflow/, error.message)
  end

  # ===========================================
  # RESUME! SCENARIOS
  # ===========================================

  # Scenario: Resume with SCHEDULED execution still in FUTURE
  #
  # Workflow was paused while waiting for a delayed step. The scheduled
  # time hasn't arrived yet.
  #
  # Expected: Re-enqueue job for the SAME execution with remaining wait time.
  # No new execution record created.
  #
  test "resume! with future scheduled execution re-enqueues same execution" do
    start_time = Time.current
    workflow = nil
    original_execution = nil

    travel_to(start_time) do
      workflow = WaitingWorkflow.create!(hero: @user)
      perform_next_step(workflow)

      original_execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
      assert original_execution
    end

    # Pause 30 minutes in (90 minutes remaining)
    travel_to(start_time + 30.minutes) do
      workflow.pause!
    end

    # Resume 45 minutes in (75 minutes remaining)
    travel_to(start_time + 45.minutes) do
      workflow.resume!

      assert_equal "ready", workflow.state

      # Should still have the SAME execution (not a new one)
      current = workflow.current_execution
      assert current
      assert_equal original_execution.id, current.id,
        "Should be the same execution record, not a new one"
      assert_equal "scheduled", current.state

      # scheduled_for should still be the original time
      expected_time = start_time + 2.hours
      assert_in_delta expected_time.to_f, current.scheduled_for.to_f, 1.0,
        "scheduled_for should remain at the original time"
    end
  end

  # Scenario: Resume with SCHEDULED execution now OVERDUE
  #
  # Workflow was paused, time passed, the scheduled time went by.
  # The execution is now overdue.
  #
  # Expected: Re-enqueue job for the SAME execution to run immediately.
  # The execution record shows when it was originally scheduled (overdue visible).
  #
  test "resume! with overdue scheduled execution enqueues immediately" do
    start_time = Time.current
    workflow = nil
    original_execution = nil

    travel_to(start_time) do
      workflow = WaitingWorkflow.create!(hero: @user)
      perform_next_step(workflow)

      original_execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    end

    # Pause 1 hour in
    travel_to(start_time + 1.hour) do
      workflow.pause!
    end

    # Resume 3 hours in (1 hour after originally scheduled time)
    travel_to(start_time + 3.hours) do
      workflow.resume!

      assert_equal "ready", workflow.state

      # Should still have the SAME execution
      current = workflow.current_execution
      assert current
      assert_equal original_execution.id, current.id

      # The execution should be overdue (scheduled_for in the past)
      assert current.scheduled_for < Time.current,
        "Execution should be overdue (scheduled_for in the past)"

      # The job will be enqueued to run immediately (no wait)
      # We can't easily test the job enqueueing, but the execution is correct
    end
  end

  # Scenario: Resume when NO scheduled execution exists
  #
  # The execution was canceled (perhaps by the executor running while paused,
  # or manually). There's no current_execution to resume.
  #
  # Expected: Create a NEW execution for next_step_name, scheduled for now.
  #
  test "resume! with no scheduled execution creates new one" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    workflow.pause!

    # Simulate executor canceling the execution (as it would if job ran while paused)
    execution.update!(state: "canceled", outcome: "canceled", canceled_at: Time.current)

    # Now resume - no scheduled execution exists
    workflow.resume!

    assert_equal "ready", workflow.state

    # Should have created a new execution
    new_execution = workflow.current_execution
    assert new_execution
    assert_not_equal execution.id, new_execution.id, "Should be a new execution"
    assert_equal "step_two", new_execution.step_name
    assert_equal "scheduled", new_execution.state
  end

  # Scenario: Resume when executor already canceled execution (job ran while paused)
  #
  # This is the edge case where:
  # 1. Step scheduled for T+2h, job enqueued
  # 2. T+1h: pause! called (execution stays scheduled)
  # 3. T+2h: Job runs, executor sees workflow is paused, cancels execution
  # 4. T+3h: resume! called
  #
  # Expected: Since execution was canceled with outcome "canceled" (not
  # "workflow_paused"), we create a new execution scheduled for now.
  #
  test "resume! after executor canceled execution creates new one" do
    start_time = Time.current
    workflow = nil

    travel_to(start_time) do
      workflow = WaitingWorkflow.create!(hero: @user)
      perform_next_step(workflow)
    end

    travel_to(start_time + 1.hour) do
      workflow.pause!
    end

    # Simulate what the executor does when job runs on paused workflow
    travel_to(start_time + 2.hours) do
      execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
      # This is what executor does (see executor.rb)
      execution.update!(
        state: "canceled",
        canceled_at: Time.current,
        finished_at: Time.current,
        outcome: "canceled"
      )
    end

    # Resume after the job already ran and canceled the execution
    travel_to(start_time + 3.hours) do
      workflow.resume!

      assert_equal "ready", workflow.state

      # Should have a new execution (the old one was canceled)
      new_execution = workflow.current_execution
      assert new_execution
      assert_equal "step_two", new_execution.step_name
      assert_equal "scheduled", new_execution.state

      # The new execution should be scheduled for "now" (not the original time)
      assert_in_delta Time.current.to_f, new_execution.scheduled_for.to_f, 1.0
    end
  end

  # Scenario: Multiple pause/resume cycles before scheduled time
  #
  # Rapid pause/resume doesn't create duplicate executions or jobs.
  # (Multiple jobs are fine - executor guards against double execution)
  #
  # Expected: Same execution is reused. Multiple jobs may be enqueued but
  # only one will actually execute (others will see wrong state and bail).
  #
  test "multiple pause/resume cycles reuse same execution" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    original_execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    original_id = original_execution.id

    # First cycle
    workflow.pause!
    workflow.resume!

    # Second cycle
    workflow.pause!
    workflow.resume!

    # Third cycle
    workflow.pause!
    workflow.resume!

    # Should still have only one step_two execution
    step_two_executions = workflow.step_executions.where(step_name: "step_two")
    assert_equal 1, step_two_executions.count,
      "Should only have one step_two execution after multiple cycles"
    assert_equal original_id, step_two_executions.first.id,
      "Should be the same execution record"
  end

  # Scenario: resume! on ready workflow
  #
  # Expected: Raises InvalidStateError
  #
  test "resume! raises error for ready workflow" do
    workflow = WaitingWorkflow.create!(hero: @user)
    assert_equal "ready", workflow.state

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.resume!
    end
    assert_match(/Cannot resume a ready workflow/, error.message)
  end

  # Scenario: resume! on finished workflow
  #
  # Expected: Raises InvalidStateError
  #
  test "resume! raises error for finished workflow" do
    workflow = WaitingWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.resume!
    end
    assert_match(/Cannot resume a finished workflow/, error.message)
  end

  # ===========================================
  # INTEGRATION SCENARIOS
  # ===========================================

  # Scenario: Full pause/resume cycle allows workflow to complete
  #
  # End-to-end test that the workflow can be paused, resumed, and
  # still complete all steps successfully.
  #
  test "full pause/resume cycle allows workflow to complete" do
    workflow = WaitingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)
    assert Thread.current[:step_one_ran]
    assert_equal "step_two", workflow.next_step_name

    # Pause while waiting for step_two
    workflow.pause!
    assert_equal "paused", workflow.state

    # Resume
    workflow.resume!
    assert_equal "ready", workflow.state

    # Execute step_two
    perform_next_step(workflow)
    assert Thread.current[:step_two_ran]
    assert_equal "step_three", workflow.next_step_name

    # Execute step_three
    perform_next_step(workflow)
    assert Thread.current[:step_three_ran]
    assert_equal "finished", workflow.state
  end

  # Scenario: Pause during overdue, resume runs immediately
  #
  # Step becomes overdue during pause, on resume it should run immediately.
  #
  test "overdue step runs immediately after resume" do
    start_time = Time.current
    workflow = nil

    travel_to(start_time) do
      workflow = WaitingWorkflow.create!(hero: @user)
      perform_next_step(workflow)
      workflow.pause!
    end

    # Fast forward past the scheduled time
    travel_to(start_time + 3.hours) do
      workflow.resume!

      # The execution is overdue but still scheduled
      execution = workflow.current_execution
      assert execution.scheduled_for < Time.current, "Should be overdue"

      # Execute it - should work fine
      perform_next_step(workflow)
      assert Thread.current[:step_two_ran]
      assert_equal "step_three", workflow.next_step_name
    end
  end

  # ===========================================
  # LOCKING BEHAVIOR
  # ===========================================

  # Scenario: pause! uses workflow lock
  #
  # The pause operation should be atomic with respect to other operations.
  #
  test "pause! operates within workflow lock" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    # This verifies the code path works - actual lock contention testing
    # would require multi-threaded or multi-process tests
    workflow.pause!
    assert_equal "paused", workflow.state
  end

  # Scenario: resume! uses workflow lock
  #
  # The resume operation should be atomic with respect to other operations.
  #
  test "resume! operates within workflow lock" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.pause!

    # This verifies the code path works
    workflow.resume!
    assert_equal "ready", workflow.state
  end
end
