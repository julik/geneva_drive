# frozen_string_literal: true

# Mongoid tests run only under `rake test:mongoid`, which boots the dummy app
# against MongoDB (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"

# The proof obligations from MONGOID_DESIGN.md: these tests run real threads
# against the live replica set and demonstrate that the document-lock
# transaction wrapper preserves the SQL implementation's transactional
# guarantees.
class AtomicTransitionsTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class RaceWorkflow < GenevaDrive::MongoidWorkflow
    step :one do
    end

    step :two do
    end

    step :three do
    end
  end

  THREADS = 8

  # Proof obligation 1: N threads race signal! with the same idempotency key
  # -> exactly one signal row, counters coherent.
  test "threads racing signal! with one idempotency key produce exactly one signal row" do
    user = create_user
    workflow = RaceWorkflow.create!(hero: user)

    barrier = Queue.new
    results = Queue.new
    threads = THREADS.times.map do
      Thread.new do
        own_copy = GenevaDrive::MongoidWorkflow.find(workflow.id)
        barrier.pop
        results << own_copy.signal!(:payment, payload: {n: 1}, idempotency_key: "evt-1")
      rescue => e
        results << e
      end
    end
    THREADS.times { barrier << true }
    threads.each(&:join)

    delivered = Array.new(THREADS) { results.pop }
    errors = delivered.select { |r| r.is_a?(Exception) }
    assert_empty errors, "no delivery may error: #{errors.map(&:message)}"

    assert_equal 1, workflow.signals.count
    signal = workflow.signals.first
    assert_equal "payment", signal.name
    assert_equal "evt-1", signal.idempotency_key
    assert_equal THREADS - 1, delivered.count(&:duplicate_delivery?),
      "all but one delivery must be flagged duplicate"
    assert delivered.all? { |s| s.id == signal.id }
    # Nothing attached to it (no step waits for it), so counters stay zero
    assert_equal 0, signal.claimed
    assert_equal 0, signal.consumed
    assert_equal "pending", signal.state
  end

  # Proof obligation 2: threads race executor-style transitions against a
  # stepping workflow -> no corruption, never more than one active execution.
  test "racing pause, resume, cancel and execution never corrupt the invariants" do
    user = create_user
    workflow = RaceWorkflow.create!(hero: user)

    violations = Queue.new
    stop = false
    watcher = Thread.new do
      until stop
        count = GenevaDrive::MongoidStepExecution
          .where(:workflow_id => workflow.id, :state.in => %w[scheduled in_progress])
          .count
        violations << count if count > 1
        sleep 0.001
      end
    end

    rescued = [
      GenevaDrive::InvalidStateError,
      GenevaDrive::InvalidStateTransition,
      GenevaDrive::StepExecutionError,
      Mongoid::Errors::DocumentNotFound
    ]

    stepper = Thread.new do
      20.times do
        w = GenevaDrive::MongoidWorkflow.find(workflow.id)
        begin
          w.current_execution&.execute!
        rescue *rescued
        end
      end
    end

    # pause!/resume! can observe state == "performing" written by the racing
    # stepper, in which case flow control throws :flow_control as if called
    # from inside a step. Catch it - there is no executor to catch it here,
    # and the point of this test is the invariants, not the throw.
    pauser = Thread.new do
      20.times do
        w = GenevaDrive::MongoidWorkflow.find(workflow.id)
        begin
          catch(:flow_control) { w.pause! }
        rescue *rescued
        end
        sleep 0.002
      end
    end

    resumer = Thread.new do
      20.times do
        w = GenevaDrive::MongoidWorkflow.find(workflow.id)
        begin
          catch(:flow_control) { w.resume! }
        rescue *rescued
        end
        sleep 0.002
      end
    end

    [stepper, pauser, resumer].each(&:join)
    stop = true
    watcher.join

    overcounts = []
    overcounts << violations.pop until violations.empty?
    assert_empty overcounts, "saw more than one active execution at once: #{overcounts}"

    workflow.reload
    assert_includes %w[ready performing finished paused], workflow.state

    # Every execution landed in a legal state with a legal outcome
    workflow.step_executions.each do |execution|
      assert_includes %w[scheduled waiting in_progress completed failed canceled skipped], execution.state
      assert_includes GenevaDrive::MongoidStepExecution::OUTCOMES + [nil], execution.outcome
    end

    # And the invariant holds at rest too
    active = workflow.step_executions.where(:state.in => %w[scheduled in_progress]).count
    assert_operator active, :<=, 1
  end

  # Proof obligation 2b: the unique index itself rejects a second active row,
  # independent of any application code.
  test "the active-execution unique index rejects a direct duplicate insert" do
    user = create_user
    workflow = RaceWorkflow.create!(hero: user)
    assert workflow.current_execution

    error = assert_raises(Mongo::Error::OperationFailure) do
      GenevaDrive::MongoidStepExecution.collection.insert_one(
        workflow_id: workflow.id,
        step_name: "one",
        state: "scheduled",
        scheduled_for: Time.current,
        active_key: workflow.id
      )
    end
    assert GenevaDrive::DocumentLock.duplicate_key_error?(error)
  end

  # Proof obligation 2c: the ongoing-workflow unique index likewise.
  test "the ongoing-workflow unique index rejects a direct duplicate insert" do
    user = create_user
    workflow = RaceWorkflow.create!(hero: user)

    error = assert_raises(Mongo::Error::OperationFailure) do
      GenevaDrive::MongoidWorkflow.collection.insert_one(
        _type: "AtomicTransitionsTest::RaceWorkflow",
        state: "ready",
        hero_type: "MongoUser",
        hero_id: user.id,
        allow_multiple: false,
        ongoing_key: workflow.reload.ongoing_key
      )
    end
    assert GenevaDrive::DocumentLock.duplicate_key_error?(error)
  end

  # Proof obligation 3: threads race create! of the same non-allow_multiple
  # workflow -> exactly one ongoing survives; losers get a validation error
  # or a duplicate-key error, never a second row.
  test "threads racing create! of the same workflow leave exactly one ongoing" do
    user = create_user

    barrier = Queue.new
    outcomes = Queue.new
    threads = 4.times.map do
      Thread.new do
        barrier.pop
        outcomes << RaceWorkflow.create!(hero: user)
      rescue => e
        outcomes << e
      end
    end
    4.times { barrier << true }
    threads.each(&:join)

    results = Array.new(4) { outcomes.pop }
    winners = results.grep(GenevaDrive::MongoidWorkflow)
    losers = results - winners

    assert_operator winners.size, :>=, 1
    assert_equal 1, GenevaDrive::MongoidWorkflow.where(:state.nin => %w[finished canceled], :hero_id => user.id).count
    assert_equal 1, GenevaDrive::MongoidWorkflow.where(hero_id: user.id).count,
      "the losers' inserts must have been rejected outright"

    losers.each do |e|
      acceptable = e.is_a?(Mongoid::Errors::Validations) ||
        (e.is_a?(Mongo::Error::OperationFailure) && GenevaDrive::DocumentLock.duplicate_key_error?(e))
      assert acceptable, "loser got unexpected #{e.class}: #{e.message}"
    end
  end

  # Proof obligation 4: an exception inside a locked block after several
  # writes rolls back everything - rows AND the deferred job enqueues.
  test "an exception inside a locked block discards all writes and enqueues nothing" do
    user = create_user
    workflow = RaceWorkflow.create!(hero: user)
    perform_next_step(workflow)
    workflow.reload

    executions_before = workflow.step_executions.pluck(:_id, :state, :outcome).sort_by { |id, _, _| id.to_s }
    signals_before = workflow.signals.count
    enqueued_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    state_before = workflow.state
    next_step_before = workflow.next_step_name
    lock_version_before = workflow.lock_version

    boom = Class.new(StandardError)
    assert_raises(boom) do
      workflow.with_lock do
        # A realistic multi-write transition: cancel strays, insert a new
        # execution, update the workflow, register the job enqueue...
        workflow.send(:create_step_execution, RaceWorkflow.steps.named("three"), wait: nil)
        workflow.signals.create!(name: "ghost", state: "pending")
        # ...and then die before commit.
        raise boom
      end
    end

    workflow.reload
    assert_equal state_before, workflow.state
    assert_equal next_step_before, workflow.next_step_name
    assert_equal lock_version_before, workflow.lock_version, "even the lock write must roll back"
    assert_equal signals_before, workflow.signals.count
    assert_equal executions_before,
      workflow.step_executions.pluck(:_id, :state, :outcome).sort_by { |id, _, _| id.to_s }
    assert_equal enqueued_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size,
      "the deferred enqueue must be discarded with the rollback"
  end
end
