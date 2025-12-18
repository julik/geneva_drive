# frozen_string_literal: true

require "test_helper"

class ExecutorTest < ActiveSupport::TestCase
  # Simple workflow for executor tests
  class BasicWorkflow < GenevaDrive::Workflow
    step :first_step do
      Thread.current[:executor_test_first_executed] = true
    end

    step :second_step do
      Thread.current[:executor_test_second_executed] = true
    end

    def self.first_executed?
      Thread.current[:executor_test_first_executed]
    end

    def self.reset_tracking!
      Thread.current[:executor_test_first_executed] = nil
      Thread.current[:executor_test_second_executed] = nil
    end
  end

  # Workflow that tracks before_step_starts
  class HookTrackingWorkflow < GenevaDrive::Workflow
    step :tracked_step do
      # Step body
    end

    def before_step_starts(step_name)
      Thread.current[:hook_test_hooks_called] ||= []
      Thread.current[:hook_test_hooks_called] << step_name
    end

    def self.hooks_called
      Thread.current[:hook_test_hooks_called]
    end

    def self.reset_tracking!
      Thread.current[:hook_test_hooks_called] = nil
    end
  end

  # Workflow with skip_if condition
  class SkipIfWorkflow < GenevaDrive::Workflow
    step :skippable, skip_if: -> { hero.name == "Skip" } do
      @ran = true
    end

    step :final do
      @final_ran = true
    end

    attr_accessor :ran, :final_ran
  end

  # Workflow with cancel_if condition
  class CancelIfWorkflow < GenevaDrive::Workflow
    cancel_if { hero.name == "Cancel" }

    step :first do
      @ran = true
    end

    attr_accessor :ran
  end

  # Workflow without hero
  class RequiresHeroWorkflow < GenevaDrive::Workflow
    step :step_one do
      @ran = true
    end

    attr_accessor :ran
  end

  # Workflow that can proceed without hero
  class OptionalHeroWorkflow < GenevaDrive::Workflow
    may_proceed_without_hero!

    step :step_one do
      Thread.current[:hero_optional_ran] = true
    end

    def self.ran?
      Thread.current[:hero_optional_ran]
    end

    def self.reset_tracking!
      Thread.current[:hero_optional_ran] = nil
    end
  end

  # Workflow with flow control
  class FlowControlWorkflow < GenevaDrive::Workflow
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
  class ExceptionHandlingWorkflow < GenevaDrive::Workflow
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

  setup do
    @user = create_user
  end

  test "executes step and transitions to next" do
    BasicWorkflow.reset_tracking!
    workflow = BasicWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert BasicWorkflow.first_executed?

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "success", step_execution.outcome
    assert_equal "ready", workflow.state
    assert_equal "second_step", workflow.current_step_name
    assert_equal 2, workflow.step_executions.count
  end

  test "calls before_step_starts hook" do
    HookTrackingWorkflow.reset_tracking!
    workflow = HookTrackingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal ["tracked_step"], HookTrackingWorkflow.hooks_called
  end

  test "skip_if condition evaluated at execution time" do
    user = create_user(name: "Skip", email: "skip@example.com")
    workflow = SkipIfWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "skipped", step_execution.outcome
    assert_nil workflow.ran
    assert_equal "final", workflow.current_step_name
  end

  test "cancel_if condition cancels workflow" do
    user = create_user(name: "Cancel", email: "cancel@example.com")
    workflow = CancelIfWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
    assert_nil workflow.ran
  end

  test "cancels workflow if hero is deleted" do
    workflow = RequiresHeroWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    @user.destroy!

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
  end

  test "proceeds without hero if may_proceed_without_hero! is set" do
    OptionalHeroWorkflow.reset_tracking!
    workflow = OptionalHeroWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    @user.destroy!

    GenevaDrive::Executor.execute!(step_execution)

    assert OptionalHeroWorkflow.ran?

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
  end

  test "cancel! flow control cancels workflow" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
  end

  test "pause! flow control pauses workflow" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "pause_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "pause_step")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "paused", workflow.state
  end

  test "skip! flow control skips to next step" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "skip_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "skip_step")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "ready", workflow.state
    assert_equal 3, workflow.step_executions.count
  end

  test "finished! flow control finishes workflow immediately" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "finish_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "finish_step")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "finished", workflow.state
  end

  test "on_exception: :pause! pauses workflow on error" do
    workflow = ExceptionHandlingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "failed", step_execution.outcome
    assert_equal "paused", workflow.state
    assert_equal "pause error", step_execution.error_message
  end

  test "on_exception: :skip! skips step on error" do
    workflow = ExceptionHandlingWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "skip_error",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "skip_error")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "ready", workflow.state
  end

  test "on_exception: :cancel! cancels workflow on error" do
    workflow = ExceptionHandlingWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "cancel_error",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "cancel_error")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "canceled", step_execution.outcome
    assert_equal "canceled", workflow.state
  end

  test "step execution idempotency - does not re-execute completed step" do
    BasicWorkflow.reset_tracking!
    workflow = BasicWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)
    assert BasicWorkflow.first_executed?

    BasicWorkflow.reset_tracking!

    GenevaDrive::Executor.execute!(step_execution.reload)

    assert_nil BasicWorkflow.first_executed?
    assert_equal "completed", step_execution.state
  end

  test "pauses workflow when step execution references non-existent step" do
    workflow = BasicWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Manually change the step name to something that doesn't exist
    step_execution.update_column(:step_name, "non_existent_step")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "failed", step_execution.outcome
    assert_match(/non_existent_step/, step_execution.error_message)
    assert_match(/not defined/, step_execution.error_message)
    assert_equal "paused", workflow.state
  end
end
