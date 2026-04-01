# frozen_string_literal: true

require "test_helper"

class ComposableExceptionPolicyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  class TransientError < StandardError; end
  class FatalError < StandardError; end
  class UnknownError < StandardError; end

  # Workflow with composable step-level policies: different exceptions get different treatment
  class ComposableStepWorkflow < GenevaDrive::Workflow
    POLICIES = [
      GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: TransientError, wait: 5.seconds, max_reattempts: 10),
      GenevaDrive::ExceptionPolicy.new(:cancel!, matching: FatalError)
    ].freeze

    step :do_work, on_exception: POLICIES do
      raise self.class.error_to_raise if self.class.error_to_raise
    end

    step :final_step do
      # noop
    end

    class << self
      attr_accessor :error_to_raise

      def reset!
        self.error_to_raise = nil
      end
    end
  end

  # Workflow with composable policies that include a blanket fallback
  class ComposableWithFallbackWorkflow < GenevaDrive::Workflow
    POLICIES = [
      GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: TransientError, max_reattempts: 3),
      GenevaDrive::ExceptionPolicy.new(:skip!) # blanket fallback
    ].freeze

    step :do_work, on_exception: POLICIES do
      raise self.class.error_to_raise if self.class.error_to_raise
    end

    step :final_step do
      # noop
    end

    class << self
      attr_accessor :error_to_raise

      def reset!
        self.error_to_raise = nil
      end
    end
  end

  # Workflow with composable step policies and a class-level fallback
  class ComposableWithClassFallbackWorkflow < GenevaDrive::Workflow
    on_exception :pause!

    POLICIES = [
      GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: TransientError, max_reattempts: 3)
    ].freeze

    step :do_work, on_exception: POLICIES do
      raise self.class.error_to_raise if self.class.error_to_raise
    end

    class << self
      attr_accessor :error_to_raise

      def reset!
        self.error_to_raise = nil
      end
    end
  end

  # Workflow for testing global cap: min(max_reattempts) across policies
  class GlobalCapWorkflow < GenevaDrive::Workflow
    POLICIES = [
      GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: TransientError, max_reattempts: 10),
      GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: FatalError, max_reattempts: 3, terminal_action: :cancel!)
    ].freeze

    step :do_work, on_exception: POLICIES do
      raise self.class.error_to_raise if self.class.error_to_raise
    end

    class << self
      attr_accessor :error_to_raise

      def reset!
        self.error_to_raise = nil
      end
    end
  end

  setup do
    clean_database!
    ComposableStepWorkflow.reset!
    ComposableWithFallbackWorkflow.reset!
    ComposableWithClassFallbackWorkflow.reset!
    GlobalCapWorkflow.reset!
    @user = create_user
  end

  teardown do
    clean_database!
  end

  # --- Different exceptions trigger different step-level policies ---

  test "TransientError triggers reattempt policy from composable array" do
    ComposableStepWorkflow.error_to_raise = TransientError.new("transient")
    workflow = ComposableStepWorkflow.create!(hero: @user)

    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "ready", workflow.state
    first_exec = workflow.step_executions.order(:created_at).first
    assert_equal "reattempted", first_exec.outcome
  end

  test "FatalError triggers cancel policy from composable array" do
    ComposableStepWorkflow.error_to_raise = FatalError.new("fatal")
    workflow = ComposableStepWorkflow.create!(hero: @user)

    assert_raises(FatalError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "canceled", workflow.state
  end

  # --- Blanket policy in array acts as fallback ---

  test "blanket policy in array catches unmatched exceptions" do
    ComposableWithFallbackWorkflow.error_to_raise = UnknownError.new("unknown")
    workflow = ComposableWithFallbackWorkflow.create!(hero: @user)

    assert_raises(UnknownError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "ready", workflow.state
    first_exec = workflow.step_executions.order(:created_at).first
    assert_equal "skipped", first_exec.outcome
  end

  # --- No match falls through to class-level ---

  test "unmatched exception in array falls through to class-level policy" do
    ComposableWithClassFallbackWorkflow.error_to_raise = FatalError.new("fatal")
    workflow = ComposableWithClassFallbackWorkflow.create!(hero: @user)

    assert_raises(FatalError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.last)
    end

    workflow.reload
    assert_equal "paused", workflow.state
  end

  # --- Global cap at min(max_reattempts) across policies ---

  test "global cap uses minimum max_reattempts across all policies in array" do
    # GlobalCapWorkflow has policies with max_reattempts: 10 and max_reattempts: 3
    # The global cap should be 3 (the minimum)
    GlobalCapWorkflow.error_to_raise = TransientError.new("transient")
    workflow = GlobalCapWorkflow.create!(hero: @user)

    # Exhaust 3 reattempts (the global cap)
    3.times do
      assert_raises(TransientError) do
        GenevaDrive::Executor.execute!(workflow.step_executions.order(:created_at).last)
      end
      workflow.reload
      assert_equal "ready", workflow.state, "Expected workflow to remain ready after reattempt"
    end

    # 4th attempt should exceed the global cap. The matched policy for TransientError
    # has terminal_action :pause! (default), so the workflow should be paused.
    assert_raises(TransientError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.order(:created_at).last)
    end

    workflow.reload
    assert_equal "paused", workflow.state
  end

  test "terminal_action from the matched policy is used when global cap is hit" do
    # When FatalError hits the global cap, the matched policy's terminal_action (:cancel!) applies
    GlobalCapWorkflow.error_to_raise = FatalError.new("fatal")
    workflow = GlobalCapWorkflow.create!(hero: @user)

    # Exhaust 3 reattempts (the global cap)
    3.times do
      assert_raises(FatalError) do
        GenevaDrive::Executor.execute!(workflow.step_executions.order(:created_at).last)
      end
      workflow.reload
      assert_equal "ready", workflow.state, "Expected workflow to remain ready after reattempt"
    end

    # 4th attempt should exceed global cap. FatalError's policy has terminal_action: :cancel!
    assert_raises(FatalError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.order(:created_at).last)
    end

    workflow.reload
    assert_equal "canceled", workflow.state
  end

  private

  def clean_database!
    GenevaDrive::StepExecution.delete_all
    GenevaDrive::Workflow.delete_all
    User.delete_all
  end
end
