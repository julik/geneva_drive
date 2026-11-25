# frozen_string_literal: true

# Mongoid tests run only under `rake test:mongoid`, which boots the dummy app
# against MongoDB (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"
require "minitest/mock"

# Delivering a signal is one database transaction: the INSERT, the
# waiting-execution scan, the attach, the state flip and the counter bumps all
# land together or not at all. Anything less is a lost wakeup - a pending
# signal sitting next to a waiting execution with nothing left to introduce
# them - so these tests pin the atomicity rather than trusting the reading.
class SignalDurabilityTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class InvoiceWorkflow < GenevaDrive::MongoidWorkflow
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

    enclosing_mongoid_transaction do
      signal = @workflow.signal!(:payment_confirmed)
      signal_id = signal.id

      # Inside the transaction everything is in place
      assert_equal "claimed", signal.reload.state
      assert_equal 1, signal.claimed
      assert_equal "scheduled", @parked.reload.state
      assert_equal signal.id, @parked.signal_id

      raise RollbackEnclosingTransaction
    end

    assert_not GenevaDrive::MongoidSignal.where(_id: signal_id).exists?
    assert_equal 0, @workflow.signals.count

    @parked.reload
    assert_equal "waiting", @parked.state
    assert_nil @parked.signal_id
    assert_not_nil @parked.waiting_since
  end

  test "the workflow is locked before the signal is persisted" do
    commands = capture_mongo_commands do
      @workflow.signal!(:payment_confirmed)
    end

    # The document lock is the findAndModify $inc on the workflow document;
    # it has to happen before the signal insert, otherwise the signal is
    # persisted outside the serialized critical section and a crash before
    # dispatch loses the wakeup.
    lock_at = commands.index { |c| c["findAndModify"] == "geneva_drive_workflows" }
    insert_at = commands.index { |c| c["insert"] == "geneva_drive_signals" }

    assert lock_at, "expected the workflow document lock: #{command_names(commands).inspect}"
    assert insert_at, "expected the signal insert: #{command_names(commands).inspect}"
    assert_operator lock_at, :<, insert_at
  end

  test "no commit separates the signal insert from the execution activation" do
    commands = capture_mongo_commands do
      @workflow.signal!(:payment_confirmed)
    end

    insert_at = commands.index { |c| c["insert"] == "geneva_drive_signals" }
    activation_at = commands.rindex { |c|
      c["update"] == "geneva_drive_step_executions" &&
        c["updates"].to_s.include?("waiting_since")
    }

    assert insert_at, "expected the signal insert in #{command_names(commands).inspect}"
    assert activation_at, "expected the execution activation update in #{command_names(commands).inspect}"
    assert_operator insert_at, :<, activation_at

    between = commands[insert_at..activation_at]
    assert_empty between.select { |c| c.key?("commitTransaction") },
      "the signal insert was committed before the execution was activated"
  end

  test "a duplicate delivery inside a caller's transaction does not poison it" do
    @workflow.signal!(:payment_confirmed, idempotency_key: "evt_1")

    enclosing_mongoid_transaction do
      duplicate = @workflow.signal!(:payment_confirmed, idempotency_key: "evt_1")
      assert duplicate.duplicate_delivery?

      # The dedup is a read-before-insert under the lock, so the caller's
      # transaction is never aborted by a unique-index violation
      @workflow.signal!(:another_event)
      # count does not ride the transaction session in Mongoid; to_a does
      assert_equal 2, @workflow.signals.to_a.size
    end

    assert_equal 2, @workflow.reload.signals.count
  end

  private

  # Captures the MongoDB commands issued inside the block, as command
  # documents (hashes keyed by command name: "insert", "update",
  # "findAndModify", "commitTransaction", ...).
  #
  # @return [Array<Hash>]
  def capture_mongo_commands
    events = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) do |event|
      events << event.command.to_h
    rescue
      events << {}
    end
    subscriber.define_singleton_method(:succeeded) { |_event| }
    subscriber.define_singleton_method(:failed) { |_event| }

    client = GenevaDrive::MongoidWorkflow.collection.client
    client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    begin
      yield
    ensure
      client.monitoring.subscribers[Mongo::Monitoring::COMMAND]&.delete(subscriber)
    end
    events
  end

  def command_names(commands)
    commands.map { |c| c.keys.first }
  end
end
