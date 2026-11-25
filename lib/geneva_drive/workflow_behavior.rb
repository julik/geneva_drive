# frozen_string_literal: true

# The instance-level workflow orchestration, shared by every persistence
# backend ({GenevaDrive::Workflow} on ActiveRecord and
# {GenevaDrive::MongoidWorkflow} on Mongoid): scheduling, pausing and
# resuming, signal delivery, hooks and logging.
#
# Persistence-specific operations are small template methods each backend
# implements:
#
# - +insert_signal_with_dedup!+ - persist a signal honoring the dedup index
# - +recover_signal_from_dedup_race+ - the backstop when the index still fires
# - +cancel_stray_executions!+ - sweep scheduled/waiting executions
# - +adopt_signal+ - point a signal's workflow association at this instance
# - +run_after_commit+ - defer a block to after the ambient transaction commits
# - +default_base_logger+ - the logger to tag when none was injected
# - +validate_unique_ongoing_workflow+ - the uniqueness validation query
#
# Each backend also exposes +step_execution_class+ / +signal_class+ on the
# class, which this module routes every model reference through.
#
# @api private
module GenevaDrive::WorkflowBehavior
  extend ActiveSupport::Concern

  included do
    # Include flow control methods
    include GenevaDrive::FlowControl

    # Validations
    validate :validate_unique_ongoing_workflow, if: -> { !allow_multiple && ongoing? }

    # Callbacks
    after_create :log_workflow_created
    after_create :schedule_first_step!
  end

  # Returns whether this workflow is in an ongoing (non-terminal) state.
  #
  # @return [Boolean]
  def ongoing?
    !finished? && !canceled?
  end

  # Schedules the next step in the workflow.
  #
  # Uses current_step_name as reference if executing, otherwise next_step_name.
  #
  # @param wait [ActiveSupport::Duration, nil] override wait time
  # @return [StepExecution, nil] the created step execution or nil if finished
  def schedule_next_step!(wait: nil)
    # Use current_step_name during execution, next_step_name otherwise
    reference_step = current_step_name || next_step_name
    next_step = steps.next_after(reference_step)
    unless next_step
      logger.info("No more steps after #{reference_step.inspect}, finishing workflow")
      return finish_workflow!
    end

    logger.info("Scheduling next step #{next_step.name.inspect} after #{reference_step.inspect}")
    create_step_execution(next_step, wait: wait || next_step.wait)
  end

  # Reschedules the current step for another attempt.
  #
  # Uses current_step_name if executing, otherwise next_step_name.
  #
  # @param wait [ActiveSupport::Duration, nil] delay before retry
  # @return [StepExecution] the created step execution
  def reschedule_current_step!(wait: nil)
    # Use current_step_name during execution, next_step_name otherwise
    step_name = current_step_name || next_step_name
    step_def = steps.named(step_name)
    wait_msg = wait ? " with wait #{wait.inspect}" : ""
    logger.info("Rescheduling step #{step_name.inspect}#{wait_msg}")
    create_step_execution(step_def, wait: wait)
  end

  # Resumes a paused workflow.
  #
  # ## Scheduling behavior
  #
  # Since pause! leaves the scheduled execution intact, resume! re-enqueues a job
  # for the existing execution:
  #
  # - **Scheduled time still in future**: Enqueues job with remaining wait time
  # - **Scheduled time has passed (overdue)**: Enqueues job to run immediately
  # - **No scheduled execution exists**: Creates a new execution for immediate run
  #   (This happens if the executor ran while paused and canceled the execution)
  #
  # This approach provides better timeline visibility - you can see that a step
  # was scheduled, became overdue during pause, and when it actually ran.
  #
  # @example Resuming while step is still scheduled for future
  #   # step_two has wait: 2.days, scheduled for tomorrow
  #   workflow.pause!         # paused today
  #   workflow.resume!        # step_two still scheduled for tomorrow
  #
  # @example Resuming after scheduled time passed (overdue)
  #   # step_two was scheduled for yesterday
  #   workflow.pause!         # paused last week
  #   workflow.resume!        # step_two runs immediately (overdue)
  #
  # @return [StepExecution, nil] the step execution that will run, or nil if none
  # @raise [InvalidStateError] if workflow is not paused
  def resume!
    raise GenevaDrive::InvalidStateError, "Cannot resume a #{state} workflow" unless state == "paused"

    logger.info("Resuming paused workflow, next step: #{next_step_name.inspect}")

    with_lock do
      update!(state: "ready", transitioned_at: nil)
    end

    # A scheduled execution preserved by pause! takes precedence - re-enqueue it
    scheduled_execution = current_execution
    if scheduled_execution
      # A parked execution is not re-enqueued: it is waiting for an event, not
      # for a clock. Re-run the rendezvous instead, which delivers any signal
      # that arrived while the workflow was paused.
      return rendezvous_waiting_execution!(scheduled_execution) if scheduled_execution.waiting?

      return enqueue_scheduled_execution(scheduled_execution)
    end

    # Resumable-step continuations need the cursor/continues_from_id columns
    if self.class.step_execution_class.resumable_columns?
      # Check for a resumable step that was paused mid-iteration. Only the most
      # recent marker row counts, and only while it has not been consumed yet
      # (creating a successor consumes it - the successor's presence marks that).
      paused_resumable_execution = step_executions
        .where(outcome: "workflow_paused", state: "completed")
        .newest_first
        .first

      if paused_resumable_execution && paused_resumable_execution.successor.nil?
        logger.info("Resuming from resumable execution #{paused_resumable_execution.id}, cursor: #{paused_resumable_execution.cursor_value.inspect}")
        return create_successor_execution!(paused_resumable_execution)
      end

      # A resumable step that failed (pausing the workflow) resumes from its
      # persisted cursor instead of redoing the whole iteration.
      failed_execution = step_executions
        .where(step_name: next_step_name, state: "failed")
        .newest_first
        .first
      if failed_execution && failed_execution.cursor.present? && failed_execution.successor.nil?
        logger.info("Retrying failed resumable execution #{failed_execution.id} from cursor: #{failed_execution.cursor_value.inspect}")
        return create_successor_execution!(failed_execution)
      end
    end

    # No scheduled execution exists - create one for the next step
    step_def = steps.named(next_step_name)

    # The step this workflow is pointed at can be gone from the code - that is
    # what paused it in the first place if it paused with StepNotDefinedError.
    # Say so plainly instead of dying on nil deeper in create_step_execution,
    # and name the way out.
    unless step_def
      raise GenevaDrive::StepNotDefinedError.new(
        "Cannot resume #{self.class.name} ##{id}: step '#{next_step_name}' is no longer defined in " \
        "#{self.class.name}. Pick the step to continue from with resume_at!(:step_name) - the steps " \
        "still defined are #{steps.runnable.map(&:name).join(", ")} - or cancel! the workflow. To stop " \
        "future removals from stranding workflows this way, leave a removed_step :#{next_step_name} " \
        "gravestone in place of the deleted step.",
        step_execution: nil,
        workflow: self
      )
    end

    create_step_execution(step_def, wait: nil)
  end

  # Resumes a paused workflow at a specific step, instead of at whatever step
  # it was pointed at when it paused.
  #
  # This is the operator's escape hatch for a workflow stranded on a step that
  # no longer exists - the step was deleted without leaving a
  # {GenevaDrive::WorkflowDsl::ClassMethods#removed_step} gravestone, so the
  # workflow paused with {StepNotDefinedError} and plain {#resume!} has
  # nowhere to go.
  #
  # Where to land is deliberately a human decision. A deleted step's position
  # in the sequence says nothing about whether the steps that follow it were
  # ever meant to run: a `capture_payment` that normally ends the workflow by
  # calling `finished!` sits directly before `refund`, and nothing in the
  # database distinguishes "carry on" from "stop here". Only the person who
  # removed the step knows which, so this method asks them.
  #
  # Any stray scheduled execution is canceled first, so the workflow continues
  # from the named step and nowhere else.
  #
  # @param step_name [String, Symbol] the step to continue from
  # @return [StepExecution] the created step execution
  # @raise [InvalidStateError] if the workflow is not paused
  # @raise [StepNotDefinedError] if the named step is not defined, or is a removed_step
  #
  # @example Continue a stranded workflow past a deleted step
  #   workflow = GenevaDrive::Workflow.find(id)
  #   workflow.resume_at!(:send_receipt)
  def resume_at!(step_name)
    raise GenevaDrive::InvalidStateError, "Cannot resume a #{state} workflow" unless state == "paused"

    step_def = steps.named(step_name.to_s)

    if step_def.nil? || step_def.removed?
      reason = step_def ? "a removed_step" : "not defined"
      raise GenevaDrive::StepNotDefinedError.new(
        "Cannot resume #{self.class.name} ##{id} at '#{step_name}': that step is #{reason} in " \
        "#{self.class.name}. The steps it can be resumed at are #{steps.runnable.map(&:name).join(", ")}.",
        step_execution: nil,
        workflow: self
      )
    end

    logger.info("Resuming paused workflow at step #{step_def.name.inspect} (was pointed at #{next_step_name.inspect})")

    with_lock do
      update!(state: "ready", current_step_name: nil, transitioned_at: nil)
    end

    create_step_execution(step_def, wait: nil)
  end

  # Delivers an external event to this workflow.
  #
  # The signal row is persisted first and dispatched second, which is what
  # makes arrival order irrelevant: a signal that lands before the waiting
  # step's execution even exists simply sits in the table until that step's
  # gate picks it up, and a signal that lands while a step is already parked
  # wakes it immediately.
  #
  # Pass an +idempotency_key+ (a webhook's event id, typically) to make
  # redelivery a no-op: the second call returns the row the first one wrote,
  # flagged {GenevaDrive::Signal#duplicate_delivery?}, without dispatching.
  #
  # On a paused workflow the row is persisted but not dispatched - waking a
  # step while the workflow is paused would only get its execution canceled.
  # {#resume!} performs the rendezvous instead.
  #
  # @param signal_name [Symbol, String] the event name
  # @param payload [Object] data describing the event, serialized through ActiveJob
  # @param idempotency_key [String, nil] deduplication key, scoped to (workflow, name)
  # @return [GenevaDrive::Signal] the persisted signal
  # @raise [ArgumentError] if the signal name is blank
  # @raise [WorkflowNotOngoing] if the workflow is finished or canceled and this is a new event
  # @raise [SignalPayloadTooLargeError] if the payload exceeds GenevaDrive.max_signal_payload_size
  #
  # @example Deliver a webhook event
  #   workflow = OrderFulfillmentWorkflow.ongoing.for_hero(order).first
  #   workflow.signal!(:payment_confirmed,
  #     payload: {amount_cents: 12_500},
  #     idempotency_key: event["id"])
  def signal!(signal_name, payload: {}, idempotency_key: nil, **unknown_options)
    if unknown_options.any?
      raise ArgumentError,
        "Unknown options passed to signal!: #{unknown_options.keys.join(", ")}"
    end

    if signal_name.blank?
      raise ArgumentError, "signal! requires a signal name"
    end

    name = signal_name.to_s
    dedup_key = idempotency_key&.to_s

    # Serialize (and bound) before anything is persisted.
    serialized_payload = self.class.signal_class.serialize_payload(payload)

    signal = nil
    duplicate = false

    # One transaction covers the lot: the INSERT, the waiting-execution scan,
    # and every attach, flip and counter bump. Taking the lock before writing
    # anything is what makes delivery all-or-nothing - insert first and
    # dispatch second, and a crash in between would leave a pending signal
    # sitting next to a waiting execution with nothing left to introduce them.
    begin
      with_lock do
        # with_lock reloads; the terminal check belongs inside it
        unless ongoing?
          existing = dedup_key && signals.where(name: name, idempotency_key: dedup_key).first
          unless existing
            raise GenevaDrive::WorkflowNotOngoing,
              "Cannot deliver signal #{name.inspect} to a #{state} workflow"
          end

          logger.info("Signal #{name.inspect} redelivered to #{state} workflow, returning existing row")
          signal = existing
          duplicate = true
          next
        end

        signal, duplicate = insert_signal_with_dedup!(name, dedup_key, serialized_payload)
        next if duplicate

        logger.info("Received signal #{name.inspect} as signal #{signal.id}")

        if paused?
          logger.info("Workflow is paused, buffering signal #{signal.id} until resume!")
        else
          wake_executions_matching!(signal)
        end
      end
    rescue => e
      # Normally the dedup is settled inside insert_signal_with_dedup!. This
      # is the backend's backstop for a dedup-index violation that aborts the
      # whole transaction (MongoDB, where a duplicate key is not survivable
      # inside the transaction). ActiveRecord never recovers here - its
      # savepoint handles the race inside the transaction.
      recovered = recover_signal_from_dedup_race(e, name, dedup_key)
      raise unless recovered
      signal = recovered
      duplicate = true
    end

    signal.duplicate_delivery! if duplicate
    signal
  end

  # Returns the current active step execution, if any.
  # Includes scheduled, waiting and in_progress states.
  #
  # @return [StepExecution, nil] the current execution
  def current_execution
    step_executions.in_states(%w[scheduled waiting in_progress]).first
  end

  # Signals that may still be attached to an execution, oldest first, each
  # pointing back at this workflow instance.
  #
  # Matcher blocks are instance_exec'd on `signal.workflow`, and `inverse_of:`
  # only primes records loaded straight off the association - a scoped
  # relation would hand each signal a freshly loaded workflow, which would
  # then see none of the caller's unsaved state.
  #
  # @return [Array<GenevaDrive::Signal>]
  # @api private
  def attachable_signals
    signals.attachable.map { |signal| adopt_signal(signal) }
  end

  # Wakes every parked step execution whose matcher accepts the given signal.
  #
  # Runs under the workflow row lock - the same lock create_step_execution
  # and the Executor take - so whichever of dispatch and the gate commits
  # second sees the other's write and no signal can slip through the gap.
  #
  # @param signal [GenevaDrive::Signal] the signal to deliver
  # @return [Array<StepExecution>] the executions that were woken
  # @api private
  def dispatch_signal!(signal)
    return [] unless self.class.step_execution_class.signal_columns?

    with_lock { wake_executions_matching!(signal) }
  end

  # Settles the signal attached to an execution we are deliberately moving
  # past, wherever the skip came from: `skip_if` firing at wake, flow control
  # inside the step, an exception policy, or an operator calling `skip!`.
  #
  # Consumption follows attachment. A skip in any flavor says "we are done
  # with this step", so an event that was delivered to it is spent by that
  # decision - leaving it claimed would hand a stale event to the next waiter
  # for the same name, which is exactly what consume-once-per-event forbids.
  # An execution that never attached has nothing to settle, so buffered
  # signals a step never reached are left alone.
  #
  # Must be called with the workflow lock held, so the settle rides the same
  # transaction as the skip itself.
  #
  # @param step_execution [StepExecution, nil] the execution being skipped past
  # @return [GenevaDrive::Signal, nil] the settled signal, if there was one
  # @api private
  def settle_signal_for_skipped!(step_execution)
    return unless self.class.step_execution_class.signal_columns?
    return if step_execution.nil? || step_execution.signal_id.blank?

    signal = step_execution.signal
    return unless signal && signal.state == "claimed"

    logger.info("Skipping past step #{step_execution.step_name}, settling attached signal #{signal.id} (#{signal.name})")
    signal.record_consumption!(resolved_step_names: [step_execution.step_name])
    signal
  end

  # The body of dispatch, for callers that already hold the workflow lock
  # (`signal!` holds it across the whole delivery so the rows land atomically).
  #
  # @param signal [GenevaDrive::Signal] the signal to deliver
  # @return [Array<StepExecution>] the executions that were woken
  # @api private
  def wake_executions_matching!(signal)
    return [] unless self.class.step_execution_class.signal_columns?
    return [] if paused? || !ongoing?

    # Matcher blocks run on signal.workflow, so point the signal at this very
    # instance instead of letting it load a second copy from the database.
    adopt_signal(signal)
    woken = []

    step_executions.where(state: "waiting").oldest_first.each do |execution|
      step_def = execution.step_definition
      # A step whose definition is gone (class removed, step renamed) can
      # never match - the matcher lives on the definition.
      next unless step_def&.waits_for_signal?
      next unless step_def.signal_matcher.matches?(signal)

      signal.claim!
      execution.update!(
        signal_id: signal.id,
        state: "scheduled",
        scheduled_for: Time.current,
        waiting_since: nil
      )
      woken << [execution, step_def]
    end

    woken.each do |execution, step_def|
      enqueue_woken_execution(execution, step_def)
    end

    woken.map(&:first)
  end

  # Returns all step executions in chronological order.
  #
  # @return [Enumerable<StepExecution>] the execution history
  def execution_history
    step_executions.order(created_at: :asc)
  end

  # Returns the step collection for this workflow's class.
  #
  # @return [StepCollection] the ordered step collection
  def steps
    self.class.steps
  end

  # Returns the name of the previously executed step.
  #
  # Logic:
  # - If `current_step_name` is set (currently executing), returns the step before it
  # - If only `next_step_name` is set (waiting for next step), returns the step before it
  # - If workflow is finished (no next step), returns the last step in the sequence
  # - Returns nil if this is the first step or no steps have been executed
  #
  # @return [String, nil] the previous step name or nil
  def previous_step_name
    reference_step = current_step_name || next_step_name

    if reference_step
      previous_step = steps.previous_before(reference_step)
      previous_step&.name
    elsif finished?
      steps.last&.name
    end
  end

  # Hook called before step execution, after validation passes.
  # Use this for APM instrumentation like setting AppSignal action/params.
  #
  # @param step_execution [GenevaDrive::StepExecution] the step execution record
  # @return [void]
  #
  # @example Set AppSignal transaction metadata
  #   def before_step_execution(step_execution)
  #     Appsignal.set_action("#{self.class.name}##{step_execution.step_name}")
  #     Appsignal.set_params("hero" => { "type" => hero_type, "id" => hero_id })
  #   end
  def before_step_execution(step_execution)
    # Override in subclasses
  end

  # Hook called after step code completes, before finalization.
  # Called regardless of whether the step succeeded, failed, or used flow control.
  #
  # @param step_execution [GenevaDrive::StepExecution] the step execution record
  # @return [void]
  def after_step_execution(step_execution)
    # Override in subclasses
  end

  # Hook that wraps around the actual step code execution.
  # Use this for APM instrumentation that requires wrapping a block.
  #
  # IMPORTANT: Subclasses MUST call super when overriding this method,
  # otherwise the step code will not execute.
  #
  # @param step_execution [GenevaDrive::StepExecution] the step execution record
  # @yield the step code block
  # @return [Object] the result of the block
  #
  # @example Wrap with AppSignal transaction
  #   def around_step_execution(step_execution)
  #     Appsignal.monitor(
  #       namespace: "workflow",
  #       action: "#{self.class.name}##{step_execution.step_name}"
  #     ) { super }
  #   end
  def around_step_execution(step_execution)
    yield
  end

  # Returns per-instance step job options stored in metadata.
  # These are merged with the class-level options when enqueuing step jobs,
  # with instance options taking precedence.
  #
  # @return [Hash] symbolized job options (e.g. `{ queue: :high, priority: 5 }`)
  def step_job_options
    (read_metadata("step_job_options") || {}).symbolize_keys
  end

  # Sets per-instance step job options in metadata.
  # Stored as part of the workflow's metadata column so they persist and
  # survive across step boundaries.
  #
  # @param options [Hash, nil] job options to store
  # @return [void]
  def step_job_options=(options)
    if options.present?
      validated = GenevaDrive::JobOptions.validate!(options, context: "#{self.class.name}#step_job_options=")
      write_metadata("step_job_options", validated.stringify_keys)
    else
      write_metadata("step_job_options", nil)
    end
  end

  # Transitions the workflow to a new state.
  #
  # @param new_state [String] the target state
  # @param attributes [Hash] additional attributes to update
  # @return [void]
  def transition_to!(new_state, **attributes)
    with_lock do
      attrs = attributes.merge(state: new_state)
      if %w[finished canceled paused].include?(new_state)
        attrs[:transitioned_at] = Time.current
      end
      update!(attrs)
    end
  end

  # Creates a successor step execution that continues a resumable step from
  # the cursor persisted on the given execution. Used by the Executor when a
  # resumable step interrupts itself, by resume! for workflows paused
  # mid-iteration, and by housekeeping recovery of stuck resumable steps.
  #
  # The successor is enqueued with the same merged job options (class,
  # per-instance, per-step) as any other execution of the step.
  #
  # @param predecessor [StepExecution] the execution to continue from
  # @param wait [ActiveSupport::Duration, Numeric, nil] optional delay
  # @return [StepExecution] the new successor execution
  # @api private
  def create_successor_execution!(predecessor, wait: nil)
    scheduled_for = wait ? wait.from_now : Time.current

    with_lock do
      # Cancel any stray scheduled or parked executions - the successor is the
      # one execution that should run next (same as create_step_execution).
      cancel_stray_executions!

      successor_attributes = {
        step_name: predecessor.step_name,
        state: "scheduled",
        scheduled_for: scheduled_for,
        continues_from_id: predecessor.id,
        cursor: predecessor.cursor
      }
      # Carry the attachment pin across the chain so successors never re-park
      # and received_signal stays stable for the whole iteration.
      if self.class.step_execution_class.signal_columns?
        successor_attributes[:signal_id] = predecessor.signal_id
      end

      successor = step_executions.create!(**successor_attributes)

      # next_step_name points to the step that's scheduled to run next
      update!(next_step_name: predecessor.step_name)

      job_options = merged_step_job_options(predecessor.step_definition)
      job_options[:wait_until] = scheduled_for if wait
      successor_id = successor.id
      workflow_logger = logger

      run_after_commit do
        dispatch_step_job(successor_id, job_options, logger: workflow_logger)
      end

      successor
    end
  end

  # Temporarily overrides the workflow's logger for the duration of the block.
  # This allows the Executor to inject the step execution's logger (which
  # includes both workflow and step-specific tags) so that step code calling
  # `logger` gets the fully-tagged step execution logger.
  #
  # The passed logger is used directly - no additional tagging is applied.
  # The original logger is restored after the block completes.
  #
  # @param logger [Logger] the logger to use (typically the step execution's logger)
  # @yield the block to execute with the injected logger
  # @return [Object] the result of the block
  #
  # @example Use step execution logger during step code
  #   workflow.with_logger(step_execution.logger) do
  #     step_def.execute_in_context(workflow)
  #   end
  def with_logger(logger)
    previous_tagged_logger = @tagged_logger
    @tagged_logger = logger
    yield
  ensure
    @tagged_logger = previous_tagged_logger
  end

  # The signal that woke the step currently executing, or nil when the step
  # does not declare +wait_for:+. Available inside step bodies only.
  #
  # @return [GenevaDrive::Signal, nil]
  #
  # @example Read the payload of the event that woke the step
  #   step :capture, wait_for: :payment_confirmed do
  #     hero.capture!(received_signal.payload[:amount_cents])
  #   end
  attr_reader :received_signal

  # Temporarily makes a signal available to step code as +received_signal+
  # for the duration of the block. Injected by the Executor the same way the
  # tagged logger is.
  #
  # @param signal [GenevaDrive::Signal, nil] the attached signal
  # @yield the block to execute with the signal in scope
  # @return [Object] the result of the block
  # @api private
  def with_received_signal(signal)
    previous_received_signal = @received_signal
    @received_signal = signal
    yield
  ensure
    @received_signal = previous_received_signal
  end

  # Returns the Logger properly tagged to this Workflow
  #
  # @return [Logger]
  def logger
    @tagged_logger ||= begin
      base_logger = @injected_base_logger || default_base_logger
      tagged_logger = ActiveSupport::TaggedLogging.new(base_logger)

      # Tag log entries with the workflow, including hero info if present.
      # Step name is logged separately via the StepExecution logger.
      tag_parts = [self.class.name, " id=", to_param]
      if hero_id.present?
        tag_parts.concat([" hero_type=", hero_type, " hero_id=", hero_id])
      end
      workflow_tag = tag_parts.join

      tagged_logger.tagged(workflow_tag)
    end
  end

  private

  # Returns class-level step job options merged with per-instance and step overrides.
  # Instance options take precedence over class options; step options take final precedence.
  #
  # @param step_definition [StepDefinition, nil] step whose job options should override defaults
  # @return [Hash] merged job options
  def merged_step_job_options(step_definition)
    self.class._step_job_options
      .merge(step_job_options)
      .merge(step_definition&.job_options || {})
  end

  # Logs when a workflow is created.
  #
  # @return [void]
  def log_workflow_created
    step_count = steps.runnable.size
    logger.info("Created workflow with #{step_count} step(s) defined")
  end

  # Schedules the first step after workflow creation.
  #
  # @return [StepExecution, nil] the created step execution
  def schedule_first_step!
    # next_after(nil) means "from the beginning" and honours both the
    # before_step:/after_step: ordering and removed_step gravestones, neither
    # of which the raw _step_definitions array knows about.
    first_step = steps.next_after(nil)
    unless first_step
      logger.info("No steps defined, finishing workflow immediately")
      return finish_workflow!
    end

    logger.info("Scheduling first step #{first_step.name.inspect}")
    create_step_execution(first_step, wait: first_step.wait)
  end

  # Enqueues the step job for an execution that dispatch just flipped
  # from waiting to scheduled. Uses the same enqueue discipline (merged job
  # options, after-commit deferral, job_id writeback) as create_step_execution.
  #
  # @param step_execution [StepExecution] the woken execution
  # @param step_definition [StepDefinition] its step definition
  # @return [void]
  def enqueue_woken_execution(step_execution, step_definition)
    job_options = merged_step_job_options(step_definition)
    execution_id = step_execution.id
    workflow_logger = logger

    run_after_commit do
      dispatch_step_job(execution_id, job_options, logger: workflow_logger)
    end
  end

  # Re-runs the rendezvous for a step execution that is parked waiting for a
  # signal. Signals that arrived while the workflow was paused are delivered
  # here, on resume.
  #
  # @param step_execution [StepExecution] the parked execution
  # @return [StepExecution] the same execution (rescheduled if a signal matched)
  def rendezvous_waiting_execution!(step_execution)
    step_def = step_execution.step_definition

    # The step was removed while this execution sat parked. It waits for an
    # event that nothing will ever match now, so release it here rather than
    # leaving it parked for good.
    if step_def&.removed?
      logger.info("Step #{step_execution.step_name} was parked but is now a removed_step — releasing it and continuing")

      step_execution.mark_skipped!
      settle_signal_for_skipped!(step_execution)
      return schedule_next_step!
    end

    matcher = step_def&.signal_matcher

    if matcher
      candidate = attachable_signals.detect { |signal| matcher.matches?(signal) }
      if candidate
        logger.info("Resuming into a matching signal #{candidate.id} (#{candidate.name}) for step #{step_execution.step_name}")
        dispatch_signal!(candidate)
        return step_execution.reload
      end
    end

    logger.info("Step #{step_execution.step_name} stays parked - no matching signal has arrived yet")
    step_execution
  end

  # Enqueues a job for an existing scheduled execution.
  #
  # If the execution is overdue (scheduled_for is in the past), runs immediately.
  # Otherwise, schedules with the remaining wait time.
  #
  # @param step_execution [StepExecution] the execution to enqueue
  # @return [StepExecution] the same execution
  def enqueue_scheduled_execution(step_execution)
    remaining_seconds = step_execution.scheduled_for - Time.current
    wait_until = (remaining_seconds > 0) ? step_execution.scheduled_for : nil

    wait_msg = wait_until ? "at #{wait_until}" : "immediately (overdue)"
    logger.info("Enqueuing job for step #{step_execution.step_name} to run #{wait_msg}")

    # Capture values for the callback
    job_options = merged_step_job_options(step_execution.step_definition)
    job_options[:wait_until] = wait_until if wait_until
    execution_id = step_execution.id
    workflow_logger = logger

    # Enqueue job after transaction commits to ensure the step execution record is visible
    # to the job worker. This callback fires after SQL COMMIT but may fire while the
    # transaction object is still being cleaned up on the Ruby side. That is why
    # PerformStepJob sets `enqueue_after_transaction_commit = :never` -- without it,
    # ActiveJob/SolidQueue would see the transaction as "open" and defer the queue
    # INSERT to a second "after commit" that never fires (the double-deferral bug).
    # SidekiqDispatcher bypasses Sidekiq's transactional push for the same reason.
    run_after_commit do
      dispatch_step_job(execution_id, job_options, logger: workflow_logger)
    end

    step_execution
  end

  # Creates a step execution and enqueues the job after transaction commits.
  # Any existing scheduled step executions are canceled first.
  # In-progress step executions are left alone - they're being executed.
  #
  # The job is enqueued using `after_commit` to ensure the step execution
  # record is visible to the job worker when it runs.
  #
  # @param step_definition [StepDefinition] the step to execute
  # @param wait [ActiveSupport::Duration, nil] delay before execution
  # @return [StepExecution] the created step execution
  def create_step_execution(step_definition, wait: nil)
    scheduled_for = wait ? wait.from_now : Time.current

    with_lock do
      cancel_stray_executions!

      step_execution = step_executions.create!(
        step_name: step_definition.name,
        state: "scheduled",
        scheduled_for: scheduled_for
      )

      # next_step_name points to the step that's scheduled to run next
      update!(next_step_name: step_definition.name)

      # Capture values for the after_commit callback
      job_options = merged_step_job_options(step_definition)
      job_options[:wait_until] = scheduled_for if wait
      execution_id = step_execution.id
      workflow_logger = logger

      wait_msg = wait ? " (scheduled for #{scheduled_for})" : ""
      workflow_logger.debug("Created step execution #{execution_id} for step #{step_definition.name.inspect}#{wait_msg}")

      # Enqueue job after transaction commits to ensure the step execution record
      # is visible to the job worker. This callback fires after SQL COMMIT but may
      # fire while the transaction object is still being cleaned up on the Ruby side.
      # That is why PerformStepJob sets `enqueue_after_transaction_commit = :never` --
      # without it, ActiveJob/SolidQueue would see the transaction as "open" and defer
      # the queue INSERT to a second "after commit" that never fires (the double-deferral
      # bug). See the extensive comment in PerformStepJob for the full explanation.
      # SidekiqDispatcher bypasses Sidekiq's transactional push for the same reason.
      run_after_commit do
        dispatch_step_job(execution_id, job_options, logger: workflow_logger)
      end

      step_execution
    end
  end

  # Finishes the workflow.
  #
  # @return [nil]
  def finish_workflow!
    logger.info("Workflow finished successfully")
    transition_to!("finished", current_step_name: nil, next_step_name: nil)
    nil
  end

  # Hands a step execution to the configured dispatcher (GenevaDrive.dispatcher)
  # and writes the returned job id onto the execution, so that the job can be
  # found from the row. Always called from inside run_after_commit.
  #
  # @param execution_id [Integer, String] the step execution to perform
  # @param job_options [Hash] merged, validated job options
  # @param logger [Logger] the workflow logger captured before the commit
  # @return [void]
  def dispatch_step_job(execution_id, job_options, logger:)
    job_id = GenevaDrive.dispatcher.enqueue_step(execution_id, job_options, workflow_class_name: self.class.name)

    logger.debug("Enqueued step job with job_id=#{job_id} for step execution #{execution_id}")

    # A separate statement, outside any transaction - the job may already be running.
    # resume! re-enqueues an existing execution, so this overwrites the old job's id.
    self.class.step_execution_class
      .where(id: execution_id)
      .update_all(job_id: job_id)
  end
end
