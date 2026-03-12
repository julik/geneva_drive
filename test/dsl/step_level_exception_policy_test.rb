# frozen_string_literal: true

require "test_helper"

class StepLevelExceptionPolicyTest < ActiveSupport::TestCase
  # Step-level on_exception: accepts ExceptionPolicy
  test "step accepts ExceptionPolicy as on_exception" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: 5)

    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :my_step, on_exception: policy do
      end
    end

    step_def = workflow_class.step_definitions.first
    assert_equal policy, step_def.on_exception
    assert step_def.has_explicit_exception_policy?
    assert_equal policy, step_def.exception_policy
  end

  # Step-level on_exception: accepts Proc
  test "step accepts Proc as on_exception" do
    handler = ->(e) { cancel! }

    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :my_step, on_exception: handler do
      end
    end

    step_def = workflow_class.step_definitions.first
    assert_equal handler, step_def.on_exception
    assert step_def.has_explicit_exception_policy?
  end

  # Symbol still works
  test "step accepts symbol as on_exception" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :my_step, on_exception: :skip! do
      end
    end

    step_def = workflow_class.step_definitions.first
    assert_equal :skip!, step_def.on_exception
    assert step_def.has_explicit_exception_policy?
  end

  # Default is NOT explicit
  test "default on_exception is not explicit" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :my_step do
      end
    end

    step_def = workflow_class.step_definitions.first
    assert_equal :pause!, step_def.on_exception
    refute step_def.has_explicit_exception_policy?
  end

  # exception_policy constructs from symbol
  test "exception_policy constructs ExceptionPolicy from symbol" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :my_step, on_exception: :reattempt!, max_reattempts: 7 do
      end
    end

    step_def = workflow_class.step_definitions.first
    policy = step_def.exception_policy
    assert_instance_of GenevaDrive::ExceptionPolicy, policy
    assert_equal :reattempt!, policy.action
    assert_equal 7, policy.max_reattempts
  end

  # Rejects max_reattempts with ExceptionPolicy
  test "rejects max_reattempts when on_exception is an ExceptionPolicy" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: 5)

    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :my_step, on_exception: policy, max_reattempts: 10 do
        end
      end
    end

    assert_match(/ExceptionPolicy or Proc/, error.message)
  end

  # Rejects max_reattempts with Proc
  test "rejects max_reattempts when on_exception is a Proc" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :my_step, on_exception: ->(e) { cancel! }, max_reattempts: 10 do
        end
      end
    end

    assert_match(/ExceptionPolicy or Proc/, error.message)
  end

  # Rejects invalid types
  test "rejects invalid on_exception types" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :my_step, on_exception: "invalid" do
        end
      end
    end

    assert_match(/Symbol, ExceptionPolicy, or Proc/, error.message)
  end
end
