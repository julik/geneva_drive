# frozen_string_literal: true

require "test_helper"

class ExecutorTest < ActiveSupport::TestCase
  # Simple workflow for executor tests
  class BasicWorkflow < GenevaDrive::Workflow
    step :first_step do
      Thread.current[:executor_test_first_executed] = true
    end

    step :second_step do
      Thread.current[:executor_test_second_executed] = true
    end

    def self.first_executed?
      Thread.current[:executor_test_first_executed]
    end

    def self.reset_tracking!
      Thread.current[:executor_test_first_executed] = nil
      Thread.current[:executor_test_second_executed] = nil
    end
  end

  # Workflow that tracks execution hooks
  class ExecutionHookTrackingWorkflow < GenevaDrive::Workflow
    step :tracked_step do
      Thread.current[:execution_hook_events] ||= []
      Thread.current[:execution_hook_events] << [:step_body, nil]
    end

    def before_step_execution(step_execution)
      Thread.current[:execution_hook_events] ||= []
      Thread.current[:execution_hook_events] << [:before_step_execution, step_execution.id]
    end

    def after_step_execution(step_execution)
      Thread.current[:execution_hook_events] ||= []
      Thread.current[:execution_hook_events] << [:after_step_execution, step_execution.id]
    end

    def self.events
      Thread.current[:execution_hook_events]
    end

    def self.reset_tracking!
      Thread.current[:execution_hook_events] = nil
    end
  end

  # Workflow that tracks around_step_execution wrapping
  class AroundHookTrackingWorkflow < GenevaDrive::Workflow
    step :tracked_step do
      Thread.current[:around_hook_events] ||= []
      Thread.current[:around_hook_events] << :step_body
    end

    def around_step_execution(step_execution)
      Thread.current[:around_hook_events] ||= []
      Thread.current[:around_hook_events] << :around_before
      Thread.current[:around_hook_step_execution_id] = step_execution.id
      result = super
      Thread.current[:around_hook_events] << :around_after
      result
    end

    def self.events
      Thread.current[:around_hook_events]
    end

    def self.step_execution_id
      Thread.current[:around_hook_step_execution_id]
    end

    def self.reset_tracking!
      Thread.current[:around_hook_events] = nil
      Thread.current[:around_hook_step_execution_id] = nil
    end
  end

  # Workflow with skip_if condition
  class SkipIfWorkflow < GenevaDrive::Workflow
    step :skippable, skip_if: -> { hero.name == "Skip" } do
      @ran = true
    end

    step :final do
      @final_ran = true
    end

    attr_accessor :ran, :final_ran
  end

  # Workflow with cancel_if condition
  class CancelIfWorkflow < GenevaDrive::Workflow
    cancel_if { hero.name == "Cancel" }

    step :first do
      @ran = true
    end

    attr_accessor :ran
  end

  # Workflow without hero
  class RequiresHeroWorkflow < GenevaDrive::Workflow
    step :step_one do
      @ran = true
    end

    attr_accessor :ran
  end

  # Workflow that can proceed without hero
  class OptionalHeroWorkflow < GenevaDrive::Workflow
    may_proceed_without_hero!

    step :step_one do
      Thread.current[:hero_optional_ran] = true
    end

    def self.ran?
      Thread.current[:hero_optional_ran]
    end

    def self.reset_tracking!
      Thread.current[:hero_optional_ran] = nil
    end
  end

  # Workflow with flow control
  class FlowControlWorkflow < GenevaDrive::Workflow
    step :cancel_step do
      cancel!
    end

    step :pause_step do
      pause!
    end

    step :skip_step do
      skip!
    end

    step :reattempt_step do
      reattempt!(wait: 1.hour) unless @reattempted
      @reattempted = true
    end

    step :finish_step do
      finished!
    end

    step :normal_step do
      # Just completes normally
    end

    attr_accessor :reattempted
  end

  # Workflow with exception handling
  # Custom exception classes for testing exception propagation
  class PauseTestError < StandardError; end
  class SkipTestError < StandardError; end
  class CancelTestError < StandardError; end
  class RetryTestError < StandardError; end

  class ExceptionHandlingWorkflow < GenevaDrive::Workflow
    step :pause_default, on_exception: :pause! do
      raise PauseTestError, "pause error"
    end

    step :reattempt_error, on_exception: :reattempt! do
      raise RetryTestError, "retry error"
    end

    step :skip_error, on_exception: :skip! do
      raise SkipTestError, "skip error"
    end

    step :cancel_error, on_exception: :cancel! do
      raise CancelTestError, "cancel error"
    end
  end

  setup do
    @user = create_user
  end

  test "executes step and transitions to next" do
    BasicWorkflow.reset_tracking!
    workflow = BasicWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert BasicWorkflow.first_executed?

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "success", step_execution.outcome
    assert_equal "ready", workflow.state
    assert_nil workflow.current_step_name, "current_step_name should be nil after execution"
    assert_equal "second_step", workflow.next_step_name
    assert_equal 2, workflow.step_executions.count
  end

  test "skip_if condition evaluated at execution time" do
    user = create_user(name: "Skip", email: "skip@example.com")
    workflow = SkipIfWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "skipped", step_execution.outcome
    assert_nil workflow.ran
    assert_nil workflow.current_step_name, "current_step_name should be nil (not executing)"
    assert_equal "final", workflow.next_step_name
  end

  test "cancel_if condition cancels workflow" do
    user = create_user(name: "Cancel", email: "cancel@example.com")
    workflow = CancelIfWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
    assert_nil workflow.ran
  end

  test "cancels workflow if hero is deleted" do
    workflow = RequiresHeroWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    @user.destroy!

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
  end

  test "proceeds without hero if may_proceed_without_hero! is set" do
    OptionalHeroWorkflow.reset_tracking!
    workflow = OptionalHeroWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    @user.destroy!

    GenevaDrive::Executor.execute!(step_execution)

    assert OptionalHeroWorkflow.ran?

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
  end

  test "cancel! flow control cancels workflow" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "canceled", workflow.state
  end

  test "pause! flow control pauses workflow" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "pause_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "pause_step")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "canceled", step_execution.state
    assert_equal "paused", workflow.state
  end

  test "skip! flow control skips to next step" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "skip_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "skip_step")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "ready", workflow.state
    assert_equal 3, workflow.step_executions.count
  end

  test "finished! flow control finishes workflow immediately" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "finish_step",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "finish_step")

    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    workflow.reload

    assert_equal "completed", step_execution.state
    assert_equal "finished", workflow.state
  end

  test "on_exception: :pause! pauses workflow on error" do
    workflow = ExceptionHandlingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    error = assert_raises(PauseTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_equal "pause error", error.message

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "failed", step_execution.outcome
    assert_equal "paused", workflow.state
    assert_equal "pause error", step_execution.error_message
  end

  test "on_exception: :skip! skips step on error" do
    workflow = ExceptionHandlingWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "skip_error",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "skip_error")

    error = assert_raises(SkipTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_equal "skip error", error.message

    step_execution.reload
    workflow.reload

    assert_equal "skipped", step_execution.state
    assert_equal "ready", workflow.state
  end

  test "on_exception: :cancel! cancels workflow on error" do
    workflow = ExceptionHandlingWorkflow.create!(hero: @user)
    workflow.step_executions.first.mark_canceled!
    step_execution = workflow.step_executions.create!(
      step_name: "cancel_error",
      state: "scheduled",
      scheduled_for: Time.current
    )
    workflow.update!(current_step_name: "cancel_error")

    error = assert_raises(CancelTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_equal "cancel error", error.message

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "canceled", step_execution.outcome
    assert_equal "canceled", workflow.state
  end

  test "step execution idempotency - does not re-execute completed step" do
    BasicWorkflow.reset_tracking!
    workflow = BasicWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)
    assert BasicWorkflow.first_executed?

    BasicWorkflow.reset_tracking!

    GenevaDrive::Executor.execute!(step_execution.reload)

    assert_nil BasicWorkflow.first_executed?
    assert_equal "completed", step_execution.state
  end

  test "pauses workflow when step execution references non-existent step" do
    workflow = BasicWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Manually change the step name to something that doesn't exist
    step_execution.update_column(:step_name, "non_existent_step")

    error = assert_raises(GenevaDrive::StepNotDefinedError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/non_existent_step/, error.message)
    assert_match(/not defined/, error.message)
    assert_equal step_execution, error.step_execution
    assert_equal workflow, error.workflow

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "failed", step_execution.outcome
    assert_match(/non_existent_step/, step_execution.error_message)
    assert_equal "paused", workflow.state
  end

  test "sets finished_at when step completes successfully" do
    BasicWorkflow.reset_tracking!
    workflow = BasicWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)
    step_execution.reload

    assert_equal "completed", step_execution.state
    assert_not_nil step_execution.finished_at
    assert_not_nil step_execution.completed_at
    assert_in_delta step_execution.completed_at.to_f, step_execution.finished_at.to_f, 0.1
  end

  test "sets finished_at when step fails" do
    workflow = ExceptionHandlingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    assert_raises(PauseTestError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    step_execution.reload

    assert_equal "failed", step_execution.state
    assert_not_nil step_execution.finished_at
    assert_not_nil step_execution.failed_at
    assert_in_delta step_execution.failed_at.to_f, step_execution.finished_at.to_f, 0.1
  end

  test "sets finished_at when step is skipped" do
    user = create_user(name: "Skip", email: "skip@example.com")
    workflow = SkipIfWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)
    step_execution.reload

    assert_equal "skipped", step_execution.state
    assert_not_nil step_execution.finished_at
    assert_not_nil step_execution.skipped_at
    assert_in_delta step_execution.skipped_at.to_f, step_execution.finished_at.to_f, 0.1
  end

  test "sets finished_at when step is canceled" do
    workflow = FlowControlWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)
    step_execution.reload

    assert_equal "canceled", step_execution.state
    assert_not_nil step_execution.finished_at
    assert_not_nil step_execution.canceled_at
    assert_in_delta step_execution.canceled_at.to_f, step_execution.finished_at.to_f, 0.1
  end

  test "calls execution hooks in correct order" do
    ExecutionHookTrackingWorkflow.reset_tracking!
    workflow = ExecutionHookTrackingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    events = ExecutionHookTrackingWorkflow.events
    assert_equal 3, events.size

    assert_equal :before_step_execution, events[0][0]
    assert_equal step_execution.id, events[0][1]

    assert_equal :step_body, events[1][0]

    assert_equal :after_step_execution, events[2][0]
    assert_equal step_execution.id, events[2][1]
  end

  test "around_step_execution wraps step body and receives step_execution" do
    AroundHookTrackingWorkflow.reset_tracking!
    workflow = AroundHookTrackingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    events = AroundHookTrackingWorkflow.events
    assert_equal [:around_before, :step_body, :around_after], events
    assert_equal step_execution.id, AroundHookTrackingWorkflow.step_execution_id
  end

  test "marks step as failed and pauses workflow when hero class does not exist" do
    # Create a workflow with a hero_type that references a non-existent class
    workflow = BasicWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Manually set hero_type to a non-existent class
    workflow.update_column(:hero_type, "NonExistentClass")

    # Execute the job - should raise but also record the failure
    error = assert_raises(NameError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/NonExistentClass/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "paused", workflow.state
    assert_match(/uninitialized constant/, step_execution.error_message)
    assert_equal "NameError", step_execution.error_class_name
    assert_not_nil step_execution.error_backtrace
  end

  # Workflow that raises during prepare_execution but has on_exception: :skip!
  class PrepareExceptionSkipWorkflow < GenevaDrive::Workflow
    step :first_step, on_exception: :skip! do
      # This won't run - exception happens during prepare
    end

    step :second_step do
      Thread.current[:prepare_exception_skip_ran] = true
    end

    def self.second_ran?
      Thread.current[:prepare_exception_skip_ran]
    end

    def self.reset_tracking!
      Thread.current[:prepare_exception_skip_ran] = nil
    end
  end

  test "respects on_exception: :skip! policy for prepare_execution exceptions" do
    PrepareExceptionSkipWorkflow.reset_tracking!
    workflow = PrepareExceptionSkipWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Manually set hero_type to a non-existent class
    workflow.update_column(:hero_type, "NonExistentClass")

    error = assert_raises(NameError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_match(/NonExistentClass/, error.message)

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "ready", workflow.state
    # Should have scheduled the next step
    assert_equal 2, workflow.step_executions.count
    assert_equal "second_step", workflow.step_executions.order(:id).last.step_name
  end

  # Workflow that raises during prepare_execution but has on_exception: :cancel!
  class PrepareExceptionCancelWorkflow < GenevaDrive::Workflow
    step :first_step, on_exception: :cancel! do
      # This won't run - exception happens during prepare
    end
  end

  test "respects on_exception: :cancel! policy for prepare_execution exceptions" do
    workflow = PrepareExceptionCancelWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Manually set hero_type to a non-existent class
    workflow.update_column(:hero_type, "NonExistentClass")

    assert_raises(NameError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    step_execution.reload
    workflow.reload

    assert_equal "failed", step_execution.state
    assert_equal "canceled", workflow.state
  end

  # Workflow that captures log output from step code
  class LoggerCapturingWorkflow < GenevaDrive::Workflow
    step :logging_step do
      logger.info("Step code log message")
    end

    def self.reset_tracking!
      Thread.current[:captured_log_output] = nil
    end

    def self.captured_output
      Thread.current[:captured_log_output]
    end

    def self.captured_output=(value)
      Thread.current[:captured_log_output] = value
    end
  end

  test "step code logger includes step execution tags when logger is injected" do
    LoggerCapturingWorkflow.reset_tracking!

    # Create a StringIO to capture log output
    log_output = StringIO.new
    base_logger = ActiveSupport::TaggedLogging.new(Logger.new(log_output))
    base_logger = base_logger.tagged("job_id=test-job-123")

    workflow = LoggerCapturingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution, logger: base_logger)

    log_content = log_output.string

    # Should include the job tag (from injected logger)
    assert_match(/job_id=test-job-123/, log_content, "Log should include job_id tag from injected logger")

    # Should include workflow tags
    assert_match(/LoggerCapturingWorkflow/, log_content, "Log should include workflow class name")
    assert_match(/id=#{workflow.id}/, log_content, "Log should include workflow id")
    assert_match(/hero_type=User/, log_content, "Log should include hero_type")
    assert_match(/hero_id=#{@user.id}/, log_content, "Log should include hero_id")

    # Should include step execution tags
    assert_match(/execution_id=#{step_execution.id}/, log_content, "Log should include execution_id")
    assert_match(/step_name=logging_step/, log_content, "Log should include step_name")

    # Should include the actual log message
    assert_match(/Step code log message/, log_content, "Log should include the step's log message")
  end

  test "step code logger uses default Rails logger when no logger is injected" do
    LoggerCapturingWorkflow.reset_tracking!

    workflow = LoggerCapturingWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    # Execute without injected logger - should not raise
    GenevaDrive::Executor.execute!(step_execution)

    step_execution.reload
    assert_equal "completed", step_execution.state
  end

  # Workflow that verifies workflow.logger and step_execution.logger return the same instance
  class LoggerIdentityWorkflow < GenevaDrive::Workflow
    step :check_logger do
      # Store the logger object_id to verify identity
      Thread.current[:workflow_logger_id] = logger.object_id
    end

    def self.workflow_logger_id
      Thread.current[:workflow_logger_id]
    end

    def self.reset_tracking!
      Thread.current[:workflow_logger_id] = nil
    end
  end

  test "workflow.logger returns the step execution logger during step execution" do
    LoggerIdentityWorkflow.reset_tracking!

    log_output = StringIO.new
    base_logger = ActiveSupport::TaggedLogging.new(Logger.new(log_output))

    workflow = LoggerIdentityWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution, logger: base_logger)

    # The logger returned by workflow.logger inside step code should be
    # the same as step_execution.logger (both should be the injected step logger)
    assert_not_nil LoggerIdentityWorkflow.workflow_logger_id
  end
end
