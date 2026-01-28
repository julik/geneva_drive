# frozen_string_literal: true

require "test_helper"

class MaxReattemptsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Disable transactional tests to test proper locking flows
  self.use_transactional_tests = false

  class TransientError < StandardError; end

  # Workflow that always fails with reattempt limit
  class LimitedReattemptWorkflow < GenevaDrive::Workflow
    step :failing_step, on_exception: :reattempt!, max_reattempts: 3 do
      raise TransientError, "Always failing"
    end
  end

  # Workflow with unlimited reattempts (nil)
  class UnlimitedReattemptWorkflow < GenevaDrive::Workflow
    step :failing_step, on_exception: :reattempt!, max_reattempts: nil do
      self.class.increment_execution_count!
      raise TransientError, "Always failing"
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
      end
    end
  end

  # Workflow that fails a few times then succeeds
  class EventuallySucceedsWorkflow < GenevaDrive::Workflow
    step :flaky_step, on_exception: :reattempt!, max_reattempts: 10 do
      self.class.increment_execution_count!

      # Fail first 5 times, succeed on 6th
      if self.class.execution_count <= 5
        raise TransientError, "Transient failure #{self.class.execution_count}"
      end
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
      end
    end
  end

  # Workflow that uses manual reattempt! calls
  class ManualReattemptWorkflow < GenevaDrive::Workflow
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
      end
    end

    # max_reattempts: 2 for automatic exception handling
    step :manual_reattempt_step, on_exception: :reattempt!, max_reattempts: 2 do
      self.class.increment_execution_count!

      # Use manual reattempt! for first 5 attempts, then succeed
      if self.class.execution_count <= 5
        reattempt!
      end
    end
  end

  # Workflow with precondition that fails
  class PreconditionReattemptWorkflow < GenevaDrive::Workflow
    step :step_with_flaky_precondition, on_exception: :reattempt!, max_reattempts: 2, skip_if: :flaky_check do
      # Step body - never reached
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
      end
    end

    def flaky_check
      self.class.increment_execution_count!
      raise TransientError, "Precondition failure"
    end
  end

  setup do
    clean_database!
    @user = User.create!(email: "test@example.com", name: "Test User")
    UnlimitedReattemptWorkflow.reset_tracking!
    EventuallySucceedsWorkflow.reset_tracking!
    PreconditionReattemptWorkflow.reset_tracking!
    ManualReattemptWorkflow.reset_tracking!
  end

  teardown do
    clean_database!
    UnlimitedReattemptWorkflow.reset_tracking!
    EventuallySucceedsWorkflow.reset_tracking!
    PreconditionReattemptWorkflow.reset_tracking!
    ManualReattemptWorkflow.reset_tracking!
  end

  test "pauses workflow when max_reattempts is exceeded" do
    workflow = LimitedReattemptWorkflow.create!(hero: @user)

    # Execute 3 attempts (max_reattempts: 3)
    3.times do |i|
      step_execution = workflow.step_executions.order(:created_at).last
      assert_raises(TransientError) do
        GenevaDrive::PerformStepJob.perform_now(step_execution.id)
      end
      workflow.reload
    end

    # After 3 reattempts, workflow should still be ready with 4 step executions
    assert_equal "ready", workflow.state
    assert_equal 4, workflow.step_executions.count

    # 4th attempt should trigger the limit and pause
    fourth_step_execution = workflow.step_executions.order(:created_at).last
    assert_raises(TransientError) do
      GenevaDrive::PerformStepJob.perform_now(fourth_step_execution.id)
    end

    workflow.reload
    fourth_step_execution.reload

    # Workflow should now be paused
    assert_equal "paused", workflow.state

    # Step execution should be failed with error stored
    assert_equal "failed", fourth_step_execution.state
    assert_equal "failed", fourth_step_execution.outcome
    assert_equal "Always failing", fourth_step_execution.error_message

    # No new step execution should be created
    assert_equal 4, workflow.step_executions.count
  end

  test "allows unlimited reattempts when max_reattempts is nil" do
    workflow = UnlimitedReattemptWorkflow.create!(hero: @user)

    # Execute many attempts - should never pause due to limit
    10.times do
      step_execution = workflow.step_executions.order(:created_at).last
      assert_raises(TransientError) do
        GenevaDrive::PerformStepJob.perform_now(step_execution.id)
      end
      workflow.reload
    end

    # After 10 reattempts, workflow should still be ready
    assert_equal "ready", workflow.state
    assert_equal 11, workflow.step_executions.count

    # All completed step executions should have "reattempted" outcome
    completed_executions = workflow.step_executions.where(state: "completed")
    assert_equal 10, completed_executions.count
    assert completed_executions.all? { |se| se.outcome == "reattempted" }
  end

  test "resets reattempt count after successful execution" do
    workflow = EventuallySucceedsWorkflow.create!(hero: @user)

    # Execute 5 failing attempts
    5.times do
      step_execution = workflow.step_executions.order(:created_at).last
      assert_raises(TransientError) do
        GenevaDrive::PerformStepJob.perform_now(step_execution.id)
      end
      workflow.reload
    end

    # 6th attempt should succeed
    sixth_step_execution = workflow.step_executions.order(:created_at).last
    GenevaDrive::PerformStepJob.perform_now(sixth_step_execution.id)

    workflow.reload
    sixth_step_execution.reload

    # Workflow should be finished (only one step)
    assert_equal "finished", workflow.state

    # Step execution should be completed with success
    assert_equal "completed", sixth_step_execution.state
    assert_equal "success", sixth_step_execution.outcome

    # Should have 6 step executions total
    assert_equal 6, workflow.step_executions.count
  end

  test "counts only consecutive reattempts since last success" do
    # First, create a workflow that will eventually succeed
    workflow = EventuallySucceedsWorkflow.create!(hero: @user)

    # Execute 5 failing attempts + 1 success
    5.times do
      step_execution = workflow.step_executions.order(:created_at).last
      assert_raises(TransientError) do
        GenevaDrive::PerformStepJob.perform_now(step_execution.id)
      end
      workflow.reload
    end

    # 6th attempt succeeds
    sixth_execution = workflow.step_executions.order(:created_at).last
    GenevaDrive::PerformStepJob.perform_now(sixth_execution.id)
    workflow.reload

    # At this point we have 5 reattempts + 1 success
    assert_equal "finished", workflow.state

    # Verify the counts
    reattempted_count = workflow.step_executions.where(outcome: "reattempted").count
    success_count = workflow.step_executions.where(outcome: "success").count

    assert_equal 5, reattempted_count
    assert_equal 1, success_count
  end

  test "enforces limit on precondition exceptions" do
    workflow = PreconditionReattemptWorkflow.create!(hero: @user)

    # First 2 attempts should reattempt
    2.times do
      step_execution = workflow.step_executions.order(:created_at).last
      assert_raises(TransientError) do
        GenevaDrive::PerformStepJob.perform_now(step_execution.id)
      end
      workflow.reload
    end

    assert_equal "ready", workflow.state
    assert_equal 3, workflow.step_executions.count

    # 3rd attempt should trigger limit and pause
    third_step_execution = workflow.step_executions.order(:created_at).last
    assert_raises(TransientError) do
      GenevaDrive::PerformStepJob.perform_now(third_step_execution.id)
    end

    workflow.reload
    third_step_execution.reload

    # Workflow should be paused
    assert_equal "paused", workflow.state
    assert_equal "failed", third_step_execution.state
    assert_equal "failed", third_step_execution.outcome
    assert_match(/Precondition failure/, third_step_execution.error_message)
  end

  test "manual reattempt! flow control is not limited" do
    ManualReattemptWorkflow.reset_tracking!

    workflow = ManualReattemptWorkflow.create!(hero: @user)

    # Execute 5 manual reattempts - should not be limited
    5.times do
      step_execution = workflow.step_executions.order(:created_at).last
      GenevaDrive::PerformStepJob.perform_now(step_execution.id)
      workflow.reload
    end

    # After 5 manual reattempts, workflow should still be ready
    assert_equal "ready", workflow.state
    assert_equal 6, workflow.step_executions.count

    # 6th attempt should succeed
    sixth_execution = workflow.step_executions.order(:created_at).last
    GenevaDrive::PerformStepJob.perform_now(sixth_execution.id)

    workflow.reload

    assert_equal "finished", workflow.state

    ManualReattemptWorkflow.reset_tracking!
  end

  private

  def clean_database!
    GenevaDrive::StepExecution.delete_all
    GenevaDrive::Workflow.delete_all
    User.delete_all
  end
end
