# frozen_string_literal: true

# Wraps an array of ExceptionPolicy objects into a single composable policy.
# Encapsulates the walk/match logic (specific match first, blanket fallback)
# and the global reattempt cap (minimum max_reattempts across all policies).
#
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
