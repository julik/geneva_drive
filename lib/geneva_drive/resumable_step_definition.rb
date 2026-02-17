# frozen_string_literal: true

# Metadata about a resumable step definition in a workflow.
# Extends StepDefinition with cursor-based iteration support.
#
# Resumable steps can iterate over large collections with checkpointing,
# allowing them to be suspended and resumed across job executions.
#
# @api private
class GenevaDrive::ResumableStepDefinition < GenevaDrive::StepDefinition
  # @return [Proc] the block to execute (receives IterableStep)
  attr_reader :block

  # @return [Integer, nil] maximum number of iterations before auto-suspend
  attr_reader :max_iterations

  # @return [ActiveSupport::Duration, nil] maximum runtime before auto-suspend
  attr_reader :max_runtime

  # Creates a new resumable step definition.
  #
  # @param name [String, Symbol] the step name
  # @param max_iterations [Integer, nil] maximum iterations before auto-suspend
  # @param max_runtime [ActiveSupport::Duration, nil] maximum runtime before auto-suspend
  # @param options [Hash] additional options (same as StepDefinition)
  # @param block [Proc] the block to execute (required, receives IterableStep)
  # @raise [StepConfigurationError] if configuration is invalid
  def initialize(name:, max_iterations: nil, max_runtime: nil, **options, &block)
    @block = block
    @max_iterations = max_iterations
    @max_runtime = max_runtime

    # Pass a dummy callable to parent since we use block instead
    super(name: name, callable: block, **options)

    validate_resumable!
  end

  # Returns true to indicate this step supports resumable iteration.
  #
  # @return [Boolean]
  def resumable?
    true
  end

  # Executes the step block with an IterableStep in the workflow context.
  # This is called by ResumableStepExecutor, not the normal Executor.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow instance
  # @param iterable_step [GenevaDrive::IterableStep] the iteration context
  # @return [Object] the result of the step execution
  def execute_in_context(workflow, iterable_step = nil)
    if iterable_step
      workflow.instance_exec(iterable_step, &@block)
    else
      # Fallback for non-resumable execution (shouldn't happen in practice)
      workflow.instance_exec(&@block)
    end
  end

  private

  # Validates resumable-specific configuration.
  #
  # @raise [StepConfigurationError] if configuration is invalid
  def validate_resumable!
    validate_block!
    validate_max_iterations!
    validate_max_runtime!
  end

  # Validates that the block is present.
  #
  # @raise [StepConfigurationError] if block is missing
  def validate_block!
    return if @block.is_a?(Proc)

    raise GenevaDrive::StepConfigurationError,
      "Resumable step '#{@name}' requires a block"
  end

  # Validates the max_iterations value.
  #
  # @raise [StepConfigurationError] if max_iterations is invalid
  def validate_max_iterations!
    return if @max_iterations.nil?
    return if @max_iterations.is_a?(Integer) && @max_iterations.positive?

    raise GenevaDrive::StepConfigurationError,
      "Resumable step '#{@name}' has invalid max_iterations: must be a positive integer"
  end

  # Validates the max_runtime value.
  #
  # @raise [StepConfigurationError] if max_runtime is invalid
  def validate_max_runtime!
    return if @max_runtime.nil?
    return if @max_runtime.respond_to?(:to_i) && @max_runtime.to_i.positive?

    raise GenevaDrive::StepConfigurationError,
      "Resumable step '#{@name}' has invalid max_runtime: must be a positive duration"
  end
end
