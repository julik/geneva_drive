# frozen_string_literal: true

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
module GenevaDrive::TestHelpers
  # Executes all steps of a workflow synchronously for testing.
  #
  # This method runs through all scheduled steps, executing each one
  # immediately regardless of wait times. Resumable steps are run to
  # completion (interruption limits are disabled).
  #
  # @param workflow [GenevaDrive::Workflow] the workflow to run
  # @param max_iterations [Integer] maximum step executions (safety limit)
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
    # Disable interruption checks so resumable steps run to completion
    config = GenevaDrive::InterruptConfiguration.new(respect_interruptions: false)

    loop do
      workflow.reload
      break if %w[finished canceled paused].include?(workflow.state)

      step_execution = workflow.current_execution
      break unless step_execution

      step_execution.execute!(interrupt_configuration: config)
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

  # Executes a step inline, bypassing normal workflow progression.
  #
  # Creates a step execution for the given step and executes it
  # immediately. This is a testing shortcut that allows you to test
  # individual steps without running through the entire flow.
  #
  # When called without a step name, executes the current step.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow containing the step
  # @param step_name [String, Symbol, nil] the step to execute (defaults to current step)
  # @return [GenevaDrive::StepExecution] the executed step
  # @raise [ArgumentError] if the step is not defined in the workflow
  #
  # @example Execute the current step
  #   workflow = OnboardingWorkflow.create!(hero: user)
  #   perform_step_inline(workflow)
  #
  # @example Execute a specific step directly
  #   workflow = OnboardingWorkflow.create!(hero: user)
  #   perform_step_inline(workflow, :send_welcome_email)
  #
  def perform_step_inline(workflow, step_name = nil)
    workflow.reload
    step_name ||= workflow.next_step_name
    step_def = workflow.class.steps.find { |s| s.name == step_name.to_s }

    unless step_def
      available = workflow.class.steps.map(&:name).join(", ")
      raise ArgumentError,
        "Step '#{step_name}' is not defined in #{workflow.class.name}. " \
        "Available steps: #{available}"
    end

    # Cancel any existing scheduled step executions to satisfy uniqueness constraint
    workflow.step_executions.where(state: "scheduled").update_all(
      state: "canceled",
      outcome: "canceled",
      canceled_at: Time.current
    )

    step_execution = workflow.step_executions.create!(
      step_name: step_def.name,
      state: "scheduled",
      scheduled_for: Time.current
    )

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

  # === Resumable Step Test Helpers ===

  # Runs the current step to completion without advancing to the next step.
  #
  # For regular steps, this is equivalent to `perform_next_step`.
  # For resumable steps, this disables interruption checks and runs until
  # the step completes (or fails/cancels/skips).
  #
  # @param workflow [GenevaDrive::Workflow] the workflow containing the step
  # @param max_executions [Integer] safety limit on job executions (default: 100)
  # @return [GenevaDrive::StepExecution] the step execution
  #
  # @example Run current step to completion
  #   workflow = BulkEmailWorkflow.create!(hero: campaign)
  #   speedrun_current_step(workflow)
  #   assert_step_executed(workflow, :send_emails)
  #
  def speedrun_current_step(workflow, max_executions: 100)
    workflow.reload
    step_execution = workflow.current_execution
    return nil unless step_execution

    executions = 0
    original_step_name = step_execution.step_name
    # Disable interruption checks so the step runs to completion
    config = GenevaDrive::InterruptConfiguration.new(respect_interruptions: false)

    loop do
      step_execution.reload
      break if step_execution.completed? || step_execution.failed? || step_execution.canceled? || step_execution.skipped?

      step_execution.execute!(interrupt_configuration: config)
      executions += 1

      if executions >= max_executions
        raise "speedrun_current_step exceeded max_executions (#{max_executions}). " \
              "Step '#{original_step_name}' may be in an infinite loop."
      end
    end

    workflow.reload
    step_execution.reload
    step_execution
  end

  # Runs a resumable step for a specific number of iterations, then allows interruption.
  # Useful for testing partial progress and suspension behavior.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow containing the step
  # @param count [Integer] number of iterations to run
  # @return [GenevaDrive::StepExecution] the step execution
  #
  # @example Run 5 iterations then stop
  #   workflow = ProcessingWorkflow.create!(hero: batch)
  #   run_iterations(workflow, count: 5)
  #   assert_equal 5, workflow.current_execution.completed_iterations
  #
  def run_iterations(workflow, count:)
    workflow.reload
    step_execution = workflow.current_execution
    return nil unless step_execution

    # Set a max_iterations_override to stop after count iterations
    config = GenevaDrive::InterruptConfiguration.new(max_iterations_override: count)
    step_execution.execute!(interrupt_configuration: config)

    workflow.reload
    step_execution.reload
    step_execution
  end

  # Asserts that a resumable step's cursor matches the expected value.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow to check
  # @param expected_cursor [Object] the expected cursor value
  # @return [void]
  #
  # @example Check cursor position
  #   assert_cursor(workflow, 42)
  #   assert_cursor(workflow, "page_token_abc")
  #
  def assert_cursor(workflow, expected_cursor)
    workflow.reload
    execution = workflow.current_execution
    actual = execution&.cursor_value

    assert_equal expected_cursor, actual,
      "Expected cursor #{expected_cursor.inspect}, got #{actual.inspect}"
  end

  # Asserts the number of completed iterations for a resumable step.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow to check
  # @param expected_count [Integer] the expected iteration count
  # @return [void]
  #
  # @example Check iteration count
  #   assert_iterations(workflow, 100)
  #
  def assert_iterations(workflow, expected_count)
    workflow.reload
    execution = workflow.current_execution
    actual = execution&.completed_iterations || 0

    assert_equal expected_count, actual,
      "Expected #{expected_count} iterations, got #{actual}"
  end

  # Asserts that a step is in suspended state.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow to check
  # @param step_name [String, Symbol, nil] optional step name (defaults to current)
  # @return [void]
  #
  # @example Check step is suspended
  #   assert_step_suspended(workflow)
  #   assert_step_suspended(workflow, :bulk_process)
  #
  def assert_step_suspended(workflow, step_name = nil)
    workflow.reload
    execution = if step_name
      workflow.step_executions.find_by(step_name: step_name.to_s, state: "suspended")
    else
      workflow.current_execution
    end

    assert execution&.suspended?,
      "Expected step #{step_name || "current"} to be suspended, " \
      "but was #{execution&.state || "not found"}"
  end
end
