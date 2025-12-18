# frozen_string_literal: true

# Metadata about a step definition in a workflow.
# Holds the step name, callable (block or method name), wait time,
# skip conditions, and exception handling configuration.
#
# @api private
class GenevaDrive::StepDefinition
  # Valid exception handler values
  EXCEPTION_HANDLERS = %i[pause! cancel! reattempt! skip!].freeze

  # Valid types for skip conditions
  VALID_SKIP_CONDITION_TYPES = [Symbol, Proc, TrueClass, FalseClass, NilClass].freeze

  # @return [String] the step name
  attr_reader :name

  # @return [Proc, Symbol] the callable to execute (block or method name)
  attr_reader :callable

  # @return [ActiveSupport::Duration, nil] wait time before executing this step
  attr_reader :wait

  # @return [Proc, Symbol, Boolean, nil] condition for skipping this step
  attr_reader :skip_condition

  # @return [Symbol] exception handler (:pause!, :cancel!, :reattempt!, :skip!)
  attr_reader :on_exception

  # @return [String, nil] name of step this should be placed before
  attr_reader :before_step

  # @return [String, nil] name of step this should be placed after
  attr_reader :after_step

  # Creates a new step definition.
  #
  # @param name [String, Symbol] the step name
  # @param callable [Proc, Symbol, nil] the code to execute (block or method name)
  # @param wait [ActiveSupport::Duration, nil] delay before execution
  # @param skip_if [Proc, Symbol, Boolean, nil] condition for skipping
  # @param if [Proc, Symbol, Boolean, nil] condition for running (inverse of skip_if)
  # @param on_exception [Symbol] how to handle exceptions
  # @param before_step [String, Symbol, nil] position before this step
  # @param after_step [String, Symbol, nil] position after this step
  # @raise [StepConfigurationError] if configuration is invalid
  def initialize(name:, callable:, **options)
    @name = name.to_s
    @callable = callable
    @wait = options[:wait]
    @skip_if_option = options[:skip_if]
    @if_option = options[:if]
    @skip_condition = @skip_if_option || @if_option
    @on_exception = options[:on_exception] || :pause!
    @before_step = options[:before_step]&.to_s
    @after_step = options[:after_step]&.to_s

    validate!
  end

  # Evaluates whether this step should be skipped for the given workflow.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow instance
  # @return [Boolean] true if the step should be skipped
  def should_skip?(workflow)
    return false unless @skip_condition
    evaluate_condition(@skip_condition, workflow)
  end

  # Executes the step callable in the context of the workflow.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow instance
  # @return [Object] the result of the step execution
  def execute_in_context(workflow)
    if @callable.is_a?(Symbol)
      workflow.send(@callable)
    else
      workflow.instance_exec(&@callable)
    end
  end

  private

  # Validates the step definition configuration.
  #
  # @raise [StepConfigurationError] if configuration is invalid
  def validate!
    validate_callable!
    validate_wait!
    validate_exception_handler!
    validate_positioning!
    validate_skip_condition!
  end

  # Validates that the callable is present and valid.
  #
  # @raise [StepConfigurationError] if callable is missing or invalid
  def validate_callable!
    return if @callable.is_a?(Proc)
    return if @callable.is_a?(Symbol)

    raise GenevaDrive::StepConfigurationError,
      "Step '#{@name}' requires either a block or a method name"
  end

  # Validates the wait duration.
  #
  # @raise [StepConfigurationError] if wait is negative
  def validate_wait!
    return if @wait.nil?
    return if @wait.respond_to?(:to_i) && @wait.to_i >= 0

    raise GenevaDrive::StepConfigurationError,
      "Step '#{@name}' has invalid wait value: must be non-negative"
  end

  # Validates the exception handler.
  #
  # @raise [StepConfigurationError] if on_exception is invalid
  def validate_exception_handler!
    return if EXCEPTION_HANDLERS.include?(@on_exception)

    raise GenevaDrive::StepConfigurationError,
      "Step '#{@name}' has invalid on_exception: must be one of #{EXCEPTION_HANDLERS.join(", ")}"
  end

  # Validates the step positioning options.
  #
  # @raise [StepConfigurationError] if both before_step and after_step are specified
  def validate_positioning!
    return unless @before_step && @after_step

    raise GenevaDrive::StepConfigurationError,
      "Step '#{@name}' cannot specify both before_step: and after_step:"
  end

  # Validates the skip condition.
  #
  # @raise [StepConfigurationError] if skip condition is invalid or both skip_if and if are specified
  def validate_skip_condition!
    if @skip_if_option && @if_option
      raise GenevaDrive::StepConfigurationError,
        "Step '#{@name}' cannot specify both skip_if: and if:"
    end

    return if @skip_condition.nil?
    return if VALID_SKIP_CONDITION_TYPES.any? { |type| @skip_condition.is_a?(type) }

    raise GenevaDrive::StepConfigurationError,
      "Step '#{@name}' has invalid skip_if: must be a Symbol, Proc, Boolean, or nil, " \
      "but was #{@skip_condition.class}"
  end

  # Evaluates a condition in the workflow context.
  #
  # @param condition [Proc, Symbol, Boolean, nil] the condition to evaluate
  # @param workflow [GenevaDrive::Workflow] the workflow instance
  # @return [Boolean] the result of the condition
  def evaluate_condition(condition, workflow)
    case condition
    when Symbol
      !!workflow.send(condition)
    when Proc
      !!workflow.instance_exec(&condition)
    when TrueClass, FalseClass
      condition
    when NilClass
      false
    else
      !!condition
    end
  end
end
