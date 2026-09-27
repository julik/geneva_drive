# frozen_string_literal: true

require "test_helper"

# Claim and consumption accounting. A signal stays claimed - and therefore
# attachable - while any attached execution chain is unresolved, and flips to
# consumed when the last one resolves cleanly. With a single claimant that is
# the same moment as the step completing; the counters are what make a
# one-to-many dispatch legible.
class SignalConsumptionTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class InvoiceWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: :payment_confirmed do
      raise "gateway unavailable" unless Thread.current[:consumption_healed]
    end

    step :issue_receipt do
    end
  end

  class SkippingWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: :payment_confirmed do
      skip!
    end
  end

  class TwoWaitersWorkflow < GenevaDrive::Workflow
    step :first_wait, wait_for: :ping do
    end

    step :second_wait, wait_for: :ping do
    end
  end

  class ResumableWaitWorkflow < GenevaDrive::Workflow
    resumable_step :process_items, wait_for: :batch_ready, max_iterations: 2 do |iter|
      iter.iterate_over([1, 2, 3, 4]) { |item| }
    end
  end

  setup do
    @user = create_user
    Thread.current[:consumption_healed] = true
  end

  teardown do
    Thread.current[:consumption_healed] = nil
  end

  # Builds a step execution attached to a signal, the way dispatch or the gate
  # would. Used to stage attachment shapes that only the DAG scheduler can
  # produce for real.
  def attach_execution(workflow, signal, step_name:, state:, outcome: nil)
    signal.claim!
    workflow.step_executions.create!(
      step_name: step_name,
      state: state,
      scheduled_for: Time.current,
      waiting_since: (state == "waiting") ? Time.current : nil,
      outcome: outcome,
      signal_id: signal.id
    )
  end

  test "a clean single-claimant run counts one claim and one consumption" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    signal = workflow.signal!(:payment_confirmed)

    assert_equal 0, signal.claimed
    assert_equal 0, signal.consumed

    perform_next_step(workflow)
    signal.reload

    assert_equal "consumed", signal.state
    assert_equal 1, signal.claimed
    assert_equal 1, signal.consumed
    assert_not_nil signal.claimed_at
    assert_not_nil signal.consumed_at
  end

  test "a skipping step consumes its signal too" do
    workflow = SkippingWorkflow.create!(hero: @user)
    signal = workflow.signal!(:payment_confirmed)

    perform_next_step(workflow)
    signal.reload

    assert_equal "consumed", signal.state
    assert_equal 1, signal.consumed
  end

  test "a retry re-attaching counts a second claim but only one consumption" do
    Thread.current[:consumption_healed] = false
    workflow = InvoiceWorkflow.create!(hero: @user)
    signal = workflow.signal!(:payment_confirmed)

    assert_raises(RuntimeError) { perform_next_step(workflow) }
    signal.reload

    assert_equal "claimed", signal.state
    assert_equal 1, signal.claimed
    assert_equal 0, signal.consumed
    first_claimed_at = signal.claimed_at

    Thread.current[:consumption_healed] = true
    workflow.resume!
    speedrun_workflow(workflow)
    signal.reload

    assert_equal "consumed", signal.state
    assert_equal 2, signal.claimed
    assert_equal 1, signal.consumed
    # claimed_at keeps meaning "when this event started being handled"
    assert_equal first_claimed_at.to_i, signal.claimed_at.to_i
  end

  test "successor executions carry the pin over without counting a new claim" do
    workflow = ResumableWaitWorkflow.create!(hero: @user)
    signal = workflow.signal!(:batch_ready, payload: {batch_id: "b1"})

    run_iterations(workflow, count: 2)
    assert_equal 1, signal.reload.claimed
    assert_equal 0, signal.consumed

    speedrun_current_step(workflow)
    signal.reload

    assert_operator workflow.step_executions.where(signal_id: signal.id).count, :>, 1
    assert_equal 1, signal.claimed
    assert_equal 1, signal.consumed
    assert_equal "consumed", signal.state
  end

  test "the signal stays claimed while another attached execution is still active" do
    workflow = TwoWaitersWorkflow.create!(hero: @user)
    workflow.current_execution.execute!
    assert_waiting_for_signal(workflow, :ping)

    signal = workflow.signal!(:ping)
    assert_equal 1, signal.reload.claimed

    # Stage a second attached execution, as a DAG salvo would produce
    attach_execution(workflow, signal, step_name: "second_wait", state: "waiting")
    assert_equal 2, signal.reload.claimed

    perform_next_step(workflow)
    signal.reload

    assert_equal "claimed", signal.state
    assert_equal 1, signal.consumed
    assert_nil signal.consumed_at
  end

  test "the flip happens when the last attached chain resolves" do
    workflow = TwoWaitersWorkflow.create!(hero: @user)
    signal = workflow.signal!(:ping)

    first = attach_execution(workflow, signal, step_name: "first_wait", state: "waiting")
    second = attach_execution(workflow, signal, step_name: "second_wait", state: "waiting")
    assert_equal 2, signal.reload.claimed

    first.update!(state: "completed", outcome: "success", completed_at: Time.current)
    signal.record_consumption!

    assert_equal "claimed", signal.state
    assert_equal 1, signal.consumed

    second.update!(state: "skipped", outcome: "skipped", skipped_at: Time.current)
    signal.record_consumption!

    assert_equal "consumed", signal.state
    assert_equal 2, signal.consumed
    assert_not_nil signal.consumed_at
  end

  test "claimed? and consumed? read the counters, not the lifecycle state" do
    workflow = TwoWaitersWorkflow.create!(hero: @user)
    signal = workflow.signal!(:ping)

    assert_equal "pending", signal.state
    assert_not signal.claimed?
    assert_not signal.consumed?

    execution = attach_execution(workflow, signal, step_name: "first_wait", state: "waiting")
    signal.reload

    assert_equal "claimed", signal.state
    assert signal.claimed?
    assert_not signal.consumed?

    # A second chain keeps the state at claimed, but the first clean
    # resolution already makes consumed? true
    second = attach_execution(workflow, signal, step_name: "second_wait", state: "waiting")
    execution.update!(state: "completed", outcome: "success")
    signal.record_consumption!

    assert_equal "claimed", signal.state
    assert signal.consumed?
    assert_equal 1, signal.consumed

    second.update!(state: "completed", outcome: "success")
    signal.record_consumption!

    assert_equal "consumed", signal.state
    assert signal.claimed?
    assert signal.consumed?
  end

  test "the state enum generates neither predicates nor scopes" do
    assert_not GenevaDrive::Signal.new.respond_to?(:pending?)
    assert_not GenevaDrive::Signal.respond_to?(:pending)

    # The names the enum would have taken belong to the counters
    assert_equal 0, GenevaDrive::Signal.new.claimed
    assert_equal 0, GenevaDrive::Signal.new.consumed
  end

  test "a signal with no attachments is vacuously resolved" do
    workflow = TwoWaitersWorkflow.create!(hero: @user)

    assert workflow.signal!(:ping).fully_resolved?
  end

  test "an unresolved chain keeps the signal from being fully resolved" do
    workflow = TwoWaitersWorkflow.create!(hero: @user)
    signal = workflow.signal!(:ping)
    # Free up the one-active slot so each staged state can occupy it in turn
    workflow.step_executions.update_all(state: "canceled", outcome: "canceled")

    %w[waiting scheduled in_progress].each_with_index do |state, index|
      execution = attach_execution(workflow, signal, step_name: "node_#{index}", state: state)
      assert_not signal.fully_resolved?, "expected #{state} to count as unresolved"
      execution.update!(state: "completed", outcome: "success")
    end

    assert signal.fully_resolved?
  end

  test "a chain whose latest execution failed or was canceled keeps the signal claimed" do
    workflow = TwoWaitersWorkflow.create!(hero: @user)
    signal = workflow.signal!(:ping)
    execution = attach_execution(workflow, signal, step_name: "first_wait", state: "failed", outcome: "failed")

    assert_not signal.fully_resolved?

    execution.update!(state: "canceled", outcome: "canceled")
    assert_not signal.fully_resolved?

    execution.update!(state: "completed", outcome: "success")
    assert signal.fully_resolved?
  end

  test "only the latest execution of a chain decides whether it resolved" do
    workflow = TwoWaitersWorkflow.create!(hero: @user)
    signal = workflow.signal!(:ping)

    attach_execution(workflow, signal, step_name: "first_wait", state: "completed", outcome: "continued")
    attach_execution(workflow, signal, step_name: "first_wait", state: "completed", outcome: "reattempted")

    assert_not signal.fully_resolved?

    attach_execution(workflow, signal, step_name: "first_wait", state: "completed", outcome: "success")

    assert signal.fully_resolved?
  end
end
