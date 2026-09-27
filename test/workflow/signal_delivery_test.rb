# frozen_string_literal: true

require "test_helper"

# The sender side of the rendezvous: Workflow#signal! and the Signal record
# itself. The receiver side (gate, park, wake) lives in
# signal_rendezvous_test.rb.
class SignalDeliveryTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class InvoiceWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: :payment_confirmed do
      Thread.current[:signal_delivery_amount] = received_signal.payload[:amount_cents]
    end

    step :issue_receipt do
    end
  end

  class PlainWorkflow < GenevaDrive::Workflow
    step :only_step do
    end
  end

  setup do
    @user = create_user
    Thread.current[:signal_delivery_amount] = nil
  end

  teardown do
    Thread.current[:signal_delivery_amount] = nil
  end

  test "signal! persists a pending signal" do
    workflow = PlainWorkflow.create!(hero: @user)

    signal = workflow.signal!(:something_happened, payload: {order_id: 42})

    assert signal.persisted?
    assert_equal "something_happened", signal.name
    assert_equal "pending", signal.state
    assert_nil signal.claimed_at
    assert_nil signal.consumed_at
    assert_not signal.duplicate_delivery?
    assert_equal workflow.id, signal.workflow_id
  end

  test "payload comes back with indifferent access" do
    workflow = PlainWorkflow.create!(hero: @user)

    workflow.signal!(:webhook, payload: {"order_id" => 42, :amount_cents => 100})
    signal = workflow.signals.last.reload

    assert_equal 42, signal.payload[:order_id]
    assert_equal 42, signal.payload["order_id"]
    assert_equal 100, signal.payload[:amount_cents]
    assert_equal 100, signal.payload["amount_cents"]
  end

  test "payload round-trips types through ActiveJob serialization" do
    workflow = PlainWorkflow.create!(hero: @user)
    moment = Time.current.change(usec: 0)

    workflow.signal!(:webhook, payload: {at: moment, hero: @user})
    signal = workflow.signals.last.reload

    assert_equal moment, signal.payload[:at]
    assert_equal @user, signal.payload[:hero]
  end

  test "non-hash payloads are returned as-is" do
    workflow = PlainWorkflow.create!(hero: @user)

    workflow.signal!(:webhook, payload: "just a string")

    assert_equal "just a string", workflow.signals.last.reload.payload
  end

  test "an empty payload is the default" do
    workflow = PlainWorkflow.create!(hero: @user)

    signal = workflow.signal!(:webhook)

    assert_equal({}, signal.reload.payload)
  end

  test "signal! requires a name" do
    workflow = PlainWorkflow.create!(hero: @user)

    assert_raises(ArgumentError) { workflow.signal!(nil) }
    assert_raises(ArgumentError) { workflow.signal!("") }
  end

  test "signal! rejects unknown options so the keyword surface stays usable" do
    workflow = PlainWorkflow.create!(hero: @user)

    error = assert_raises(ArgumentError) { workflow.signal!(:webhook, timeout: 5.minutes) }
    assert_match(/timeout/, error.message)
  end

  test "an oversized payload raises before anything is persisted" do
    workflow = PlainWorkflow.create!(hero: @user)
    original = GenevaDrive.max_signal_payload_size
    GenevaDrive.max_signal_payload_size = 64

    error = assert_raises(GenevaDrive::SignalPayloadTooLargeError) do
      workflow.signal!(:webhook, payload: {blob: "x" * 1024})
    end

    assert_match(/max_signal_payload_size/, error.message)
    assert_equal 0, workflow.signals.count
  ensure
    GenevaDrive.max_signal_payload_size = original
  end

  test "the payload bound can be disabled" do
    workflow = PlainWorkflow.create!(hero: @user)
    original = GenevaDrive.max_signal_payload_size
    GenevaDrive.max_signal_payload_size = nil

    signal = workflow.signal!(:webhook, payload: {blob: "x" * 1024})

    assert signal.persisted?
  ensure
    GenevaDrive.max_signal_payload_size = original
  end

  test "redelivery with the same idempotency key returns the original row" do
    workflow = PlainWorkflow.create!(hero: @user)

    first = workflow.signal!(:webhook, payload: {n: 1}, idempotency_key: "evt_1")
    second = workflow.signal!(:webhook, payload: {n: 2}, idempotency_key: "evt_1")

    assert_equal first.id, second.id
    assert second.duplicate_delivery?
    assert_not first.duplicate_delivery?
    assert_equal 1, workflow.signals.count
    # The first payload wins - the duplicate is a no-op, not an update
    assert_equal 1, second.payload[:n]
  end

  test "the same idempotency key under a different name is a different signal" do
    workflow = PlainWorkflow.create!(hero: @user)

    workflow.signal!(:webhook_a, idempotency_key: "evt_1")
    workflow.signal!(:webhook_b, idempotency_key: "evt_1")

    assert_equal 2, workflow.signals.count
  end

  test "the same idempotency key on a different workflow is a different signal" do
    other_user = create_user(email: "other@example.com")
    workflow = PlainWorkflow.create!(hero: @user)
    other_workflow = PlainWorkflow.create!(hero: other_user)

    workflow.signal!(:webhook, idempotency_key: "evt_1")
    other_workflow.signal!(:webhook, idempotency_key: "evt_1")

    assert_equal 1, workflow.signals.count
    assert_equal 1, other_workflow.signals.count
  end

  test "signals without an idempotency key never deduplicate" do
    workflow = PlainWorkflow.create!(hero: @user)

    workflow.signal!(:webhook)
    workflow.signal!(:webhook)

    assert_equal 2, workflow.signals.count
  end

  test "signal! on a finished workflow raises WorkflowNotOngoing" do
    workflow = PlainWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)
    assert_equal "finished", workflow.state

    error = assert_raises(GenevaDrive::WorkflowNotOngoing) { workflow.signal!(:webhook) }

    assert_match(/finished workflow/, error.message)
    assert_equal 0, workflow.signals.count
  end

  test "signal! on a canceled workflow raises WorkflowNotOngoing" do
    workflow = PlainWorkflow.create!(hero: @user)
    workflow.cancel!

    assert_raises(GenevaDrive::WorkflowNotOngoing) { workflow.signal!(:webhook) }
  end

  test "redelivery of the event that finished the workflow is a no-op" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    workflow.signal!(:payment_confirmed, payload: {amount_cents: 500}, idempotency_key: "evt_1")
    speedrun_workflow(workflow)
    assert_equal "finished", workflow.state

    redelivered = workflow.signal!(:payment_confirmed, payload: {amount_cents: 500}, idempotency_key: "evt_1")

    assert redelivered.duplicate_delivery?
    assert_equal 1, workflow.signals.count
  end

  test "a new event on a finished workflow still raises even when other signals exist" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    workflow.signal!(:payment_confirmed, idempotency_key: "evt_1")
    speedrun_workflow(workflow)

    assert_raises(GenevaDrive::WorkflowNotOngoing) do
      workflow.signal!(:payment_confirmed, idempotency_key: "evt_2")
    end
  end

  test "signal! survives an enclosing transaction thanks to the savepoint" do
    workflow = PlainWorkflow.create!(hero: @user)
    workflow.signal!(:webhook, idempotency_key: "evt_1")

    GenevaDrive::Workflow.transaction do
      duplicate = workflow.signal!(:webhook, idempotency_key: "evt_1")
      assert duplicate.duplicate_delivery?

      # The enclosing transaction is still usable
      workflow.signal!(:other_webhook)
    end

    assert_equal 2, workflow.signals.count
  end

  test "signals can still be recorded for a workflow whose class was removed" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!
    assert_waiting_for_signal(workflow, :payment_confirmed)

    # The class is gone: STI resolution falls back to the base Workflow, which
    # has no step definitions - so no matcher can be resolved and nothing is
    # woken, but the row is still written.
    GenevaDrive::Workflow.where(id: workflow.id).update_all(type: "DeletedInvoiceWorkflow")
    orphan = GenevaDrive::Workflow.find(workflow.id)
    assert_equal GenevaDrive::Workflow, orphan.class

    signal = orphan.signal!(:payment_confirmed)

    assert signal.persisted?
    assert_equal "pending", signal.reload.state
    assert_equal "waiting", orphan.current_execution.state
  end

  test "signals are deleted with their workflow" do
    workflow = PlainWorkflow.create!(hero: @user)
    workflow.signal!(:webhook)

    assert_difference -> { GenevaDrive::Signal.count }, -1 do
      workflow.destroy!
    end
  end
end
