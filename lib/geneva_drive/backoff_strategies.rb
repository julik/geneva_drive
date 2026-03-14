# frozen_string_literal: true

# Resolves wait values for reattempt backoff. Accepts fixed durations,
# named strategies (symbols), or Procs that receive the attempt count.
#
# @api private
module GenevaDrive::BackoffStrategies
  # Polynomial backoff: attempts**4 + jitter + 2 seconds.
  # Sequence (without jitter): ~3s, ~18s, ~83s, ~258s, ~627s...
  # Mirrors the Rails ActiveJob :polynomially_longer strategy.
  POLYNOMIALLY_LONGER = ->(attempts, jitter: 0.15) {
    delay = attempts**4
    delay_jitter = (jitter > 0) ? Kernel.rand * delay * jitter : 0.0
    (delay + delay_jitter + 2).seconds
  }

  STRATEGIES = {
    polynomially_longer: POLYNOMIALLY_LONGER
  }.freeze

  # Resolves a wait value to a concrete duration.
  #
  # @param wait [Symbol, Proc, ActiveSupport::Duration, Integer, Float, nil]
  #   the wait specification
  # @param attempts [Integer] the current reattempt count (1-based)
  # @param jitter [Float] jitter factor for symbol strategies (0.0 to 1.0)
  # @return [ActiveSupport::Duration, Integer, Float, nil] the resolved wait
  def self.resolve(wait, attempts:, jitter: nil)
    case wait
    when Symbol
      strategy = STRATEGIES.fetch(wait) {
        raise ArgumentError, "Unknown backoff strategy: #{wait.inspect}. " \
          "Valid strategies: #{STRATEGIES.keys.join(", ")}"
      }
      strategy.call(attempts, jitter: jitter || 0.15)
    when Proc
      wait.call(attempts)
    when ActiveSupport::Duration, Integer, Float
      wait
    when nil
      nil
    else
      raise ArgumentError, "Invalid wait value: #{wait.inspect}"
    end
  end
end
