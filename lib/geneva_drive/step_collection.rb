# frozen_string_literal: true

require "forwardable"

module GenevaDrive
  # Manages an ordered collection of step definitions for a workflow.
  # Handles step ordering based on before_step/after_step positioning
  # and provides methods for navigating between steps.
  #
  # @api private
  class StepCollection
    include Enumerable
    extend Forwardable

    # @!method each
    #   Iterates over steps in order.
    #   @yield [StepDefinition] each step definition in order
    #   @return [Enumerator] if no block given

    # @!method size
    #   Returns the number of steps.
    #   @return [Integer] the step count

    # @!method first
    #   Returns the first step in the workflow.
    #   @return [StepDefinition, nil] the first step or nil if empty

    # @!method last
    #   Returns the last step in the workflow.
    #   @return [StepDefinition, nil] the last step or nil if empty

    # @!method empty?
    #   Checks if the collection is empty.
    #   @return [Boolean] true if no steps

    # @!method []
    #   Returns the step at the given index.
    #   @param index [Integer] the index
    #   @return [StepDefinition, nil] the step or nil

    def_delegators :ordered_steps, :each, :size, :first, :last, :empty?, :[]
    alias_method :length, :size

    # Creates a new step collection from an array of step definitions.
    #
    # @param step_definitions [Array<StepDefinition>] the step definitions to manage
    def initialize(step_definitions)
      @step_definitions = step_definitions
      @ordered_steps = nil
    end

    # Finds a step by name.
    #
    # @param name [String, Symbol] the step name
    # @return [StepDefinition, nil] the step definition or nil if not found
    def find_by_name(name)
      name_str = name.to_s
      find { |step| step.name == name_str }
    end

    # Returns the next step after the given step name.
    #
    # @param current_name [String, Symbol, nil] the current step name
    # @return [StepDefinition, nil] the next step or nil if at end
    def next_after(current_name)
      return first if current_name.nil?

      current_index = ordered_steps.index { |s| s.name == current_name.to_s }
      return nil unless current_index

      self[current_index + 1]
    end

    # Checks if a step exists with the given name.
    #
    # @param name [String, Symbol] the step name
    # @return [Boolean] true if step exists
    def include?(name)
      !find_by_name(name).nil?
    end

    private

    # Returns the steps in their proper order, applying before_step/after_step positioning.
    #
    # @return [Array<StepDefinition>] ordered step definitions
    def ordered_steps
      @ordered_steps ||= compute_order
    end

    # Computes the step order based on positioning constraints.
    # Steps without positioning constraints maintain their definition order.
    # Steps with before_step/after_step are repositioned accordingly.
    #
    # @return [Array<StepDefinition>] ordered step definitions
    def compute_order
      return [] if @step_definitions.empty?

      # Separate steps with and without positioning
      positioned = []
      unpositioned = []

      @step_definitions.each do |step|
        if step.before_step || step.after_step
          positioned << step
        else
          unpositioned << step
        end
      end

      # Start with unpositioned steps in definition order
      result = unpositioned.dup

      # Insert positioned steps
      positioned.each do |step|
        insert_positioned_step(result, step)
      end

      result
    end

    # Inserts a positioned step into the result array at the correct location.
    #
    # @param result [Array<StepDefinition>] the current ordered steps
    # @param step [StepDefinition] the step to insert
    # @raise [StepConfigurationError] if referenced step does not exist
    def insert_positioned_step(result, step)
      if step.before_step
        target_index = result.index { |s| s.name == step.before_step }
        unless target_index
          raise StepConfigurationError,
            "Step '#{step.name}' references non-existent step '#{step.before_step}' in before_step:"
        end
        result.insert(target_index, step)
      elsif step.after_step
        target_index = result.index { |s| s.name == step.after_step }
        unless target_index
          raise StepConfigurationError,
            "Step '#{step.name}' references non-existent step '#{step.after_step}' in after_step:"
        end
        result.insert(target_index + 1, step)
      end
    end
  end
end
