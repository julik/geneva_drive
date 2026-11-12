# frozen_string_literal: true

require "test_helper"

class BackoffIntegrationTest < ActiveSupport::TestCase
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

  class StepPolicyBackoffWorkflow < GenevaDrive::Workflow
    step :always_fails, on_exception: GenevaDrive::ExceptionPolicy.new(:reattempt!, wait: :polynomially_longer, max_reattempts: 5, jitter: 0.0) do
      raise TransientError, "transient"
    end
  end

  test "polynomial backoff increases wait with each reattempt" do
    workflow = PolynomialBackoffWorkflow.create!(hero: create_user)

    # First reattempt: wait = 1**4 + 2 = 3 seconds
    assert_reattempt_wait(workflow, 3.0)

    # Second reattempt: wait = 2**4 + 2 = 18 seconds
    assert_reattempt_wait(workflow, 18.0)
  end

  test "proc backoff uses custom formula" do
    workflow = ProcBackoffWorkflow.create!(hero: create_user)

    # First reattempt: wait = 1 * 10 = 10 seconds
    assert_reattempt_wait(workflow, 10.0)

    # Second reattempt: wait = 2 * 10 = 20 seconds
    assert_reattempt_wait(workflow, 20.0)
  end

  test "fixed wait stays constant across reattempts" do
    workflow = FixedWaitWorkflow.create!(hero: create_user)

    2.times do
      assert_reattempt_wait(workflow, 30.0)
    end
  end

  test "backoff applies to step-level policy objects" do
    workflow = StepPolicyBackoffWorkflow.create!(hero: create_user)

    assert_reattempt_wait(workflow, 3.0)
    assert_reattempt_wait(workflow, 18.0)
  end

  private

  # Executes the currently scheduled step (which raises), then asserts the
  # replacement execution is scheduled `expected_wait` seconds out.
  def assert_reattempt_wait(workflow, expected_wait)
    step_execution = workflow.step_executions.scheduled.last
    before = Time.current
    assert_raises(TransientError) { GenevaDrive::Executor.execute!(step_execution) }
    workflow.reload

    assert_equal "ready", workflow.state
    new_execution = workflow.step_executions.scheduled.last
    refute_equal step_execution.id, new_execution.id
    wait_applied = new_execution.scheduled_for - before
    assert_in_delta expected_wait, wait_applied, 2.0
  end
end
