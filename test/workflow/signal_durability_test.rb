# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Delivering a signal is one database transaction: the INSERT, the
# waiting-execution scan, the attach, the state flip and the counter bumps all
# land together or not at all. Anything less is a lost wakeup - a pending
# signal sitting next to a waiting execution with nothing left to introduce
# them - so these tests pin the atomicity rather than trusting the reading.
class SignalDurabilityTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class InvoiceWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: :payment_confirmed do
    end

    step :issue_receipt do
    end
  end

  setup do
    @user = create_user
    @workflow = InvoiceWorkflow.create!(hero: @user)
    @workflow.current_execution.execute!
    @workflow.reload
    @parked = @workflow.current_execution
    assert_equal "waiting", @parked.state
  end

  # Fails the last write of the dispatch path, after the signal row and the
  # execution have already been mutated inside the transaction.
  def failing_late_in_dispatch(workflow)
    workflow.stub(:enqueue_woken_execution, ->(_execution, _step_def) { raise "crash after the rows moved" }) do
      yield
    end
  end

  test "a failure late in dispatch rolls the whole delivery back" do
    original_scheduled_for = @parked.scheduled_for
    original_waiting_since = @parked.waiting_since

    failing_late_in_dispatch(@workflow) do
      assert_raises(RuntimeError) { @workflow.signal!(:payment_confirmed, payload: {amount_cents: 10}) }
    end

    assert_equal 0, @workflow.signals.count

    @parked.reload
    assert_equal "waiting", @parked.state
    assert_nil @parked.signal_id
    assert_equal original_scheduled_for.to_i, @parked.scheduled_for.to_i
    assert_equal original_waiting_since.to_i, @parked.waiting_since.to_i
  end

  test "a failed redelivery leaves the previously buffered signal untouched" do
    buffered = @workflow.signal!(:unrelated_event, idempotency_key: "evt_0")
    assert_equal "pending", buffered.reload.state
    assert_equal 0, buffered.claimed

    failing_late_in_dispatch(@workflow) do
      assert_raises(RuntimeError) { @workflow.signal!(:payment_confirmed, idempotency_key: "evt_1") }
    end

    assert_equal 1, @workflow.signals.count
    buffered.reload
    assert_equal "pending", buffered.state
    assert_equal 0, buffered.claimed
    assert_equal 0, buffered.consumed
    assert_equal "waiting", @parked.reload.state
  end

  test "every effect of a delivery is undone by an enclosing rollback" do
    signal_id = nil

    GenevaDrive::Workflow.transaction(requires_new: true) do
      signal = @workflow.signal!(:payment_confirmed)
      signal_id = signal.id

      # Inside the transaction everything is in place
      assert_equal "claimed", signal.reload.state
      assert_equal 1, signal.claimed
      assert_equal "scheduled", @parked.reload.state
      assert_equal signal.id, @parked.signal_id

      raise ActiveRecord::Rollback
    end

    assert_not GenevaDrive::Signal.exists?(signal_id)
    assert_equal 0, @workflow.signals.count

    @parked.reload
    assert_equal "waiting", @parked.state
    assert_nil @parked.signal_id
    assert_not_nil @parked.waiting_since
  end

  test "the workflow is locked before the signal is persisted" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    begin
      @workflow.signal!(:payment_confirmed)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # with_lock reloads the workflow row; that read has to happen before the
    # INSERT, otherwise the signal is persisted in a transaction of its own and
    # a crash before dispatch loses the wakeup. (SQLite has no SELECT ... FOR
    # UPDATE, so the reload itself is what all three adapters have in common.)
    lock_at = statements.index { |sql| sql.match?(/SELECT.*FROM ["`]?geneva_drive_workflows/i) }
    insert_at = statements.index { |sql| sql.match?(/INSERT INTO ["`]?geneva_drive_signals/i) }

    assert lock_at, "expected the workflow row to be locked: #{statements.inspect}"
    assert insert_at, "expected the signal INSERT: #{statements.inspect}"
    assert_operator lock_at, :<, insert_at
  end

  test "no commit separates the signal insert from the execution activation" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    begin
      @workflow.signal!(:payment_confirmed)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    insert_at = statements.index { |sql| sql.match?(/INSERT INTO ["`]?geneva_drive_signals/i) }
    activation_at = statements.rindex do |sql|
      sql.match?(/UPDATE ["`]?geneva_drive_step_executions/i) && sql.match?(/waiting_since/i)
    end

    assert insert_at, "expected the signal INSERT in #{statements.inspect}"
    assert activation_at, "expected the execution activation UPDATE in #{statements.inspect}"
    assert_operator insert_at, :<, activation_at

    between = statements[insert_at..activation_at]
    assert_empty between.grep(/\Acommit/i),
      "the signal INSERT was committed before the execution was activated: #{between.inspect}"
  end

  test "a duplicate delivery inside a caller's transaction does not poison it" do
    @workflow.signal!(:payment_confirmed, idempotency_key: "evt_1")

    GenevaDrive::Workflow.transaction do
      duplicate = @workflow.signal!(:payment_confirmed, idempotency_key: "evt_1")
      assert duplicate.duplicate_delivery?

      # The savepoint absorbed the unique violation, so the caller's
      # transaction is still usable (this is where PostgreSQL would otherwise
      # refuse every subsequent statement)
      @workflow.signal!(:another_event)
      assert_equal 2, @workflow.signals.count
    end

    assert_equal 2, @workflow.signals.reload.count
  end
end
