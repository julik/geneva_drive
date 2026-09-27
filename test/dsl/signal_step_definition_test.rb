# frozen_string_literal: true

require "test_helper"

# wait: and wait_for: read alike and take disjoint types, so the step
# definition enforces the disjointness in both directions at class load.
class SignalStepDefinitionTest < ActiveSupport::TestCase
  class NameSetMatcher
    def initialize(*names)
      @names = names.map(&:to_s)
    end

    def matches?(signal)
      @names.include?(signal.name)
    end
  end

  def build_step(**options)
    GenevaDrive::StepDefinition.new(name: "capture", callable: proc {}, **options)
  end

  test "wait_for: with a symbol builds a name matcher" do
    step_def = build_step(wait_for: :payment_confirmed)

    assert step_def.waits_for_signal?
    assert_equal "payment_confirmed", step_def.signal_matcher.name
    assert_nil step_def.signal_matcher.condition
  end

  test "wait_for: with a string builds a name matcher" do
    step_def = build_step(wait_for: "payment_confirmed")

    assert step_def.waits_for_signal?
    assert_equal "payment_confirmed", step_def.signal_matcher.name
  end

  test "wait_for: with matching: keeps the payload predicate" do
    predicate = ->(payload) { payload[:order_id] == 1 }
    step_def = build_step(wait_for: :payment_confirmed, matching: predicate)

    assert_equal predicate, step_def.signal_matcher.condition
  end

  test "wait_for: with a matcher object delegates the whole predicate" do
    matcher = NameSetMatcher.new(:a, :b)
    step_def = build_step(wait_for: matcher)

    assert step_def.waits_for_signal?
    assert_equal matcher, step_def.signal_matcher.matcher
    assert_nil step_def.signal_matcher.name
  end

  test "steps without wait_for: do not wait for a signal" do
    assert_not build_step.waits_for_signal?
    assert_nil build_step.signal_matcher
  end

  test "wait_for: with a duration points at wait:" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(wait_for: 2.days) }

    assert_match(/wait_for: 2 days/, error.message)
    assert_match(/to delay the step, use wait:/, error.message)
  end

  test "wait_for: with a number points at wait:" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(wait_for: 30) }

    assert_match(/to delay the step, use wait:/, error.message)
  end

  test "wait_for: with a time points at wait:" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(wait_for: Time.current) }

    assert_match(/to delay the step, use wait:/, error.message)
  end

  test "wait: with a symbol points at wait_for:" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(wait: :payment_confirmed) }

    assert_match(/wait: :payment_confirmed/, error.message)
    assert_match(/to wait for a signal, use wait_for:/, error.message)
  end

  test "wait: with a string points at wait_for: instead of silently meaning zero seconds" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(wait: "payment_confirmed") }

    assert_match(/to wait for a signal, use wait_for:/, error.message)
  end

  test "wait: with a duration-shaped string is rejected too" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(wait: "7200") }

    assert_match(/to wait for a signal, use wait_for:/, error.message)
  end

  test "wait: with a matcher object points at wait_for:" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(wait: NameSetMatcher.new(:a)) }

    assert_match(/to wait for a signal, use wait_for:/, error.message)
  end

  test "wait: still accepts durations and numbers" do
    assert_equal 2.days, build_step(wait: 2.days).wait
    assert_equal 30, build_step(wait: 30).wait
  end

  test "matching: without wait_for: is rejected" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(matching: ->(payload) { true }) }

    assert_match(/matching: without wait_for:/, error.message)
  end

  test "matching: alongside a matcher object is rejected" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      build_step(wait_for: NameSetMatcher.new(:a), matching: ->(payload) { true })
    end

    assert_match(/owns its whole predicate/, error.message)
  end

  test "matching: must be a proc" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      build_step(wait_for: :payment_confirmed, matching: :some_method)
    end

    assert_match(/invalid matching:/, error.message)
  end

  test "wait_for: with an unusable value is rejected" do
    error = assert_raises(GenevaDrive::StepConfigurationError) { build_step(wait_for: Object.new) }

    assert_match(/must be a Symbol, String, or an object responding to #matches\?/, error.message)
  end

  test "wait: and wait_for: compose" do
    step_def = build_step(wait: 2.days, wait_for: :payment_confirmed)

    assert_equal 2.days, step_def.wait
    assert step_def.waits_for_signal?
  end

  test "resumable steps accept wait_for:" do
    step_def = GenevaDrive::ResumableStepDefinition.new(name: "iterate", wait_for: :go) { |iter| }

    assert step_def.resumable?
    assert step_def.waits_for_signal?
  end
end
