# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Tests for the double-deferral bug fix in PerformStepJob.
#
# Background: GenevaDrive enqueues PerformStepJob via `after_all_transactions_commit`
# to ensure step execution records are committed before the job runs. However, on
# Rails 7.2+ with queue adapters like SolidQueue, ActiveJob may _additionally_ defer
# the queue INSERT to "after the current transaction commits." When `perform_later` is
# called inside an `after_all_transactions_commit` callback, the transaction is already
# past its commit phase -- the deferred INSERT is silently lost. This results in a
# StepExecution with a job_id but no corresponding job row in the queue backend.
#
# The fix: PerformStepJob sets `enqueue_after_transaction_commit = :never`, which makes
# the queue INSERT synchronous. This is safe because the `after_all_transactions_commit`
# callback guarantees we are outside any application transaction.
class PerformStepJobDoubleDeferralTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class TwoStepWorkflow < GenevaDrive::Workflow
    step :step_one do
      # First step completes, triggering scheduling of step_two
    end

    step :step_two do
      Thread.current[:step_two_executed] = true
    end
  end

  class SimpleWorkflow < GenevaDrive::Workflow
    step :step_one do
      Thread.current[:step_executed] = true
    end
  end

  setup do
    @user = create_user
    Thread.current[:step_executed] = nil
    Thread.current[:step_two_executed] = nil
  end

  teardown do
    Thread.current[:step_executed] = nil
    Thread.current[:step_two_executed] = nil
  end

  # == Configuration tests ==
  # These verify the critical configuration that prevents the double-deferral.

  test "PerformStepJob has enqueue_after_transaction_commit disabled" do
    # This is THE critical fix. Without disabling this, queue adapters like SolidQueue
    # that opt into enqueue_after_transaction_commit will defer the INSERT into
    # a callback that never fires when perform_later is called from inside
    # after_all_transactions_commit. Rails 8.0 deprecated :never in favor of false.
    expected_value = Rails::VERSION::MAJOR >= 8 ? false : :never
    assert_equal expected_value, GenevaDrive::PerformStepJob.enqueue_after_transaction_commit,
      "PerformStepJob.enqueue_after_transaction_commit must be disabled to prevent " \
      "the double-deferral bug. GenevaDrive already handles transaction-awareness " \
      "via after_all_transactions_commit -- the queue adapter must NOT add a second " \
      "layer of deferral on top of that."
  end

  # == Integration tests: outer transaction wrapping ==
  # These tests verify that jobs are correctly enqueued even when workflow creation
  # or step completion happens inside an outer transaction, which is the exact
  # scenario where the double-deferral bug manifests.

  test "job is enqueued when workflow is created inside an outer transaction" do
    # This simulates the production scenario where workflow creation happens
    # inside a service object's transaction, e.g.:
    #   ActiveRecord::Base.transaction do
    #     user.update!(onboarded: true)
    #     OnboardingWorkflow.create!(hero: user)
    #   end
    #
    # The after_all_transactions_commit callback must wait for the OUTER
    # transaction to commit, and then the perform_later must actually
    # write the job row (not defer it into the void).
    clear_enqueued_jobs

    workflow = nil
    ActiveRecord::Base.transaction do
      workflow = SimpleWorkflow.create!(hero: @user)
    end

    # After the outer transaction commits, the job must exist.
    # If the double-deferral bug resurfaces, this assertion will fail because
    # perform_later will have deferred the INSERT into a callback that never fires.
    assert_enqueued_jobs 1, only: GenevaDrive::PerformStepJob

    step_execution = workflow.step_executions.first.reload
    assert_equal "scheduled", step_execution.state
  end

  test "job_id is set on step execution when created inside an outer transaction" do
    # The job_id is written by update_all inside the after_all_transactions_commit
    # callback, after perform_later returns. If perform_later silently defers (the
    # bug), job_id would still be set (ActiveJob generates UUIDs in the constructor)
    # but no actual job row would exist. This test verifies the full flow works.
    workflow = nil
    ActiveRecord::Base.transaction do
      workflow = SimpleWorkflow.create!(hero: @user)
    end

    step_execution = workflow.step_executions.first.reload
    assert_not_nil step_execution.job_id,
      "job_id should be set on step execution after enqueueing"
  end

  test "step completion inside an outer transaction enqueues the next step's job" do
    # This is the exact production scenario from the bug report:
    # 1. PerformStepJob runs step_one inside a transaction (with_lock)
    # 2. Step completes -> handle_completion -> schedule_next_step!
    # 3. create_step_execution creates step_two execution and registers
    #    after_all_transactions_commit callback
    # 4. Transaction commits -> callback fires -> perform_later for step_two
    #
    # The bug: step 4's perform_later gets double-deferred and the INSERT is lost.
    clear_enqueued_jobs

    workflow = TwoStepWorkflow.create!(hero: @user)
    step_one_execution = workflow.step_executions.first

    # Execute step_one, which will complete and schedule step_two.
    # This happens inside with_execution_lock (a transaction).
    # The after_all_transactions_commit callback fires after that transaction.
    clear_enqueued_jobs
    step_one_execution.execute!

    workflow.reload
    assert_equal "ready", workflow.state
    assert_equal "step_two", workflow.next_step_name

    # step_two should have a scheduled execution with a job enqueued
    step_two_execution = workflow.step_executions.where(step_name: "step_two").first
    assert_not_nil step_two_execution, "step_two execution should be created"
    assert_equal "scheduled", step_two_execution.state

    # If the double-deferral bug resurfaces, this will fail because the
    # after_all_transactions_commit callback's perform_later gets deferred
    # into a second callback that never fires.
    assert_enqueued_jobs 1, only: GenevaDrive::PerformStepJob
  end

  test "full workflow execution inside an outer transaction succeeds end-to-end" do
    # End-to-end test: create workflow inside a transaction, then execute all
    # steps. Each step completion triggers scheduling of the next step via
    # after_all_transactions_commit, and each perform_later must synchronously
    # write the job row (not defer it).
    workflow = nil
    ActiveRecord::Base.transaction do
      workflow = TwoStepWorkflow.create!(hero: @user)
    end

    # Execute step_one
    step_one = workflow.step_executions.where(step_name: "step_one").first
    step_one.execute!
    workflow.reload

    assert_equal "step_two", workflow.next_step_name

    # Execute step_two
    step_two = workflow.step_executions.where(step_name: "step_two").first
    assert_not_nil step_two, "step_two execution should exist after step_one completes"
    step_two.execute!
    workflow.reload

    assert_equal "finished", workflow.state
    assert Thread.current[:step_two_executed], "step_two should have executed"
  end

  # == Poll-retry tests ==
  # These verify the defense-in-depth retry logic in find_step_execution.

  test "perform retries lookup when step execution is not immediately visible" do
    # Simulate a step execution that isn't visible on the first few lookups
    # (e.g., due to replication lag on a read replica).
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    lookup_count = 0
    original_find_by = GenevaDrive::StepExecution.method(:find_by)

    # Stub find_by to return nil for the first 2 calls, then the real record.
    # This simulates replication lag where the record isn't visible immediately.
    stubbed_find_by = ->(*args, **kwargs) {
      lookup_count += 1
      if lookup_count <= 2
        nil
      else
        original_find_by.call(*args, **kwargs)
      end
    }

    GenevaDrive::StepExecution.stub(:find_by, stubbed_find_by) do
      GenevaDrive::PerformStepJob.perform_now(step_execution.id)
    end

    assert_equal 3, lookup_count,
      "Should have retried lookup 3 times (2 nil + 1 success)"
    assert Thread.current[:step_executed],
      "Step should have executed after successful retry"
  end

  test "perform gives up after max attempts when step execution never appears" do
    # If the step execution truly doesn't exist (e.g., deleted by cleanup),
    # the poll-retry should give up after 5 attempts and log a warning.
    lookup_count = 0

    GenevaDrive::StepExecution.stub(:find_by, ->(*args, **kwargs) {
      lookup_count += 1
      nil
    }) do
      # Override sleep on the job instance to avoid 500ms of real sleeping in tests
      job = GenevaDrive::PerformStepJob.new
      job.stub(:sleep, ->(_delay) {}) do
        job.perform(999_999_999)
      end
    end

    assert_equal 5, lookup_count,
      "Should have attempted lookup 5 times before giving up"
    assert_nil Thread.current[:step_executed],
      "Step should NOT have executed when record is never found"
  end

  test "perform does not retry when step execution is found on first attempt" do
    # Normal happy path: no retry needed. The step execution is visible immediately.
    # This is the overwhelmingly common case.
    workflow = SimpleWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    lookup_count = 0
    original_find_by = GenevaDrive::StepExecution.method(:find_by)

    GenevaDrive::StepExecution.stub(:find_by, ->(*args, **kwargs) {
      lookup_count += 1
      original_find_by.call(*args, **kwargs)
    }) do
      GenevaDrive::PerformStepJob.perform_now(step_execution.id)
    end

    assert_equal 1, lookup_count,
      "Should have found the step execution on the first attempt without retrying"
    assert Thread.current[:step_executed]
  end

  # == Resume inside outer transaction ==

  test "resume! enqueues job when called inside an outer transaction" do
    # resume! also uses after_all_transactions_commit to enqueue the job.
    # Verify the same double-deferral protection works for this path.
    clear_enqueued_jobs

    workflow = SimpleWorkflow.create!(hero: @user)
    workflow.transition_to!("paused")

    clear_enqueued_jobs

    ActiveRecord::Base.transaction do
      workflow.resume!
    end

    assert_enqueued_jobs 1, only: GenevaDrive::PerformStepJob
  end
end
