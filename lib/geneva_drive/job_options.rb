# frozen_string_literal: true

# Validation helper for Active Job option hashes passed through the workflow DSL
# (`set_step_job_options`, `step(job_options: ...)`, and `workflow.step_job_options=`).
#
# Active Job itself silently ignores unknown keys in `set` — a typo like
# `piority:` would never raise, and the workflow would just run at the default
# priority. This helper enforces the known key set so misconfigurations surface
# at definition time, or at assignment time for per-instance overrides.
#
# The allowed keys mirror what `ActiveJob::Core#set` actually consumes.
#
# @api private
module GenevaDrive::JobOptions
  # Keys that Active Job's `set` recognizes. See `ActiveJob::Core#set` in
  # activejob/lib/active_job/core.rb.
  ALLOWED_KEYS = %i[wait wait_until queue priority].freeze

  # Validates a job options hash and returns a symbolized copy.
  #
  # @param options [#to_h, Hash, nil] the value to validate — anything that
  #   coerces to a Hash via `#to_h` is accepted (Hash, keyword-args splat,
  #   ActiveSupport::HashWithIndifferentAccess, structs, etc.)
  # @param context [String] human-readable identifier used in error messages
  #   (e.g. "Step 'foo'" or "MyWorkflow.step_job_options")
  # @return [Hash{Symbol=>Object}] symbolized copy safe to pass to `.set`
  # @raise [GenevaDrive::StepConfigurationError] if options can't be coerced to
  #   a Hash, contains unknown keys, or has values of the wrong type
  def self.validate!(options, context:)
    hash = begin
      options.to_h
    rescue NoMethodError, TypeError, ArgumentError
      raise GenevaDrive::StepConfigurationError,
        "#{context} has invalid job_options: cannot coerce #{options.class} to a Hash via #to_h"
    end

    symbolized = hash.symbolize_keys

    unknown = symbolized.keys - ALLOWED_KEYS
    unless unknown.empty?
      raise GenevaDrive::StepConfigurationError,
        "#{context} has unknown job_options key(s): #{unknown.map(&:inspect).join(", ")}. " \
        "Active Job only recognizes: #{ALLOWED_KEYS.map(&:inspect).join(", ")}"
    end

    symbolized.each { |k, v| validate_value!(k, v, context) }
    symbolized
  end

  # @api private
  def self.validate_value!(key, value, context)
    return if value.nil?

    valid = case key
    when :wait
      value.respond_to?(:to_i) && value.to_i >= 0
    when :wait_until
      value.respond_to?(:to_time) || value.respond_to?(:to_f)
    when :queue
      value.is_a?(String) || value.is_a?(Symbol)
    when :priority
      value.is_a?(Integer)
    end

    return if valid

    raise GenevaDrive::StepConfigurationError,
      "#{context} has invalid job_options[#{key.inspect}]: #{value.inspect} (#{value.class})"
  end
end
