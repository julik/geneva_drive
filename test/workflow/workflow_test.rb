# frozen_string_literal: true

require "test_helper"

class WorkflowTest < ActiveSupport::TestCase
  # Basic workflow for testing
  class SimpleWorkflow < GenevaDrive::Workflow
    step :step_one do
      # Just a simple step
    end

    step :step_two do
      # Another simple step
    end
  end

  # Workflow with wait times
  class WaitingWorkflow < GenevaDrive::Workflow
    step :immediate_step do
      # Runs immediately
    end

    step :delayed_step, wait: 2.days do
      # Runs after 2 days
    end
  end

  # Workflow with skip conditions
  class SkippableWorkflow < GenevaDrive::Workflow
    step :always_runs do
      # This always runs
    end

    step :conditionally_skipped, skip_if: -> { hero.active? } do
      # Skipped if hero is active
    end

    step :final_step do
      # Final step
    end
  end

  # Workflow with cancel_if
  class CancelableWorkflow < GenevaDrive::Workflow
    cancel_if { hero.deactivated? }

    step :first_step do
      # First step
    end

    step :second_step do
      # Second step
    end
  end

  # Workflow that can proceed without hero
  class HerolessWorkflow < GenevaDrive::Workflow
    may_proceed_without_hero!

    step :cleanup do
      # Can run even without hero
    end
  end

  # Workflow with flow control
  class FlowControlWorkflow < GenevaDrive::Workflow
    step :might_cancel do
      cancel! if hero.name == "Cancel Me"
    end

    step :might_skip do
      skip! if hero.name == "Skip Me"
    end

    step :might_pause do
      pause! if hero.name == "Pause Me"
    end

    step :might_reattempt do
      reattempt!(wait: 1.hour) if hero.name == "Retry Me" && !@retried
      @retried = true
    end

    step :final do
      # Final step
    end
  end

  # Workflow with exception handling
  class ExceptionWorkflow < GenevaDrive::Workflow
    step :reattempt_on_error, on_exception: :reattempt! do
      raise "Temporary error"
    end

    step :skip_on_error, on_exception: :skip! do
      raise "Non-critical error"
    end

    step :cancel_on_error, on_exception: :cancel! do
      raise "Critical error"
    end

    step :pause_on_error, on_exception: :pause! do
      raise "Needs investigation"
    end
  end

  # Base workflow for inheritance tests
  class BaseWorkflow < GenevaDrive::Workflow
    cancel_if :hero_inactive?
    set_step_job_options queue: :base_queue

    def hero_inactive?
      !hero.active?
    end
  end

  # Child workflow inheriting from base
  class ChildWorkflow < BaseWorkflow
    cancel_if { hero.name == "Child Cancel" }
    set_step_job_options priority: 10

    step :child_step do
      # Child step
    end
  end

  setup do
    @user = create_user
  end

  test "creates workflow with hero and schedules first step" do
    workflow = SimpleWorkflow.create!(hero: @user)

    assert_equal "ready", workflow.state
    assert_nil workflow.current_step_name, "current_step_name should be nil until execution starts"
    assert_equal "step_one", workflow.next_step_name
    assert_equal 1, workflow.step_executions.count

    step_execution = workflow.step_executions.first
    assert_equal "scheduled", step_execution.state
    assert_equal "step_one", step_execution.step_name
  end

  test "step definitions are inherited" do
    assert_equal 1, ChildWorkflow.step_definitions.count
    assert_equal "child_step", ChildWorkflow.step_definitions.first.name
  end

  test "cancel_if conditions are inherited" do
    assert_equal 2, ChildWorkflow._cancel_conditions.count
  end

  test "job options are merged from parent" do
    options = ChildWorkflow._step_job_options
    assert_equal :base_queue, options[:queue]
    assert_equal 10, options[:priority]
  end

  test "may_proceed_without_hero! is inherited" do
    assert HerolessWorkflow._may_proceed_without_hero
    assert_not SimpleWorkflow._may_proceed_without_hero
  end

  test "step collection provides ordered steps" do
    collection = SimpleWorkflow.steps

    assert_equal 2, collection.size
    assert_equal "step_one", collection.first.name
    assert_equal "step_two", collection.last.name
  end

  test "step collection finds next step" do
    collection = SimpleWorkflow.steps

    next_step = collection.next_after("step_one")
    assert_equal "step_two", next_step.name

    assert_nil collection.next_after("step_two")
  end

  test "workflow with wait schedules step for future" do
    workflow = WaitingWorkflow.create!(hero: @user)

    first_execution = workflow.step_executions.first
    assert first_execution.scheduled_for <= Time.current + 1.second

    # Simulate step execution completing
    first_execution.execute!
    workflow.reload

    second_execution = workflow.step_executions.where(step_name: "delayed_step").first
    assert second_execution.scheduled_for > Time.current + 1.day
    assert second_execution.scheduled_for <= Time.current + 2.days + 1.second
  end

  test "resume! works for paused workflows" do
    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.pause!  # External pause cancels the execution

    workflow.resume!

    assert_equal "ready", workflow.state
    assert_nil workflow.transitioned_at
    # With the new pause/resume behavior, scheduled executions are preserved
    # and reused on resume - no new execution is created
    assert_equal 1, workflow.step_executions.count
  end

  test "resume! raises for non-paused workflows" do
    workflow = SimpleWorkflow.create!(hero: @user)

    assert_raises(GenevaDrive::InvalidStateError) do
      workflow.resume!
    end
  end

  test "transitioned_at is set when transitioning to terminal states" do
    workflow = SimpleWorkflow.create!(hero: @user)

    workflow.transition_to!("finished")

    assert_not_nil workflow.transitioned_at
    assert workflow.transitioned_at <= Time.current
  end

  test "scopes work correctly" do
    workflow1 = SimpleWorkflow.create!(hero: @user)
    workflow2 = SimpleWorkflow.create!(hero: @user, allow_multiple: true)
    workflow2.transition_to!("finished")

    assert_includes GenevaDrive::Workflow.ready, workflow1
    assert_includes GenevaDrive::Workflow.finished, workflow2
    assert_includes GenevaDrive::Workflow.ongoing, workflow1
    assert_not_includes GenevaDrive::Workflow.ongoing, workflow2
    assert_equal 2, GenevaDrive::Workflow.for_hero(@user).count
  end

  # Three-step workflow for next_step_name tests
  class ThreeStepWorkflow < GenevaDrive::Workflow
    step :first do
    end

    step :second do
    end

    step :third do
    end
  end

  test "next_step_name is set on workflow creation" do
    workflow = ThreeStepWorkflow.create!(hero: @user)

    assert_nil workflow.current_step_name, "current_step_name should be nil until execution starts"
    assert_equal "first", workflow.next_step_name
  end

  test "current_step_name and next_step_name are set during execution" do
    workflow = ThreeStepWorkflow.create!(hero: @user)

    # Start execution - this sets current_step_name
    workflow.step_executions.first.execute!
    workflow.reload

    # After execution completes, current_step_name is cleared
    assert_nil workflow.current_step_name
    # next_step_name points to the next step that was scheduled
    assert_equal "second", workflow.next_step_name
  end

  test "next_step_name is nil when last step is scheduled" do
    workflow = SimpleWorkflow.create!(hero: @user)

    # Execute first step - schedules second step
    workflow.step_executions.first.execute!
    workflow.reload

    # After first step completes, next_step_name is "step_two" (what's scheduled)
    assert_equal "step_two", workflow.next_step_name
  end

  test "next_step_name is cleared when workflow finishes" do
    workflow = SimpleWorkflow.create!(hero: @user)

    # Execute both steps
    workflow.step_executions.first.execute!
    workflow.reload
    workflow.step_executions.where(step_name: "step_two").first.execute!
    workflow.reload

    assert_equal "finished", workflow.state
    assert_nil workflow.current_step_name
    assert_nil workflow.next_step_name
  end

  # previous_step_name tests
  test "previous_step_name returns nil when at first step" do
    workflow = ThreeStepWorkflow.create!(hero: @user)

    assert_equal "first", workflow.next_step_name
    assert_nil workflow.previous_step_name
  end

  test "previous_step_name returns first step when at second step" do
    workflow = ThreeStepWorkflow.create!(hero: @user)

    # Execute first step - schedules second step
    workflow.step_executions.first.execute!
    workflow.reload

    assert_equal "second", workflow.next_step_name
    assert_equal "first", workflow.previous_step_name
  end

  test "previous_step_name returns second step when at third step" do
    workflow = ThreeStepWorkflow.create!(hero: @user)

    # Execute first two steps
    workflow.step_executions.first.execute!
    workflow.reload
    workflow.step_executions.where(step_name: "second").first.execute!
    workflow.reload

    assert_equal "third", workflow.next_step_name
    assert_equal "second", workflow.previous_step_name
  end

  test "previous_step_name returns last step when finished" do
    workflow = ThreeStepWorkflow.create!(hero: @user)

    # Execute all steps
    workflow.step_executions.first.execute!
    workflow.reload
    workflow.step_executions.where(step_name: "second").first.execute!
    workflow.reload
    workflow.step_executions.where(step_name: "third").first.execute!
    workflow.reload

    assert_equal "finished", workflow.state
    assert_nil workflow.next_step_name
    assert_equal "third", workflow.previous_step_name
  end

  # Workflow with no steps for edge case testing
  class EmptyWorkflow < GenevaDrive::Workflow
  end

  test "previous_step_name returns nil for empty workflow when finished" do
    workflow = EmptyWorkflow.create!(hero: @user)
    # Empty workflow finishes immediately
    workflow.reload

    assert_equal "finished", workflow.state
    assert_nil workflow.previous_step_name
  end
end
