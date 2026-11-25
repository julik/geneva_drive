# frozen_string_literal: true

# The concurrency proof pack: adversarial race proofs that run real threads
# against a live database and demonstrate that the transactional guarantees
# hold. The proofs drive only the public API and are backend-agnostic - the
# same obligations are proven against every supported SQL engine (through
# GenevaDrive::Workflow) and against MongoDB (through
# GenevaDrive::MongoidWorkflow).
#
# The including test case provides the backend specifics:
#
# - +race_workflow_class+ - a workflow class with steps :one, :two, :three
# - +workflow_model+ - the workflow base class of the backend
# - +create_hero+ - persists and returns a hero record
# - +with_thread_connection+ - wraps a thread body; on ActiveRecord this
#   checks a connection out of the pool, on Mongoid it just yields
# - +count_active_executions(workflow_id)+ - scheduled/in_progress count
# - +execution_outcomes+ - the backend's StepExecution OUTCOMES list
# - +transition_race_errors+ - error classes a legal loser of a transition
#   race may raise (invalid state, not found, ...)
# - +duplicate_key_error_classes+ / +duplicate_key_error?(error)+ - how the
#   backend reports a unique index violation
# - +raw_insert_duplicate_active_execution(workflow)+ - bypasses the models
#   and inserts a second active execution row directly
# - +raw_insert_duplicate_ongoing_workflow(workflow, hero)+ - likewise for a
#   second ongoing workflow row
# - +acceptable_create_loser?(error)+ - whether a create! race loser failed
#   in one of the two legal ways (validation or unique index)
# - +ongoing_workflow_count_for(hero)+ / +total_workflow_count_for(hero)+
# - +extra_rollback_state(workflow)+ - backend-specific fields that must also
#   roll back in the crash proof (e.g. the Mongoid lock_version)
# - +retryable_serialization_error?(error)+ - see the serialization proof
module ConcurrencyProofs
  # How many threads race one signal delivery / one workflow creation. Not
  # per-engine: the point of the pack is that the same contention level holds
  # everywhere.
  SIGNAL_RACE_THREADS = 8
  CREATE_RACE_THREADS = 4

  # Iterations per actor in the transition race.
  TRANSITION_ITERATIONS = 20

  # The serialization proof: INCREMENT_THREADS * INCREMENTS_PER_THREAD
  # read-modify-write cycles under with_lock must lose nothing.
  INCREMENT_THREADS = 2
  INCREMENTS_PER_THREAD = 100

  # Proof obligation (a): N threads race signal! with the same idempotency key
  # -> exactly one signal row, the rest flagged duplicate, counters coherent.
  def test_threads_racing_signal_with_one_idempotency_key_produce_exactly_one_signal_row
    hero = create_hero
    workflow = race_workflow_class.create!(hero: hero)

    barrier = Queue.new
    results = Queue.new
    threads = SIGNAL_RACE_THREADS.times.map do
      Thread.new do
        with_thread_connection do
          own_copy = workflow_model.find(workflow.id)
          barrier.pop
          results << own_copy.signal!(:payment, payload: {n: 1}, idempotency_key: "evt-1")
        end
      rescue => e
        results << e
      end
    end
    SIGNAL_RACE_THREADS.times { barrier << true }
    threads.each(&:join)

    delivered = Array.new(SIGNAL_RACE_THREADS) { results.pop }
    errors = delivered.select { |r| r.is_a?(Exception) }
    assert_empty errors, "no delivery may error: #{errors.map { |e| "#{e.class}: #{e.message}" }}"

    assert_equal 1, workflow.signals.count
    signal = workflow.signals.first
    assert_equal "payment", signal.name
    assert_equal "evt-1", signal.idempotency_key
    assert_equal SIGNAL_RACE_THREADS - 1, delivered.count(&:duplicate_delivery?),
      "all but one delivery must be flagged duplicate"
    assert delivered.all? { |s| s.id == signal.id }
    # Nothing attached to it (no step waits for it), so counters stay zero
    assert_equal 0, signal.claimed
    assert_equal 0, signal.consumed
    assert_equal "pending", signal.state
  end

  # Proof obligation (b): threads race executor-style transitions - execute,
  # pause, resume and cancel - against a stepping workflow while a watcher
  # samples the active-execution count. No corruption, never more than one
  # active execution, only legal states and outcomes.
  def test_racing_pause_resume_cancel_and_execution_never_corrupt_the_invariants
    hero = create_hero
    workflow = race_workflow_class.create!(hero: hero)

    violations = Queue.new
    stop = false
    watcher = Thread.new do
      with_thread_connection do
        until stop
          count = count_active_executions(workflow.id)
          violations << count if count > 1
          sleep 0.001
        end
      end
    end

    rescued = transition_race_errors

    stepper = Thread.new do
      with_thread_connection do
        TRANSITION_ITERATIONS.times do
          w = workflow_model.find(workflow.id)
          begin
            w.current_execution&.execute!
          rescue *rescued
          end
        end
      end
    end

    # pause!/resume!/cancel! can observe state == "performing" written by the
    # racing stepper, in which case flow control throws :flow_control as if
    # called from inside a step. Catch it - there is no executor to catch it
    # here, and the point of this test is the invariants, not the throw.
    pauser = Thread.new do
      with_thread_connection do
        TRANSITION_ITERATIONS.times do
          w = workflow_model.find(workflow.id)
          begin
            catch(:flow_control) { w.pause! }
          rescue *rescued
          end
          sleep 0.002
        end
      end
    end

    resumer = Thread.new do
      with_thread_connection do
        TRANSITION_ITERATIONS.times do
          w = workflow_model.find(workflow.id)
          begin
            catch(:flow_control) { w.resume! }
          rescue *rescued
          end
          sleep 0.002
        end
      end
    end

    # Joins the race late, so the other actors get a real contention window
    # before the workflow may go terminal.
    canceller = Thread.new do
      with_thread_connection do
        2.times do
          sleep 0.02
          w = workflow_model.find(workflow.id)
          begin
            catch(:flow_control) { w.cancel! }
          rescue *rescued
          end
        end
      end
    end

    [stepper, pauser, resumer, canceller].each(&:join)
    stop = true
    watcher.join

    overcounts = []
    overcounts << violations.pop until violations.empty?
    assert_empty overcounts, "saw more than one active execution at once: #{overcounts}"

    workflow.reload
    assert_includes %w[ready performing finished paused canceled], workflow.state

    # Every execution landed in a legal state with a legal outcome
    workflow.step_executions.each do |execution|
      assert_includes %w[scheduled waiting in_progress completed failed canceled skipped], execution.state
      assert_includes execution_outcomes + [nil], execution.outcome
    end

    # And the invariant holds at rest too
    assert_operator count_active_executions(workflow.id), :<=, 1
  end

  # Proof obligation (b2): the unique index itself rejects a second active
  # execution row, independent of any application code.
  def test_the_active_execution_unique_constraint_rejects_a_direct_duplicate_insert
    hero = create_hero
    workflow = race_workflow_class.create!(hero: hero)
    assert workflow.current_execution

    error = assert_raises(*duplicate_key_error_classes) do
      raw_insert_duplicate_active_execution(workflow)
    end
    assert duplicate_key_error?(error),
      "expected a duplicate-key violation, got #{error.class}: #{error.message}"
  end

  # Proof obligation (b3): the ongoing-workflow unique index likewise.
  def test_the_ongoing_workflow_unique_constraint_rejects_a_direct_duplicate_insert
    hero = create_hero
    workflow = race_workflow_class.create!(hero: hero)

    error = assert_raises(*duplicate_key_error_classes) do
      raw_insert_duplicate_ongoing_workflow(workflow, hero)
    end
    assert duplicate_key_error?(error),
      "expected a duplicate-key violation, got #{error.class}: #{error.message}"
  end

  # Proof obligation (c): threads race create! of the same non-allow_multiple
  # workflow -> exactly one ongoing survives; losers get a validation error
  # or a duplicate-key error, never a second row.
  def test_threads_racing_create_of_the_same_workflow_leave_exactly_one_ongoing
    hero = create_hero

    barrier = Queue.new
    outcomes = Queue.new
    threads = CREATE_RACE_THREADS.times.map do
      Thread.new do
        with_thread_connection do
          barrier.pop
          outcomes << race_workflow_class.create!(hero: hero)
        end
      rescue => e
        outcomes << e
      end
    end
    CREATE_RACE_THREADS.times { barrier << true }
    threads.each(&:join)

    results = Array.new(CREATE_RACE_THREADS) { outcomes.pop }
    winners = results.grep(workflow_model)
    losers = results - winners

    assert_operator winners.size, :>=, 1
    assert_equal 1, ongoing_workflow_count_for(hero)
    assert_equal 1, total_workflow_count_for(hero),
      "the losers' inserts must have been rejected outright"

    losers.each do |e|
      assert acceptable_create_loser?(e), "loser got unexpected #{e.class}: #{e.message}"
    end
  end

  # Proof obligation (d): an exception inside a locked block after several
  # writes rolls back everything - rows AND the deferred job enqueues.
  def test_an_exception_inside_a_locked_block_discards_all_writes_and_enqueues_nothing
    hero = create_hero
    workflow = race_workflow_class.create!(hero: hero)
    perform_next_step(workflow)
    workflow.reload

    executions_before = execution_fingerprints(workflow)
    signals_before = workflow.signals.count
    enqueued_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    state_before = workflow.state
    next_step_before = workflow.next_step_name
    extra_before = extra_rollback_state(workflow)

    boom = Class.new(StandardError)
    assert_raises(boom) do
      workflow.with_lock do
        # A realistic multi-write transition: cancel strays, insert a new
        # execution, update the workflow, register the job enqueue...
        workflow.send(:create_step_execution, workflow.steps.named("three"), wait: nil)
        workflow.signals.create!(name: "ghost", state: "pending")
        # ...and then die before commit.
        raise boom
      end
    end

    workflow.reload
    assert_equal state_before, workflow.state
    assert_equal next_step_before, workflow.next_step_name
    assert_equal extra_before, extra_rollback_state(workflow)
    assert_equal signals_before, workflow.signals.count
    assert_equal executions_before, execution_fingerprints(workflow)
    assert_equal enqueued_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size,
      "the deferred enqueue must be discarded with the rollback"
  end

  # Proof obligation (e): read-modify-write cycles under with_lock serialize.
  # Two threads each perform 100 increments of a metadata counter; if with_lock
  # ever let two read-modify-write cycles interleave, an increment would be
  # lost and the counter would come up short.
  def test_concurrent_locked_read_modify_write_increments_lose_nothing
    hero = create_hero
    workflow = race_workflow_class.create!(hero: hero)

    threads = INCREMENT_THREADS.times.map do
      Thread.new do
        with_thread_connection do
          INCREMENTS_PER_THREAD.times do
            attempts = 0
            begin
              w = workflow_model.find(workflow.id)
              w.with_lock do
                # with_lock has reloaded w: this read is made under the lock
                w.write_metadata(:counter, (w.read_metadata(:counter) || 0) + 1)
                w.save!
              end
            rescue => e
              # Engines without row locks (SQLite) abort one contender instead
              # of blocking it; the aborted transaction wrote nothing, so the
              # whole read-modify-write is retried. See the backend's
              # retryable_serialization_error? for the exact justification.
              raise unless retryable_serialization_error?(e)
              attempts += 1
              raise if attempts > 50
              sleep 0.001 * attempts
              retry
            end
          end
        end
      end
    end
    threads.each(&:join)

    expected = INCREMENT_THREADS * INCREMENTS_PER_THREAD
    assert_equal expected, workflow_model.find(workflow.id).read_metadata(:counter),
      "increments were lost - with_lock failed to serialize read-modify-write"
  end

  private

  # A stable, comparable image of every execution row of the workflow.
  def execution_fingerprints(workflow)
    workflow.step_executions.pluck(:id, :state, :outcome).sort_by { |id, _, _| id.to_s }
  end

  # Backends without extra lock bookkeeping prove nothing extra.
  def extra_rollback_state(_workflow)
    {}
  end

  # No engine artifact is retryable unless the backend says so - a deadlock or
  # a lock-wait timeout on an engine with row locks is a finding, not noise.
  def retryable_serialization_error?(_error)
    false
  end

  def with_thread_connection
    yield
  end
end
