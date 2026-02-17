# frozen_string_literal: true

# Base class for all durable workflows in GenevaDrive.
#
# Provides a DSL for defining multi-step workflows that execute asynchronously,
# with strong guarantees around idempotency, concurrency control, and state management.
#
# @example Basic workflow definition
#   class SignupWorkflow < GenevaDrive::Workflow
#     step :send_welcome_email do
#       WelcomeMailer.welcome(hero).deliver_later
#     end
#
#     step :send_reminder, wait: 2.days do
#       ReminderMailer.remind(hero).deliver_later
#     end
#   end
#
# @example Creating and starting a workflow
#   SignupWorkflow.create!(hero: current_user)
#
class GenevaDrive::Workflow < ActiveRecord::Base
  self.table_name = "geneva_drive_workflows"

  # Workflow states as enum with string values
  # Provides: ready?, performing?, etc. predicates
  # Provides: ready, performing, etc. scopes
  enum :state, {
    ready: "ready",
    performing: "performing",
    finished: "finished",
    canceled: "canceled",
    paused: "paused"
  }

  # Associations
  belongs_to :hero, polymorphic: true, optional: true
  has_many :step_executions,
    class_name: "GenevaDrive::StepExecution",
    foreign_key: :workflow_id,
    inverse_of: :workflow,
    dependent: :delete_all

  # Class-inheritable attributes for DSL
  class_attribute :_step_definitions, instance_writer: false, default: []
  class_attribute :_cancel_conditions, instance_writer: false, default: []
  class_attribute :_step_job_options, instance_writer: false, default: {}
  class_attribute :_may_proceed_without_hero, instance_writer: false, default: false

  # Include flow control methods
  include GenevaDrive::FlowControl

  # Additional scopes
  scope :ongoing, -> { where.not(state: %w[finished canceled]) }
  scope :for_hero, ->(hero) { where(hero: hero) }

  # Callbacks
  after_create :log_workflow_created
  after_create :schedule_first_step!

  class << self
    # Defines a step in the workflow.
    #
    # @param name [String, Symbol, nil] the step name (auto-generated if nil)
    # @param options [Hash] step options
    # @option options [ActiveSupport::Duration, nil] :wait delay before execution
    # @option options [Proc, Symbol, Boolean, nil] :skip_if condition for skipping
    # @option options [Symbol] :on_exception exception handler (:pause!, :cancel!, :reattempt!, :skip!)
    # @option options [String, Symbol, nil] :before_step position before this step
    # @option options [String, Symbol, nil] :after_step position after this step
    # @yield the step implementation
    # @return [void]
    #
    # @example Named step with block
    #   step :send_email do
    #     Mailer.send(hero).deliver_later
    #   end
    #
    # @example Step with wait time
    #   step :send_reminder, wait: 2.days do
    #     ReminderMailer.remind(hero).deliver_later
    #   end
    #
    # @example Step with skip condition
    #   step :charge, skip_if: -> { hero.free_tier? } do
    #     PaymentGateway.charge(hero)
    #   end
    #
    # @example Step with exception handling
    #   step :external_api, on_exception: :reattempt! do
    #     ExternalApi.call(hero)
    #   end
    def step(name = nil, **options, &block)
      # Capture source locations before any other operations
      caller_loc = caller_locations(1, 1).first
      call_location = caller_loc ? [caller_loc.path, caller_loc.lineno] : nil
      block_location = block&.source_location

      # Duplicate parent's array only if we haven't already (avoid mutating inherited definitions)
      if _step_definitions.equal?(superclass._step_definitions)
        self._step_definitions = _step_definitions.dup
      end
      # Invalidate cached step collection since we're adding a step
      @steps = nil

      step_name = (name || generate_step_name).to_s

      # Check for duplicate step names
      if _step_definitions.any? { |s| s.name == step_name }
        raise GenevaDrive::StepConfigurationError,
          "Step '#{step_name}' is already defined in #{self.name}"
      end

      # Validate positioning references exist
      validate_step_positioning_reference!(step_name, options[:before_step], :before_step)
      validate_step_positioning_reference!(step_name, options[:after_step], :after_step)

      step_def = GenevaDrive::StepDefinition.new(
        name: step_name,
        callable: block || name,
        call_location: call_location,
        block_location: block_location,
        **options
      )

      _step_definitions << step_def

      step_def
    end

    # Defines a blanket cancellation condition for the workflow.
    # Checked before every step execution.
    #
    # @param conditions [Array<Symbol, Proc>] condition methods or procs
    # @yield an optional block condition
    # @return [void]
    #
    # @example Cancel if hero is deactivated
    #   cancel_if { hero.deactivated? }
    #
    # @example Cancel using a method
    #   cancel_if :hero_deactivated?
    def cancel_if(*conditions, &block)
      # Duplicate parent's array to avoid mutation
      self._cancel_conditions = _cancel_conditions.dup

      _cancel_conditions.concat(conditions)
      _cancel_conditions << block if block_given?
    end

    # Sets job options for step execution jobs.
    # Options are passed to ActiveJob's set method.
    #
    # @param options [Hash] job options (queue, priority, etc.)
    # @return [void]
    #
    # @example Set queue for workflow steps
    #   set_step_job_options queue: :workflows, priority: 10
    def set_step_job_options(**options)
      # Merge with parent's options
      self._step_job_options = _step_job_options.merge(options)
    end

    # Allows the workflow to continue even if the hero is deleted.
    # By default, workflows cancel if their hero is missing.
    #
    # @return [void]
    #
    # @example Allow cleanup workflows to run without hero
    #   class CleanupWorkflow < GenevaDrive::Workflow
    #     may_proceed_without_hero!
    #
    #     step :cleanup do
    #       DataArchive.cleanup_for_hero_id(hero&.id)
    #     end
    #   end
    def may_proceed_without_hero!
      self._may_proceed_without_hero = true
    end

    # Returns the step definitions for this workflow class.
    #
    # @return [Array<StepDefinition>] the step definitions
    def step_definitions
      _step_definitions
    end

    # Returns the step collection with proper ordering.
    #
    # @return [StepCollection] the ordered step collection
    def steps
      @steps ||= GenevaDrive::StepCollection.new(_step_definitions)
    end

    private

    # Validates that a positioning reference (before_step/after_step) exists.
    #
    # @param step_name [String] the step being defined
    # @param reference [String, Symbol, nil] the referenced step name
    # @param option_name [Symbol] :before_step or :after_step
    # @raise [StepConfigurationError] if reference doesn't exist
    def validate_step_positioning_reference!(step_name, reference, option_name)
      return unless reference

      reference_str = reference.to_s
      return if _step_definitions.any? { |s| s.name == reference_str }

      raise GenevaDrive::StepConfigurationError,
        "Step '#{step_name}' references non-existent step '#{reference}' in #{option_name}:. " \
        "You can only reference steps that have already been defined."
    end

    # Generates an auto-incrementing step name.
    #
    # @return [String] the generated step name
    def generate_step_name
      "step_#{_step_definitions.size + 1}"
    end

    # Implement fallback for removed ActiveRecord subclasses. When we try to examine a Workflow
    # which exists in our database - but its class has been removed - this would otherwise fail
    # with an ActiveRecord::SubclassNotFound. We need to avoid this because even if a class has
    # been removed - we should still be able to examine a workflow that was using it.
    #
    # @return [self]
    def find_sti_class(_type_name)
      super
    rescue ActiveRecord::SubclassNotFound
      self
    end
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

    # Look for a scheduled execution to resume
    scheduled_execution = current_execution
    if scheduled_execution
      enqueue_scheduled_execution(scheduled_execution)
    else
      # No scheduled execution exists - create one for the next step
      step_def = steps.named(next_step_name)
      create_step_execution(step_def, wait: nil)
    end
  end

  # Returns the current active step execution, if any.
  #
  # @return [StepExecution, nil] the current execution
  def current_execution
    step_executions.where(state: %w[scheduled in_progress]).first
  end

  # Returns all step executions in chronological order.
  #
  # @return [ActiveRecord::Relation<StepExecution>] the execution history
  def execution_history
    step_executions.order(:created_at)
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

  private

  # Logs when a workflow is created.
  #
  # @return [void]
  def log_workflow_created
    step_count = self.class.step_definitions.size
    logger.info("Created workflow with #{step_count} step(s) defined")
  end

  # Schedules the first step after workflow creation.
  #
  # @return [StepExecution, nil] the created step execution
  def schedule_first_step!
    first_step = self.class.step_definitions.first
    unless first_step
      logger.info("No steps defined, finishing workflow immediately")
      return finish_workflow!
    end

    logger.info("Scheduling first step #{first_step.name.inspect}")
    create_step_execution(first_step, wait: first_step.wait)
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
    job_options = self.class._step_job_options.dup
    job_options[:wait_until] = wait_until if wait_until
    execution_id = step_execution.id
    workflow_logger = logger

    # Enqueue job after transaction commits to ensure the step execution record is visible
    # to the job worker. This callback fires after SQL COMMIT but may fire while the
    # transaction object is still being cleaned up on the Ruby side. That is why
    # PerformStepJob sets `enqueue_after_transaction_commit = :never` -- without it,
    # ActiveJob/SolidQueue would see the transaction as "open" and defer the queue
    # INSERT to a second "after commit" that never fires (the double-deferral bug).
    run_after_commit do
      job = GenevaDrive::PerformStepJob
        .set(**job_options)
        .perform_later(execution_id)

      workflow_logger.debug("Enqueued job #{job.job_id} for step execution #{execution_id}")
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
      # Cancel any scheduled step executions (not in_progress - those are being executed).
      # Safe to use update_all since we hold the workflow lock, blocking any executor
      # that would try to start these steps.
      canceled_count = step_executions.scheduled.update_all(
        state: "canceled",
        outcome: "canceled",
        canceled_at: Time.current
      )
      logger.debug("Canceled #{canceled_count} previously scheduled step execution(s)") if canceled_count > 0

      step_execution = step_executions.create!(
        step_name: step_definition.name,
        state: "scheduled",
        scheduled_for: scheduled_for
      )

      # next_step_name points to the step that's scheduled to run next
      update!(next_step_name: step_definition.name)

      # Capture values for the after_commit callback
      job_options = self.class._step_job_options.dup
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
      run_after_commit do
        job = GenevaDrive::PerformStepJob
          .set(**job_options)
          .perform_later(execution_id)

        workflow_logger.debug("Enqueued PerformStepJob with job_id=#{job.job_id} for step execution #{execution_id}")

        # Update job_id for debugging purposes (this is a separate transaction)
        GenevaDrive::StepExecution
          .where(id: execution_id)
          .update_all(job_id: job.job_id)
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

  # Runs a block either after all transactions commit or immediately,
  # depending on GenevaDrive.enqueue_after_commit.
  #
  # In production, deferring to after_all_transactions_commit ensures that
  # records written inside the transaction are visible to job workers. In
  # transactional tests (especially with SQLite) the outermost test
  # transaction never commits, so deferring can cause callbacks to misbehave
  # or not fire. Setting GenevaDrive.enqueue_after_commit = false (the
  # default in test environments) runs the block inline instead.
  def run_after_commit(&block)
    if GenevaDrive.enqueue_after_commit
      ActiveRecord.after_all_transactions_commit(&block)
    else
      yield
    end
  end

  # Returns the Logger properly tagged to this Workflow
  #
  # @return [Logger]
  public def logger
    @tagged_logger ||= begin
      tagged_logger = ActiveSupport::TaggedLogging.new(super)

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
end
