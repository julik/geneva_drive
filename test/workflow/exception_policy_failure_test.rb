# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class ExceptionPolicyFailureTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include GenevaDrive::TestHelpers

  class InvalidStrategyWorkflow < GenevaDrive::Workflow
    on_exception StandardError, report: :never do
      reattempt!(wait: :exponentially_longer)
    end

    step :request do
      raise "request failed"
    end
  end

  class PreconditionWorkflow < InvalidStrategyWorkflow
    cancel_if { raise "precondition failed" }
  end

  class RaisingHandlerWorkflow < InvalidStrategyWorkflow
    on_exception StandardError, report: :never do
      raise "handler failed"
    end
  end

  class PolynomialWorkflow < InvalidStrategyWorkflow
    on_exception StandardError, action: :reattempt!, wait: :polynomially_longer, report: :never
  end

  test "invalid strategies in handlers fail safely during execution and preconditions" do
    user = create_user
    [InvalidStrategyWorkflow, PreconditionWorkflow].each do |workflow_class|
      workflow = workflow_class.create!(hero: user)

      assert_policy_failure(workflow, ArgumentError, "Unknown retry wait strategy: :exponentially_longer")
    end
  end

  test "invalid strategies in preparation handlers fail safely" do
    workflow = InvalidStrategyWorkflow.create!(hero: create_user)
    workflow.update_column(:hero_type, "NonExistentClass")

    assert_policy_failure(workflow, ArgumentError, "Unknown retry wait strategy: :exponentially_longer")
  end

  test "handler errors pause without invoking the failing handler again" do
    workflow = RaisingHandlerWorkflow.create!(hero: create_user)

    assert_policy_failure(workflow, RuntimeError, "handler failed")
  end

  test "delay resolution errors fail safely" do
    workflow = PolynomialWorkflow.create!(hero: create_user)

    GenevaDrive::RetryWait.stub(:resolve, ->(*) { raise "delay resolution failed" }) do
      assert_policy_failure(workflow, RuntimeError, "delay resolution failed")
    end
  end

  private

  def assert_policy_failure(workflow, error_class, message)
    execution = workflow.current_execution
    clear_enqueued_jobs
    reports = []

    error = Rails.error.stub(:report, ->(reported) { reports << reported }) do
      assert_raises(error_class) { perform_next_step(workflow) }
    end

    assert_equal message, error.message
    assert_equal "paused", workflow.reload.state
    assert_nil workflow.current_step_name
    assert_equal "failed", execution.reload.state
    assert_equal "failed", execution.outcome
    assert_equal error_class.name, execution.error_class_name
    assert_equal message, execution.error_message
    assert_equal message, execution.exception_info.fetch("message")
    assert_equal [error], reports
    assert_nil workflow.current_execution
    assert_equal 1, workflow.step_executions.count
    assert_no_enqueued_jobs

    assert_no_difference -> { workflow.step_executions.count } do
      GenevaDrive::PerformStepJob.perform_now(execution.id)
    end
    assert_equal "paused", workflow.reload.state
    assert_no_enqueued_jobs
  end
end
