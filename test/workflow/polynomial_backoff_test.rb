# frozen_string_literal: true

require "test_helper"

class PolynomialBackoffTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include GenevaDrive::TestHelpers

  class RetryError < StandardError; end

  class PolicyWorkflow < GenevaDrive::Workflow
    on_exception RetryError, action: :reattempt!, wait: :polynomially_longer,
      max_reattempts: 3, report: :never

    step :first do
      raise RetryError unless hero.name == "recovered"
    end

    step :second do
      raise RetryError
    end
  end

  class StepPolicyWorkflow < GenevaDrive::Workflow
    step :request, on_exception: GenevaDrive::ExceptionPolicy.new(
      :reattempt!, wait: :polynomially_longer, max_reattempts: 3, report: :never
    ) do
      raise RetryError
    end
  end

  class ImperativeWorkflow < GenevaDrive::Workflow
    on_exception RetryError, report: :never do
      reattempt! wait: :polynomially_longer
    end

    step :request do
      raise RetryError
    end
  end

  class ManualWorkflow < GenevaDrive::Workflow
    step :first do
      reattempt! wait: :polynomially_longer unless hero.name == "recovered"
    end

    step :second do
      reattempt! wait: :polynomially_longer
    end
  end

  class PreconditionWorkflow < PolicyWorkflow
    cancel_if { raise RetryError }
  end

  class ResumableWorkflow < GenevaDrive::Workflow
    on_exception RetryError, action: :reattempt!, wait: :polynomially_longer,
      max_reattempts: 3, report: :never

    resumable_step :items do |iter|
      iter.set!((iter.cursor || 0) + 1)
      raise RetryError
    end
  end

  class ResumableManualWorkflow < GenevaDrive::Workflow
    resumable_step :items do |iter|
      iter.set!((iter.cursor || 0) + 1)
      reattempt! wait: :polynomially_longer
    end
  end

  class PreparationWorkflow < PolicyWorkflow
    on_exception NameError, action: :reattempt!, wait: :polynomially_longer,
      max_reattempts: 3, report: :never
  end

  class ResumablePreparationWorkflow < ResumableWorkflow
    on_exception NameError, action: :reattempt!, wait: :polynomially_longer,
      max_reattempts: 3, report: :never
  end

  class InvalidStrategyWorkflow < GenevaDrive::Workflow
    step :request do
      reattempt! wait: :exponentially_longer
    end
  end

  class ReferenceJob < ActiveJob::Base
    retry_on RetryError, wait: :polynomially_longer, attempts: 4

    def perform
      raise RetryError
    end
  end

  setup do
    @user = create_user
  end

  test "policies and imperative handlers back off across persisted attempts" do
    [PolicyWorkflow, StepPolicyWorkflow, ImperativeWorkflow, PreconditionWorkflow].each do |workflow_class|
      workflow = workflow_class.create!(hero: @user)

      travel_to Time.zone.local(2026, 1, 2, 3, 4, 5) do
        (1..3).each do |attempt|
          assert_polynomial_retry(workflow, attempt: attempt, error: RetryError)
          workflow = workflow_class.find(workflow.id)
        end
      end
    end
  end

  test "polynomial policies still pause when the retry limit is exhausted" do
    workflow = PolicyWorkflow.create!(hero: @user)
    4.times { assert_raises(RetryError) { perform_next_step(workflow) } }

    assert_equal "paused", workflow.reload.state
    assert_nil workflow.current_execution
    assert_equal 4, workflow.step_executions.count
  end

  test "unexpected preparation errors advance backoff and exhaust the retry budget" do
    [PreparationWorkflow, ResumablePreparationWorkflow].each do |workflow_class|
      workflow = workflow_class.create!(hero: @user)
      workflow.update_column(:hero_type, "NonExistentClass")
      resumable = workflow_class == ResumablePreparationWorkflow
      workflow.current_execution.update!(cursor: 7) if resumable

      travel_to Time.zone.local(2026, 1, 2, 3, 4, 5) do
        (1..3).each do |attempt|
          predecessor = workflow.current_execution
          successor = assert_polynomial_retry(workflow, attempt: attempt, error: NameError)

          assert_equal "completed", predecessor.reload.state
          assert_equal "reattempted", predecessor.outcome
          assert_equal "exception_policy", predecessor.read_metadata("reattempt_reason")
          assert_equal "NameError", predecessor.error_class_name
          if resumable
            assert_equal predecessor.id, successor.continues_from_id
            assert_equal 7, successor.cursor_value
          end
          workflow = workflow_class.find(workflow.id)
        end

        terminal_execution = workflow.current_execution
        clear_enqueued_jobs
        assert_raises(NameError) { perform_next_step(workflow) }

        assert_equal "paused", workflow.reload.state
        assert_equal "failed", terminal_execution.reload.state
        assert_equal "failed", terminal_execution.outcome
        assert_equal "NameError", terminal_execution.error_class_name
        assert_nil workflow.current_execution
        assert_equal 4, workflow.step_executions.count
        assert_no_enqueued_jobs

        assert_no_difference -> { workflow.step_executions.count } do
          GenevaDrive::PerformStepJob.perform_now(terminal_execution.id)
        end
        assert_equal "paused", workflow.reload.state
        assert_no_enqueued_jobs
      end
    end
  end

  test "manual reattempts increase their delay and different steps start over" do
    [ManualWorkflow, PolicyWorkflow].each do |workflow_class|
      @user.update!(name: "failing")
      workflow = workflow_class.create!(hero: @user)
      error = (workflow_class == PolicyWorkflow) ? RetryError : nil

      travel_to Time.zone.local(2026, 1, 2, 3, 4, 5) do
        assert_polynomial_retry(workflow, attempt: 1, error: error)
        assert_polynomial_retry(workflow, attempt: 2, error: error)
        @user.update!(name: "recovered")
        perform_next_step(workflow)

        assert_equal "second", workflow.reload.next_step_name
        assert_polynomial_retry(workflow, attempt: 1, error: error)
      end
    end
  end

  test "resumable retries preserve cursors and schedule successors with backoff" do
    [ResumableWorkflow, ResumableManualWorkflow].each do |workflow_class|
      workflow = workflow_class.create!(hero: @user)
      error = (workflow_class == ResumableWorkflow) ? RetryError : nil

      travel_to Time.zone.local(2026, 1, 2, 3, 4, 5) do
        (1..3).each do |attempt|
          predecessor = workflow.current_execution
          successor = assert_polynomial_retry(workflow, attempt: attempt, error: error)

          assert_equal predecessor.id, successor.continues_from_id
          assert_equal attempt, successor.cursor_value
        end
      end
    end
  end

  test "retry timing matches Active Job including its configured jitter" do
    original_jitter = ActiveJob::Base.retry_jitter
    original_seed = srand(1234)
    ActiveJob::Base.retry_jitter = 0.3
    workflow = PolicyWorkflow.create!(hero: @user)
    job = ReferenceJob.new

    travel_to Time.zone.local(2026, 1, 2, 3, 4, 5) do
      3.times do
        clear_enqueued_jobs
        srand(1234)
        job.perform_now
        expected = enqueued_jobs.last.fetch(:at)

        srand(1234)
        assert_raises(RetryError) { perform_next_step(workflow) }
        assert_in_delta expected, workflow.reload.current_execution.scheduled_for.to_f, 0.000001
      end
    end
  ensure
    ActiveJob::Base.retry_jitter = original_jitter
    srand(original_seed)
  end

  test "manual reattempts reject unknown retry strategies" do
    workflow = InvalidStrategyWorkflow.create!(hero: @user)
    execution = workflow.current_execution
    clear_enqueued_jobs

    error = assert_raises(ArgumentError) { perform_next_step(workflow) }
    assert_match "Unknown retry wait strategy", error.message
    assert_equal "paused", workflow.reload.state
    assert_equal "failed", execution.reload.state
    assert_equal "ArgumentError", execution.error_class_name
    assert_nil workflow.current_execution
    assert_no_enqueued_jobs

    assert_no_difference -> { workflow.step_executions.count } do
      GenevaDrive::PerformStepJob.perform_now(execution.id)
    end
    assert_equal "paused", workflow.reload.state
    assert_no_enqueued_jobs
  end

  private

  def assert_polynomial_retry(workflow, attempt:, error: nil)
    if error
      assert_raises(error) { perform_next_step(workflow) }
    else
      perform_next_step(workflow)
    end

    execution = workflow.reload.current_execution
    delay = attempt**4
    assert_equal "ready", workflow.state
    assert_operator execution.scheduled_for, :>=, (delay + 2).seconds.from_now
    assert_operator execution.scheduled_for, :<=, (delay * 1.15 + 2).seconds.from_now
    assert_enqueued_with(job: GenevaDrive::PerformStepJob, args: [execution.id], at: execution.scheduled_for)
    execution
  end
end
