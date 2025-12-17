# frozen_string_literal: true

require "test_helper"

class TestHelpersTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  # Basic multi-step workflow
  class MultiStepWorkflow < GenevaDrive::Workflow
    step :step_one do
      # First step
    end

    step :step_two do
      # Second step
    end

    step :step_three do
      # Third step
    end
  end

  # Workflow that pauses
  class PausingWorkflow < GenevaDrive::Workflow
    step :will_pause do
      pause!
    end

    step :never_reached do
      # Never reached
    end
  end

  # Workflow with skip
  class SkippingWorkflow < GenevaDrive::Workflow
    step :first do
      # First step
    end

    step :skipped, skip_if: -> { true } do
      # Always skipped
    end

    step :final do
      # Final step
    end
  end

  setup do
    @user = create_user
  end

  test "speedrun_workflow runs workflow to completion" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    speedrun_workflow(workflow)

    assert_equal "finished", workflow.state
    assert_equal 3, workflow.step_executions.completed.count
  end

  test "speedrun_workflow stops on pause" do
    workflow = PausingWorkflow.create!(hero: @user)

    speedrun_workflow(workflow)

    assert_equal "paused", workflow.state
    assert_equal 1, workflow.step_executions.count
  end

  test "step_workflow executes one step at a time" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    step_workflow(workflow)
    assert_equal "step_two", workflow.current_step_name

    step_workflow(workflow)
    assert_equal "step_three", workflow.current_step_name

    step_workflow(workflow)
    assert_equal "finished", workflow.state
  end

  test "assert_step_executed checks for completed step" do
    workflow = MultiStepWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    assert_step_executed(workflow, :step_one)
    assert_step_executed(workflow, "step_two")
    assert_step_executed(workflow, :step_three)
  end

  test "assert_step_executed checks for skipped step" do
    workflow = SkippingWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    assert_step_executed(workflow, :skipped, state: "skipped")
  end

  test "assert_workflow_state checks workflow state" do
    workflow = MultiStepWorkflow.create!(hero: @user)

    assert_workflow_state(workflow, :ready)
    assert_workflow_state(workflow, "ready")

    speedrun_workflow(workflow)

    assert_workflow_state(workflow, :finished)
  end
end
