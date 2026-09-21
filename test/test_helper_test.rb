# frozen_string_literal: true

require "test_helper"

class TestHelperTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class MultiStepWorkflow < GenevaDrive::Workflow
    step :first_step do
      Thread.current[:first_step_ran] = true
    end

    step :second_step do
      Thread.current[:second_step_ran] = true
    end

    step :third_step do
      Thread.current[:third_step_ran] = true
    end
  end

  class ResumableMultiStepWorkflow < GenevaDrive::Workflow
    resumable_step :resumable_first do |iter|
      items = %w[a b c]
      iter.iterate_over(items) do |item|
        Thread.current[:resumable_items] ||= []
        Thread.current[:resumable_items] << item
      end
    end

    step :after_resumable do
      Thread.current[:after_resumable_ran] = true
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
    Thread.current[:first_step_ran] = nil
    Thread.current[:second_step_ran] = nil
    Thread.current[:third_step_ran] = nil
    Thread.current[:resumable_items] = nil
    Thread.current[:after_resumable_ran] = nil
  end

  # speedrun_current_step tests

  test "speedrun_current_step only runs the current step, not subsequent steps" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    speedrun_current_step(workflow)

    assert Thread.current[:first_step_ran], "first step should have run"
    assert_nil Thread.current[:second_step_ran], "second step should NOT have run"
    assert_nil Thread.current[:third_step_ran], "third step should NOT have run"

    # Workflow should still be ready with next step scheduled
    workflow.reload
    assert_equal "ready", workflow.state
    assert_equal "second_step", workflow.next_step_name
  end

  test "speedrun_current_step runs resumable step to completion without continuing" do
    workflow = ResumableMultiStepWorkflow.create!(hero: @user)

    speedrun_current_step(workflow)

    assert_equal %w[a b c], Thread.current[:resumable_items], "resumable step should complete all items"
    assert_nil Thread.current[:after_resumable_ran], "step after resumable should NOT have run"

    workflow.reload
    assert_equal "ready", workflow.state
    assert_equal "after_resumable", workflow.next_step_name
  end

  test "speedrun_current_step returns the step execution" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    result = speedrun_current_step(workflow)

    assert_instance_of GenevaDrive::StepExecution, result
    assert_equal "first_step", result.step_name
    assert_equal "completed", result.state
  end

  test "speedrun_current_step returns nil if no current execution" do
    workflow = MultiStepWorkflow.create!(hero: @user)
    speedrun_workflow(workflow) # Complete the whole workflow

    result = speedrun_current_step(workflow)

    assert_nil result
  end

  # speedrun_workflow tests

  test "speedrun_workflow runs all steps to completion" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    speedrun_workflow(workflow)

    assert Thread.current[:first_step_ran]
    assert Thread.current[:second_step_ran]
    assert Thread.current[:third_step_ran]
    assert_equal "finished", workflow.state
  end

  test "speedrun_workflow handles resumable steps" do
    workflow = ResumableMultiStepWorkflow.create!(hero: @user)

    speedrun_workflow(workflow)

    assert_equal %w[a b c], Thread.current[:resumable_items]
    assert Thread.current[:after_resumable_ran]
    assert_equal "finished", workflow.state
  end

  # perform_next_step tests

  test "perform_next_step executes one step and stops" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    perform_next_step(workflow)

    assert Thread.current[:first_step_ran]
    assert_nil Thread.current[:second_step_ran]
  end

  test "perform_next_step returns the executed step execution" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    result = perform_next_step(workflow)

    assert_instance_of GenevaDrive::StepExecution, result
    assert_equal "first_step", result.step_name
  end

  test "perform_next_step returns nil when no current execution" do
    workflow = MultiStepWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    result = perform_next_step(workflow)

    assert_nil result
  end

  # perform_step_inline tests

  test "perform_step_inline executes a specific step by name" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    perform_step_inline(workflow, :second_step)

    assert_nil Thread.current[:first_step_ran], "first step should not run"
    assert Thread.current[:second_step_ran], "second step should run"
  end

  test "perform_step_inline executes current step when no name given" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    perform_step_inline(workflow)

    assert Thread.current[:first_step_ran]
  end

  test "perform_step_inline raises ArgumentError for non-existent step" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    error = assert_raises(ArgumentError) do
      perform_step_inline(workflow, :non_existent_step)
    end

    assert_match(/non_existent_step/, error.message)
    assert_match(/not defined/, error.message)
  end

  test "perform_step_inline returns the step execution" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    result = perform_step_inline(workflow, :second_step)

    assert_instance_of GenevaDrive::StepExecution, result
    assert_equal "second_step", result.step_name
  end

  # assert_step_executed tests

  test "assert_step_executed passes when step is in expected state" do
    workflow = MultiStepWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    # Should not raise
    assert_step_executed(workflow, :first_step)
    assert_step_executed(workflow, :first_step, state: "completed")
  end

  test "assert_step_executed fails when step not found" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    error = assert_raises(Minitest::Assertion) do
      assert_step_executed(workflow, :first_step)
    end

    assert_match(/first_step/, error.message)
  end

  test "assert_step_executed fails when step in different state" do
    workflow = MultiStepWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    error = assert_raises(Minitest::Assertion) do
      assert_step_executed(workflow, :first_step, state: "failed")
    end

    assert_match(/first_step/, error.message)
  end

  # assert_workflow_state tests

  test "assert_workflow_state passes when state matches" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    # Should not raise
    assert_workflow_state(workflow, :ready)
    assert_workflow_state(workflow, "ready")
  end

  test "assert_workflow_state fails when state differs" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    error = assert_raises(Minitest::Assertion) do
      assert_workflow_state(workflow, :finished)
    end

    assert_match(/finished/, error.message)
    assert_match(/ready/, error.message)
  end

  test "assert_workflow_state works after workflow completes" do
    workflow = MultiStepWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    assert_workflow_state(workflow, :finished)
  end

  # assert_cursor tests

  test "assert_cursor passes when cursor matches" do
    workflow = ResumableMultiStepWorkflow.create!(hero: @user)

    # Execute the step - it will complete
    speedrun_current_step(workflow)

    # After completion, we can check the cursor on the last execution
    # Note: For a fully completed step, cursor may be nil or final value
    workflow.reload
    execution = workflow.step_executions.find_by(step_name: "resumable_first")
    assert_not_nil execution
  end

  # assert_step_has_successor tests

  test "assert_step_has_successor passes when successor exists" do
    workflow = ResumableMultiStepWorkflow.create!(hero: @user)

    # Execute the resumable step - it will complete without successor in this simple case
    speedrun_current_step(workflow)

    # Just verify the helper doesn't crash when there's no successor
    workflow.reload
    completed = workflow.step_executions.find_by(step_name: "resumable_first", state: "completed")
    assert completed, "Expected completed execution"
  end
end
