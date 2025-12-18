# frozen_string_literal: true

require "test_helper"

class PerformStepJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class SimpleWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_executed] = true
    end
  end

  setup do
    @user = create_user
    Thread.current[:step_executed] = nil
  end

  teardown do
    Thread.current[:step_executed] = nil
  end

  test "performs step execution with valid ID" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::PerformStepJob.perform_now(step_execution.id)

    assert Thread.current[:step_executed]
    step_execution.reload
    assert_equal "completed", step_execution.state
  end

  test "does not raise with non-existent step_execution_id" do
    assert_nothing_raised do
      GenevaDrive::PerformStepJob.perform_now(999_999_999)
    end
  end

  test "does not raise with nil step_execution_id" do
    assert_nothing_raised do
      GenevaDrive::PerformStepJob.perform_now(nil)
    end
  end

  test "does not execute step when step_execution is deleted" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first
    step_execution_id = step_execution.id

    # Delete the step execution
    step_execution.destroy!

    assert_nothing_raised do
      GenevaDrive::PerformStepJob.perform_now(step_execution_id)
    end

    assert_nil Thread.current[:step_executed]
  end

  test "does not execute step when step_execution is already completed" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Mark as completed before job runs
    step_execution.update!(state: "completed", completed_at: Time.current, outcome: "success")

    # Reset tracking
    Thread.current[:step_executed] = nil

    GenevaDrive::PerformStepJob.perform_now(step_execution.id)

    # Step should not have executed again
    assert_nil Thread.current[:step_executed]
  end

  test "handles concurrent job execution gracefully" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # First job executes
    GenevaDrive::PerformStepJob.perform_now(step_execution.id)
    assert Thread.current[:step_executed]

    # Reset tracking
    Thread.current[:step_executed] = nil

    # Second job (simulating concurrent execution) should not execute
    GenevaDrive::PerformStepJob.perform_now(step_execution.id)
    assert_nil Thread.current[:step_executed]
  end

  test "job is enqueued with correct arguments" do
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    assert_enqueued_with(
      job: GenevaDrive::PerformStepJob,
      args: [step_execution.id]
    )
  end

  test "job passes job options from workflow" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      set_step_job_options queue: :high_priority

      step :test_step do
        # Step body
      end
    end

    # Give the class a name for STI
    Object.const_set(:TestJobOptionsWorkflow, workflow_class)

    begin
      clear_enqueued_jobs

      TestJobOptionsWorkflow.create!(hero: @user)

      assert_enqueued_with(
        job: GenevaDrive::PerformStepJob,
        queue: "high_priority"
      )
    ensure
      Object.send(:remove_const, :TestJobOptionsWorkflow)
    end
  end
end
