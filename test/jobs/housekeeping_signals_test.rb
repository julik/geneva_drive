# frozen_string_literal: true

require "test_helper"

# Signals are wiped with their workflows, and parked executions - which the
# stuck sweeps deliberately ignore - are reported through gauges instead.
class HousekeepingSignalsTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class GaugeRecorder
    attr_reader :gauges

    def initialize
      @gauges = []
    end

    def set_gauge(name, value, tags = {})
      @gauges << {name: name.to_s, value: value, tags: tags}
    end

    def instrument(*, &blk) = blk&.call

    def add_distribution_value(*) = nil

    def increment_counter(*) = nil
  end

  class WaitingWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: :payment_confirmed do
    end
  end

  class OtherWaitingWorkflow < GenevaDrive::Workflow
    step :await_approval, wait_for: :approved do
    end
  end

  setup do
    @user = create_user
    @original_delete_after = GenevaDrive.delete_completed_workflows_after
    @original_batch_size = GenevaDrive.housekeeping_batch_size
    @original_waiting_threshold = GenevaDrive.waiting_visibility_threshold
    @recorder = GaugeRecorder.new
    Measurometer.drivers << @recorder
  end

  teardown do
    GenevaDrive.delete_completed_workflows_after = @original_delete_after
    GenevaDrive.housekeeping_batch_size = @original_batch_size
    GenevaDrive.waiting_visibility_threshold = @original_waiting_threshold
    Measurometer.drivers.delete(@recorder)
  end

  def gauge(name, workflow: nil)
    found = @recorder.gauges.select { |g| g[:name] == name && g[:tags][:workflow] == workflow }
    found.last&.fetch(:value)
  end

  def park_workflow(workflow_class, user)
    workflow = workflow_class.create!(hero: user)
    workflow.current_execution.execute!
    workflow.reload
  end

  test "signals of old workflows are deleted before the workflows themselves" do
    GenevaDrive.delete_completed_workflows_after = 30.days

    workflow = WaitingWorkflow.create!(hero: @user)
    workflow.signal!(:payment_confirmed)
    workflow.signal!(:unrelated)
    workflow.cancel!
    workflow.update!(transitioned_at: 60.days.ago)

    results = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 2, results[:signals_cleaned_up]
    assert_equal 1, results[:workflows_cleaned_up]
    assert_equal 0, GenevaDrive::Signal.where(workflow_id: workflow.id).count
    assert_not GenevaDrive::Workflow.exists?(workflow.id)
  end

  test "signals of recent workflows are kept" do
    GenevaDrive.delete_completed_workflows_after = 30.days

    workflow = WaitingWorkflow.create!(hero: @user)
    workflow.signal!(:payment_confirmed)
    workflow.cancel!

    results = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 0, results[:signals_cleaned_up]
    assert_equal 1, GenevaDrive::Signal.where(workflow_id: workflow.id).count
  end

  test "signal deletion is batched" do
    GenevaDrive.delete_completed_workflows_after = 30.days
    GenevaDrive.housekeeping_batch_size = 2

    workflow = WaitingWorkflow.create!(hero: @user)
    4.times { |n| workflow.signal!(:noise, idempotency_key: "evt_#{n}") }
    workflow.cancel!
    workflow.update!(transitioned_at: 60.days.ago)

    results = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 4, results[:signals_cleaned_up]
    assert_equal 0, GenevaDrive::Signal.where(workflow_id: workflow.id).count
  end

  test "parked executions are counted per workflow class" do
    park_workflow(WaitingWorkflow, @user)
    park_workflow(OtherWaitingWorkflow, create_user(email: "two@example.com"))

    GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, gauge("geneva_drive.waiting_step_executions", workflow: WaitingWorkflow.name)
    assert_equal 1, gauge("geneva_drive.waiting_step_executions", workflow: OtherWaitingWorkflow.name)
    assert_equal 2, gauge("geneva_drive.waiting_step_executions")
  end

  test "parked executions past the visibility threshold are reported as overdue" do
    GenevaDrive.waiting_visibility_threshold = 7.days

    fresh = park_workflow(WaitingWorkflow, @user)
    stale = park_workflow(OtherWaitingWorkflow, create_user(email: "two@example.com"))
    stale.current_execution.update!(waiting_since: 30.days.ago)

    GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, gauge("geneva_drive.waiting_overdue")
    assert_equal 1, gauge("geneva_drive.waiting_overdue", workflow: OtherWaitingWorkflow.name)
    assert_nil gauge("geneva_drive.waiting_overdue", workflow: WaitingWorkflow.name)
    assert_equal "waiting", fresh.current_execution.state
  end

  test "the overdue gauge can be disabled" do
    GenevaDrive.waiting_visibility_threshold = nil
    park_workflow(WaitingWorkflow, @user)

    GenevaDrive::HousekeepingJob.perform_now

    assert_nil gauge("geneva_drive.waiting_overdue")
    assert_equal 1, gauge("geneva_drive.waiting_step_executions")
  end

  test "parked executions are never treated as stuck" do
    GenevaDrive.delete_completed_workflows_after = nil
    workflow = park_workflow(WaitingWorkflow, @user)
    workflow.current_execution.update!(scheduled_for: 30.days.ago, waiting_since: 30.days.ago)

    results = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 0, results[:stuck_scheduled_recovered]
    assert_equal 0, results[:stuck_in_progress_recovered]
    assert_equal "waiting", workflow.reload.current_execution.state
  end

  test "a worker crashing mid-step re-attaches to the same claimed signal" do
    GenevaDrive.delete_completed_workflows_after = nil
    workflow = park_workflow(WaitingWorkflow, @user)
    signal = workflow.signal!(:payment_confirmed, payload: {amount_cents: 7})

    # Pretend the worker died after the gate attached and the step started
    crashed = workflow.reload.current_execution
    crashed.update!(state: "in_progress", started_at: 30.days.ago)
    workflow.update!(state: "performing", current_step_name: "await_payment")

    results = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, results[:stuck_in_progress_recovered]
    assert_equal "claimed", signal.reload.state

    recovered = workflow.reload.current_execution
    recovered.execute!

    assert_equal signal.id, recovered.reload.signal_id
    assert_equal "consumed", signal.reload.state
  end

  test "a dispatched execution whose job got lost is recovered as a stuck scheduled one" do
    GenevaDrive.delete_completed_workflows_after = nil
    workflow = park_workflow(WaitingWorkflow, @user)
    signal = workflow.signal!(:payment_confirmed)

    # Pretend the enqueue evaporated and the threshold has passed
    workflow.current_execution.update!(scheduled_for: 30.days.ago)

    results = GenevaDrive::HousekeepingJob.perform_now

    assert_equal 1, results[:stuck_scheduled_recovered]

    recovered = workflow.reload.current_execution
    assert_equal "scheduled", recovered.state
    # The fresh execution re-attaches to the still-claimed signal at its gate
    recovered.execute!
    assert_equal "consumed", signal.reload.state
  end
end
