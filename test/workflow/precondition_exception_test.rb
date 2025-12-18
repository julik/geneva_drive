# frozen_string_literal: true

require "test_helper"

class PreconditionExceptionTest < ActiveSupport::TestCase
  # Custom exception classes for testing exception propagation
  class CancelIfTestError < StandardError; end
  class SkipIfTestError < StandardError; end

  # Workflow with cancel_if that raises exception
  class CancelIfExceptionWorkflow < GenevaDrive::Workflow
    cancel_if { raise CancelIfTestError, "Exception in cancel_if condition" }

    step :test_step, on_exception: :pause! do
      Thread.current[:step_executed] = true
    end
  end

  # Workflow with cancel_if exception and cancel! policy
  class CancelIfCancelPolicyWorkflow < GenevaDrive::Workflow
    cancel_if { raise CancelIfTestError, "Exception in cancel_if" }

    step :test_step, on_exception: :cancel! do
      Thread.current[:step_executed] = true
    end
  end

  # Workflow with cancel_if exception and reattempt! policy
  class CancelIfReattemptPolicyWorkflow < GenevaDrive::Workflow
    cancel_if { raise CancelIfTestError, "Exception in cancel_if" }

    step :test_step, on_exception: :reattempt! do
      Thread.current[:step_executed] = true
    end
  end

  # Workflow with cancel_if exception and skip! policy
  class CancelIfSkipPolicyWorkflow < GenevaDrive::Workflow
    cancel_if { raise CancelIfTestError, "Exception in cancel_if" }

    step :test_step, on_exception: :skip! do
      Thread.current[:step_executed] = true
    end

    step :next_step do
      Thread.current[:next_step_executed] = true
    end
  end

  # Workflow with skip_if that raises exception
  class SkipIfExceptionWorkflow < GenevaDrive::Workflow
    step :test_step, skip_if: -> { raise SkipIfTestError, "Exception in skip_if" }, on_exception: :pause! do
      Thread.current[:step_executed] = true
    end
  end

  # Workflow with skip_if exception and cancel! policy
  class SkipIfCancelPolicyWorkflow < GenevaDrive::Workflow
    step :test_step, skip_if: -> { raise SkipIfTestError, "Exception in skip_if" }, on_exception: :cancel! do
      Thread.current[:step_executed] = true
    end
  end

  # Workflow with skip_if exception and reattempt! policy
  class SkipIfReattemptPolicyWorkflow < GenevaDrive::Workflow
    step :test_step, skip_if: -> { raise SkipIfTestError, "Exception in skip_if" }, on_exception: :reattempt! do
      Thread.current[:step_executed] = true
    end
  end

  # Workflow with skip_if exception and skip! policy
  class SkipIfSkipPolicyWorkflow < GenevaDrive::Workflow
    step :test_step, skip_if: -> { raise SkipIfTestError, "Exception in skip_if" }, on_exception: :skip! do
      Thread.current[:step_executed] = true
    end

    step :next_step do
      Thread.current[:next_step_executed] = true
    end
  end

  setup do
    @user = create_user
    Thread.current[:step_executed] = nil
    Thread.current[:next_step_executed] = nil
  end

  teardown do
    Thread.current[:step_executed] = nil
    Thread.current[:next_step_executed] = nil
  end

  # Tests for cancel_if exception handling

  test "exception in cancel_if with pause! policy pauses workflow" do
    workflow = CancelIfExceptionWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(CancelIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/Exception in cancel_if/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "paused", workflow.state
    assert_nil Thread.current[:step_executed]
    assert_match(/Exception in cancel_if/, step_execution.error_message)
  end

  test "exception in cancel_if with cancel! policy cancels workflow" do
    workflow = CancelIfCancelPolicyWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(CancelIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/Exception in cancel_if/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "canceled", step_execution.outcome
    assert_equal "canceled", workflow.state
    assert_nil Thread.current[:step_executed]
  end

  test "exception in cancel_if with reattempt! policy reschedules step" do
    workflow = CancelIfReattemptPolicyWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(CancelIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/Exception in cancel_if/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "reattempted", step_execution.outcome
    assert_equal "ready", workflow.state
    assert_nil Thread.current[:step_executed]
    # A new step execution should be scheduled
    assert_equal 2, workflow.step_executions.count
  end

  test "exception in cancel_if with skip! policy skips to next step" do
    workflow = CancelIfSkipPolicyWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(CancelIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/Exception in cancel_if/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "ready", workflow.state
    assert_nil Thread.current[:step_executed]
    assert_equal "next_step", workflow.next_step_name
  end

  # Tests for skip_if exception handling

  test "exception in skip_if with pause! policy pauses workflow" do
    workflow = SkipIfExceptionWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(SkipIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/Exception in skip_if/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "paused", workflow.state
    assert_nil Thread.current[:step_executed]
    assert_match(/Exception in skip_if/, step_execution.error_message)
  end

  test "exception in skip_if with cancel! policy cancels workflow" do
    workflow = SkipIfCancelPolicyWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(SkipIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/Exception in skip_if/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "canceled", step_execution.outcome
    assert_equal "canceled", workflow.state
    assert_nil Thread.current[:step_executed]
  end

  test "exception in skip_if with reattempt! policy reschedules step" do
    workflow = SkipIfReattemptPolicyWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(SkipIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/Exception in skip_if/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "reattempted", step_execution.outcome
    assert_equal "ready", workflow.state
    assert_nil Thread.current[:step_executed]
    assert_equal 2, workflow.step_executions.count
  end

  test "exception in skip_if with skip! policy skips to next step" do
    workflow = SkipIfSkipPolicyWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(SkipIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/Exception in skip_if/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "ready", workflow.state
    assert_nil Thread.current[:step_executed]
    assert_equal "next_step", workflow.next_step_name
  end

  # Test that step is not executed when precondition raises
  test "step body is not executed when cancel_if raises exception" do
    workflow = CancelIfExceptionWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    assert_raises(CancelIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_nil Thread.current[:step_executed]
  end

  test "step body is not executed when skip_if raises exception" do
    workflow = SkipIfExceptionWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    assert_raises(SkipIfTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_nil Thread.current[:step_executed]
  end
end
