# frozen_string_literal: true

require "test_helper"

# Tests for external cancel! behavior (calling cancel! from outside a step).
#
# BEHAVIOR:
# - cancel! on a "ready" or "paused" workflow: cancels any scheduled execution
#   and transitions the workflow to "canceled"
# - cancel! on a "performing" workflow: throws FlowControlSignal (existing internal behavior)
# - cancel! on "finished" or "canceled": raises InvalidStateError
#
class ExternalCancelTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  # Workflow with a waiting step for testing cancel
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

  # Workflow with immediate steps
  class ImmediateWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_one_ran] = true
    end

    step :step_two do
      Thread.current[:step_two_ran] = true
    end
  end

  # Workflow that fails on step_two
  class FailingWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_one_ran] = true
    end

    step :step_two, on_exception: :pause! do
      raise "Intentional failure"
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
    Thread.current[:step_two_ran] = nil
    Thread.current[:step_three_ran] = nil
  end

  # ===========================================
  # CANCEL! ON READY WORKFLOWS
  # ===========================================

  test "cancel! on freshly created workflow cancels it" do
    workflow = WaitingWorkflow.create!(hero: @user)
    assert_equal "ready", workflow.state

    workflow.cancel!

    assert_equal "canceled", workflow.state
    assert_not_nil workflow.transitioned_at
  end

  test "cancel! on ready workflow cancels the scheduled execution" do
    workflow = WaitingWorkflow.create!(hero: @user)

    # Execute step_one - this schedules step_two
    perform_next_step(workflow)
    assert_equal "step_two", workflow.next_step_name

    execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    assert execution, "Should have a scheduled step_two execution"

    workflow.cancel!

    assert_equal "canceled", workflow.state

    # The scheduled execution should be canceled
    execution.reload
    assert_equal "canceled", execution.state
    assert_equal "canceled", execution.outcome
    assert_not_nil execution.canceled_at
  end

  test "cancel! on ready workflow with future scheduled execution cancels both" do
    start_time = Time.current

    travel_to(start_time) do
      workflow = WaitingWorkflow.create!(hero: @user)
      perform_next_step(workflow)

      execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
      assert execution.scheduled_for > Time.current, "Execution should be in the future"

      workflow.cancel!

      assert_equal "canceled", workflow.state

      execution.reload
      assert_equal "canceled", execution.state
    end
  end

  test "cancel! on ready workflow with immediate step cancels it" do
    workflow = ImmediateWorkflow.create!(hero: @user)

    execution = workflow.step_executions.where(step_name: "step_one", state: "scheduled").first
    assert execution

    workflow.cancel!

    assert_equal "canceled", workflow.state

    execution.reload
    assert_equal "canceled", execution.state
  end

  # ===========================================
  # CANCEL! ON PAUSED WORKFLOWS
  # ===========================================

  test "cancel! on paused workflow cancels it" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.pause!
    assert_equal "paused", workflow.state

    workflow.cancel!

    assert_equal "canceled", workflow.state
    assert_not_nil workflow.transitioned_at
  end

  test "cancel! on paused workflow cancels the scheduled execution" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    execution = workflow.step_executions.where(step_name: "step_two", state: "scheduled").first
    assert execution

    workflow.pause!
    workflow.cancel!

    execution.reload
    assert_equal "canceled", execution.state
    assert_equal "canceled", execution.outcome
  end

  test "cancel! on workflow paused due to failure" do
    workflow = FailingWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    # Fail step_two, which pauses the workflow
    assert_raises(RuntimeError) { perform_next_step(workflow) }
    assert_equal "paused", workflow.state

    workflow.cancel!

    assert_equal "canceled", workflow.state
  end

  # ===========================================
  # ERROR CASES
  # ===========================================

  test "cancel! raises error for finished workflow" do
    workflow = WaitingWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)
    assert_equal "finished", workflow.state

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.cancel!
    end
    assert_match(/Cannot cancel a finished workflow/, error.message)
  end

  test "cancel! raises error for already canceled workflow" do
    workflow = WaitingWorkflow.create!(hero: @user)
    workflow.cancel!
    assert_equal "canceled", workflow.state

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.cancel!
    end
    assert_match(/Cannot cancel a canceled workflow/, error.message)
  end

  # ===========================================
  # CANCEL IS TERMINAL
  # ===========================================

  test "canceled workflow cannot be resumed" do
    workflow = WaitingWorkflow.create!(hero: @user)
    workflow.cancel!

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.resume!
    end
    assert_match(/Cannot resume a canceled workflow/, error.message)
  end

  test "canceled workflow cannot be paused" do
    workflow = WaitingWorkflow.create!(hero: @user)
    workflow.cancel!

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.pause!
    end
    assert_match(/Cannot pause a canceled workflow/, error.message)
  end

  # ===========================================
  # LOCKING BEHAVIOR
  # ===========================================

  test "cancel! operates within workflow lock" do
    workflow = WaitingWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    workflow.cancel!
    assert_equal "canceled", workflow.state
  end
end
