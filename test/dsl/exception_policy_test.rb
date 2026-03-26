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

  # matching: kwarg tests
  test "matching: with a single class populates exception_matchers" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError)

    assert policy.specific?
    assert policy.matches?(ArgumentError.new)
    refute policy.matches?(RuntimeError.new)
  end

  test "matching: with an array of classes populates exception_matchers" do
    policy = GenevaDrive::ExceptionPolicy.new(:cancel!, matching: [ArgumentError, TypeError])

    assert policy.specific?
    assert policy.matches?(ArgumentError.new)
    assert policy.matches?(TypeError.new)
    refute policy.matches?(RuntimeError.new)
  end

  test "matching: with a string creates a LazyExceptionMatcher" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: "ArgumentError")

    assert policy.specific?
    assert policy.matches?(ArgumentError.new)
    refute policy.matches?(RuntimeError.new)
    assert_instance_of GenevaDrive::ExceptionPolicy::LazyExceptionMatcher, policy.exception_matchers.first
  end

  test "matching: with mixed classes and strings" do
    policy = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: [ArgumentError, "TypeError"])

    assert policy.matches?(ArgumentError.new)
    assert policy.matches?(TypeError.new)
    refute policy.matches?(RuntimeError.new)
  end

  test "matching: rejects non-Exception classes" do
    assert_raises(ArgumentError) do
      GenevaDrive::ExceptionPolicy.new(:cancel!, matching: String)
    end
  end

  test "matching: works with block (imperative mode)" do
    policy = GenevaDrive::ExceptionPolicy.new(matching: ArgumentError) { |_e| pause! }

    assert policy.specific?
    assert policy.captures?(ArgumentError.new)
    refute policy.captures?(RuntimeError.new)
    assert_instance_of Proc, policy.handler
  end

  test "matching: nil leaves exception_matchers empty" do
    policy = GenevaDrive::ExceptionPolicy.new(:pause!, matching: nil)
    assert policy.blanket?
  end
end

class CombinedExceptionPolicyTest < ActiveSupport::TestCase
  setup do
    @mock_workflow = Minitest::Mock.new
  end

  test "captures? returns true when any constituent policy matches" do
    specific = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError)
    blanket = GenevaDrive::ExceptionPolicy.new(:pause!)
    combined = GenevaDrive::CombinedExceptionPolicy.new([specific, blanket])

    assert combined.captures?(ArgumentError.new)
    assert combined.captures?(RuntimeError.new)
  end

  test "captures? returns false when no policy matches" do
    specific = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError)
    combined = GenevaDrive::CombinedExceptionPolicy.new([specific])

    refute combined.captures?(RuntimeError.new)
  end

  test "apply delegates to specific match over blanket" do
    specific = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError, max_reattempts: 5)
    blanket = GenevaDrive::ExceptionPolicy.new(:pause!)
    combined = GenevaDrive::CombinedExceptionPolicy.new([specific, blanket])

    result = combined.apply(ArgumentError.new, reattempt_count: 0, workflow: @mock_workflow)
    assert_equal :reattempt, result[:action]
  end

  test "apply falls back to blanket when no specific match" do
    specific = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError, max_reattempts: 5)
    blanket = GenevaDrive::ExceptionPolicy.new(:pause!)
    combined = GenevaDrive::CombinedExceptionPolicy.new([specific, blanket])

    result = combined.apply(RuntimeError.new, reattempt_count: 0, workflow: @mock_workflow)
    assert_equal :pause, result[:action]
  end

  test "apply returns nil when no policy matches" do
    specific = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError, max_reattempts: 5)
    combined = GenevaDrive::CombinedExceptionPolicy.new([specific])

    assert_nil combined.apply(RuntimeError.new, reattempt_count: 0, workflow: @mock_workflow)
  end

  test "apply prefers first matching policy" do
    first = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: StandardError, max_reattempts: 5)
    second = GenevaDrive::ExceptionPolicy.new(:cancel!, matching: ArgumentError)
    combined = GenevaDrive::CombinedExceptionPolicy.new([first, second])

    result = combined.apply(ArgumentError.new, reattempt_count: 0, workflow: @mock_workflow)
    assert_equal :reattempt, result[:action]
  end

  test "apply enforces global reattempt cap across policies" do
    p1 = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError, max_reattempts: 10)
    p2 = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: TypeError, max_reattempts: 3)
    combined = GenevaDrive::CombinedExceptionPolicy.new([p1, p2])

    result = combined.apply(ArgumentError.new, reattempt_count: 3, workflow: @mock_workflow)
    assert_equal :pause, result[:action]
  end

  test "apply uses terminal_action when global cap exceeded" do
    p1 = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError, max_reattempts: 10, terminal_action: :cancel!)
    p2 = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: TypeError, max_reattempts: 3)
    combined = GenevaDrive::CombinedExceptionPolicy.new([p1, p2])

    result = combined.apply(ArgumentError.new, reattempt_count: 3, workflow: @mock_workflow)
    assert_equal :cancel, result[:action]
  end

  test "max_reattempts returns minimum across policies" do
    p1 = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError, max_reattempts: 10)
    p2 = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: TypeError, max_reattempts: 3)
    combined = GenevaDrive::CombinedExceptionPolicy.new([p1, p2])

    assert_equal 3, combined.max_reattempts
  end

  test "max_reattempts ignores nil (unlimited) policies" do
    p1 = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError, max_reattempts: 10)
    p2 = GenevaDrive::ExceptionPolicy.new(:cancel!, matching: TypeError)
    combined = GenevaDrive::CombinedExceptionPolicy.new([p1, p2])

    assert_equal 10, combined.max_reattempts
  end

  test "max_reattempts returns nil when all policies have unlimited reattempts" do
    p1 = GenevaDrive::ExceptionPolicy.new(:cancel!, matching: ArgumentError)
    p2 = GenevaDrive::ExceptionPolicy.new(:pause!)
    combined = GenevaDrive::CombinedExceptionPolicy.new([p1, p2])

    assert_nil combined.max_reattempts
  end

  test "policies returns the flat array of constituent policies" do
    p1 = GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: ArgumentError, max_reattempts: 5)
    p2 = GenevaDrive::ExceptionPolicy.new(:cancel!)
    combined = GenevaDrive::CombinedExceptionPolicy.new([p1, p2])

    assert_equal [p1, p2], combined.policies
  end
end
