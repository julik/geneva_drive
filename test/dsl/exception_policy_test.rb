# frozen_string_literal: true

require "test_helper"

class ExceptionPolicyTest < ActiveSupport::TestCase
  # Declarative mode tests
  test "creates a declarative policy with action" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!)

    assert policy.declarative?
    assert_equal :reattempt!, policy.action
    assert_nil policy.wait
    assert_nil policy.max_reattempts
    assert_nil policy.handler
    assert_empty policy.exception_matchers
  end

  test "creates a declarative policy with all options" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, wait: 15.seconds, max_reattempts: 5)

    assert_equal :reattempt!, policy.action
    assert_equal 15.seconds, policy.wait
    assert_equal 5, policy.max_reattempts
  end

  test "validates action is a valid symbol" do
    assert_raises(ArgumentError) { GenevaDrive::ExceptionPolicy.new(:invalid!) }
  end

  test "validates wait only with reattempt!" do
    assert_raises(ArgumentError) { GenevaDrive::ExceptionPolicy.new(:cancel!, wait: 5.seconds) }
  end

  test "validates max_reattempts only with reattempt!" do
    assert_raises(ArgumentError) { GenevaDrive::ExceptionPolicy.new(:pause!, max_reattempts: 3) }
  end

  test "validates max_reattempts is a positive integer" do
    assert_raises(ArgumentError) { GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: 0) }
    assert_raises(ArgumentError) { GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: -1) }
    assert_raises(ArgumentError) { GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: 1.5) }
  end

  test "allows nil max_reattempts" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: nil)
    assert_nil policy.max_reattempts
  end

  test "requires action or block" do
    assert_raises(ArgumentError) { GenevaDrive::ExceptionPolicy.new }
  end

  # Imperative mode tests
  test "creates an imperative policy with block" do
    policy = GenevaDrive::ExceptionPolicy.new { |_e| pause! }

    refute policy.declarative?
    assert_nil policy.action
    assert_nil policy.wait
    assert_nil policy.max_reattempts
    assert_instance_of Proc, policy.handler
  end

  test "rejects action with block" do
    assert_raises(ArgumentError) do
      GenevaDrive::ExceptionPolicy.new(:reattempt!) { |_e| reattempt! }
    end
  end

  test "rejects wait with block" do
    assert_raises(ArgumentError) do
      GenevaDrive::ExceptionPolicy.new(wait: 5.seconds) { |_e| reattempt! }
    end
  end

  test "rejects max_reattempts with block" do
    assert_raises(ArgumentError) do
      GenevaDrive::ExceptionPolicy.new(max_reattempts: 3) { |_e| reattempt! }
    end
  end

  # Matching tests
  test "blanket policy matches any error" do
    policy = GenevaDrive::ExceptionPolicy.new(:pause!)

    assert policy.matches?(RuntimeError.new)
    assert policy.matches?(StandardError.new)
    assert policy.blanket?
    refute policy.specific?
  end

  test "specific policy matches only listed exception classes" do
    policy = GenevaDrive::ExceptionPolicy.new(:cancel!)
    policy.exception_matchers.concat([ArgumentError, TypeError])

    assert policy.matches?(ArgumentError.new)
    assert policy.matches?(TypeError.new)
    refute policy.matches?(RuntimeError.new)
    assert policy.specific?
    refute policy.blanket?
  end

  test "specific policy matches subclasses" do
    policy = GenevaDrive::ExceptionPolicy.new(:cancel!)
    policy.exception_matchers << StandardError

    assert policy.matches?(RuntimeError.new)
    assert policy.matches?(ArgumentError.new)
  end

  # All valid actions
  test "accepts all valid actions" do
    %i[pause! cancel! reattempt! skip!].each do |action|
      policy = GenevaDrive::ExceptionPolicy.new(action)
      assert_equal action, policy.action
    end
  end

  # terminal_action tests
  test "terminal_action defaults to :pause!" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: 5)
    assert_equal :pause!, policy.terminal_action
  end

  test "terminal_action: :cancel! sets terminal_action" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, max_reattempts: 5, terminal_action: :cancel!)
    assert_equal :cancel!, policy.terminal_action
  end

  test "terminal_action: rejects invalid values" do
    assert_raises(ArgumentError) do
      GenevaDrive::ExceptionPolicy.new(:reattempt!, terminal_action: :skip!)
    end
  end

  test "terminal_action: only makes sense with :reattempt!" do
    assert_raises(ArgumentError) do
      GenevaDrive::ExceptionPolicy.new(:pause!, terminal_action: :cancel!)
    end
  end

  test "terminal_action: rejected with block" do
    assert_raises(ArgumentError) do
      GenevaDrive::ExceptionPolicy.new(terminal_action: :cancel!) { |_e| reattempt! }
    end
  end

  # LazyExceptionMatcher tests
  test "LazyExceptionMatcher matches by class name at runtime" do
    matcher = GenevaDrive::ExceptionPolicy::LazyExceptionMatcher.new("ArgumentError")
    assert matcher === ArgumentError.new("test")
    refute matcher === RuntimeError.new("test")
  end

  test "LazyExceptionMatcher matches subclasses" do
    matcher = GenevaDrive::ExceptionPolicy::LazyExceptionMatcher.new("StandardError")
    assert matcher === ArgumentError.new("test")
    assert matcher === RuntimeError.new("test")
  end

  test "LazyExceptionMatcher returns false for unresolvable class names" do
    matcher = GenevaDrive::ExceptionPolicy::LazyExceptionMatcher.new("Nonexistent::FakeError")
    refute matcher === RuntimeError.new("test")
  end
end
