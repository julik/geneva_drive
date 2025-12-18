# frozen_string_literal: true

require "test_helper"

class InstrumentationTest < ActiveSupport::TestCase
  # Simple workflow for instrumentation tests
  class InstrumentedWorkflow < GenevaDrive::Workflow
    step :first_step do
      Thread.current[:instrumentation_test_executed] = true
    end

    step :second_step do
      # Second step
    end

    def self.executed?
      Thread.current[:instrumentation_test_executed]
    end

    def self.reset_tracking!
      Thread.current[:instrumentation_test_executed] = nil
    end
  end

  # Workflow with skip_if condition
  class SkippingWorkflow < GenevaDrive::Workflow
    step :skippable, skip_if: -> { hero.name == "Skip" } do
      Thread.current[:skip_test_ran] = true
    end

    step :final do
      # Final step
    end
  end

  # Workflow with cancel_if condition
  class CancelingWorkflow < GenevaDrive::Workflow
    cancel_if { hero.name == "Cancel" }

    step :first do
      Thread.current[:cancel_test_ran] = true
    end
  end

  # Workflow with flow control
  class FlowControlWorkflow < GenevaDrive::Workflow
    step :pause_step do
      pause!
    end

    step :next_step do
      # Never reached
    end
  end

  # Workflow with exception
  class ExceptionWorkflow < GenevaDrive::Workflow
    step :failing_step, on_exception: :pause! do
      raise StandardError, "test error"
    end
  end

  setup do
    @user = create_user
    @events = []
    @subscriptions = []
  end

  teardown do
    @subscriptions.each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }
  end

  def subscribe_to(event_name)
    sub = ActiveSupport::Notifications.subscribe(event_name) do |name, start, finish, id, payload|
      @events << {name: name, payload: payload, duration: finish - start}
    end
    @subscriptions << sub
    sub
  end

  test "emits precondition.geneva_drive event on successful precondition check" do
    InstrumentedWorkflow.reset_tracking!
    subscribe_to("precondition.geneva_drive")

    workflow = InstrumentedWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal 1, @events.length
    event = @events.first

    assert_equal "precondition.geneva_drive", event[:name]
    assert_equal step_execution.id, event[:payload][:execution_id]
    assert_equal workflow.id, event[:payload][:workflow_id]
    assert_equal "InstrumentationTest::InstrumentedWorkflow", event[:payload][:workflow_class]
    assert_equal "first_step", event[:payload][:step_name]
    assert_equal :passed, event[:payload][:outcome]
  end

  test "emits precondition.geneva_drive event with skipped outcome" do
    subscribe_to("precondition.geneva_drive")

    user = create_user(name: "Skip", email: "skip@example.com")
    workflow = SkippingWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal 1, @events.length
    event = @events.first

    assert_equal :skipped, event[:payload][:outcome]
    assert_equal "skippable", event[:payload][:step_name]
  end

  test "emits precondition.geneva_drive event with canceled outcome" do
    subscribe_to("precondition.geneva_drive")

    user = create_user(name: "Cancel", email: "cancel@example.com")
    workflow = CancelingWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal 1, @events.length
    event = @events.first

    assert_equal :canceled, event[:payload][:outcome]
  end

  test "emits step.geneva_drive event on successful step execution" do
    InstrumentedWorkflow.reset_tracking!
    subscribe_to("step.geneva_drive")

    workflow = InstrumentedWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal 1, @events.length
    event = @events.first

    assert_equal "step.geneva_drive", event[:name]
    assert_equal step_execution.id, event[:payload][:execution_id]
    assert_equal workflow.id, event[:payload][:workflow_id]
    assert_equal "InstrumentationTest::InstrumentedWorkflow", event[:payload][:workflow_class]
    assert_equal "first_step", event[:payload][:step_name]
    assert_equal :completed, event[:payload][:outcome]
  end

  test "emits step.geneva_drive event with flow control outcome" do
    subscribe_to("step.geneva_drive")

    workflow = FlowControlWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal 1, @events.length
    event = @events.first

    assert_equal :pause, event[:payload][:outcome]
  end

  test "emits step.geneva_drive event with exception outcome" do
    subscribe_to("step.geneva_drive")

    workflow = ExceptionWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    assert_raises(StandardError) do
      GenevaDrive::Executor.execute!(step_execution)
    end

    assert_equal 1, @events.length
    event = @events.first

    assert_equal :exception, event[:payload][:outcome]
    assert_kind_of StandardError, event[:payload][:exception]
    assert_equal "test error", event[:payload][:exception].message
  end

  test "emits finalize.geneva_drive event after step completion" do
    InstrumentedWorkflow.reset_tracking!
    subscribe_to("finalize.geneva_drive")

    workflow = InstrumentedWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal 1, @events.length
    event = @events.first

    assert_equal "finalize.geneva_drive", event[:name]
    assert_equal step_execution.id, event[:payload][:execution_id]
    assert_equal workflow.id, event[:payload][:workflow_id]
    assert_equal "InstrumentationTest::InstrumentedWorkflow", event[:payload][:workflow_class]
    assert_equal "first_step", event[:payload][:step_name]
    assert_equal "ready", event[:payload][:workflow_state]
    assert_equal "completed", event[:payload][:step_state]
  end

  test "emits finalize.geneva_drive event with paused workflow state" do
    subscribe_to("finalize.geneva_drive")

    workflow = FlowControlWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal 1, @events.length
    event = @events.first

    assert_equal "paused", event[:payload][:workflow_state]
    assert_equal "canceled", event[:payload][:step_state]
  end

  test "all three instrumentation events are emitted in sequence" do
    InstrumentedWorkflow.reset_tracking!
    subscribe_to("precondition.geneva_drive")
    subscribe_to("step.geneva_drive")
    subscribe_to("finalize.geneva_drive")

    workflow = InstrumentedWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    assert_equal 3, @events.length
    assert_equal "precondition.geneva_drive", @events[0][:name]
    assert_equal "step.geneva_drive", @events[1][:name]
    assert_equal "finalize.geneva_drive", @events[2][:name]

    # All events should have the same execution and workflow IDs
    @events.each do |event|
      assert_equal step_execution.id, event[:payload][:execution_id]
      assert_equal workflow.id, event[:payload][:workflow_id]
      assert_equal "InstrumentationTest::InstrumentedWorkflow", event[:payload][:workflow_class]
    end
  end

  test "no step or finalize events when precondition aborts execution" do
    subscribe_to("precondition.geneva_drive")
    subscribe_to("step.geneva_drive")
    subscribe_to("finalize.geneva_drive")

    user = create_user(name: "Skip", email: "skip@example.com")
    workflow = SkippingWorkflow.create!(hero: user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    # Only precondition event should be emitted
    assert_equal 1, @events.length
    assert_equal "precondition.geneva_drive", @events[0][:name]
  end

  test "instrumentation events have measurable duration" do
    InstrumentedWorkflow.reset_tracking!
    subscribe_to("step.geneva_drive")

    workflow = InstrumentedWorkflow.create!(hero: @user)
    step_execution = workflow.step_executions.first

    GenevaDrive::Executor.execute!(step_execution)

    event = @events.first
    assert event[:duration] >= 0, "Duration should be non-negative"
  end
end
