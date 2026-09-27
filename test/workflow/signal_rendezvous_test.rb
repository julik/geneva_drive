# frozen_string_literal: true

require "test_helper"

# The receiver side of the rendezvous, in both arrival orders: the gate that
# parks or attaches, and the dispatch that wakes a parked execution.
class SignalRendezvousTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers
  include ActiveJob::TestHelper

  class MinimumAmountMatcher
    def initialize(min_cents:)
      @min_cents = min_cents
    end

    def matches?(signal)
      signal.name == "payment_confirmed" && signal.payload[:amount_cents].to_i >= @min_cents
    end
  end

  class InvoiceWorkflow < GenevaDrive::Workflow
    step :prepare do
      Thread.current[:rendezvous_log] << :prepared
    end

    step :await_payment, wait_for: :payment_confirmed do
      Thread.current[:rendezvous_log] << [:captured, received_signal.payload[:amount_cents]]
    end

    step :issue_receipt do
      Thread.current[:rendezvous_log] << :receipt
    end
  end

  class FirstStepWaitsWorkflow < GenevaDrive::Workflow
    step :await_approval, wait_for: :approved do
      Thread.current[:rendezvous_log] << :approved
    end
  end

  class NarrowedWorkflow < GenevaDrive::Workflow
    step :await_payment,
      wait_for: :payment_confirmed,
      matching: ->(payload) { payload[:email] == hero.email } do
      Thread.current[:rendezvous_log] << :matched
    end
  end

  class MatcherObjectWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: MinimumAmountMatcher.new(min_cents: 1000) do
      Thread.current[:rendezvous_log] << :big_enough
    end
  end

  class DelayedWaitWorkflow < GenevaDrive::Workflow
    step :await_payment, wait: 2.days, wait_for: :payment_confirmed do
      Thread.current[:rendezvous_log] << :captured
    end
  end

  class TwoWaitersWorkflow < GenevaDrive::Workflow
    step :first_wait, wait_for: :ping do
      Thread.current[:rendezvous_log] << [:first, received_signal.id]
    end

    step :second_wait, wait_for: :ping do
      Thread.current[:rendezvous_log] << [:second, received_signal.id]
    end
  end

  class SkippableWaitWorkflow < GenevaDrive::Workflow
    step :await_signature, wait_for: :signed, skip_if: -> { Thread.current[:rendezvous_presigned] } do
      Thread.current[:rendezvous_log] << :signed
    end

    step :archive do
      Thread.current[:rendezvous_log] << :archived
    end
  end

  class FinishingWaitWorkflow < GenevaDrive::Workflow
    step :await_decision, wait_for: :decided do
      finished!
    end

    step :never_reached do
      Thread.current[:rendezvous_log] << :never
    end
  end

  class FlakyWaitWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: :payment_confirmed do
      Thread.current[:rendezvous_log] << [:attempt, received_signal.payload[:amount_cents]]
      raise "gateway unavailable" unless Thread.current[:rendezvous_healed]
    end
  end

  class ResumableWaitWorkflow < GenevaDrive::Workflow
    resumable_step :process_items, wait_for: :batch_ready, max_iterations: 2 do |iter|
      iter.iterate_over([1, 2, 3, 4]) do |item|
        Thread.current[:rendezvous_log] << [:item, item, received_signal.payload[:batch_id]]
      end
    end
  end

  class MatcherRaisingWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: :payment_confirmed, matching: ->(payload) { raise "matcher blew up" } do
      Thread.current[:rendezvous_log] << :never
    end
  end

  setup do
    @user = create_user
    Thread.current[:rendezvous_log] = []
    Thread.current[:rendezvous_presigned] = nil
    Thread.current[:rendezvous_healed] = nil
  end

  teardown do
    Thread.current[:rendezvous_log] = nil
    Thread.current[:rendezvous_presigned] = nil
    Thread.current[:rendezvous_healed] = nil
  end

  # --- Receiver arrives first (park, then wake) ---

  test "a waiting step parks instead of running, and holds no queue slot" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    execution = workflow.current_execution
    assert_equal "await_payment", execution.step_name
    assert_equal "scheduled", execution.state

    execution.execute!
    execution.reload

    assert_equal "waiting", execution.state
    assert_not_nil execution.waiting_since
    assert_nil execution.signal_id
    assert_waiting_for_signal(workflow, :payment_confirmed)
    assert_equal [:prepared], Thread.current[:rendezvous_log]
    assert_equal "ready", workflow.reload.state
  end

  test "dispatch wakes the parked execution and the step sees the payload" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    signal = workflow.signal!(:payment_confirmed, payload: {amount_cents: 12_500})

    execution = workflow.reload.current_execution
    assert_equal "scheduled", execution.state
    assert_equal signal.id, execution.signal_id
    assert_nil execution.waiting_since
    assert_equal "claimed", signal.reload.state
    assert_not_nil signal.claimed_at

    perform_next_step(workflow)

    assert_equal [:prepared, [:captured, 12_500]], Thread.current[:rendezvous_log]
    assert_equal "consumed", signal.reload.state
    assert_not_nil signal.consumed_at
  end

  test "dispatch enqueues a job for the woken execution" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    assert_enqueued_with(job: GenevaDrive::PerformStepJob) do
      workflow.signal!(:payment_confirmed)
    end
  end

  # --- Sender arrives first (buffer, then attach at the gate) ---

  test "a signal arriving before the waiting step is buffered and claimed at the gate" do
    workflow = InvoiceWorkflow.create!(hero: @user)

    signal = workflow.signal!(:payment_confirmed, payload: {amount_cents: 700})
    assert_equal "pending", signal.reload.state

    speedrun_workflow(workflow)

    assert_equal [:prepared, [:captured, 700], :receipt], Thread.current[:rendezvous_log]
    assert_equal "consumed", signal.reload.state
    assert_equal "finished", workflow.state
  end

  test "the first step of a workflow can wait for a signal" do
    workflow = FirstStepWaitsWorkflow.create!(hero: @user)
    workflow.current_execution.execute!

    assert_waiting_for_signal(workflow, :approved)

    workflow.signal!(:approved)
    speedrun_workflow(workflow)

    assert_equal [:approved], Thread.current[:rendezvous_log]
    assert_equal "finished", workflow.state
  end

  # --- Matching ---

  test "a non-matching name leaves the execution parked" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    workflow.signal!(:something_else)

    assert_equal "waiting", workflow.reload.current_execution.state
    assert_equal "pending", workflow.signals.last.reload.state
  end

  test "matching: narrows by payload and is evaluated on the workflow" do
    workflow = NarrowedWorkflow.create!(hero: @user)
    workflow.current_execution.execute!

    workflow.signal!(:payment_confirmed, payload: {email: "nobody@example.com"})
    assert_equal "waiting", workflow.reload.current_execution.state

    workflow.signal!(:payment_confirmed, payload: {email: @user.email})
    assert_equal "scheduled", workflow.reload.current_execution.state

    speedrun_workflow(workflow)
    assert_equal [:matched], Thread.current[:rendezvous_log]
  end

  test "a matcher object owns the whole predicate" do
    workflow = MatcherObjectWorkflow.create!(hero: @user)
    workflow.current_execution.execute!

    workflow.signal!(:payment_confirmed, payload: {amount_cents: 100})
    assert_equal "waiting", workflow.reload.current_execution.state

    workflow.signal!(:payment_confirmed, payload: {amount_cents: 5000})
    speedrun_workflow(workflow)

    assert_equal [:big_enough], Thread.current[:rendezvous_log]
  end

  test "the oldest matching signal wins at the gate" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)

    first = workflow.signal!(:payment_confirmed, payload: {amount_cents: 1})
    workflow.signal!(:payment_confirmed, payload: {amount_cents: 2})

    perform_next_step(workflow)

    assert_equal [:prepared, [:captured, 1]], Thread.current[:rendezvous_log]
    assert_equal first.id, workflow.step_executions.find_by(step_name: "await_payment").signal_id
  end

  test "a matcher raising at the gate goes through the exception machinery" do
    workflow = MatcherRaisingWorkflow.create!(hero: @user)
    workflow.signal!(:payment_confirmed)

    assert_raises(RuntimeError) { perform_next_step(workflow) }

    assert_equal "paused", workflow.reload.state
    assert_equal [], Thread.current[:rendezvous_log]
  end

  test "a matcher raising at dispatch raises to the sender" do
    workflow = MatcherRaisingWorkflow.create!(hero: @user)
    workflow.current_execution.execute!
    assert_waiting_for_signal(workflow)

    assert_raises(RuntimeError) { workflow.signal!(:payment_confirmed) }

    # The row is committed regardless, so redelivery is safe
    assert_equal 1, workflow.signals.count
  end

  # --- Composition with other step options ---

  test "wait: and wait_for: compose" do
    workflow = DelayedWaitWorkflow.create!(hero: @user)
    execution = workflow.current_execution

    assert execution.scheduled_for > 1.day.from_now

    # A signal arriving during the delay is simply buffered
    workflow.signal!(:payment_confirmed)
    assert_equal "pending", workflow.signals.last.reload.state

    execution.execute!

    assert_equal [:captured], Thread.current[:rendezvous_log]
    assert_equal "consumed", workflow.signals.last.reload.state
  end

  test "skip_if beats waiting - a skippable step never parks" do
    Thread.current[:rendezvous_presigned] = true
    workflow = SkippableWaitWorkflow.create!(hero: @user)

    speedrun_workflow(workflow)

    assert_equal [:archived], Thread.current[:rendezvous_log]
    assert_step_executed(workflow, :await_signature, state: "skipped")
    assert_equal "finished", workflow.state
  end

  test "skip_if is re-evaluated when the signal wakes the step" do
    workflow = SkippableWaitWorkflow.create!(hero: @user)
    workflow.current_execution.execute!
    assert_waiting_for_signal(workflow, :signed)

    Thread.current[:rendezvous_presigned] = true
    workflow.signal!(:signed)
    speedrun_workflow(workflow)

    assert_equal [:archived], Thread.current[:rendezvous_log]
    assert_step_executed(workflow, :await_signature, state: "skipped")
  end

  test "two sequential steps waiting on the same name consume one signal each" do
    workflow = TwoWaitersWorkflow.create!(hero: @user)
    first_signal = workflow.signal!(:ping)

    perform_next_step(workflow)
    assert_equal [[:first, first_signal.id]], Thread.current[:rendezvous_log]
    assert_equal "consumed", first_signal.reload.state

    # The second step parks: the only signal so far has been consumed
    workflow.current_execution.execute!
    assert_waiting_for_signal(workflow, :ping)

    second_signal = workflow.signal!(:ping)
    perform_next_step(workflow)

    assert_equal [[:first, first_signal.id], [:second, second_signal.id]], Thread.current[:rendezvous_log]
    assert_equal "consumed", second_signal.reload.state
  end

  test "finished! from a waiting step consumes its signal" do
    workflow = FinishingWaitWorkflow.create!(hero: @user)
    signal = workflow.signal!(:decided)

    perform_next_step(workflow)

    assert_equal "finished", workflow.reload.state
    assert_equal "consumed", signal.reload.state
    assert_equal [], Thread.current[:rendezvous_log]
  end

  # --- Redelivery across attempts ---

  test "a reattempt re-reads the same claimed signal" do
    workflow = FlakyWaitWorkflow.create!(hero: @user)
    signal = workflow.signal!(:payment_confirmed, payload: {amount_cents: 42})

    assert_raises(RuntimeError) { perform_next_step(workflow) }
    assert_equal "paused", workflow.reload.state
    assert_equal "claimed", signal.reload.state

    Thread.current[:rendezvous_healed] = true
    workflow.resume!
    speedrun_workflow(workflow)

    assert_equal [[:attempt, 42], [:attempt, 42]], Thread.current[:rendezvous_log]
    assert_equal "consumed", signal.reload.state
    assert_equal "finished", workflow.state
  end

  test "signals delivered while paused are dispatched on resume" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!
    assert_waiting_for_signal(workflow, :payment_confirmed)

    workflow.pause!
    signal = workflow.signal!(:payment_confirmed, payload: {amount_cents: 99})

    assert_equal "pending", signal.reload.state
    assert_equal "waiting", workflow.reload.current_execution.state

    workflow.resume!

    execution = workflow.reload.current_execution
    assert_equal "scheduled", execution.state
    assert_equal signal.id, execution.signal_id

    speedrun_workflow(workflow)
    assert_equal [:prepared, [:captured, 99], :receipt], Thread.current[:rendezvous_log]
  end

  test "resume! leaves a parked execution parked when nothing matches" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    workflow.pause!
    workflow.resume!

    assert_equal "ready", workflow.reload.state
    assert_equal "waiting", workflow.current_execution.state
  end

  test "a workflow paused between dispatch and execution re-attaches on resume" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    signal = workflow.signal!(:payment_confirmed, payload: {amount_cents: 5})
    workflow.pause!

    # The job runs while paused: prepare cancels the execution
    workflow.step_executions.find_by(state: "scheduled").execute!
    assert_equal "claimed", signal.reload.state

    workflow.reload.resume!
    speedrun_workflow(workflow)

    assert_equal [:prepared, [:captured, 5], :receipt], Thread.current[:rendezvous_log]
    assert_equal "consumed", signal.reload.state
  end

  # --- External verbs ---

  test "cancel! cancels a parked execution and leaves the signal claimed" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    workflow.cancel!

    assert_equal "canceled", workflow.reload.state
    assert_equal "canceled", workflow.step_executions.find_by(step_name: "await_payment").state
  end

  test "skip! is the operator escape hatch for a parked step" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!
    assert_waiting_for_signal(workflow)

    workflow.skip!

    assert_step_executed(workflow, :await_payment, state: "skipped")
    speedrun_workflow(workflow)

    assert_equal [:prepared, :receipt], Thread.current[:rendezvous_log]
    assert_equal "finished", workflow.state
  end

  test "a parked execution is swept when a new execution is created past it" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    parked = workflow.current_execution
    parked.execute!
    assert_equal "waiting", parked.reload.state

    workflow.reschedule_current_step!

    assert_equal "canceled", parked.reload.state
    assert_equal 1, workflow.step_executions.where(state: "scheduled").count
  end

  # --- Resumable chains ---

  test "a resumable step gates once and carries the pin across successors" do
    workflow = ResumableWaitWorkflow.create!(hero: @user)
    signal = workflow.signal!(:batch_ready, payload: {batch_id: "b1"})

    # Interrupt after two items so the step continues through a successor
    run_iterations(workflow, count: 2)
    successor = workflow.reload.current_execution
    assert_equal signal.id, successor.signal_id
    assert_equal "scheduled", successor.state

    speedrun_current_step(workflow)

    logged_batches = Thread.current[:rendezvous_log].map(&:last).uniq
    assert_equal ["b1"], logged_batches
    assert_equal 4, Thread.current[:rendezvous_log].size

    executions = workflow.step_executions.where(step_name: "process_items").order(:id)
    assert executions.count > 1, "expected a chain of executions"
    assert executions.all? { |execution| execution.signal_id == signal.id }
    assert_equal "consumed", signal.reload.state
  end

  # --- Duplicates ---

  test "a duplicate signal delivered while one is claimed just buffers" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    claimed = workflow.signal!(:payment_confirmed, payload: {amount_cents: 1})
    buffered = workflow.signal!(:payment_confirmed, payload: {amount_cents: 2})

    assert_equal "claimed", claimed.reload.state
    assert_equal "pending", buffered.reload.state

    perform_next_step(workflow)

    assert_equal [:prepared, [:captured, 1]], Thread.current[:rendezvous_log]
    assert_equal "consumed", claimed.reload.state
    assert_equal "pending", buffered.reload.state
  end

  test "a deduplicated redelivery does not dispatch twice" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    workflow.signal!(:payment_confirmed, idempotency_key: "evt_1")
    execution_id = workflow.reload.current_execution.id

    duplicate = workflow.signal!(:payment_confirmed, idempotency_key: "evt_1")

    assert duplicate.duplicate_delivery?
    assert_equal execution_id, workflow.reload.current_execution.id
    assert_equal 1, workflow.signals.count
  end

  # --- Test helper guardrails ---

  test "step-driving helpers refuse to spin on a parked execution" do
    workflow = InvoiceWorkflow.create!(hero: @user)
    perform_next_step(workflow)
    workflow.current_execution.execute!

    error = assert_raises(RuntimeError) { speedrun_workflow(workflow) }
    assert_match(/parked/, error.message)
    assert_match(/payment_confirmed/, error.message)

    error = assert_raises(RuntimeError) { perform_next_step(workflow) }
    assert_match(/parked/, error.message)
  end
end
