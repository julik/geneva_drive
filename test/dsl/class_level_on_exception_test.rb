# frozen_string_literal: true

require "test_helper"

class ClassLevelOnExceptionTest < ActiveSupport::TestCase
  # Registration tests
  test "registers a blanket declarative policy" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      on_exception :reattempt!, max_reattempts: 3
      step(:work) { }
    end

    assert_equal 1, workflow_class._exception_policies.size
    policy = workflow_class._exception_policies.first
    assert_equal :reattempt!, policy.action
    assert_equal 3, policy.max_reattempts
    assert policy.blanket?
  end

  test "registers a specific declarative policy with exception classes" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      on_exception ArgumentError, TypeError, action: :cancel!
      step(:work) { }
    end

    assert_equal 1, workflow_class._exception_policies.size
    policy = workflow_class._exception_policies.first
    assert_equal :cancel!, policy.action
    assert_equal [ArgumentError, TypeError], policy.exception_classes
    assert policy.specific?
  end

  test "registers a policy with action as first positional arg and exception classes" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      on_exception :reattempt!, wait: 15.seconds
      step(:work) { }
    end

    policy = workflow_class._exception_policies.first
    assert_equal :reattempt!, policy.action
    assert_equal 15.seconds, policy.wait
  end

  test "registers an imperative policy with block" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      on_exception(RuntimeError) { |_e| cancel! }
      step(:work) { }
    end

    policy = workflow_class._exception_policies.first
    refute policy.declarative?
    assert_equal [RuntimeError], policy.exception_classes
  end

  test "rejects non-Exception classes" do
    assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        on_exception String, action: :cancel!
      end
    end
  end

  test "rejects both positional action and action: keyword" do
    assert_raises(ArgumentError) do
      Class.new(GenevaDrive::Workflow) do
        on_exception :reattempt!, action: :cancel!
      end
    end
  end

  # Inheritance tests
  test "subclass inherits parent policies" do
    parent = Class.new(GenevaDrive::Workflow) do
      on_exception :reattempt!, max_reattempts: 3
      step(:work) { }
    end

    child = Class.new(parent) do
      on_exception ArgumentError, action: :cancel!
    end

    assert_equal 1, parent._exception_policies.size
    assert_equal 2, child._exception_policies.size
  end

  test "subclass does not mutate parent policies" do
    parent = Class.new(GenevaDrive::Workflow) do
      on_exception :pause!
      step(:work) { }
    end

    Class.new(parent) do
      on_exception :reattempt!, max_reattempts: 5
    end

    assert_equal 1, parent._exception_policies.size
  end

  # Resolution tests
  test "resolves specific policy over blanket" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      on_exception :pause!
      on_exception ArgumentError, action: :cancel!
      step(:work) { }
    end

    policy = workflow_class.resolve_exception_policy(ArgumentError.new("test"))
    assert_equal :cancel!, policy.action

    policy = workflow_class.resolve_exception_policy(RuntimeError.new("test"))
    assert_equal :pause!, policy.action
  end

  test "resolves most recently defined specific policy first" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      on_exception ArgumentError, action: :pause!
      on_exception ArgumentError, action: :cancel!
      step(:work) { }
    end

    policy = workflow_class.resolve_exception_policy(ArgumentError.new("test"))
    assert_equal :cancel!, policy.action
  end

  test "resolves subclass blanket over parent blanket" do
    parent = Class.new(GenevaDrive::Workflow) do
      on_exception :pause!
      step(:work) { }
    end

    child = Class.new(parent) do
      on_exception :reattempt!, max_reattempts: 3
    end

    policy = child.resolve_exception_policy(RuntimeError.new("test"))
    assert_equal :reattempt!, policy.action
    assert_equal 3, policy.max_reattempts
  end

  test "resolves subclass specific policy before parent blanket" do
    parent = Class.new(GenevaDrive::Workflow) do
      on_exception :pause!
      step(:work) { }
    end

    child = Class.new(parent) do
      on_exception ArgumentError, action: :cancel!
    end

    policy = child.resolve_exception_policy(ArgumentError.new("test"))
    assert_equal :cancel!, policy.action
  end

  test "returns nil when no policies match" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      on_exception ArgumentError, action: :cancel!
      step(:work) { }
    end

    policy = workflow_class.resolve_exception_policy(RuntimeError.new("test"))
    assert_nil policy
  end

  test "returns nil when no policies defined" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step(:work) { }
    end

    policy = workflow_class.resolve_exception_policy(RuntimeError.new("test"))
    assert_nil policy
  end
end
