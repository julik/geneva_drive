# frozen_string_literal: true

# Decides whether a given {GenevaDrive::Signal} is the one a step is waiting
# for. A matcher is a plain object, so it can live in a constant and be shared
# between steps and workflows.
#
# Name equality is the whole predicate unless a block is given; the block
# receives the (indifferent-access) payload and is +instance_exec+'d on the
# signal's workflow, so +hero+ and the workflow's own methods are in scope.
#
# @example Name only (what `wait_for: :payment_confirmed` builds for you)
#   GenevaDrive::SignalMatcher.new(:payment_confirmed)
#
# @example Narrowed by payload
#   GenevaDrive::SignalMatcher.new(:document_signed) do |payload|
#     payload[:document_id] == hero.contract_id
#   end
#
# Anything else responding to +#matches?(signal)+ works just as well in
# +wait_for:+ - a custom matcher owns its whole predicate and can, for
# instance, accept either of two signal names.
#
# Matchers run both at the gate (the waiting step's own job) and at dispatch
# (inside +signal!+, in the sender's process). They must be cheap and free of
# side effects, the same expectation +skip_if:+ carries.
class GenevaDrive::SignalMatcher
  # @return [String] the signal name this matcher accepts
  attr_reader :name

  # @return [Proc, nil] the payload predicate, if any
  attr_reader :condition

  # @param name [String, Symbol] signal name for equality matching
  # @yield [payload] optional payload predicate, instance_exec'd on the workflow
  # @raise [ArgumentError] if the name is blank
  def initialize(name, &condition)
    raise ArgumentError, "GenevaDrive::SignalMatcher needs a signal name" if name.blank?

    @name = name.to_s
    @condition = condition
  end

  # Whether the signal is the one being waited for.
  #
  # @param signal [GenevaDrive::Signal] the candidate signal
  # @return [Boolean]
  def matches?(signal)
    return false unless signal.name == @name
    return true unless @condition

    !!signal.workflow.instance_exec(signal.payload, &@condition)
  end

  # Human-readable description, used in log lines and test helper messages.
  #
  # @return [String]
  def to_s
    @condition ? "#{@name} (narrowed by payload)" : @name
  end
end
