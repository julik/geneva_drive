# frozen_string_literal: true

module GenevaDrive
  # Metadata about a step definition in a workflow.
  # Holds the step name, callable (block or method name), wait time,
  # skip conditions, and exception handling configuration.
  #
  # @api private
  class StepDefinition
    # Valid exception handler values
    EXCEPTION_HANDLERS = %i[pause! cancel! reattempt! skip!].freeze

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
    # @param callable [Proc, Symbol] the code to execute
    # @param wait [ActiveSupport::Duration, nil] delay before execution
    # @param skip_if [Proc, Symbol, Boolean, nil] condition for skipping
    # @param on_exception [Symbol] how to handle exceptions
    # @param before_step [String, Symbol, nil] position before this step
    # @param after_step [String, Symbol, nil] position after this step
    # @raise [ArgumentError] if on_exception is not a valid handler
    def initialize(name:, callable:, **options)
      @name = name.to_s
      @callable = callable
      @wait = options[:wait]
      @skip_condition = options[:skip_if] || options[:if]
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
    # @raise [ArgumentError] if on_exception is not valid
    def validate!
      return if EXCEPTION_HANDLERS.include?(@on_exception)

      raise ArgumentError,
        "on_exception must be one of: #{EXCEPTION_HANDLERS.join(", ")}"
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
end
