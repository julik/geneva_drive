# frozen_string_literal: true

require "test_helper"

class FlowControlTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  # Workflow for testing that code after flow control doesn't execute
  class CodeAfterFlowControlWorkflow < GenevaDrive::Workflow
    step :pause_step do
      Thread.current[:before_pause] = true
      pause!
      Thread.current[:after_pause] = true
    end

    step :skip_step do
      Thread.current[:before_skip] = true
      skip!
      Thread.current[:after_skip] = true
    end

    step :cancel_step do
      Thread.current[:before_cancel] = true
      cancel!
      Thread.current[:after_cancel] = true
    end

    step :final_step do
      Thread.current[:final_ran] = true
    end
  end

  # Workflow for testing skip on last step
  class SkipLastStepWorkflow < GenevaDrive::Workflow
    step :first_step do
      Thread.current[:first_ran] = true
    end

    step :last_step do
      Thread.current[:before_skip_last] = true
      skip!
      Thread.current[:after_skip_last] = true
    end
  end

  # Simple workflow for external flow control tests
  class SimpleWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_one_ran] = true
    end

    step :step_two do
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
    Thread.current[:before_pause] = nil
    Thread.current[:after_pause] = nil
    Thread.current[:before_skip] = nil
    Thread.current[:after_skip] = nil
    Thread.current[:before_cancel] = nil
    Thread.current[:after_cancel] = nil
    Thread.current[:before_skip_last] = nil
    Thread.current[:after_skip_last] = nil
    Thread.current[:first_ran] = nil
    Thread.current[:final_ran] = nil
    Thread.current[:step_one_ran] = nil
    Thread.current[:step_two_ran] = nil
    Thread.current[:step_three_ran] = nil
  end

  # Tests for code after flow control not executing

  test "code after pause! does not execute" do
    workflow = CodeAfterFlowControlWorkflow.create!(hero: @user)

    perform_next_step(workflow)

    assert Thread.current[:before_pause], "Code before pause! should execute"
    assert_nil Thread.current[:after_pause], "Code after pause! should NOT execute"
    assert_equal "paused", workflow.state
  end

  test "code after skip! does not execute" do
    workflow = CodeAfterFlowControlWorkflow.create!(hero: @user)
    # Move to skip_step
    workflow.step_executions.first.mark_canceled!
    workflow.step_executions.create!(
      step_name: "skip_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "skip_step")

    perform_next_step(workflow)

    assert Thread.current[:before_skip], "Code before skip! should execute"
    assert_nil Thread.current[:after_skip], "Code after skip! should NOT execute"
    assert_equal "ready", workflow.state
  end

  test "code after cancel! does not execute" do
    workflow = CodeAfterFlowControlWorkflow.create!(hero: @user)
    # Move to cancel_step
    workflow.step_executions.first.mark_canceled!
    workflow.step_executions.create!(
      step_name: "cancel_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "cancel_step")

    perform_next_step(workflow)

    assert Thread.current[:before_cancel], "Code before cancel! should execute"
    assert_nil Thread.current[:after_cancel], "Code after cancel! should NOT execute"
    assert_equal "canceled", workflow.state
  end

  # Tests for skip! on last step

  test "skip! on last step finishes the workflow" do
    workflow = SkipLastStepWorkflow.create!(hero: @user)

    # Execute first step
    perform_next_step(workflow)
    assert Thread.current[:first_ran]
    assert_equal "ready", workflow.state
    assert_equal "last_step", workflow.current_step_name

    # Execute last step (which calls skip!)
    perform_next_step(workflow)

    assert Thread.current[:before_skip_last], "Code before skip! should execute"
    assert_nil Thread.current[:after_skip_last], "Code after skip! should NOT execute"
    assert_equal "finished", workflow.state
  end

  # Tests for external pause!

  test "external pause! pauses a ready workflow" do
    workflow = SimpleWorkflow.create!(hero: @user)
    assert_equal "ready", workflow.state

    workflow.pause!

    assert_equal "paused", workflow.state
    assert_not_nil workflow.transitioned_at
  end

  test "external pause! cancels pending step execution with workflow_paused outcome" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first
    assert_equal "scheduled", step_execution.state

    workflow.pause!

    step_execution.reload
    assert_equal "canceled", step_execution.state
    assert_equal "workflow_paused", step_execution.outcome
  end

  test "external pause! raises error for paused workflow" do
    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.pause!

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.pause!
    end

    assert_match(/Cannot pause a paused workflow/, error.message)
  end

  test "external pause! raises error for finished workflow" do
    workflow = SimpleWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)
    assert_equal "finished", workflow.state

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.pause!
    end

    assert_match(/Cannot pause a finished workflow/, error.message)
  end

  test "external pause! raises error for canceled workflow" do
    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.transition_to!("canceled")

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.pause!
    end

    assert_match(/Cannot pause a canceled workflow/, error.message)
  end

  test "paused workflow can be resumed after external pause" do
    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.pause!
    assert_equal "paused", workflow.state

    workflow.resume!
    assert_equal "ready", workflow.state

    # Should be able to continue execution
    perform_next_step(workflow)
    assert Thread.current[:step_one_ran]
  end

  # Tests for external skip!

  test "external skip! skips current step and schedules next" do
    workflow = SimpleWorkflow.create!(hero: @user)
    assert_equal "step_one", workflow.current_step_name

    workflow.skip!

    workflow.reload
    assert_equal "ready", workflow.state
    assert_equal "step_two", workflow.current_step_name
  end

  test "external skip! marks step execution as skipped" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first
    assert_equal "scheduled", step_execution.state

    workflow.skip!

    step_execution.reload
    assert_equal "skipped", step_execution.state
    assert_equal "skipped", step_execution.outcome
  end

  test "external skip! on last step finishes workflow" do
    workflow = SimpleWorkflow.create!(hero: @user)
    # Execute first two steps
    perform_next_step(workflow)
    perform_next_step(workflow)
    assert_equal "step_three", workflow.current_step_name

    workflow.skip!

    workflow.reload
    assert_equal "finished", workflow.state
  end

  test "external skip! raises error for paused workflow" do
    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.pause!

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.skip!
    end

    assert_match(/Cannot skip on a paused workflow/, error.message)
  end

  test "external skip! raises error for finished workflow" do
    workflow = SimpleWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.skip!
    end

    assert_match(/Cannot skip on a finished workflow/, error.message)
  end

  test "external skip! raises error for canceled workflow" do
    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.transition_to!("canceled")

    error = assert_raises(GenevaDrive::InvalidStateError) do
      workflow.skip!
    end

    assert_match(/Cannot skip on a canceled workflow/, error.message)
  end

  test "external skip! can skip multiple steps in sequence" do
    workflow = SimpleWorkflow.create!(hero: @user)
    assert_equal "step_one", workflow.current_step_name

    workflow.skip!
    assert_equal "step_two", workflow.reload.current_step_name

    workflow.skip!
    assert_equal "step_three", workflow.reload.current_step_name

    workflow.skip!
    assert_equal "finished", workflow.reload.state
  end

  # Tests for flow control inside vs outside step

  test "pause! inside step uses throw/catch mechanism" do
    workflow = CodeAfterFlowControlWorkflow.create!(hero: @user)

    # This should work and pause the workflow
    perform_next_step(workflow)

    assert_equal "paused", workflow.state
    # The step execution should be canceled (not completed)
    step_execution = workflow.step_executions.first
    assert_equal "canceled", step_execution.state
  end

  test "skip! inside step uses throw/catch mechanism" do
    workflow = CodeAfterFlowControlWorkflow.create!(hero: @user)
    # Move to skip_step
    workflow.step_executions.first.mark_canceled!
    workflow.step_executions.create!(
      step_name: "skip_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "skip_step")

    perform_next_step(workflow)

    assert_equal "ready", workflow.state
    # Should have moved to next step
    assert_equal "cancel_step", workflow.current_step_name
  end
end
