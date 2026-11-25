# frozen_string_literal: true

# The MongoDB replacement for the SQL `SELECT ... FOR UPDATE` row lock that
# `Workflow#with_lock` used to take.
#
# Every critical section on a workflow runs inside a MongoDB multi-document
# transaction whose *first write* is a `$inc` on the workflow document's
# `lock_version`. In a MongoDB transaction the first write to a document takes
# a document lock held until commit; a concurrent transaction writing the same
# document aborts with a WriteConflict (a TransientTransactionError), and
# `with_transaction` re-runs the whole block against a fresh snapshot. Since
# every critical section starts by writing the workflow document, critical
# sections on one workflow are serialized exactly like the SQL row lock.
#
# The lock is reentrant per thread (the forked code nests `with_lock` freely),
# tracked in a thread-local registry keyed by workflow id. On reentry the
# workflow is reloaded and the block runs within the ambient transaction -
# the same "with_lock reloads" semantics ActiveRecord has.
#
# Deferred after-commit callbacks come in two flavors, both owned here:
#
# - For the gem's own lock transactions, the wrapper keeps a thread-local
#   callback list: callbacks registered through
#   {GenevaDrive::MongoidWorkflow#run_after_commit} while a lock transaction
#   is open are queued and flushed only after the outermost transaction
#   commits. The queue is reset at the start of every `with_transaction`
#   retry attempt, so a rolled-back attempt never leaks an enqueue.
# - When the *caller* owns the transaction (the lock joined an ambient
#   Mongoid session transaction), callbacks are queued on the session itself
#   and flushed by the {SessionAfterCommit} prepend on the driver's
#   `Mongo::Session#commit_transaction` - or discarded by
#   `#abort_transaction`, which also runs between `with_transaction` retry
#   attempts. That is what keeps "no job before the caller's commit, no job
#   at all after the caller's abort" true even for transactions this module
#   never opened.
#
# @api private
module GenevaDrive::DocumentLock
  HELD_KEY = :geneva_drive_held_workflow_locks
  DEFERRED_KEY = :geneva_drive_deferred_after_commit

  # The one spot where Mongoid 8 and 9 diverge for us: Mongoid 9 keys the
  # ambient session by client (`Threaded.get_session(client:)`), Mongoid 8
  # keeps a single session per thread and its `get_session` takes no
  # arguments.
  AMBIENT_SESSION_KEYED_BY_CLIENT = Mongoid::Threaded.method(:get_session).parameters.any? { |_type, name| name == :client }

  module_function

  # The thread-local registry of workflow ids whose lock this thread holds.
  #
  # @return [Hash{String => true}]
  def held_locks
    Thread.current[HELD_KEY] ||= {}
  end

  # @param workflow_id [BSON::ObjectId, String]
  # @return [Boolean] whether this thread already holds the lock for the workflow
  def lock_held?(workflow_id)
    held_locks.key?(workflow_id.to_s)
  end

  # @return [Boolean] whether this thread holds any workflow lock (and so has
  #   a lock transaction open)
  def any_lock_held?
    held_locks.any?
  end

  # The deferred after-commit callback list of the currently open lock
  # transaction, or nil when no lock transaction is open on this thread.
  #
  # @return [Array<Proc>, nil]
  def deferred_callbacks
    Thread.current[DEFERRED_KEY]
  end

  # Queues a callback on the given session, to run after the session's
  # current transaction commits (or never, if it aborts). Used when the
  # caller - not this module - owns the transaction.
  #
  # @param session [Mongo::Session]
  # @param block [Proc]
  # @return [void]
  def defer_on_session(session, block)
    queue = session.instance_variable_get(:@geneva_drive_after_commit_queue)
    unless queue
      queue = []
      session.instance_variable_set(:@geneva_drive_after_commit_queue, queue)
    end
    queue << block
  end

  # Detaches and runs the session's deferred callbacks. Called by the
  # commit_transaction prepend after a commit that returned without raising.
  #
  # @param session [Mongo::Session]
  # @return [void]
  def flush_session_queue!(session)
    queue = session.instance_variable_get(:@geneva_drive_after_commit_queue)
    return unless queue
    session.instance_variable_set(:@geneva_drive_after_commit_queue, nil)
    queue.each(&:call)
  end

  # Discards the session's deferred callbacks. Called by the
  # abort_transaction prepend - including the abort the driver performs
  # between `with_transaction` retry attempts, which is what resets the
  # queue before the block re-runs.
  #
  # @param session [Mongo::Session]
  # @return [void]
  def discard_session_queue!(session)
    session.instance_variable_set(:@geneva_drive_after_commit_queue, nil)
  end

  # Prepended onto the driver's Mongo::Session (by geneva_drive/mongoid.rb)
  # so callbacks queued on a caller-owned transaction fire exactly at its
  # outcome. Sessions without a queue pass through untouched.
  #
  # On UnknownTransactionCommitResult the driver retries commit_transaction;
  # `super` raising means nothing is flushed on that call, and the eventually
  # successful retry flushes exactly once. If every retry fails even though
  # the server did commit, the callbacks are lost - the step execution row is
  # then the outbox, and housekeeping's stuck-scheduled sweep re-enqueues it.
  #
  # @api private
  module SessionAfterCommit
    def commit_transaction(*args)
      result = super
      GenevaDrive::DocumentLock.flush_session_queue!(self)
      result
    end

    def abort_transaction(*args)
      super
    ensure
      GenevaDrive::DocumentLock.discard_session_queue!(self)
    end
  end

  # Runs the block holding the document lock on the given workflow, inside a
  # MongoDB transaction. Reentrant; see the module docs for the semantics.
  #
  # @param workflow [GenevaDrive::Workflow]
  # @yield the critical section
  # @return [Object] the block's return value
  def with_workflow_lock(workflow)
    key = workflow.id.to_s

    # Reentry on the same workflow: reload within the ambient session and yield.
    if lock_held?(key)
      workflow.reload
      return yield
    end

    # Either a different workflow's lock transaction is already open on this
    # thread, or the caller opened their own Mongoid transaction around us
    # (the SQL implementation's with_lock joined the caller's transaction the
    # same way). Take this workflow's document lock inside that ambient
    # transaction instead of trying to nest a new one.
    if any_lock_held? || ambient_transaction_open?(workflow)
      acquire_document_lock!(workflow)
      held_locks[key] = true
      begin
        workflow.reload
        return yield
      ensure
        held_locks.delete(key)
      end
    end

    # Outermost: open the transaction, lock, run, flush deferrals on commit.
    result = nil
    callbacks_to_flush = nil
    begin
      workflow.class.with_session do |session|
        session.with_transaction do
          # Reset on every retry attempt: writes of an aborted attempt roll
          # back, so its deferred enqueues must be discarded with them.
          Thread.current[DEFERRED_KEY] = []
          held_locks[key] = true
          begin
            acquire_document_lock!(workflow, session: session)
            workflow.reload
            result = yield
          ensure
            held_locks.delete(key)
          end
        end
      end
      callbacks_to_flush = Thread.current[DEFERRED_KEY]
    ensure
      Thread.current[DEFERRED_KEY] = nil
    end

    callbacks_to_flush&.each(&:call)
    result
  end

  # Whether the thread's ambient Mongoid session (if any) has a transaction
  # in progress - i.e. the caller wrapped us in their own transaction.
  #
  # @param workflow [GenevaDrive::Workflow]
  # @return [Boolean]
  def ambient_transaction_open?(workflow)
    session = ambient_session(workflow.class)
    !!session&.in_transaction?
  end

  # The thread's ambient Mongoid session for the given model class, or nil.
  #
  # @param klass [Class] a Mongoid model class
  # @return [Mongo::Session, nil]
  def ambient_session(klass)
    if AMBIENT_SESSION_KEYED_BY_CLIENT
      Mongoid::Threaded.get_session(client: klass.collection.client)
    else
      Mongoid::Threaded.get_session
    end
  end

  # Performs the first-write `$inc` on the workflow document that takes the
  # document lock for the current transaction.
  #
  # @param workflow [GenevaDrive::Workflow]
  # @param session [Mongo::Session, nil] the session owning the transaction;
  #   when nil, the thread's ambient Mongoid session is used
  # @return [void]
  # @raise [Mongoid::Errors::DocumentNotFound] if the workflow document is gone
  def acquire_document_lock!(workflow, session: nil)
    session ||= ambient_session(workflow.class)
    updated = workflow.class.collection.find_one_and_update(
      {_id: workflow.id},
      {"$inc" => {"lock_version" => 1}},
      session: session
    )
    unless updated
      raise Mongoid::Errors::DocumentNotFound.new(workflow.class, {_id: workflow.id}, workflow.id)
    end
  end

  # Whether the given exception is a MongoDB duplicate-key error (unique
  # index violation, server error code 11000).
  #
  # @param error [Exception]
  # @return [Boolean]
  def duplicate_key_error?(error)
    error.is_a?(Mongo::Error::OperationFailure) &&
      (error.code == 11000 || error.message.include?("E11000"))
  end
end
