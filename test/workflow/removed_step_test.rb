# frozen_string_literal: true

require "test_helper"

class RemovedStepTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  # The shape a workflow has after `capture_payment` was taken out of the
  # middle of it and a gravestone left behind.
  class PaymentWorkflow < GenevaDrive::Workflow
    step :authorize do
      Thread.current[:ran] << :authorize
    end

    removed_step :capture_payment

    step :send_receipt do
      Thread.current[:ran] << :send_receipt
    end
  end

  # A gravestone in first position, so nothing runnable precedes it.
  class LeadingRemovalWorkflow < GenevaDrive::Workflow
    removed_step :old_preflight

    step :only_step do
      Thread.current[:ran] << :only_step
    end
  end

  # A gravestone in last position, so nothing runnable follows it.
  class TrailingRemovalWorkflow < GenevaDrive::Workflow
    step :only_step do
      Thread.current[:ran] << :only_step
    end

    removed_step :old_teardown
  end

  # Every step removed - there is nothing left to run at all.
  class FullyRemovedWorkflow < GenevaDrive::Workflow
    removed_step :gone_one
    removed_step :gone_two
  end

  # A step deleted outright, with no gravestone. This is the situation
  # removed_step exists to prevent, kept here to prove the default is
  # unchanged: the workflow still pauses rather than guessing.
  class UndeclaredRemovalWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:ran] << :step_one
    end

    step :step_two do
      Thread.current[:ran] << :step_two
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
  # The declaration itself
  # ===========================================

  test "removed_step registers a gravestone that reports itself as removed" do
    step_def = PaymentWorkflow.steps.named("capture_payment")

    assert_not_nil step_def
    assert_predicate step_def, :removed?
    assert_equal "capture_payment", step_def.name
  end

  test "an ordinary step is not removed" do
    assert_not_predicate PaymentWorkflow.steps.named("authorize"), :removed?
  end

  test "a removed step keeps its name resolvable" do
    assert PaymentWorkflow.steps.key?("capture_payment")
  end

  test "a removed step holds its position in the declared order" do
    assert_equal %w[authorize capture_payment send_receipt], PaymentWorkflow.steps.map(&:name)
  end

  test "runnable omits removed steps and removed lists them" do
    assert_equal %w[authorize send_receipt], PaymentWorkflow.steps.runnable.map(&:name)
    assert_equal %w[capture_payment], PaymentWorkflow.steps.removed.map(&:name)
  end

  test "removed_step refuses a name already taken by a step" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        def self.name = "DoubleDeclarationWorkflow"

        step :thing do
          # no-op
        end

        removed_step :thing
      end
    end

    assert_match(/already defined/, error.message)
  end

  test "removed_step requires a name" do
    assert_raises(ArgumentError) do
      Class.new(GenevaDrive::Workflow) do
        removed_step nil
      end
    end
  end

  test "before_step can still reference a removed step" do
    klass = Class.new(GenevaDrive::Workflow) do
      def self.name = "PositionedAroundRemovalWorkflow"

      removed_step :gone

      step :inserted, before_step: :gone do
        # no-op
      end
    end

    assert_equal %w[inserted gone], klass.steps.map(&:name)
  end

  # ===========================================
  # Navigation never lands on a gravestone
  # ===========================================

  test "next_after steps over a removed step" do
    assert_equal "send_receipt", PaymentWorkflow.steps.next_after("authorize").name
  end

  test "next_after from a removed step returns the next runnable one" do
    assert_equal "send_receipt", PaymentWorkflow.steps.next_after("capture_payment").name
  end

  test "next_after returns nil when only removed steps remain" do
    assert_nil TrailingRemovalWorkflow.steps.next_after("only_step")
  end

  test "next_after from the beginning skips a leading removed step" do
    assert_equal "only_step", LeadingRemovalWorkflow.steps.next_after(nil).name
  end

  test "next_after still returns nil for a name the collection never had" do
    assert_nil PaymentWorkflow.steps.next_after("never_existed")
  end

  test "previous_before steps over a removed step" do
    assert_equal "authorize", PaymentWorkflow.steps.previous_before("send_receipt").name
  end

  test "previous_before returns nil when only removed steps precede" do
    assert_nil LeadingRemovalWorkflow.steps.previous_before("only_step")
  end

  # ===========================================
  # Scheduling never spools a removed step
  # ===========================================

  test "a new workflow runs straight past a removed middle step" do
    workflow = PaymentWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    assert_equal %i[authorize send_receipt], Thread.current[:ran]
    assert_workflow_state(workflow, :finished)
    assert_empty workflow.step_executions.where(step_name: "capture_payment")
  end

  test "a new workflow starts at the first runnable step, not a leading gravestone" do
    workflow = LeadingRemovalWorkflow.create!(hero: @user)

    assert_equal "only_step", workflow.next_step_name

    speedrun_workflow(workflow)

    assert_equal %i[only_step], Thread.current[:ran]
    assert_workflow_state(workflow, :finished)
  end

  test "a trailing gravestone finishes the workflow instead of being scheduled" do
    workflow = TrailingRemovalWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    assert_workflow_state(workflow, :finished)
    assert_empty workflow.step_executions.where(step_name: "old_teardown")
  end

  test "a workflow whose every step was removed finishes immediately" do
    workflow = FullyRemovedWorkflow.create!(hero: @user)

    assert_workflow_state(workflow, :finished)
    assert_empty workflow.step_executions
  end

  # ===========================================
  # Executions scheduled before the removal shipped
  # ===========================================

  test "an execution scheduled before the removal is skipped and the workflow continues" do
    workflow = PaymentWorkflow.create!(hero: @user)

    # Stand in for a rolling deploy: this row was written by the old code,
    # which still had capture_payment as a real step.
    execution = reschedule_at(workflow, "capture_payment")

    execution.execute!

    assert_equal "skipped", execution.reload.state
    assert_equal "skipped", execution.outcome

    speedrun_workflow(workflow)

    assert_equal %i[send_receipt], Thread.current[:ran]
    assert_workflow_state(workflow, :finished)
  end

  test "an execution for a trailing removed step finishes the workflow" do
    workflow = TrailingRemovalWorkflow.create!(hero: @user)
    execution = reschedule_at(workflow, "old_teardown")

    execution.execute!

    assert_equal "skipped", execution.reload.state
    assert_workflow_state(workflow, :finished)
  end

  test "a step deleted without a gravestone still pauses the workflow" do
    workflow = UndeclaredRemovalWorkflow.create!(hero: @user)
    execution = reschedule_at(workflow, "deleted_without_a_trace")

    assert_raises(GenevaDrive::StepNotDefinedError) { execution.execute! }

    assert_workflow_state(workflow, :paused)
  end

  # ===========================================
  # Knowing when the gravestone can go
  # ===========================================

  test "removed_steps_in_flight counts rows still pointing at a removed step" do
    workflow = PaymentWorkflow.create!(hero: @user)
    reschedule_at(workflow, "capture_payment")

    assert_equal({"capture_payment" => 1}, PaymentWorkflow.removed_steps_in_flight)
  end

  test "removed_steps_in_flight ignores workflows that will never run again" do
    workflow = PaymentWorkflow.create!(hero: @user)
    reschedule_at(workflow, "capture_payment")
    workflow.update!(state: "canceled")

    assert_empty PaymentWorkflow.removed_steps_in_flight
  end

  test "removed_steps_in_flight is empty once nothing references the name" do
    PaymentWorkflow.create!(hero: @user)

    assert_empty PaymentWorkflow.removed_steps_in_flight
  end

  test "removed_steps_in_flight is empty for a workflow with no removals" do
    assert_empty UndeclaredRemovalWorkflow.removed_steps_in_flight
  end

  private

  # Replaces whatever is scheduled with an execution for the given step name,
  # the way a row written by a previous deploy would look.
  def reschedule_at(workflow, step_name)
    workflow.step_executions.where(state: %w[scheduled waiting]).update_all(
      state: "canceled",
      outcome: "canceled",
      canceled_at: Time.current
    )
    execution = workflow.step_executions.create!(
      step_name: step_name,
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(next_step_name: step_name, current_step_name: nil)
    execution
  end
end
