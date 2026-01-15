# frozen_string_literal: true

# Configuration object for controlling step interruption behavior.
#
# In production, steps respect all interruption conditions (max_iterations,
# max_runtime, shutdown signals, etc.). In tests, you can disable these
# checks to run steps to completion quickly.
#
# @example Production behavior (default)
#   config = InterruptConfiguration.new
#   config.respects_interruptions? # => true
#
# @example Test behavior - disable all interruption
#   config = InterruptConfiguration.new(respect_interruptions: false)
#   config.respects_interruptions? # => false
#
# @example Test behavior - limit iterations
#   config = InterruptConfiguration.new(max_iterations_override: 5)
#   config.max_iterations_for(step_definition) # => 5
#
class GenevaDrive::InterruptConfiguration
  attr_reader :max_iterations_override

  # Creates a new interrupt configuration.
  #
  # @param respect_interruptions [Boolean] whether to respect interruption conditions
  # @param max_iterations_override [Integer, nil] override max_iterations for testing
  def initialize(respect_interruptions: true, max_iterations_override: nil)
    @respect_interruptions = respect_interruptions
    @max_iterations_override = max_iterations_override
  end

  # Returns whether interruption conditions should be respected.
  #
  # When false, steps run to completion ignoring max_iterations, max_runtime, etc.
  # This is primarily for testing.
  #
  # @return [Boolean]
  def respects_interruptions?
    @respect_interruptions
  end

  # Returns the effective max_iterations for a step.
  #
  # If an override is set (for testing), returns the override.
  # Otherwise returns the step definition's configured value.
  #
  # @param step_definition [ResumableStepDefinition] the step definition
  # @return [Integer, nil]
  def max_iterations_for(step_definition)
    @max_iterations_override || step_definition&.max_iterations
  end

  # Default configuration for production use.
  #
  # @return [InterruptConfiguration]
  def self.default
    @default ||= new
  end
end
