# frozen_string_literal: true

require "test_helper"

# Integration tests for resumable steps going through the unified Executor:
# exception policies, job options, pause/resume and housekeeping recovery.
class ResumableStepIntegrationTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers
  include ActiveJob::TestHelper

  class TransientError < StandardError; end

  # Class-level exception policy must apply inside resumable steps
  class ClassPolicyResumableWorkflow < GenevaDrive::Workflow
    on_exception :reattempt!, max_reattempts: 5

    resumable_step :process do |iter|
      iter.iterate_over((1..5).to_a) do |item|
        Thread.current[:class_policy_items] ||= []
        Thread.current[:class_policy_items] << item

        if item == 3 && !Thread.current[:class_policy_raised]
          Thread.current[:class_policy_raised] = true
          raise TransientError, "flaky at item 3"
        end
      end
    end
  end

  # Step-level reattempt with a terminal action, inside a resumable step
  class TerminalSkipResumableWorkflow < GenevaDrive::Workflow
    resumable_step :always_fails, on_exception: :reattempt!, max_reattempts: 2, terminal_action: :skip! do |iter|
      raise TransientError, "always fails"
    end

    step :after do
      Thread.current[:terminal_skip_after_ran] = true
    end
  end

  # Per-step job options must be preserved on successor enqueues
  class CriticalQueueResumableWorkflow < GenevaDrive::Workflow
    resumable_step :process, job_options: {queue: :critical} do |iter|
      current = iter.cursor || 0
      while current < 4
        current += 1
        iter.set!(current)
        # Suspend once, on the first pass - the successor resumes past 2
        suspend! if current == 2
      end
    end
  end

  # A failing resumable step with the default policy (pause)
  class FailingResumableWorkflow < GenevaDrive::Workflow
    resumable_step :process do |iter|
      iter.iterate_over(%w[a b c d]) do |item|
        Thread.current[:failing_items] ||= []
        Thread.current[:failing_items] << item

        if item == "c" && !Thread.current[:failing_raised]
          Thread.current[:failing_raised] = true
          raise TransientError, "boom at c"
        end
      end
    end

    step :after do
      Thread.current[:failing_after_ran] = true
    end
  end

  # Simulates the workflow being paused externally mid-iteration
  class ExternallyPausedResumableWorkflow < GenevaDrive::Workflow
    resumable_step :process do |iter|
      iter.iterate_over((1..5).to_a) do |item|
        Thread.current[:ext_pause_items] ||= []
        Thread.current[:ext_pause_items] << item

        if item == 2 && !Thread.current[:ext_paused]
          Thread.current[:ext_paused] = true
          # Out-of-band state change (e.g. an operator or another process)
          GenevaDrive::Workflow.where(id: id).update_all(state: "paused")
        end
      end
    end
  end

  # A normal step misusing suspend!
  class SuspendMisuseWorkflow < GenevaDrive::Workflow
    step :not_resumable do
      suspend!
    end
  end

  # Suspends after every item - speedrun_current_step must follow the chain
  class SuspendEveryItemWorkflow < GenevaDrive::Workflow
    resumable_step :drip do |iter|
      current = iter.cursor || 0
      while current < 3
        current += 1
        Thread.current[:drip_items] ||= []
        Thread.current[:drip_items] << current
        iter.set!(current)
        suspend! if current < 3
      end
    end
  end

  # skip_if applies to continuation executions like to any other execution
  class SkipIfMidwayWorkflow < GenevaDrive::Workflow
    resumable_step :process, skip_if: -> { Thread.current[:skipif_now] } do |iter|
      iter.iterate_over((1..6).to_a) do |item|
        Thread.current[:skipif_items] ||= []
        Thread.current[:skipif_items] << item

        if item == 2
          Thread.current[:skipif_now] = true
          suspend!
        end
      end
    end

    step :after do
      Thread.current[:skipif_after_ran] = true
    end
  end

  class PlainResumableWorkflow < GenevaDrive::Workflow
    resumable_step :process do |iter|
      iter.iterate_over((1..3).to_a) do |item|
        Thread.current[:plain_items] ||= []
        Thread.current[:plain_items] << item
      end
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
    %i[
      class_policy_items class_policy_raised
      terminal_skip_after_ran
      critical_suspended
      failing_items failing_raised failing_after_ran
      ext_pause_items ext_paused
      drip_items
      plain_items
      skipif_now skipif_items skipif_after_ran
    ].each { |key| Thread.current[key] = nil }
  end

  test "class-level on_exception applies inside resumable steps and reattempts from the cursor" do
    workflow = ClassPolicyResumableWorkflow.create!(hero: @user)

    assert_raises(TransientError) { perform_next_step(workflow) }

    workflow.reload
    assert_equal "ready", workflow.state, "class-level reattempt! policy should apply, not the default pause"

    first_exec = workflow.step_executions.find_by(step_name: "process", continues_from_id: nil)
    assert_equal "completed", first_exec.state
    assert_equal "reattempted", first_exec.outcome

    successor = first_exec.successor
    assert_not_nil successor, "reattempt of a resumable step should continue via a successor"
    assert_equal 2, successor.cursor_value, "cursor should be preserved across the reattempt"

    perform_next_step(workflow)

    workflow.reload
    assert_equal "finished", workflow.state
    # Items 1, 2 done before the failure; item 3 is re-done after the reattempt
    assert_equal [1, 2, 3, 3, 4, 5], Thread.current[:class_policy_items]
  end

  test "max_reattempts with terminal_action skip! terminates a failing resumable step" do
    workflow = TerminalSkipResumableWorkflow.create!(hero: @user)

    # Attempts 1 and 2 reattempt (count 0 and 1), attempt 3 hits the limit and skips
    3.times do
      assert_raises(TransientError) { perform_next_step(workflow) }
      workflow.reload
    end

    skipped = workflow.step_executions.where(step_name: "always_fails", state: "skipped")
    assert skipped.exists?, "step should be skipped once max_reattempts is exhausted"

    perform_next_step(workflow)

    workflow.reload
    assert_equal "finished", workflow.state
    assert Thread.current[:terminal_skip_after_ran]
  end

  test "successor executions are enqueued with the per-step job options" do
    workflow = CriticalQueueResumableWorkflow.create!(hero: @user)

    clear_enqueued_jobs
    perform_next_step(workflow)

    workflow.reload
    successor = workflow.current_execution
    assert_not_nil successor
    assert successor.resuming?

    assert_enqueued_with(job: GenevaDrive::PerformStepJob, args: [successor.id], queue: "critical")
  end

  test "a failed resumable step is retried from its cursor on resume, not skipped" do
    workflow = FailingResumableWorkflow.create!(hero: @user)

    assert_raises(TransientError) { perform_next_step(workflow) }

    workflow.reload
    assert_equal "paused", workflow.state
    failed_exec = workflow.step_executions.find_by(step_name: "process", state: "failed")
    assert_not_nil failed_exec
    assert_equal 2, failed_exec.cursor_value, "cursor persisted up to the last checkpoint before the failure"

    workflow.resume!

    workflow.reload
    successor = workflow.current_execution
    assert_not_nil successor
    assert_equal "process", successor.step_name, "resume must retry the failed step, not skip to the next one"
    assert_equal failed_exec.id, successor.continues_from_id
    assert_equal 2, successor.cursor_value

    speedrun_workflow(workflow)

    assert_equal "finished", workflow.state
    # a, b done before failure; c re-done after resume
    assert_equal %w[a b c c d], Thread.current[:failing_items]
    assert Thread.current[:failing_after_ran]
  end

  test "external pause mid-iteration preserves the cursor and resume continues from it" do
    workflow = ExternallyPausedResumableWorkflow.create!(hero: @user)

    perform_next_step(workflow)

    workflow.reload
    assert_equal "paused", workflow.state
    assert_equal [1, 2], Thread.current[:ext_pause_items]

    interrupted = workflow.step_executions.find_by(step_name: "process")
    assert_equal "completed", interrupted.state
    assert_equal "workflow_paused", interrupted.outcome
    assert_equal 2, interrupted.cursor_value, "cursor handoff must survive an external pause"

    workflow.resume!

    workflow.reload
    successor = workflow.current_execution
    assert_not_nil successor
    assert_equal interrupted.id, successor.continues_from_id
    assert_equal 2, successor.cursor_value

    speedrun_workflow(workflow)

    assert_equal "finished", workflow.state
    assert_equal [1, 2, 3, 4, 5], Thread.current[:ext_pause_items], "no items should be reprocessed"
  end

  test "skip_if is evaluated on continuation executions too" do
    workflow = SkipIfMidwayWorkflow.create!(hero: @user)

    # Items 1, 2 processed, then the step suspends with the skip flag now set
    perform_next_step(workflow)
    # The continuation sees skip_if as true and skips the rest of the step
    perform_next_step(workflow)

    workflow.reload
    assert_equal [1, 2], Thread.current[:skipif_items]
    assert workflow.step_executions.exists?(step_name: "process", state: "skipped")

    perform_next_step(workflow)

    workflow.reload
    assert_equal "finished", workflow.state
    assert Thread.current[:skipif_after_ran]
  end

  test "suspend! raises when called from a non-resumable step" do
    workflow = SuspendMisuseWorkflow.create!(hero: @user)

    error = assert_raises(GenevaDrive::InvalidStateError) { perform_next_step(workflow) }
    assert_match(/resumable_step/, error.message)
  end

  test "speedrun_current_step follows the successor chain across suspensions" do
    workflow = SuspendEveryItemWorkflow.create!(hero: @user)

    execution = speedrun_current_step(workflow)

    assert_equal [1, 2, 3], Thread.current[:drip_items]
    assert_equal "completed", execution.state
    assert_equal "success", execution.outcome
    assert_nil execution.successor
    workflow.reload
    assert_equal "finished", workflow.state
  end

  test "housekeeping recovers a stuck resumable execution by continuing from its cursor" do
    workflow = PlainResumableWorkflow.create!(hero: @user)

    execution = workflow.current_execution
    # Simulate a worker that died mid-iteration: in_progress past the
    # threshold, with a persisted cursor
    execution.update!(state: "in_progress", started_at: 3.hours.ago)
    execution.cursor_value = 2
    execution.save!
    workflow.update!(state: "performing", current_step_name: "process")

    GenevaDrive::HousekeepingJob.perform_now

    execution.reload
    workflow.reload
    assert_equal "completed", execution.state
    assert_equal "recovered", execution.outcome
    assert_equal "ready", workflow.state

    successor = execution.successor
    assert_not_nil successor, "recovery must continue the iteration, not restart it"
    assert_equal "scheduled", successor.state
    assert_equal 2, successor.cursor_value

    speedrun_workflow(workflow)

    assert_equal "finished", workflow.state
    assert_equal [3], Thread.current[:plain_items], "only the remaining item should be processed"
  end
end
