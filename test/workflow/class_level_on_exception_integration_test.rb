# frozen_string_literal: true

require "test_helper"

class ClassLevelOnExceptionIntegrationTest < ActiveSupport::TestCase
  class TransientError < StandardError; end
  class FatalError < StandardError; end

  # Workflow with class-level blanket on_exception
  class BlanketReattemptWorkflow < GenevaDrive::Workflow
    on_exception :reattempt!, max_reattempts: 2

    step :failing_step do
      raise TransientError, "transient failure"
    end
  end

  # Workflow with class-level exception class matching — raises TransientError
  class TransientMatchWorkflow < GenevaDrive::Workflow
    on_exception TransientError, action: :reattempt!, max_reattempts: 2
    on_exception FatalError, action: :cancel!

    step :step_one do
      raise TransientError, "transient"
    end
  end

  # Workflow with class-level exception class matching — raises FatalError
  class FatalMatchWorkflow < GenevaDrive::Workflow
    on_exception TransientError, action: :reattempt!, max_reattempts: 2
    on_exception FatalError, action: :cancel!

    step :step_one do
      raise FatalError, "fatal"
    end
  end

  # Workflow with step-level override taking precedence
  class StepOverrideWorkflow < GenevaDrive::Workflow
    on_exception :reattempt!, max_reattempts: 5

    step :overridden_step, on_exception: :skip! do
      raise TransientError, "should be skipped"
    end

    step :final_step do
      # This should run after skip
    end
  end

  # Workflow with imperative (block) handler — retry case
  class ImperativeRetryWorkflow < GenevaDrive::Workflow
    on_exception TransientError do |_error|
      reattempt! wait: 30.seconds
    end

    step :step_one do
      raise TransientError, "please retry this"
    end
  end

  # Workflow with imperative (block) handler — cancel case
  class ImperativeCancelWorkflow < GenevaDrive::Workflow
    on_exception TransientError do |_error|
      cancel!
    end

    step :step_one do
      raise TransientError, "no retry for you"
    end
  end

  # Workflow with class-level policy and ExceptionPolicy on step
  class PolicyObjectWorkflow < GenevaDrive::Workflow
    TRANSIENT_RETRY = GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: 2)

    on_exception :cancel!

    step :retrying_step, on_exception: TRANSIENT_RETRY do
      raise TransientError, "transient"
    end
  end

  test "class-level blanket policy applies to all steps" do
    user = create_user
    workflow = BlanketReattemptWorkflow.create!(hero: user)

    # First attempt - should reattempt
    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "ready", workflow.state
    assert_equal 2, workflow.step_executions.count

    # Verify metadata records reattempt reason
    first_execution = workflow.step_executions.order(:created_at).first
    assert_equal "reattempted", first_execution.outcome
    assert_equal "exception_policy", first_execution.reattempt_reason
  end

  test "class-level blanket policy respects max_reattempts" do
    user = create_user
    workflow = BlanketReattemptWorkflow.create!(hero: user)

    # Exhaust reattempts (max_reattempts: 2)
    3.times do
      assert_raises(TransientError) do
        GenevaDrive::Executor.execute!(workflow.step_executions.scheduled.last)
      end
      workflow.reload
    end

    # After 2 reattempts + 1 final attempt that exceeds limit → paused
    assert_equal "paused", workflow.state
  end

  test "class-level policy matches specific exception classes for reattempt" do
    user = create_user
    workflow = TransientMatchWorkflow.create!(hero: user)

    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "ready", workflow.state
    assert_equal "reattempted", workflow.step_executions.order(:created_at).first.outcome
  end

  test "class-level policy cancels on fatal error" do
    user = create_user
    workflow = FatalMatchWorkflow.create!(hero: user)

    assert_raises(FatalError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "canceled", workflow.state
  end

  test "step-level on_exception overrides class-level policy" do
    user = create_user
    workflow = StepOverrideWorkflow.create!(hero: user)

    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "ready", workflow.state

    # Step was skipped (step-level :skip! won over class-level :reattempt!)
    first_execution = workflow.step_executions.order(:created_at).first
    assert_equal "skipped", first_execution.outcome

    # Next step was scheduled
    assert_equal "final_step", workflow.next_step_name
  end

  test "imperative handler block can trigger reattempt" do
    user = create_user
    workflow = ImperativeRetryWorkflow.create!(hero: user)

    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "ready", workflow.state
    assert_equal "reattempted", workflow.step_executions.order(:created_at).first.outcome
  end

  test "imperative handler block can cancel" do
    user = create_user
    workflow = ImperativeCancelWorkflow.create!(hero: user)

    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "canceled", workflow.state
  end

  test "step-level ExceptionPolicy object overrides class-level" do
    user = create_user
    workflow = PolicyObjectWorkflow.create!(hero: user)

    # First attempt - should reattempt (step-level policy, not class-level :cancel!)
    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "ready", workflow.state
  end

  # Workflow with imperative handler that does NOT call flow control
  class ImperativeNoFlowControlWorkflow < GenevaDrive::Workflow
    on_exception TransientError do |_error|
      # Oops, forgot to call a flow control method
      logger.info("Handler ran but didn't call flow control")
    end

    step :step_one do
      raise TransientError, "oops"
    end
  end

  # Workflow with step-level Proc as on_exception
  class StepLevelProcWorkflow < GenevaDrive::Workflow
    on_exception :cancel! # class-level should NOT apply

    step :step_one, on_exception: ->(e) { skip! } do
      raise TransientError, "should skip"
    end

    step :step_two do
      # should run after skip
    end
  end

  # Workflow that polls via reattempt! and can be made to fail via class var
  class PollingWorkflow < GenevaDrive::Workflow
    cattr_accessor :attempt_count, default: 0
    cattr_accessor :should_fail, default: false

    on_exception :reattempt!, max_reattempts: 1

    step :polling_step do
      PollingWorkflow.attempt_count += 1

      if PollingWorkflow.should_fail
        raise TransientError, "transient"
      end

      reattempt! wait: 0.seconds
    end
  end

  test "imperative handler that does not call flow control falls through to pause" do
    user = create_user
    workflow = ImperativeNoFlowControlWorkflow.create!(hero: user)

    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "paused", workflow.state
    assert_equal "failed", workflow.step_executions.order(:created_at).first.outcome
  end

  test "step-level Proc overrides class-level policy" do
    user = create_user
    workflow = StepLevelProcWorkflow.create!(hero: user)

    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "ready", workflow.state

    # Step was skipped via Proc (not canceled via class-level)
    first_execution = workflow.step_executions.order(:created_at).first
    assert_equal "skipped", first_execution.outcome
    assert_equal "step_two", workflow.next_step_name
  end

  test "flow_control reattempts do not count toward max_reattempts" do
    PollingWorkflow.attempt_count = 0
    PollingWorkflow.should_fail = false

    user = create_user
    workflow = PollingWorkflow.create!(hero: user)

    # Execute 3 flow-control reattempts (business logic)
    3.times do
      execution = workflow.step_executions.scheduled.last
      GenevaDrive::Executor.execute!(execution)
      workflow.reload
    end

    assert_equal "ready", workflow.state
    assert_equal 3, PollingWorkflow.attempt_count

    # Verify metadata shows flow_control reason
    reattempted = workflow.step_executions.where(outcome: "reattempted").order(:created_at)
    reattempted.each do |exec|
      assert_equal "flow_control", exec.reattempt_reason
    end

    # Now make it fail — should still get 1 exception-policy reattempt
    PollingWorkflow.should_fail = true

    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.scheduled.last)
    end
    workflow.reload
    assert_equal "ready", workflow.state # Got the one reattempt

    # Second exception → should pause (max_reattempts exhausted)
    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.scheduled.last)
    end
    workflow.reload
    assert_equal "paused", workflow.state
  end
end
