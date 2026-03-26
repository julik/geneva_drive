# frozen_string_literal: true

# Wraps an array of {ExceptionPolicy} objects into a single composable unit.
#
# Created automatically when a step's +on_exception:+ receives an Array of
# {ExceptionPolicy} objects. You never need to instantiate this class directly;
# it is produced by {StepDefinition} during validation.
#
# ## Resolution order
#
# When an exception is raised, {#resolve} walks the constituent policies:
#
# 1. **Specific policies** (those with +matching:+) are checked first, in
#    definition order. The first policy whose exception matchers match the
#    error wins.
# 2. **Blanket policy** (the first policy without +matching:+) is used as a
#    fallback if no specific policy matches.
# 3. If neither matches, {#resolve} returns +nil+ and the executor falls
#    through to class-level exception resolution.
#
# ## Global reattempt cap
#
# {#max_reattempts} returns the *minimum* +max_reattempts+ value across all
# constituent policies (ignoring +nil+, which means unlimited). This prevents
# runaway retries when different exception types alternate — the total
# consecutive reattempt count is capped at the tightest limit in the array.
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

  # @param policies [Array<GenevaDrive::ExceptionPolicy>] policies to combine (will be flattened)
  def initialize(policies)
    @policies = Array(policies).flatten
  end

  # Resolves which policy matches the given error.
  # Walks policies looking for a specific match first, then falls back to
  # the first blanket policy. Returns nil if nothing matches (so the caller
  # can fall through to class-level resolution).
  #
  # @param error [Exception]
  # @return [GenevaDrive::ExceptionPolicy, nil]
  def resolve(error)
    blanket_policy = nil
    @policies.each do |policy|
      if policy.specific?
        return policy if policy.matches?(error)
      else
        blanket_policy ||= policy
      end
    end
    blanket_policy
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
