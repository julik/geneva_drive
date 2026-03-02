# frozen_string_literal: true

require "test_helper"

class SkipUndefinedStepsTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  # Workflow with skip_undefined_steps! enabled
  class ResilientWorkflow < GenevaDrive::Workflow
    skip_undefined_steps!

    step :step_one do
      # No-op
    end

    step :step_two do
      # No-op
    end
  end

  # Workflow without skip_undefined_steps! (default behavior)
  class StrictWorkflow < GenevaDrive::Workflow
    step :step_one do
      # No-op
    end
  end

  def setup
    @hero = create_user
  end

  # --- DSL ---

  test "skip_undefined_steps! defaults to false" do
    refute GenevaDrive::Workflow._skip_undefined_steps
    refute StrictWorkflow._skip_undefined_steps
  end

  test "skip_undefined_steps! sets flag to true" do
    assert ResilientWorkflow._skip_undefined_steps
  end

  test "skip_undefined_steps! is inherited by subclasses" do
    subclass = Class.new(ResilientWorkflow)
    assert subclass._skip_undefined_steps
  end

  test "skip_undefined_steps! does not bleed into sibling classes" do
    refute StrictWorkflow._skip_undefined_steps
  end

  # --- StepExecution#step_definition ---

  test "step_definition returns nil for undefined step on non-opted-in workflow" do
    workflow = StrictWorkflow.create!(hero: @hero)
    execution = workflow.step_executions.create!(
      step_name: "nonexistent_step",
      state: "scheduled",
      scheduled_for: Time.current
    )

    assert_nil execution.step_definition
  end

  test "step_definition returns tombstone for undefined step on opted-in workflow" do
    workflow = ResilientWorkflow.create!(hero: @hero)
    execution = workflow.step_executions.create!(
      step_name: "removed_old_step",
      state: "scheduled",
      scheduled_for: Time.current
    )

    step_def = execution.step_definition
    assert_not_nil step_def
    assert_equal "removed_old_step", step_def.name
  end

  test "step_definition returns real definition for defined steps" do
    workflow = ResilientWorkflow.create!(hero: @hero)
    execution = workflow.step_executions.create!(
      step_name: "step_one",
      state: "scheduled",
      scheduled_for: Time.current
    )

    step_def = execution.step_definition
    assert_not_nil step_def
    assert_equal "step_one", step_def.name
  end

  # --- StepCollection#next_after ---

  test "next_after returns first step for unknown step name" do
    steps = ResilientWorkflow.steps
    result = steps.next_after("removed_old_step")
    assert_equal steps.first.name, result.name
  end

  test "next_after returns nil at end of defined steps" do
    steps = ResilientWorkflow.steps
    assert_nil steps.next_after(steps.last.name)
  end

  test "next_after returns next step for defined steps" do
    steps = ResilientWorkflow.steps
    result = steps.next_after(steps.first.name)
    assert_equal steps[1].name, result.name
  end

  test "next_after returns first step when current_name is nil" do
    steps = ResilientWorkflow.steps
    assert_equal steps.first.name, steps.next_after(nil).name
  end

  # --- Integration: undefined step is skipped and workflow continues ---

  test "undefined step is skipped and workflow completes" do
    workflow = ResilientWorkflow.create!(hero: @hero)

    # Simulate rolling deploy: replace the first scheduled step with a removed one
    workflow.step_executions.scheduled.update_all(
      state: "canceled",
      outcome: "canceled",
      canceled_at: Time.current
    )
    workflow.step_executions.create!(
      step_name: "removed_old_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(next_step_name: "removed_old_step")

    speedrun_workflow(workflow)

    assert workflow.finished?, "Workflow should complete after skipping undefined step"

    undefined_exec = workflow.step_executions.find_by(step_name: "removed_old_step")
    assert_equal "skipped", undefined_exec.state
    assert_equal "skipped", undefined_exec.outcome
  end

  test "workflow restarts from first step after skipping undefined step" do
    workflow = ResilientWorkflow.create!(hero: @hero)

    workflow.step_executions.scheduled.update_all(
      state: "canceled",
      outcome: "canceled",
      canceled_at: Time.current
    )
    workflow.step_executions.create!(
      step_name: "removed_old_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(next_step_name: "removed_old_step")

    speedrun_workflow(workflow)

    step_one_exec = workflow.step_executions.find_by(step_name: "step_one", state: "completed")
    assert step_one_exec, "step_one should have been executed after skipping undefined step"
  end

  test "StepNotDefinedError is still raised for non-opted-in workflows" do
    workflow = StrictWorkflow.create!(hero: @hero)

    workflow.step_executions.scheduled.update_all(
      state: "canceled",
      outcome: "canceled",
      canceled_at: Time.current
    )
    execution = workflow.step_executions.create!(
      step_name: "removed_old_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(next_step_name: "removed_old_step")

    assert_raises(GenevaDrive::StepNotDefinedError) do
      execution.execute!
    end

    assert workflow.reload.paused?
  end
end
