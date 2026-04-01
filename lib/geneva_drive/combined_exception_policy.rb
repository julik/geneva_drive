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
# ## Global reattempt cap
#
# {#max_reattempts} returns the *minimum* +max_reattempts+ value across all
# constituent policies (ignoring +nil+, which means unlimited). When {#apply}
# delegates to a child that wants to reattempt, it checks this global cap
# first. If the cap is exceeded, the matched policy's +terminal_action+ is
# applied instead. This prevents runaway retries when different exception
# types alternate.
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
#   # - global cap      -> 10 (the only finite max_reattempts in the array)
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
  # error. Before delegating a reattempt, checks the global cap
  # ({#max_reattempts}) and overrides with the matched policy's
  # +terminal_action+ if exceeded.
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

    result = child.apply(error, reattempt_count: reattempt_count, workflow: workflow)

    # Enforce global reattempt cap (min max_reattempts across all children).
    # If the matched policy wants to reattempt but the global cap is exceeded,
    # override with the matched policy's terminal_action.
    cap = max_reattempts
    if cap && result[:action] == :reattempt && reattempt_count >= cap
      terminal = child.terminal_action.to_s.chomp("!").to_sym
      return {action: terminal, error: error}
    end

    result
  end

  # Returns the effective global reattempt cap: the minimum max_reattempts
  # across all constituent policies (ignoring nil = unlimited).
  # Returns nil if all policies have unlimited reattempts.
  #
  # @return [Integer, nil]
  def max_reattempts
    caps = @policies.filter_map(&:max_reattempts)
    caps.empty? ? nil : caps.min
  end
end
