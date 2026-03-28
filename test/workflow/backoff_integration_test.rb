# frozen_string_literal: true

require "test_helper"

class BackoffIntegrationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  class TransientError < StandardError; end

  class PolynomialBackoffWorkflow < GenevaDrive::Workflow
    on_exception :reattempt!, wait: :polynomially_longer, max_reattempts: 5, jitter: 0.0

    step :always_fails do
      raise TransientError, "transient"
    end
  end

  class ProcBackoffWorkflow < GenevaDrive::Workflow
    on_exception :reattempt!, wait: ->(attempts) { (attempts * 10).seconds }, max_reattempts: 3

    step :always_fails do
      raise TransientError, "transient"
    end
  end

  class FixedWaitWorkflow < GenevaDrive::Workflow
    on_exception :reattempt!, wait: 30.seconds, max_reattempts: 3

    step :always_fails do
      raise TransientError, "transient"
    end
  end

  setup do
    clean_database!
    @user = User.create!(email: "test@example.com", name: "Test User")
  end

  teardown do
    clean_database!
  end

  test "polynomial backoff increases wait with each reattempt" do
    workflow = PolynomialBackoffWorkflow.create!(hero: @user)

    # First reattempt: wait = 1**4 + 2 = 3 seconds
    step_execution = workflow.step_executions.scheduled.last
    before = Time.current
    assert_raises(TransientError) { GenevaDrive::Executor.execute!(step_execution) }
    workflow.reload

    new_execution = workflow.step_executions.scheduled.last
    wait_applied = new_execution.scheduled_for - before
    assert_in_delta 3.0, wait_applied, 2.0

    # Second reattempt: wait = 2**4 + 2 = 18 seconds
    before = Time.current
    assert_raises(TransientError) { GenevaDrive::Executor.execute!(new_execution) }
    workflow.reload

    new_execution = workflow.step_executions.scheduled.last
    wait_applied = new_execution.scheduled_for - before
    assert_in_delta 18.0, wait_applied, 2.0
  end

  test "proc backoff uses custom formula" do
    workflow = ProcBackoffWorkflow.create!(hero: @user)

    # First reattempt: wait = 1 * 10 = 10 seconds
    step_execution = workflow.step_executions.scheduled.last
    before = Time.current
    assert_raises(TransientError) { GenevaDrive::Executor.execute!(step_execution) }
    workflow.reload

    new_execution = workflow.step_executions.scheduled.last
    wait_applied = new_execution.scheduled_for - before
    assert_in_delta 10.0, wait_applied, 2.0

    # Second reattempt: wait = 2 * 10 = 20 seconds
    before = Time.current
    assert_raises(TransientError) { GenevaDrive::Executor.execute!(new_execution) }
    workflow.reload

    new_execution = workflow.step_executions.scheduled.last
    wait_applied = new_execution.scheduled_for - before
    assert_in_delta 20.0, wait_applied, 2.0
  end

  test "fixed wait stays constant across reattempts" do
    workflow = FixedWaitWorkflow.create!(hero: @user)

    2.times do
      step_execution = workflow.step_executions.scheduled.last
      before = Time.current
      assert_raises(TransientError) { GenevaDrive::Executor.execute!(step_execution) }
      workflow.reload

      new_execution = workflow.step_executions.scheduled.last
      wait_applied = new_execution.scheduled_for - before
      assert_in_delta 30.0, wait_applied, 2.0
    end
  end

  private

  def clean_database!
    GenevaDrive::StepExecution.delete_all
    GenevaDrive::Workflow.delete_all
    User.delete_all
  end
end
