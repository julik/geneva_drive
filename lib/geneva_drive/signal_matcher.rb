# frozen_string_literal: true

# Decides whether a given {GenevaDrive::Signal} is the one a step is waiting
# for. Every form of +wait_for:+ normalizes into one of these:
#
# - +wait_for: :payment_confirmed+ - name equality
# - +wait_for: :payment_confirmed, matching: ->(payload) { ... }+ - name
#   equality narrowed by a predicate that is +instance_exec+'d on the
#   workflow, so +hero+ and the workflow's own methods are in scope
# - +wait_for: SomeMatcher.new+ - delegation to any object responding to
#   +#matches?(signal)+, which owns the whole predicate
#
# Matchers run both at the gate (the waiting step's own job) and at dispatch
# (inside +signal!+, in the sender's process). They must be cheap and free of
# side effects, the same expectation +skip_if:+ carries.
#
# @api private
class GenevaDrive::SignalMatcher
  # @return [String, nil] the signal name this matcher accepts
  attr_reader :name

  # @return [Proc, nil] the payload predicate, if any
  attr_reader :condition

  # @return [Object, nil] the delegated matcher object, if any
  attr_reader :matcher

  # @param name [String, Symbol, nil] signal name for equality matching
  # @param condition [Proc, nil] payload predicate, instance_exec'd on the workflow
  # @param matcher [Object, nil] an object responding to #matches?(signal)
  def initialize(name: nil, condition: nil, matcher: nil)
    @name = name&.to_s
    @condition = condition
    @matcher = matcher
  end

  # Whether the signal is the one being waited for.
  #
  # @param signal [GenevaDrive::Signal] the candidate signal
  # @param workflow [GenevaDrive::Workflow, nil] context for the payload predicate
  # @return [Boolean]
  def matches?(signal, workflow = nil)
    return !!@matcher.matches?(signal) if @matcher
    return false unless signal.name == @name
    return true unless @condition

    !!workflow.instance_exec(signal.payload, &@condition)
  end

  # Human-readable description, used in log lines and test helper messages.
  #
  # @return [String]
  def to_s
    return @matcher.class.name if @matcher
    @condition ? "#{@name} (narrowed by matching:)" : @name.to_s
  end
end
