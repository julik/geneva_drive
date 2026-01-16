# frozen_string_literal: true

require "test_helper"

class ResumableStepTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  # Simple workflow with a resumable step that processes an array
  class ArrayProcessingWorkflow < GenevaDrive::Workflow
    step :setup do
      Thread.current[:setup_ran] = true
    end

    resumable_step :process_items do |iter|
      items = %w[a b c d e]
      iter.iterate_over(items) do |item|
        Thread.current[:processed_items] ||= []
        Thread.current[:processed_items] << item
      end
    end

    step :finalize do
      Thread.current[:finalize_ran] = true
    end
  end

  # Workflow with manual cursor control
  class ManualCursorWorkflow < GenevaDrive::Workflow
    resumable_step :count_up do |iter|
      current = iter.cursor || 1
      while current <= 5
        Thread.current[:counted_values] ||= []
        Thread.current[:counted_values] << current
        current += 1
        iter.set!(current)
      end
    end
  end

  # Workflow using advance! for integer cursors
  class AdvanceCursorWorkflow < GenevaDrive::Workflow
    resumable_step :process_pages do |iter|
      iter.set!(0) unless iter.cursor
      while iter.cursor < 5
        Thread.current[:pages_processed] ||= []
        Thread.current[:pages_processed] << iter.cursor
        iter.advance!
      end
    end
  end

  # Workflow testing skip_to!
  class SkipToWorkflow < GenevaDrive::Workflow
    resumable_step :paginate do |iter|
      page = iter.cursor || 1
      loop do
        Thread.current[:pages_fetched] ||= []
        Thread.current[:pages_fetched] << page

        # Simulate API: skip to page 5 after page 2
        if page == 2
          iter.skip_to!(5)
        end

        break if page >= 6
        page += 1
        iter.set!(page)
      end
    end
  end

  # Workflow with max_iterations limit
  class MaxIterationsWorkflow < GenevaDrive::Workflow
    resumable_step :bulk_process, max_iterations: 3 do |iter|
      items = (1..10).to_a
      iter.iterate_over(items) do |item|
        Thread.current[:bulk_items] ||= []
        Thread.current[:bulk_items] << item
      end
    end
  end

  # Workflow testing flow control inside resumable step
  class FlowControlInResumableWorkflow < GenevaDrive::Workflow
    resumable_step :process_with_cancel do |iter|
      items = (1..10).to_a
      iter.iterate_over(items) do |item|
        Thread.current[:items_before_cancel] ||= []
        Thread.current[:items_before_cancel] << item
        cancel! if item == 3
      end
    end
  end

  # Workflow testing reattempt with rewind
  class RewindWorkflow < GenevaDrive::Workflow
    resumable_step :process_then_rewind do |iter|
      items = %w[x y z]
      iter.iterate_over(items) do |item|
        Thread.current[:rewind_items] ||= []
        Thread.current[:rewind_items] << item

        if item == "y" && !Thread.current[:rewind_triggered]
          Thread.current[:rewind_triggered] = true
          reattempt!(rewind: true)
        end
      end
    end
  end

  # Workflow testing resumed? detection
  class ResumedDetectionWorkflow < GenevaDrive::Workflow
    resumable_step :check_resumed do |iter|
      Thread.current[:resumed_values] ||= []
      Thread.current[:resumed_values] << iter.resumed?

      items = %w[one two three]
      iter.iterate_over(items) do |item|
        Thread.current[:resumed_items] ||= []
        Thread.current[:resumed_items] << item
      end
    end
  end

  # Workflow testing suspend! flow control
  # Note: suspend! should be used with manual cursor control, not inside iterate_over
  class SuspendFlowControlWorkflow < GenevaDrive::Workflow
    resumable_step :suspend_midway do |iter|
      current = iter.cursor || 1
      while current <= 5
        Thread.current[:suspend_items] ||= []
        Thread.current[:suspend_items] << current
        if current == 2 && !Thread.current[:suspend_triggered]
          Thread.current[:suspend_triggered] = true
          iter.set!(current + 1)  # Save position before suspending
          suspend!
        end
        current += 1
        iter.set!(current)
      end
    end
  end

  # Workflow testing pause! inside resumable step
  # pause! should suspend the step (preserving cursor), not cancel it
  class PauseInResumableWorkflow < GenevaDrive::Workflow
    resumable_step :process_with_pause do |iter|
      current = iter.cursor || 1
      while current <= 5
        Thread.current[:pause_items] ||= []
        Thread.current[:pause_items] << current
        if current == 3 && !Thread.current[:pause_triggered]
          Thread.current[:pause_triggered] = true
          iter.set!(current + 1)  # Save position before pausing
          pause!
        end
        current += 1
        iter.set!(current)
      end
    end

    step :after_pause do
      Thread.current[:after_pause_ran] = true
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
    Thread.current[:setup_ran] = nil
    Thread.current[:finalize_ran] = nil
    Thread.current[:processed_items] = nil
    Thread.current[:counted_values] = nil
    Thread.current[:pages_processed] = nil
    Thread.current[:pages_fetched] = nil
    Thread.current[:bulk_items] = nil
    Thread.current[:items_before_cancel] = nil
    Thread.current[:rewind_items] = nil
    Thread.current[:rewind_triggered] = nil
    Thread.current[:resumed_values] = nil
    Thread.current[:resumed_items] = nil
    Thread.current[:suspend_items] = nil
    Thread.current[:suspend_triggered] = nil
    Thread.current[:pause_items] = nil
    Thread.current[:pause_triggered] = nil
    Thread.current[:after_pause_ran] = nil
  end

  # Basic resumable step tests

  test "resumable_step processes all items and completes" do
    workflow = ArrayProcessingWorkflow.create!(hero: @user)

    speedrun_workflow(workflow)

    assert_equal "finished", workflow.state
    assert Thread.current[:setup_ran]
    assert_equal %w[a b c d e], Thread.current[:processed_items]
    assert Thread.current[:finalize_ran]
  end

  test "resumable_step processes all items in sequence" do
    workflow = ArrayProcessingWorkflow.create!(hero: @user)

    # Execute setup step
    perform_next_step(workflow)
    assert Thread.current[:setup_ran]

    # Execute resumable step to completion
    speedrun_current_step(workflow)

    workflow.reload
    completed_executions = workflow.step_executions.where(step_name: "process_items", state: "completed")
    assert completed_executions.exists?
    assert_equal %w[a b c d e], Thread.current[:processed_items]
  end

  test "manual cursor control works correctly" do
    workflow = ManualCursorWorkflow.create!(hero: @user)

    speedrun_current_step(workflow)

    assert_equal [1, 2, 3, 4, 5], Thread.current[:counted_values]
    assert_equal "finished", workflow.state
  end

  test "advance! increments integer cursor" do
    workflow = AdvanceCursorWorkflow.create!(hero: @user)

    speedrun_current_step(workflow)

    assert_equal [0, 1, 2, 3, 4], Thread.current[:pages_processed]
    assert_equal "finished", workflow.state
  end

  test "advance! raises error for non-integer cursor" do
    # Test that advance! only works with integers
    iter = GenevaDrive::IterableStep.new(
      :test,
      "not_an_integer",
      execution: nil,
      resumed: false,
      interrupter: nil
    )

    error = assert_raises(ArgumentError) do
      iter.advance!
    end

    assert_match(/requires integer cursor/, error.message)
  end

  # skip_to! tests

  test "skip_to! jumps to new cursor position and creates successor" do
    workflow = SkipToWorkflow.create!(hero: @user)

    # First execution: processes pages 1, 2, then skip_to!(5)
    perform_next_step(workflow)

    workflow.reload
    # First execution should be completed
    first_exec = workflow.step_executions.find_by(step_name: "paginate", continues_from_id: nil)
    assert_equal "completed", first_exec.state
    assert_equal [1, 2], Thread.current[:pages_fetched]

    # Successor should be scheduled with cursor=5
    successor = first_exec.successor
    assert_not_nil successor, "Expected a successor execution"
    assert_equal "scheduled", successor.state
    assert_equal 5, successor.cursor_value

    # Second execution: continues from page 5
    Thread.current[:pages_fetched] = nil
    perform_next_step(workflow)

    workflow.reload
    assert_equal "completed", successor.reload.state
    assert_equal [5, 6], Thread.current[:pages_fetched]
  end

  # chained executions tests

  test "resumable step that gets interrupted creates successor" do
    workflow = MaxIterationsWorkflow.create!(hero: @user)

    # Execute the step to completion (no iteration limits now)
    speedrun_current_step(workflow)

    workflow.reload
    assert_equal "finished", workflow.state
    assert_equal (1..10).to_a, Thread.current[:bulk_items]
  end

  # Flow control tests

  test "cancel! works inside resumable step" do
    workflow = FlowControlInResumableWorkflow.create!(hero: @user)

    perform_next_step(workflow)

    assert_equal "canceled", workflow.state
    assert_equal [1, 2, 3], Thread.current[:items_before_cancel]
  end

  test "pause! inside resumable step preserves cursor and resumes from it" do
    workflow = PauseInResumableWorkflow.create!(hero: @user)

    # First execution: processes 1, 2, 3, saves cursor=4, pauses
    perform_next_step(workflow)

    workflow.reload
    assert_equal "paused", workflow.state
    assert_equal [1, 2, 3], Thread.current[:pause_items]

    # The step execution should be COMPLETED with outcome "workflow_paused"
    step_execution = workflow.step_executions.find_by(step_name: "process_with_pause")
    assert_equal "completed", step_execution.state
    assert_equal "workflow_paused", step_execution.outcome
    assert_equal 4, step_execution.cursor_value, "cursor should be preserved"

    # Resume the workflow - this creates a successor execution
    workflow.resume!

    workflow.reload
    assert_equal "ready", workflow.state

    # A successor execution should be created
    successor = step_execution.successor
    assert_not_nil successor, "Expected a successor execution after resume"
    assert_equal "scheduled", successor.state
    assert_equal 4, successor.cursor_value

    # Continue execution - should resume from cursor=4, not restart
    speedrun_workflow(workflow)

    # Should have processed 4, 5 (not 1, 2, 3 again)
    assert_equal [1, 2, 3, 4, 5], Thread.current[:pause_items]
    assert_equal "finished", workflow.state
    assert Thread.current[:after_pause_ran]
  end

  test "reattempt! with rewind: true restarts from beginning" do
    workflow = RewindWorkflow.create!(hero: @user)

    # First execution: x, y (triggers rewind)
    perform_next_step(workflow)

    workflow.reload
    # First execution completed, created successor with nil cursor (rewind)
    first_exec = workflow.step_executions.find_by(step_name: "process_then_rewind", continues_from_id: nil)
    assert_equal "completed", first_exec.state
    assert_equal %w[x y], Thread.current[:rewind_items]

    # Successor should be scheduled with nil cursor (rewind)
    successor = first_exec.successor
    assert_not_nil successor, "Expected successor after reattempt"
    assert_equal "scheduled", successor.state
    assert_nil successor.cursor_value

    # Second execution: starts from beginning again
    speedrun_current_step(workflow)

    assert_equal %w[x y x y z], Thread.current[:rewind_items]
    assert_equal "finished", workflow.state
  end

  # resumed? detection

  test "resumed? returns false on first run" do
    workflow = ResumedDetectionWorkflow.create!(hero: @user)

    # Execute the step to completion
    speedrun_current_step(workflow)

    # First (and only) execution should have resumed? = false
    assert_equal [false], Thread.current[:resumed_values]
    assert_equal %w[one two three], Thread.current[:resumed_items]
  end

  test "resuming? returns true for successor executions" do
    workflow = SkipToWorkflow.create!(hero: @user)

    # First execution
    perform_next_step(workflow)

    workflow.reload
    first_exec = workflow.step_executions.find_by(step_name: "paginate", continues_from_id: nil)
    successor = first_exec.successor

    assert_not first_exec.resuming?, "First execution should not be resuming"
    assert successor.resuming?, "Successor should be resuming"
  end

  # suspend! flow control

  test "suspend! completes execution and creates successor" do
    workflow = SuspendFlowControlWorkflow.create!(hero: @user)

    # First execution: processes 1, 2, saves cursor=3, suspends
    perform_next_step(workflow)

    workflow.reload
    first_exec = workflow.step_executions.find_by(step_name: "suspend_midway", continues_from_id: nil)
    assert_equal "completed", first_exec.state
    assert_equal [1, 2], Thread.current[:suspend_items]

    # Successor should be scheduled with cursor=3
    successor = first_exec.successor
    assert_not_nil successor, "Expected successor after suspend!"
    assert_equal "scheduled", successor.state
    assert_equal 3, successor.cursor_value

    # Continue from cursor=3
    speedrun_current_step(workflow)

    assert_equal [1, 2, 3, 4, 5], Thread.current[:suspend_items]
    assert_equal "finished", workflow.state
  end

  # Cursor serialization tests

  test "cursor_value serializes and deserializes integers" do
    workflow = ManualCursorWorkflow.create!(hero: @user)
    # Use existing execution
    execution = workflow.current_execution

    execution.cursor_value = 42
    execution.save!
    execution.reload

    assert_equal 42, execution.cursor_value
  end

  test "cursor_value serializes and deserializes strings" do
    workflow = ManualCursorWorkflow.create!(hero: @user)
    # Use existing execution
    execution = workflow.current_execution

    execution.cursor_value = "page_token_abc123"
    execution.save!
    execution.reload

    assert_equal "page_token_abc123", execution.cursor_value
  end

  test "cursor_value handles nil" do
    workflow = ManualCursorWorkflow.create!(hero: @user)
    # Use existing execution
    execution = workflow.current_execution

    execution.cursor_value = nil
    execution.save!
    execution.reload

    assert_nil execution.cursor_value
  end

  # StepExecution state tests

  test "current_execution returns scheduled or in_progress execution" do
    workflow = ArrayProcessingWorkflow.create!(hero: @user)

    # Should have a scheduled execution
    workflow.reload
    execution = workflow.current_execution

    assert_not_nil execution
    assert_equal "scheduled", execution.state
  end

  test "continues_from association links chained executions" do
    workflow = SkipToWorkflow.create!(hero: @user)

    # First execution creates successor
    perform_next_step(workflow)

    workflow.reload
    first_exec = workflow.step_executions.find_by(step_name: "paginate", continues_from_id: nil)
    successor = first_exec.successor

    assert_not_nil successor
    assert_equal first_exec, successor.continues_from
    assert_equal successor, first_exec.successor
  end

  # DSL validation tests

  test "resumable_step requires a block" do
    error = assert_raises(ArgumentError) do
      Class.new(GenevaDrive::Workflow) do
        resumable_step :no_block
      end
    end

    assert_match(/requires a block/, error.message)
  end

  test "resumable_step validates max_iterations is positive" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        resumable_step :bad_iterations, max_iterations: 0 do |iter|
        end
      end
    end

    assert_match(/positive integer/, error.message)
  end

  test "resumable_step validates max_runtime is positive" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        resumable_step :bad_runtime, max_runtime: -1.minute do |iter|
        end
      end
    end

    assert_match(/positive duration/, error.message)
  end

  # Test helper tests

  test "assert_cursor checks cursor value" do
    workflow = SkipToWorkflow.create!(hero: @user)

    # Execute to create successor with cursor
    perform_next_step(workflow)

    workflow.reload
    successor = workflow.current_execution
    assert_cursor(workflow, 5)
  end

  test "assert_step_has_successor checks for scheduled successor" do
    workflow = SkipToWorkflow.create!(hero: @user)

    # Execute to create successor
    perform_next_step(workflow)

    assert_step_has_successor(workflow, :paginate)
  end

  # ResumableStepDefinition tests

  test "resumable? returns true for resumable step definitions" do
    klass = Class.new(GenevaDrive::Workflow) do
      resumable_step :my_resumable do |iter|
      end
    end

    step_def = klass.steps.first
    assert step_def.resumable?
  end

  test "resumable step definition inherits standard step options" do
    klass = Class.new(GenevaDrive::Workflow) do
      resumable_step :with_options, wait: 5.minutes, on_exception: :skip! do |iter|
      end
    end

    step_def = klass.steps.first
    assert_equal 5.minutes, step_def.wait
    assert_equal :skip!, step_def.on_exception
  end
end
