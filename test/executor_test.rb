# frozen_string_literal: true

require "test_helper"

# Simple workflow for executor tests
class ExecutorTestWorkflow < GenevaDrive::Workflow
  step :first_step do
    @first_executed = true
  end

  step :second_step do
    @second_executed = true
  end

  attr_accessor :first_executed, :second_executed
end

# Workflow that tracks before_step_starts
class HookTestWorkflow < GenevaDrive::Workflow
  attr_accessor :hooks_called

  step :tracked_step do
    # Step body
  end

  def before_step_starts(step_name)
    @hooks_called ||= []
    @hooks_called << step_name
  end
end

# Workflow with skip_if condition
class SkipIfTestWorkflow < GenevaDrive::Workflow
  step :skippable, skip_if: -> { hero.name == "Skip" } do
    @ran = true
  end

  step :final do
    @final_ran = true
  end

  attr_accessor :ran, :final_ran
end

# Workflow with cancel_if condition
class CancelIfTestWorkflow < GenevaDrive::Workflow
  cancel_if { hero.name == "Cancel" }

  step :first do
    @ran = true
  end

  attr_accessor :ran
end

# Workflow without hero
class NoHeroTestWorkflow < GenevaDrive::Workflow
  step :step_one do
    @ran = true
  end

  attr_accessor :ran
end

class HeroOptionalWorkflow < GenevaDrive::Workflow
  may_proceed_without_hero!

  step :step_one do
    @ran = true
  end

  attr_accessor :ran
end

# Workflow with flow control
class FlowControlTestWorkflow < GenevaDrive::Workflow
  step :cancel_step do
    cancel!
  end

  step :pause_step do
    pause!
  end

  step :skip_step do
    skip!
  end

  step :reattempt_step do
    reattempt!(wait: 1.hour) unless @reattempted
    @reattempted = true
  end

  step :finish_step do
    finished!
  end

  step :normal_step do
    # Just completes normally
  end

  attr_accessor :reattempted
end

# Workflow with exception handling
class ExceptionTestWorkflow < GenevaDrive::Workflow
  step :pause_default, on_exception: :pause! do
    raise "pause error"
  end

  step :reattempt_error, on_exception: :reattempt! do
    raise "retry error"
  end

  step :skip_error, on_exception: :skip! do
    raise "skip error"
  end

  step :cancel_error, on_exception: :cancel! do
    raise "cancel error"
  end
end

class ExecutorTest < ActiveSupport::TestCase
  setup do
    @user = create_user
  end

  test "executes step and transitions to next" do
    workflow = ExecutorTestWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "success", step_execution.outcome
    assert workflow.first_executed
    assert_equal "ready", workflow.state
    assert_equal "second_step", workflow.current_step_name
    assert_equal 2, workflow.step_executions.count
  end

  test "calls before_step_starts hook" do
    workflow = HookTestWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    assert_equal ["tracked_step"], workflow.hooks_called
  end

  test "skip_if condition evaluated at execution time" do
    user = create_user(name: "Skip", email: "skip@example.com")
    workflow = SkipIfTestWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "skipped", step_execution.outcome
    assert_nil workflow.ran
    assert_equal "final", workflow.current_step_name
  end

  test "cancel_if condition cancels workflow" do
    user = create_user(name: "Cancel", email: "cancel@example.com")
    workflow = CancelIfTestWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
    assert_nil workflow.ran
  end

  test "cancels workflow if hero is deleted" do
    workflow = NoHeroTestWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Delete the hero
    @user.destroy!

    GenevaDrive::Executor.new(workflow.reload, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
  end

  test "proceeds without hero if may_proceed_without_hero! is set" do
    workflow = HeroOptionalWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Delete the hero
    @user.destroy!

    GenevaDrive::Executor.new(workflow.reload, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert workflow.ran
  end

  test "cancel! flow control cancels workflow" do
    workflow = FlowControlTestWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
  end

  test "pause! flow control pauses workflow" do
    # Create workflow that will run pause_step
    workflow = FlowControlTestWorkflow.create!(hero: @user)
    # Cancel the auto-scheduled first step and create pause_step manually
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "pause_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "pause_step")

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "paused", workflow.state
  end

  test "skip! flow control skips to next step" do
    workflow = FlowControlTestWorkflow.create!(hero: @user)
    # Cancel the auto-scheduled first step and create skip_step manually
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "skip_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "skip_step")

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "ready", workflow.state
    # Should have scheduled next step (3 total: canceled first, executed skip_step, scheduled next)
    assert_equal 3, workflow.step_executions.count
  end

  test "finished! flow control finishes workflow immediately" do
    workflow = FlowControlTestWorkflow.create!(hero: @user)
    # Cancel the auto-scheduled first step and create finish_step manually
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "finish_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "finish_step")

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "finished", workflow.state
  end

  test "on_exception: :pause! pauses workflow on error" do
    workflow = ExceptionTestWorkflow.create!(hero: @user)
    # First step is pause_default, which will raise an error
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "failed", step_execution.outcome
    assert_equal "paused", workflow.state
    assert_equal "pause error", step_execution.error_message
  end

  test "on_exception: :skip! skips step on error" do
    workflow = ExceptionTestWorkflow.create!(hero: @user)
    # Cancel the auto-scheduled first step and create skip_error manually
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "skip_error",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "skip_error")

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "ready", workflow.state
  end

  test "on_exception: :cancel! cancels workflow on error" do
    workflow = ExceptionTestWorkflow.create!(hero: @user)
    # Cancel the auto-scheduled first step and create cancel_error manually
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "cancel_error",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "cancel_error")

    GenevaDrive::Executor.new(workflow, step_execution).execute!

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "canceled", step_execution.outcome
    assert_equal "canceled", workflow.state
  end

  test "step execution idempotency - does not re-execute completed step" do
    workflow = ExecutorTestWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Execute once
    GenevaDrive::Executor.new(workflow, step_execution).execute!
    workflow.first_executed = nil

    # Try to execute again - should be a no-op
    GenevaDrive::Executor.new(workflow.reload, step_execution.reload).execute!

    assert_nil workflow.first_executed
    assert_equal "completed", step_execution.state
  end
end
