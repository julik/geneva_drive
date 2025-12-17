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
    assert_equal "step_one", workflow.current_step_name
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
    collection = SimpleWorkflow.step_collection

    assert_equal 2, collection.size
    assert_equal "step_one", collection.first.name
    assert_equal "step_two", collection.last.name
  end

  test "step collection finds next step" do
    collection = SimpleWorkflow.step_collection

    next_step = collection.next_after("step_one")
    assert_equal "step_two", next_step.name

    assert_nil collection.next_after("step_two")
  end

  test "workflow with wait schedules step for future" do
    workflow = WaitingWorkflow.create!(hero: @user)

    first_execution = workflow.step_executions.first
    assert first_execution.scheduled_for <= Time.current + 1.second

    first_execution.mark_completed!
    workflow.transition_to!("ready")
    workflow.schedule_next_step!

    second_execution = workflow.step_executions.last
    assert second_execution.scheduled_for > Time.current + 1.day
    assert second_execution.scheduled_for <= Time.current + 2.days + 1.second
  end

  test "resume! works for paused workflows" do
    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.transition_to!("paused")

    workflow.resume!

    assert_equal "ready", workflow.state
    assert_nil workflow.transitioned_at
    assert_equal 2, workflow.step_executions.count
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
    assert_includes GenevaDrive::Workflow.active, workflow1
    assert_not_includes GenevaDrive::Workflow.active, workflow2
    assert_equal 2, GenevaDrive::Workflow.for_hero(@user).count
  end
end
