# frozen_string_literal: true

require "test_helper"

class ResumeAtTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class ThreeStepWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:ran] << :step_one
    end

    step :step_two do
      Thread.current[:ran] << :step_two
    end

    step :step_three do
      Thread.current[:ran] << :step_three
    end
  end

  class WorkflowWithRemoval < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:ran] << :step_one
    end

    removed_step :parked_forever

    step :step_three do
      Thread.current[:ran] << :step_three
    end
  end

  setup do
    @user = create_user
    Thread.current[:ran] = []
  end

  teardown do
    Thread.current[:ran] = nil
  end

  # ===========================================
  # resume_at!
  # ===========================================

  test "resume_at! continues from the named step" do
    workflow = paused_at(ThreeStepWorkflow.create!(hero: @user), "step_two")

    execution = workflow.resume_at!(:step_three)

    assert_equal "step_three", execution.step_name
    assert_equal "step_three", workflow.reload.next_step_name
    assert_equal "ready", workflow.state

    speedrun_workflow(workflow)

    assert_equal %i[step_three], Thread.current[:ran]
    assert_workflow_state(workflow, :finished)
  end

  test "resume_at! cancels the execution the workflow was pointed at" do
    workflow = ThreeStepWorkflow.create!(hero: @user)
    stale = workflow.current_execution
    workflow.pause!

    workflow.resume_at!(:step_three)

    assert_equal "canceled", stale.reload.state
  end

  test "resume_at! accepts a string as readily as a symbol" do
    workflow = paused_at(ThreeStepWorkflow.create!(hero: @user), "step_two")

    assert_equal "step_three", workflow.resume_at!("step_three").step_name
  end

  test "resume_at! rejects a step that is not defined" do
    workflow = paused_at(ThreeStepWorkflow.create!(hero: @user), "step_two")

    error = assert_raises(GenevaDrive::StepNotDefinedError) { workflow.resume_at!(:nowhere) }

    assert_match(/not defined/, error.message)
    assert_match(/step_one, step_two, step_three/, error.message)
    assert_equal "paused", workflow.reload.state
  end

  test "resume_at! refuses to land on a removed step" do
    workflow = paused_at(WorkflowWithRemoval.create!(hero: @user), "step_one")

    error = assert_raises(GenevaDrive::StepNotDefinedError) { workflow.resume_at!(:parked_forever) }

    assert_match(/removed_step/, error.message)
    assert_equal "paused", workflow.reload.state
  end

  test "resume_at! only applies to paused workflows" do
    workflow = ThreeStepWorkflow.create!(hero: @user)

    assert_raises(GenevaDrive::InvalidStateError) { workflow.resume_at!(:step_three) }
  end

  # ===========================================
  # resume! on a workflow pointed at a vanished step
  # ===========================================

  test "resume! explains itself when the step it points at is gone" do
    workflow = paused_at(ThreeStepWorkflow.create!(hero: @user), "deleted_without_a_trace")

    error = assert_raises(GenevaDrive::StepNotDefinedError) { workflow.resume! }

    assert_match(/no longer defined/, error.message)
    assert_match(/resume_at!/, error.message)
    assert_match(/removed_step :deleted_without_a_trace/, error.message)
    assert_match(/step_one, step_two, step_three/, error.message)
  end

  test "resume_at! rescues a workflow stranded by a vanished step" do
    workflow = paused_at(ThreeStepWorkflow.create!(hero: @user), "deleted_without_a_trace")

    workflow.resume_at!(:step_three)
    speedrun_workflow(workflow)

    assert_equal %i[step_three], Thread.current[:ran]
    assert_workflow_state(workflow, :finished)
  end

  # ===========================================
  # A step removed while an execution was parked
  # ===========================================

  test "resume! releases an execution parked on a since-removed step" do
    workflow = WorkflowWithRemoval.create!(hero: @user)

    # The old code parked here waiting for a signal; the new code has only a
    # gravestone, so nothing can ever match.
    workflow.step_executions.where(state: %w[scheduled waiting]).update_all(
      state: "canceled", outcome: "canceled", canceled_at: Time.current
    )
    parked = workflow.step_executions.create!(
      step_name: "parked_forever",
      state: "waiting",
      scheduled_for: Time.current,
      waiting_since: Time.current
    )
    workflow.update!(next_step_name: "parked_forever", current_step_name: nil)
    workflow.pause!

    workflow.resume!

    assert_equal "skipped", parked.reload.state

    speedrun_workflow(workflow)

    assert_equal %i[step_three], Thread.current[:ran]
    assert_workflow_state(workflow, :finished)
  end

  private

  # Puts the workflow in the state it would be in after pausing while pointed
  # at the given step name, with no live execution left behind.
  def paused_at(workflow, step_name)
    workflow.step_executions.where(state: %w[scheduled waiting]).update_all(
      state: "canceled", outcome: "canceled", canceled_at: Time.current
    )
    workflow.update!(state: "paused", next_step_name: step_name, current_step_name: nil)
    workflow
  end
end
