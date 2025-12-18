# frozen_string_literal: true

module GenevaDrive
  # Test helpers for testing workflows in your application.
  #
  # Include this module in your test classes to get access to
  # workflow testing utilities.
  #
  # @example Using in a test
  #   class SignupWorkflowTest < ActiveSupport::TestCase
  #     include GenevaDrive::TestHelpers
  #
  #     test "completes all steps" do
  #       workflow = SignupWorkflow.create!(hero: users(:one))
  #       speedrun_workflow(workflow)
  #       assert workflow.finished?
  #     end
  #   end
  #
  module TestHelpers
    # Executes all steps of a workflow synchronously for testing.
    #
    # This method runs through all scheduled steps, executing each one
    # immediately regardless of wait times. Useful for testing complete
    # workflow behavior.
    #
    # @param workflow [GenevaDrive::Workflow] the workflow to run
    # @param max_iterations [Integer] maximum steps to execute (safety limit)
    # @return [GenevaDrive::Workflow] the workflow after execution
    # @raise [RuntimeError] if max_iterations is exceeded
    #
    # @example Run a workflow to completion
    #   workflow = OnboardingWorkflow.create!(hero: user)
    #   speedrun_workflow(workflow)
    #   assert_equal "finished", workflow.state
    #
    # @example Run with custom iteration limit
    #   speedrun_workflow(workflow, max_iterations: 10)
    #
    def speedrun_workflow(workflow, max_iterations: 100)
      iterations = 0

      loop do
        workflow.reload
        break if %w[finished canceled paused].include?(workflow.state)

        step_execution = workflow.current_execution
        break unless step_execution

        step_execution.execute!
        iterations += 1

        if iterations >= max_iterations
          raise "speedrun_workflow exceeded max_iterations (#{max_iterations}). " \
                "Workflow may be in an infinite loop."
        end
      end

      workflow.reload
    end

    # Executes only the next pending step of a workflow.
    #
    # Useful for testing step-by-step behavior and inspecting
    # state between steps.
    #
    # @param workflow [GenevaDrive::Workflow] the workflow to step
    # @return [GenevaDrive::StepExecution, nil] the executed step or nil
    #
    # @example Execute one step at a time
    #   workflow = PaymentWorkflow.create!(hero: order)
    #   perform_next_step(workflow)
    #   assert_equal "charge", workflow.current_step_name
    #   perform_next_step(workflow)
    #   assert_equal "receipt", workflow.current_step_name
    #
    def perform_next_step(workflow)
      workflow.reload
      step_execution = workflow.current_execution
      return nil unless step_execution

      step_execution.execute!
      workflow.reload
      step_execution
    end

    # Asserts that a workflow has executed a specific step.
    #
    # @param workflow [GenevaDrive::Workflow] the workflow to check
    # @param step_name [String, Symbol] the expected step name
    # @param state [String] the expected step state (default: "completed")
    # @return [void]
    #
    # @example Check that a step was executed
    #   assert_step_executed(workflow, :send_email)
    #   assert_step_executed(workflow, :optional_step, state: "skipped")
    #
    def assert_step_executed(workflow, step_name, state: "completed")
      step_execution = workflow.step_executions.find_by(
        step_name: step_name.to_s,
        state: state
      )

      assert step_execution,
        "Expected step '#{step_name}' to be #{state}, but it was not found"
    end

    # Asserts that a workflow is in a specific state.
    #
    # @param workflow [GenevaDrive::Workflow] the workflow to check
    # @param expected_state [String, Symbol] the expected state
    # @return [void]
    #
    # @example Check workflow state
    #   assert_workflow_state(workflow, :finished)
    #   assert_workflow_state(workflow, "paused")
    #
    def assert_workflow_state(workflow, expected_state)
      workflow.reload
      assert_equal expected_state.to_s, workflow.state,
        "Expected workflow to be #{expected_state}, but was #{workflow.state}"
    end
  end
end
