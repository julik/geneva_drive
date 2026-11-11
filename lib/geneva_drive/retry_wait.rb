# frozen_string_literal: true

# Validates retry strategies and turns them into delays without reading execution history.
# @api private
module GenevaDrive::RetryWait
  def self.validate!(wait)
    if wait.is_a?(Symbol) && wait != :polynomially_longer
      raise ArgumentError, "Unknown retry wait strategy: #{wait.inspect}"
    end
  end

  def self.resolve(wait, reattempt_count:)
    return wait unless wait == :polynomially_longer

    delay = (reattempt_count + 1)**4
    (delay + Kernel.rand * delay * ActiveJob::Base.retry_jitter + 2).seconds
  end
end
