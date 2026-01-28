# frozen_string_literal: true

require "test_helper"

class ResumeAndSkipTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  # Workflow that fails on a specific step
  class FailingWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_one_ran] = true
    end

    step :step_two, on_exception: :pause! do
      Thread.current[:step_two_attempts] ||= 0
      Thread.current[:step_two_attempts] += 1
      raise "Intentional failure" if Thread.current[:should_fail]
      Thread.current[:step_two_completed] = true
    end

    step :step_three do
      Thread.current[:step_three_ran] = true
    end
  end

  # Workflow with a waiting step
  class WaitingWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_one_ran] = true
    end

    step :step_two, wait: 2.days do
      Thread.current[:step_two_ran] = true
    end

    step :step_three do
      Thread.current[:step_three_ran] = true
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
    Thread.current[:step_two_attempts] = nil
    Thread.current[:step_two_completed] = nil
    Thread.current[:step_three_ran] = nil
    Thread.current[:should_fail] = nil
    Thread.current[:step_two_ran] = nil
  end

  # ===========================================
  # Tests for resume! retrying failed step
  # ===========================================

  test "resume! retries the failed step instead of skipping to next" do
    workflow = FailingWorkflow.create!(hero: @user)

    # Execute step_one successfully
    perform_next_step(workflow)
    assert Thread.current[:step_one_ran]
    assert_equal "step_two", workflow.next_step_name

    # Make step_two fail (exception is re-raised after workflow pauses)
    Thread.current[:should_fail] = true
    assert_raises(RuntimeError) { perform_next_step(workflow) }

    assert_equal "paused", workflow.state
    assert_equal 1, Thread.current[:step_two_attempts]
    assert_equal "step_two", workflow.next_step_name, "next_step_name should still point to the failed step"

    # Fix the issue and resume
    Thread.current[:should_fail] = false
    workflow.resume!

    assert_equal "ready", workflow.state
    assert_equal "step_two", workflow.next_step_name, "resume! should schedule the same step for retry"

    # Execute the retried step
    perform_next_step(workflow)

    assert_equal 2, Thread.current[:step_two_attempts], "step_two should have been attempted twice"
    assert Thread.current[:step_two_completed], "step_two should have completed on retry"
    assert_equal "step_three", workflow.next_step_name
  end

  test "resume! creates new step execution for the failed step" do
    workflow = FailingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)

    # Make step_two fail
    Thread.current[:should_fail] = true
    assert_raises(RuntimeError) { perform_next_step(workflow) }

    assert_equal "paused", workflow.state
    failed_execution = workflow.step_executions.where(step_name: "step_two", state: "failed").first
    assert failed_execution, "Should have a failed step_two execution"

    # Resume
    Thread.current[:should_fail] = false
    workflow.resume!

    # Should have a new scheduled execution for step_two
    new_execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    assert new_execution, "Should have a new scheduled step_two execution"
    assert_not_equal failed_execution.id, new_execution.id, "Should be a different execution record"
  end

  test "next_step_name points to failed step after pause due to exception" do
    workflow = FailingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)
    assert_equal "step_two", workflow.next_step_name

    # Fail step_two
    Thread.current[:should_fail] = true
    assert_raises(RuntimeError) { perform_next_step(workflow) }

    assert_equal "paused", workflow.state
    assert_equal "step_two", workflow.next_step_name, "next_step_name should point to the failed step, not the next one"
  end

  # ===========================================
  # Tests for skip! on paused workflows
  # ===========================================

  test "skip! on paused workflow advances past the failed step" do
    workflow = FailingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)

    # Fail step_two
    Thread.current[:should_fail] = true
    assert_raises(RuntimeError) { perform_next_step(workflow) }

    assert_equal "paused", workflow.state
    assert_equal "step_two", workflow.next_step_name

    # Skip the failed step
    workflow.skip!
    workflow.reload

    assert_equal "ready", workflow.state
    assert_equal "step_three", workflow.next_step_name, "skip! should advance to the next step"
  end

  test "skip! on paused workflow creates execution for the next step" do
    workflow = FailingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)

    # Fail step_two
    Thread.current[:should_fail] = true
    assert_raises(RuntimeError) { perform_next_step(workflow) }

    assert_equal "paused", workflow.state

    # Skip the failed step
    workflow.skip!
    workflow.reload

    # Should have a scheduled execution for step_three
    step_three_execution = workflow.step_executions.where(step_name: "step_three", state: "scheduled").first
    assert step_three_execution, "Should have a scheduled step_three execution"
  end

  test "skip! on paused workflow allows continuing execution" do
    workflow = FailingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)

    # Fail step_two
    Thread.current[:should_fail] = true
    assert_raises(RuntimeError) { perform_next_step(workflow) }

    # Skip the failed step and continue
    workflow.skip!
    perform_next_step(workflow)

    assert Thread.current[:step_three_ran], "step_three should have run after skipping step_two"
    assert_nil Thread.current[:step_two_completed], "step_two should not have completed"
    assert_equal "finished", workflow.state
  end

  # ===========================================
  # Tests for external pause (not due to failure)
  # ===========================================

  test "resume! after external_pause re-uses the existing scheduled execution" do
    workflow = WaitingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)
    assert_equal "step_two", workflow.next_step_name

    original_execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    original_id = original_execution.id

    # Externally pause while waiting for step_two
    workflow.pause!

    assert_equal "paused", workflow.state
    assert_equal "step_two", workflow.next_step_name

    # Resume - should re-enqueue the existing execution
    workflow.resume!

    assert_equal "ready", workflow.state
    assert_equal "step_two", workflow.next_step_name

    # Verify the same execution is reused (new behavior: no canceled + new, just reused)
    step_two_executions = workflow.step_executions.where(step_name: "step_two")
    assert_equal 1, step_two_executions.count, "Should reuse the existing scheduled execution"
    assert_equal original_id, step_two_executions.first.id, "Should be the same execution record"
    assert step_two_executions.exists?(state: "scheduled")
  end

  test "resume! preserves original scheduled time when paused before scheduled time arrives" do
    # This test verifies the new pause/resume behavior:
    # When a workflow is paused while a step is scheduled for a future time,
    # the scheduled execution is preserved (not canceled). On resume, the same
    # execution is re-enqueued with its original scheduled_for time preserved.
    #
    # Timeline:
    # - T+0: step_one completes, step_two scheduled for T+2days
    # - T+1day: workflow paused (execution stays scheduled)
    # - T+1day: workflow resumed -> same execution re-enqueued for T+2days

    start_time = Time.current
    workflow = nil
    original_execution = nil

    travel_to(start_time) do
      workflow = WaitingWorkflow.create!(hero: @user)

      # Execute step_one - this schedules step_two for 2 days from now
      perform_next_step(workflow)
      assert_equal "step_two", workflow.next_step_name

      original_execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
      assert original_execution, "Should have a scheduled step_two execution"

      # step_two should be scheduled for 2 days from start_time
      expected_original_time = start_time + 2.days
      assert_in_delta expected_original_time.to_f, original_execution.scheduled_for.to_f, 1.0,
        "step_two should be scheduled for 2 days from now"
    end

    # Fast forward 1 day (halfway through the wait) and pause
    travel_to(start_time + 1.day) do
      workflow.pause!

      assert_equal "paused", workflow.state

      # The original execution should still be scheduled (not canceled)
      original_execution.reload
      assert_equal "scheduled", original_execution.state,
        "Execution should stay 'scheduled' after pause (new behavior)"

      # Now resume - the same execution should be re-enqueued
      workflow.resume!

      assert_equal "ready", workflow.state

      # Should still have only ONE step_two execution (the original)
      step_two_executions = workflow.step_executions.where(step_name: "step_two")
      assert_equal 1, step_two_executions.count, "Should have just one step_two execution (reused)"

      current_execution = step_two_executions.first
      assert_equal original_execution.id, current_execution.id, "Should be the same execution record"
      assert_equal "scheduled", current_execution.state

      # The scheduled_for should still be the original time (start_time + 2.days)
      expected_time = start_time + 2.days
      assert_in_delta expected_time.to_f, current_execution.scheduled_for.to_f, 1.0,
        "Resumed step_two should retain its original scheduled_for time"
    end
  end

  test "resume! re-enqueues step for immediate run when paused before but resumed after scheduled time" do
    # This test verifies the scenario where:
    # - A step is scheduled for a future time
    # - Workflow is paused BEFORE that time arrives (execution stays scheduled)
    # - Workflow is resumed AFTER that time has passed (execution is now overdue)
    # - The same execution is re-enqueued to run immediately
    #
    # Timeline:
    # - T+0: step_one completes, step_two scheduled for T+2days
    # - T+1day: workflow paused (execution stays scheduled at T+2days)
    # - T+3days: workflow resumed (execution is overdue, re-enqueued for immediate run)

    start_time = Time.current
    workflow = nil
    original_execution = nil

    travel_to(start_time) do
      workflow = WaitingWorkflow.create!(hero: @user)

      # Execute step_one - this schedules step_two for 2 days from now
      perform_next_step(workflow)
      assert_equal "step_two", workflow.next_step_name

      original_execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
      assert_in_delta (start_time + 2.days).to_f, original_execution.scheduled_for.to_f, 1.0,
        "step_two should be scheduled for T+2days"
    end

    # T+1day: Pause BEFORE the scheduled time (1 day remaining)
    travel_to(start_time + 1.day) do
      workflow.pause!
      assert_equal "paused", workflow.state

      # The execution should still be scheduled (not canceled)
      original_execution.reload
      assert_equal "scheduled", original_execution.state,
        "Execution should stay 'scheduled' after pause"
      assert_in_delta (start_time + 2.days).to_f, original_execution.scheduled_for.to_f, 1.0,
        "Execution should preserve original scheduled_for time"
    end

    # T+3days: Resume AFTER the original scheduled time has passed
    travel_to(start_time + 3.days) do
      workflow.resume!
      assert_equal "ready", workflow.state

      # Should still have only ONE step_two execution (the original, now overdue)
      step_two_executions = workflow.step_executions.where(step_name: "step_two")
      assert_equal 1, step_two_executions.count, "Should have just one step_two execution"

      current_execution = step_two_executions.first
      assert_equal original_execution.id, current_execution.id, "Should be the same execution record"

      # The scheduled_for is still the original time (now in the past = overdue)
      # A new job is enqueued to run immediately, but scheduled_for is preserved
      assert_in_delta (start_time + 2.days).to_f, current_execution.scheduled_for.to_f, 1.0,
        "Execution should retain original scheduled_for time (showing it became overdue)"
      assert current_execution.scheduled_for < Time.current,
        "Execution should be overdue (scheduled_for in the past)"
    end
  end

  test "skip! on externally paused workflow advances to next step" do
    workflow = WaitingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)
    assert_equal "step_two", workflow.next_step_name

    # Externally pause
    workflow.pause!
    assert_equal "paused", workflow.state

    # Skip step_two
    workflow.skip!
    workflow.reload

    assert_equal "ready", workflow.state
    assert_equal "step_three", workflow.next_step_name
  end

  # ===========================================
  # Error cases
  # ===========================================

  test "skip! raises error for finished workflow" do
    workflow = FailingWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)
    assert_equal "finished", workflow.state

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.skip!
    end
    assert_match(/Cannot skip on a finished workflow/, error.message)
  end

  test "skip! raises error for canceled workflow" do
    workflow = FailingWorkflow.create!(hero: @user)
    workflow.transition_to!("canceled")

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.skip!
    end
    assert_match(/Cannot skip on a canceled workflow/, error.message)
  end

  # ===========================================
  # Integration: multiple retries then skip
  # ===========================================

  test "can retry multiple times then skip" do
    workflow = FailingWorkflow.create!(hero: @user)

    # Execute step_one
    perform_next_step(workflow)

    # Fail step_two multiple times
    Thread.current[:should_fail] = true

    3.times do |i|
      assert_raises(RuntimeError) { perform_next_step(workflow) }
      assert_equal "paused", workflow.state
      assert_equal "step_two", workflow.next_step_name
      assert_equal i + 1, Thread.current[:step_two_attempts]

      workflow.resume! if i < 2 # Resume for first two attempts
    end

    # After 3 failures, decide to skip
    workflow.skip!
    workflow.reload

    assert_equal "ready", workflow.state
    assert_equal "step_three", workflow.next_step_name

    # Complete the workflow
    perform_next_step(workflow)
    assert Thread.current[:step_three_ran]
    assert_equal "finished", workflow.state
  end
end
