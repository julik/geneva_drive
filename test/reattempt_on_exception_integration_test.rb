# frozen_string_literal: true

require "test_helper"

class ReattemptOnExceptionIntegrationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Disable transactional tests to test proper locking flows
  self.use_transactional_tests = false

  # Custom exception for testing
  class TransientError < StandardError; end

  # Workflow with a single step that reattempts on exception.
  # Uses a class-level counter to track executions and raise on first attempt.
  class ReattemptingWorkflow < GenevaDrive::Workflow
    step :process, on_exception: :reattempt! do
      # Increment execution count
      self.class.increment_execution_count!

      # Raise on first attempt, succeed on second
      if self.class.execution_count == 1
        raise TransientError, "Transient failure on first attempt"
      end

      # Second attempt succeeds
      Thread.current[:reattempt_test_completed] = true
    end

    class << self
      def execution_count
        @execution_count ||= 0
      end

      def increment_execution_count!
        @execution_count ||= 0
        @execution_count += 1
      end

      def reset_tracking!
        @execution_count = 0
        Thread.current[:reattempt_test_completed] = nil
      end

      def step_completed?
        Thread.current[:reattempt_test_completed]
      end
    end
  end

  setup do
    ReattemptingWorkflow.reset_tracking!
    clean_database!
    @user = User.create!(email: "test@example.com", name: "Test User")
  end

  teardown do
    ReattemptingWorkflow.reset_tracking!
    clean_database!
  end

  test "workflow reattempts step on exception and succeeds on second attempt" do
    # Phase 1: Create workflow - verify initial state
    workflow = ReattemptingWorkflow.create!(hero: @user)

    assert_equal "ready", workflow.state
    assert_equal "process", workflow.current_step_name
    assert_equal 1, workflow.step_executions.count

    first_step_execution = workflow.step_executions.first
    assert_equal "scheduled", first_step_execution.state
    assert_equal "process", first_step_execution.step_name
    assert_nil first_step_execution.outcome

    # Verify job was enqueued
    assert_enqueued_jobs 1, only: GenevaDrive::PerformStepJob

    # Phase 2: Execute first attempt - should raise and reattempt
    error = assert_raises(TransientError) do
      GenevaDrive::PerformStepJob.perform_now(first_step_execution.id)
    end

    assert_equal "Transient failure on first attempt", error.message
    assert_equal 1, ReattemptingWorkflow.execution_count

    # Reload to get fresh state
    first_step_execution.reload
    workflow.reload

    # First step execution should be completed with "reattempted" outcome
    assert_equal "completed", first_step_execution.state
    assert_equal "reattempted", first_step_execution.outcome
    assert_not_nil first_step_execution.completed_at

    # Workflow should be back to ready state
    assert_equal "ready", workflow.state
    assert_equal "process", workflow.current_step_name

    # A new step execution should have been created for the reattempt
    assert_equal 2, workflow.step_executions.count

    second_step_execution = workflow.step_executions.order(:created_at).last
    assert_equal "scheduled", second_step_execution.state
    assert_equal "process", second_step_execution.step_name
    assert_nil second_step_execution.outcome

    # Phase 3: Execute second attempt - should succeed
    # Clear the queue state for accurate assertion
    clear_enqueued_jobs

    GenevaDrive::PerformStepJob.perform_now(second_step_execution.id)

    assert_equal 2, ReattemptingWorkflow.execution_count
    assert ReattemptingWorkflow.step_completed?

    # Reload to get fresh state
    second_step_execution.reload
    workflow.reload

    # Second step execution should be completed with "success" outcome
    assert_equal "completed", second_step_execution.state
    assert_equal "success", second_step_execution.outcome
    assert_not_nil second_step_execution.completed_at

    # Workflow should be finished (only one step)
    assert_equal "finished", workflow.state
    assert_not_nil workflow.transitioned_at

    # Total step executions: 2 (first reattempted, second succeeded)
    assert_equal 2, workflow.step_executions.count

    # Verify all step executions are in terminal states
    assert workflow.step_executions.all? { |se| %w[completed skipped failed canceled].include?(se.state) }
  end

  test "step execution states after workflow creation" do
    workflow = ReattemptingWorkflow.create!(hero: @user)

    assert_equal 1, workflow.step_executions.count
    step_execution = workflow.step_executions.first

    assert_equal "scheduled", step_execution.state
    assert_equal "process", step_execution.step_name
    assert_nil step_execution.outcome
    assert_nil step_execution.started_at
    assert_nil step_execution.completed_at
    assert_nil step_execution.failed_at
    assert_nil step_execution.error_message
    assert_not_nil step_execution.scheduled_for
  end

  test "step execution states after first attempt with exception" do
    workflow = ReattemptingWorkflow.create!(hero: @user)
    first_step_execution = workflow.step_executions.first

    assert_raises(TransientError) do
      GenevaDrive::PerformStepJob.perform_now(first_step_execution.id)
    end

    first_step_execution.reload
    workflow.reload

    # First execution marked as completed with reattempted outcome
    assert_equal "completed", first_step_execution.state
    assert_equal "reattempted", first_step_execution.outcome
    assert_not_nil first_step_execution.completed_at

    # Error details are NOT stored on reattempt (only on failure)
    # The exception is re-raised but the step is marked as reattempted, not failed
    assert_nil first_step_execution.error_message

    # Workflow remains ready
    assert_equal "ready", workflow.state

    # New step execution scheduled
    assert_equal 2, workflow.step_executions.count
    new_execution = workflow.step_executions.order(:created_at).last
    assert_equal "scheduled", new_execution.state
  end

  test "database record counts throughout workflow lifecycle" do
    # Before workflow creation
    assert_equal 0, GenevaDrive::Workflow.count
    assert_equal 0, GenevaDrive::StepExecution.count

    # After workflow creation
    workflow = ReattemptingWorkflow.create!(hero: @user)
    assert_equal 1, GenevaDrive::Workflow.count
    assert_equal 1, GenevaDrive::StepExecution.count

    # After first attempt (with exception)
    first_execution = workflow.step_executions.first
    assert_raises(TransientError) do
      GenevaDrive::PerformStepJob.perform_now(first_execution.id)
    end

    assert_equal 1, GenevaDrive::Workflow.count
    assert_equal 2, GenevaDrive::StepExecution.count

    # After second attempt (success)
    second_execution = workflow.step_executions.order(:created_at).last
    GenevaDrive::PerformStepJob.perform_now(second_execution.id)

    assert_equal 1, GenevaDrive::Workflow.count
    assert_equal 2, GenevaDrive::StepExecution.count # No new execution after success on final step
  end

  test "original exception is re-raised after reattempt is scheduled" do
    workflow = ReattemptingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(TransientError) do
      GenevaDrive::PerformStepJob.perform_now(step_execution.id)
    end

    # The original exception is re-raised
    assert_equal "Transient failure on first attempt", error.message
    assert_kind_of TransientError, error

    # But the reattempt was still scheduled
    step_execution.reload
    workflow.reload
    assert_equal "completed", step_execution.state
    assert_equal "reattempted", step_execution.outcome
    assert_equal 2, workflow.step_executions.count
  end

  private

  def clean_database!
    GenevaDrive::StepExecution.delete_all
    GenevaDrive::Workflow.delete_all
    User.delete_all
  end
end
