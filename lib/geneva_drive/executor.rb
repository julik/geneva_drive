# frozen_string_literal: true

module GenevaDrive
  # Executes a single step within a workflow context.
  # Handles flow control signals, exception handling, and state transitions.
  #
  # The execution flow:
  # 1. Transition step execution to 'executing' state
  # 2. Transition workflow to 'performing' state (if ready)
  # 3. Check if hero exists (unless may_proceed_without_hero!)
  # 4. Check blanket cancel_if conditions
  # 5. Check step skip_if condition
  # 6. Call before_step_starts hook
  # 7. Execute the step block with flow control
  # 8. Handle the result and update states
  #
  # @api private
  class Executor
    # Creates a new executor for the given workflow and step execution.
    #
    # @param workflow [GenevaDrive::Workflow] the workflow instance
    # @param step_execution [GenevaDrive::StepExecution] the step to execute
    def initialize(workflow, step_execution)
      @workflow = workflow
      @step_execution = step_execution
    end

    # Executes the step with full flow control and exception handling.
    #
    # @return [void]
    def execute!
      # 1. Transition step execution to executing (with lock)
      return unless @step_execution.start_executing!

      # 2. Transition workflow to performing
      @workflow.transition_to!("performing") if @workflow.state == "ready"

      # 3. Check hero exists (unless workflow opts out)
      unless @workflow.class._may_proceed_without_hero
        unless @workflow.hero
          @step_execution.mark_canceled!(outcome: "canceled")
          @workflow.transition_to!("canceled")
          return
        end
      end

      # 4. Check blanket cancel_if conditions
      if should_cancel_workflow?
        handle_blanket_cancellation
        return
      end

      # 5. Get step definition
      step_def = @step_execution.step_definition

      # 6. Check skip_if condition (evaluated at execution time!)
      if step_def.should_skip?(@workflow)
        handle_skip_by_condition
        return
      end

      # 7. Invoke before_step_starts hook
      @workflow.before_step_starts(step_def.name)

      # 8. Execute step with flow control
      flow_result = catch(:flow_control) do
        step_def.execute_in_context(@workflow)
        :completed # Default: step completed successfully
      rescue => e
        handle_exception(e, step_def)
      end

      # 9. Handle flow control result
      handle_flow_control(flow_result)
    end

    private

    # Checks if any blanket cancel conditions are true.
    #
    # @return [Boolean] true if workflow should be canceled
    def should_cancel_workflow?
      @workflow.class._cancel_conditions.any? do |condition|
        evaluate_condition(condition)
      end
    end

    # Evaluates a condition in the workflow context.
    #
    # @param condition [Symbol, Proc, Object] the condition to evaluate
    # @return [Boolean] the result
    def evaluate_condition(condition)
      case condition
      when Symbol
        @workflow.send(condition)
      when Proc
        @workflow.instance_exec(&condition)
      else
        !!condition
      end
    end

    # Handles workflow cancellation due to blanket cancel_if condition.
    #
    # @return [void]
    def handle_blanket_cancellation
      @step_execution.mark_canceled!(outcome: "canceled")
      @workflow.transition_to!("canceled")
    end

    # Handles step skip due to skip_if condition.
    #
    # @return [void]
    def handle_skip_by_condition
      @step_execution.mark_skipped!(outcome: "skipped")
      @workflow.transition_to!("ready")
      @workflow.schedule_next_step!
    end

    # Handles an exception based on the step's on_exception configuration.
    #
    # @param error [Exception] the exception that was raised
    # @param step_def [StepDefinition] the step definition
    # @return [nil]
    def handle_exception(error, step_def)
      Rails.logger.error("Step execution #{@step_execution.id} failed: #{error.message}")
      Rails.error.report(error)

      case step_def.on_exception
      when :reattempt!
        @step_execution.mark_completed!(outcome: "reattempted")
        @workflow.transition_to!("ready")
        @workflow.reschedule_current_step!

      when :cancel!
        @step_execution.mark_failed!(error, outcome: "canceled")
        @workflow.transition_to!("canceled")

      when :skip!
        @step_execution.mark_skipped!(outcome: "skipped")
        @workflow.transition_to!("ready")
        @workflow.schedule_next_step!

      when :pause!
        @step_execution.mark_failed!(error, outcome: "failed")
        @workflow.transition_to!("paused")

      else
        # Default: pause
        @step_execution.mark_failed!(error, outcome: "failed")
        @workflow.transition_to!("paused")
      end

      nil # Indicate exception was handled
    end

    # Handles the result of step execution (success or flow control signal).
    #
    # @param signal [Symbol, FlowControlSignal, nil] the execution result
    # @return [void]
    def handle_flow_control(signal)
      return if signal.nil? # Exception was already handled

      case signal
      when :completed
        @step_execution.mark_completed!(outcome: "success")
        @workflow.transition_to!("ready")
        schedule_next_or_finish!

      when FlowControlSignal
        handle_flow_control_signal(signal)
      end
    end

    # Handles a specific flow control signal.
    #
    # @param signal [FlowControlSignal] the flow control signal
    # @return [void]
    def handle_flow_control_signal(signal)
      case signal.action
      when :cancel
        @step_execution.mark_canceled!(outcome: "canceled")
        @workflow.transition_to!("canceled")

      when :pause
        @step_execution.mark_canceled!(outcome: "canceled")
        @workflow.transition_to!("paused")

      when :reattempt
        @step_execution.mark_completed!(outcome: "reattempted")
        @workflow.transition_to!("ready")
        @workflow.reschedule_current_step!(wait: signal.options[:wait])

      when :skip
        @step_execution.mark_skipped!(outcome: "skipped")
        @workflow.transition_to!("ready")
        schedule_next_or_finish!

      when :finished
        @step_execution.mark_completed!(outcome: "success")
        @workflow.transition_to!("finished")
      end
    end

    # Schedules the next step or finishes the workflow.
    #
    # @return [void]
    def schedule_next_or_finish!
      @workflow.schedule_next_step!
    end
  end
end
