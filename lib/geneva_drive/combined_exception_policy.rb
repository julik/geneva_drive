# frozen_string_literal: true

# Wraps an array of {ExceptionPolicy} objects into a single composable unit.
#
# Created automatically when a step's +on_exception:+ receives an Array of
# {ExceptionPolicy} objects. You never need to instantiate this class directly;
# it is produced by {StepDefinition} during validation. The executor also builds
# a CombinedExceptionPolicy at resolution time by composing step-level,
# class-level, and default policies into one stack.
#
# ## Resolution order
#
# {#apply} walks the constituent policies in order. The first policy whose
# {ExceptionPolicy#captures? captures?} returns +true+ for the error wins.
# Ordering determines precedence: specific policies (those with +matching:+)
# should be listed before blanket policies, like +rescue+ clauses in Ruby.
#
# If no policy captures the error, {#apply} returns +nil+.
#
# ## Reattempt caps
#
# Each constituent policy enforces its own +max_reattempts+ (+nil+ means
# unlimited) and fires its own +terminal_action+ when the budget is exhausted
# — see {ExceptionPolicy#apply}. The combined policy imposes no cap of its
# own: the budget that applies is always the matched policy's, and policies
# that did not match the error never constrain the result. Note that
# +reattempt_count+ counts consecutive reattempts of the step regardless of
# which policy produced them, so when different exception types alternate,
# each policy's cap is still checked against the shared consecutive count —
# a bound on runaway alternating retries.
#
# @example Policies defined on a step
#   step :sync, on_exception: [
#     ExceptionPolicy.new(:reattempt!, matching: Timeout::Error, max_reattempts: 10),
#     ExceptionPolicy.new(:cancel!, matching: FatalApiError),
#     ExceptionPolicy.new(:skip!)  # blanket fallback
#   ] do
#     ExternalApi.sync(hero)
#   end
#   # StepDefinition wraps this array in a CombinedExceptionPolicy automatically.
#   # - Timeout::Error  -> reattempt (up to 10 times)
#   # - FatalApiError   -> cancel
#   # - anything else   -> skip
#
# @see ExceptionPolicy
# @see StepDefinition#exception_policy
# @api private
class GenevaDrive::CombinedExceptionPolicy
  # @return [Array<GenevaDrive::ExceptionPolicy>] the constituent policies
  attr_reader :policies

  # @param policies [Array<GenevaDrive::ExceptionPolicy>] policies to combine
  def initialize(policies)
    @policies = Array(policies)
  end

  # Returns true if any constituent policy captures the given error.
  #
  # @param error [Exception]
  # @return [Boolean]
  def captures?(error)
    @policies.any? { |policy| policy.captures?(error) }
  end

  alias_method :matches?, :captures?

  # Applies the first matching policy to the given error.
  #
  # Walks policies in order, delegating to the first one that captures the
  # error. The matched policy enforces its own +max_reattempts+ and fires its
  # own +terminal_action+ when the budget is exhausted (see
  # {ExceptionPolicy#apply}); the budgets of policies that did not match never
  # constrain the result.
  #
  # @param error [Exception] the exception that was raised
  # @param reattempt_count [Integer] consecutive reattempts so far
  # @param workflow [GenevaDrive::Workflow] the workflow instance
  # @return [Hash, nil] result Hash (see {ExceptionPolicy#apply}), or nil if
  #   no policy captures the error
  #
  # @see ExceptionPolicy#apply
  def apply(error, reattempt_count:, workflow:)
    child = @policies.find { |p| p.captures?(error) }
    return nil unless child

    child.apply(error, reattempt_count: reattempt_count, workflow: workflow)
  end

  # Returns the minimum max_reattempts across all constituent policies
  # (ignoring nil = unlimited), or nil if all policies have unlimited
  # reattempts.
  #
  # Informational only: {#apply} does not enforce this value — each matched
  # policy enforces its own cap. Kept for introspection, and for
  # {StepDefinition#max_reattempts} which reads it for backward compatibility.
  #
  # @return [Integer, nil]
  def max_reattempts
    caps = @policies.filter_map(&:max_reattempts)
    caps.empty? ? nil : caps.min
  end
end
