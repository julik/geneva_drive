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

  require_relative "workflow/metadata_accessor"
  include MetadataAccessor

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
  has_many :signals,
    class_name: "GenevaDrive::Signal",
    foreign_key: :workflow_id,
    inverse_of: :workflow,
    dependent: :delete_all

  # Class-inheritable attributes for DSL
  class_attribute :_step_definitions, instance_writer: false, default: []
  class_attribute :_cancel_conditions, instance_writer: false, default: []
  class_attribute :_step_job_options, instance_writer: false, default: {}
  class_attribute :_may_proceed_without_hero, instance_writer: false, default: false
  class_attribute :_exception_policies, instance_writer: false, default: []

  # Include flow control methods
  include GenevaDrive::FlowControl

  # Validations
  validate :validate_unique_ongoing_workflow, if: -> { !allow_multiple && ongoing? }

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
    # @option options [Hash] :job_options options passed to Active Job's set method
    # @option options [Proc, Symbol, Boolean, nil] :skip_if condition for skipping
    # @option options [Symbol, GenevaDrive::ExceptionPolicy, Proc, Array<GenevaDrive::ExceptionPolicy>] :on_exception
    #   exception handling policy. Accepts:
    #   - A Symbol (+:pause!+, +:cancel!+, +:reattempt!+, +:skip!+) for simple actions
    #   - An {ExceptionPolicy} object for reusable, configurable policies
    #   - A Proc/lambda that receives the exception and calls a flow control method
    #   - An Array of {ExceptionPolicy} objects for composable per-exception-type handling.
    #     Specific policies (those with +matching:+) are checked first; the first blanket
    #     policy acts as a fallback. If nothing matches, class-level policies are consulted.
    # @option options [Integer, nil] :max_reattempts max consecutive reattempts (only with symbol form)
    # @option options [Symbol] :terminal_action what to do when max_reattempts is exceeded
    #   (+:pause!+ or +:cancel!+, only with symbol form)
    # @option options [String, Symbol, nil] :before_step position before this step
    # @option options [String, Symbol, nil] :after_step position after this step
    # @yield the step implementation
    # @return [GenevaDrive::StepDefinition]
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
    # @example Step with simple exception handling
    #   step :external_api, on_exception: :reattempt! do
    #     ExternalApi.call(hero)
    #   end
    #
    # @example Step with composable exception policies
    #   step :sync_calendar, on_exception: [
    #     GenevaDrive::ExceptionPolicy.new(:reattempt!, matching: Timeout::Error, max_reattempts: 5),
    #     GenevaDrive::ExceptionPolicy.new(:cancel!, matching: OAuth2::Error),
    #     GenevaDrive::ExceptionPolicy.new(:skip!)  # blanket fallback
    #   ] do
    #     GoogleCalendar.sync(hero)
    #   end
    def step(name = nil, **options, &block)
      # Capture source locations before any other operations
      caller_loc = caller_locations(1, 1).first
      call_location = caller_loc ? [caller_loc.path, caller_loc.lineno] : nil
      block_location = block&.source_location

      step_name = prepare_step_registration!(name, options)

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

    # Defines a resumable step that can iterate over large collections.
    # The block receives an IterableStep object for cursor-based iteration
    # that survives job restarts.
    #
    # @param name [String, Symbol, nil] the step name (auto-generated if nil)
    # @param options [Hash] step options
    # @option options [Integer, nil] :max_iterations interrupt after N iterations
    # @option options [ActiveSupport::Duration, nil] :max_runtime interrupt after duration
    # @option options [ActiveSupport::Duration, nil] :wait delay before execution
    # @option options [Proc, Symbol, Boolean, nil] :skip_if condition for skipping
    # @option options [Symbol] :on_exception exception handler (:pause!, :cancel!, :reattempt!, :skip!)
    # @option options [String, Symbol, nil] :before_step position before this step
    # @option options [String, Symbol, nil] :after_step position after this step
    # @yield [iter] the step implementation receiving an IterableStep object
    # @yieldparam iter [GenevaDrive::IterableStep] cursor management object
    # @return [void]
    #
    # @example Iterate over records with automatic checkpointing
    #   resumable_step :process_users do |iter|
    #     iter.iterate_over_records(hero.users) do |user|
    #       process(user)
    #     end
    #   end
    #
    # @example Manual cursor control
    #   resumable_step :sync_pages do |iter|
    #     page = iter.cursor || 1
    #     loop do
    #       response = Api.fetch(page: page)
    #       break if response.empty?
    #       response.each { |item| process(item) }
    #       page += 1
    #       iter.set!(page)
    #     end
    #   end
    #
    # @example With iteration limits
    #   resumable_step :bulk_import, max_iterations: 10_000 do |iter|
    #     iter.iterate_over_records(records) { |r| import(r) }
    #   end
    def resumable_step(name = nil, **options, &block)
      raise ArgumentError, "resumable_step requires a block" unless block_given?

      # Capture source locations before any other operations
      caller_loc = caller_locations(1, 1).first
      call_location = caller_loc ? [caller_loc.path, caller_loc.lineno] : nil
      block_location = block.source_location

      step_name = prepare_step_registration!(name, options)

      step_def = GenevaDrive::ResumableStepDefinition.new(
        name: step_name,
        call_location: call_location,
        block_location: block_location,
        **options,
        &block
      )

      _step_definitions << step_def

      step_def
    end

    # Marks a step as removed, leaving a gravestone in the position the step
    # used to occupy.
    #
    # Deleting a `step` outright is unsafe while workflows are in flight.
    # Executions scheduled under the old name find no definition when their
    # job runs, and the workflow pauses with {StepNotDefinedError} - stuck
    # until an operator intervenes. The gem cannot recover from this on its
    # own: it knows the step is gone, but not whether the work it did still
    # needs doing, and not which of the remaining steps would have run had it
    # executed. Only the author of the removal knows that.
    #
    # `removed_step` is how that knowledge gets written down. Declaring it
    # where the step used to be says "this step no longer needs to happen,
    # carry on past it", and the gem can then act without guessing:
    #
    # - Executions already scheduled for the name resolve, are skipped, and
    #   the workflow proceeds to the next runnable step.
    # - Scheduling never spools a new execution for the name again.
    # - `before_step:` / `after_step:` references to it keep working.
    #
    # Ship the `removed_step`, let in-flight workflows drain past it, then
    # delete the line once {.removed_steps_in_flight} comes back empty.
    #
    # A removed step takes a name and nothing else. There is nothing to
    # configure about a step that does not run.
    #
    # @param name [String, Symbol] the name of the step that was removed
    # @return [RemovedStepDefinition] the gravestone
    #
    # @example Taking a step out of a live workflow
    #   class PaymentWorkflow < GenevaDrive::Workflow
    #     step :authorize do
    #       # ...
    #     end
    #
    #     removed_step :capture_payment
    #
    #     step :send_receipt do
    #       # ...
    #     end
    #   end
    def removed_step(name)
      raise ArgumentError, "removed_step requires a step name" if name.nil?

      caller_loc = caller_locations(1, 1).first
      call_location = caller_loc ? [caller_loc.path, caller_loc.lineno] : nil

      step_name = prepare_step_registration!(name, {})

      step_def = GenevaDrive::RemovedStepDefinition.new(
        name: step_name,
        call_location: call_location
      )

      _step_definitions << step_def

      step_def
    end

    # Returns the names of this workflow's removed steps that step execution
    # rows still reference, so a `removed_step` gravestone is only deleted
    # once nothing can land on it any more.
    #
    # Each name maps to the number of rows still referencing it. An empty
    # hash means every in-flight workflow has drained past the removal and
    # the `removed_step` lines can go.
    #
    # Rows belonging to finished and canceled workflows are ignored - they
    # will never execute again.
    #
    # @return [Hash{String => Integer}] removed step names to referencing row counts
    #
    # @example
    #   PaymentWorkflow.removed_steps_in_flight
    #   # => {"capture_payment" => 3}
    def removed_steps_in_flight
      removed_names = steps.removed.map(&:name)
      return {} if removed_names.empty?

      GenevaDrive::StepExecution
        .where(step_name: removed_names)
        .where(workflow_id: where.not(state: %w[finished canceled]).select(:id))
        .group(:step_name)
        .count
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
      validated = GenevaDrive::JobOptions.validate!(options, context: "#{name || "Workflow"}.set_step_job_options")
      # Merge with parent's options
      self._step_job_options = _step_job_options.merge(validated)
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

    # Declares a class-level exception handling policy.
    # Policies are checked when a step raises an exception and the step itself
    # does not have an explicit `on_exception:` override.
    #
    # @overload on_exception(action, *exception_matchers, wait: nil, max_reattempts: nil, report: :always)
    #   Declarative mode — specify an action symbol.
    #   @param action [Symbol] :pause!, :cancel!, :reattempt!, or :skip!
    #   @param exception_matchers [Array<Class>] optional exception classes to match
    #   @param wait [ActiveSupport::Duration, nil] wait before reattempt
    #   @param max_reattempts [Integer, nil] max consecutive reattempts
    #   @param report [Symbol] when to report the exception to +Rails.error.report+
    #     (+:always+, +:never+, or +:terminal_only+). See {ExceptionPolicy} for details.
    #
    # @overload on_exception(*exception_matchers, action:, wait: nil, max_reattempts: nil, report: :always)
    #   Declarative mode with exception classes as leading args and action as keyword.
    #   @param exception_matchers [Array<Class>] exception classes to match
    #   @param action [Symbol] :pause!, :cancel!, :reattempt!, or :skip!
    #   @param report [Symbol] when to report the exception (+:always+, +:never+, or +:terminal_only+)
    #
    # @overload on_exception(*exception_matchers, report: :always, &block)
    #   Imperative mode — block receives exception, runs in workflow context.
    #   @param exception_matchers [Array<Class>] optional exception classes to match
    #   @param report [Symbol] when to report the exception (+:always+, +:never+, or +:terminal_only+)
    #   @yield [error] the exception that was raised
    #
    # @example Blanket default for all exceptions
    #   on_exception :reattempt!, wait: 15.seconds, max_reattempts: 3
    #
    # @example Match specific exception classes
    #   on_exception OAuth2::Error, action: :reattempt!, wait: 15.seconds
    #   on_exception Google::Apis::ClientError, action: :cancel!
    #
    # @example Imperative block handler
    #   on_exception RateLimitError do |error|
    #     reattempt! wait: error.retry_after.seconds
    #   end
    #
    # @example Suppress reporting for expected rate limits
    #   on_exception RateLimitError, report: :never do |error|
    #     reattempt! wait: error.retry_after.seconds
    #   end
    #
    # @example Report only when reattempts are exhausted
    #   on_exception Timeout::Error, action: :reattempt!, max_reattempts: 5, report: :terminal_only
    def on_exception(*args, action: nil, wait: nil, max_reattempts: nil, terminal_action: :pause!, report: :always, &block)
      # Separate exception classes from a leading action symbol
      if args.first.is_a?(Symbol)
        raise ArgumentError, "Cannot pass both a positional action and action: keyword" if action
        action = args.shift
      end

      exception_matchers = args.map do |matcher|
        if matcher.is_a?(String)
          GenevaDrive::ExceptionPolicy::LazyExceptionMatcher.new(matcher)
        elsif matcher.is_a?(Class)
          unless matcher <= Exception
            raise GenevaDrive::StepConfigurationError,
              "Expected an Exception subclass, got #{matcher.inspect}"
          end
          matcher
        elsif matcher.respond_to?(:===)
          matcher
        else
          raise GenevaDrive::StepConfigurationError,
            "Expected an exception matcher (Exception subclass, String, or object responding to #===), got #{matcher.inspect}"
        end
      end

      policy = if block
        GenevaDrive::ExceptionPolicy.new(report: report, &block)
      else
        raise ArgumentError, "Either an action or a block is required" unless action
        GenevaDrive::ExceptionPolicy.new(action, wait: wait, max_reattempts: max_reattempts, terminal_action: terminal_action, report: report)
      end

      policy.exception_matchers.concat(exception_matchers)

      # Duplicate parent's array to avoid mutation
      if _exception_policies.equal?(superclass._exception_policies)
        self._exception_policies = _exception_policies.dup
      end

      _exception_policies << policy
    end

    # Resolves the class-level exception policy for a given error.
    # Checks policies in reverse definition order (most recent first).
    # Specific (exception class) policies are checked before blanket policies.
    #
    # @param error [Exception] the exception to match
    # @return [ExceptionPolicy, nil] the matching policy, or nil if none
    def resolve_exception_policy(error)
      # Walk in reverse order (most recently defined first).
      # Check specific policies (with exception class filters) first,
      # then blanket policies (no filters).
      blanket_policy = nil

      _exception_policies.reverse_each do |policy|
        if policy.specific?
          return policy if policy.matches?(error)
        else
          # Remember the first (most recent) blanket policy
          blanket_policy ||= policy
        end
      end

      blanket_policy
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

    # Shared bookkeeping for registering a step definition: copy-on-write of
    # the inherited definitions array, cache invalidation, name generation,
    # duplicate-name check, and positioning validation.
    #
    # @param name [String, Symbol, nil] the requested step name
    # @param options [Hash] the step options (read for before_step/after_step)
    # @return [String] the resolved step name
    def prepare_step_registration!(name, options)
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

      step_name
    end

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
    if GenevaDrive::StepExecution.resumable_columns?
      # Check for a resumable step that was paused mid-iteration. Only the most
      # recent marker row counts, and only while it has not been consumed yet
      # (creating a successor consumes it - the successor's presence marks that).
      paused_resumable_execution = step_executions
        .where(outcome: "workflow_paused", state: "completed")
        .order(created_at: :desc, id: :desc)
        .first

      if paused_resumable_execution && paused_resumable_execution.successor.nil?
        logger.info("Resuming from resumable execution #{paused_resumable_execution.id}, cursor: #{paused_resumable_execution.cursor_value.inspect}")
        return create_successor_execution!(paused_resumable_execution)
      end

      # A resumable step that failed (pausing the workflow) resumes from its
      # persisted cursor instead of redoing the whole iteration.
      failed_execution = step_executions
        .where(step_name: next_step_name, state: "failed")
        .order(created_at: :desc, id: :desc)
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
  # {GenevaDrive::Workflow.removed_step} gravestone, so the workflow paused
  # with {StepNotDefinedError} and plain {#resume!} has nowhere to go.
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
    serialized_payload = GenevaDrive::Signal.serialize_payload(payload)

    signal = nil
    duplicate = false

    # One transaction covers the lot: the INSERT, the waiting-execution scan,
    # and every attach, flip and counter bump. Taking the lock before writing
    # anything is what makes delivery all-or-nothing - insert first and
    # dispatch second, and a crash in between would leave a pending signal
    # sitting next to a waiting execution with nothing left to introduce them.
    with_lock do
      # with_lock reloads; the terminal check belongs inside it
      unless ongoing?
        existing = dedup_key && signals.find_by(name: name, idempotency_key: dedup_key)
        unless existing
          raise GenevaDrive::WorkflowNotOngoing,
            "Cannot deliver signal #{name.inspect} to a #{state} workflow"
        end

        logger.info("Signal #{name.inspect} redelivered to #{state} workflow, returning existing row")
        signal = existing
        duplicate = true
        next
      end

      begin
        # A savepoint so that hitting the dedup index does not poison the
        # transaction - the caller's, if they had one open, or ours.
        transaction(requires_new: true) do
          record = signals.new(name: name, idempotency_key: dedup_key, state: "pending")
          record[:payload] = serialized_payload
          record.save!
          signal = record
        end
      rescue ActiveRecord::RecordNotUnique
        signal = signals.find_by!(name: name, idempotency_key: dedup_key)
        logger.info("Signal #{name.inspect} is a duplicate delivery of signal #{signal.id}, not dispatching")
        duplicate = true
        next
      end

      logger.info("Received signal #{name.inspect} as signal #{signal.id}")

      if paused?
        logger.info("Workflow is paused, buffering signal #{signal.id} until resume!")
      else
        wake_executions_matching!(signal)
      end
    end

    signal.duplicate_delivery! if duplicate
    signal
  end

  # Returns the current active step execution, if any.
  # Includes scheduled, waiting and in_progress states.
  #
  # @return [StepExecution, nil] the current execution
  def current_execution
    step_executions.where(state: %w[scheduled waiting in_progress]).first
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
  public def attachable_signals
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
  public def dispatch_signal!(signal)
    return [] unless GenevaDrive::StepExecution.signal_columns?

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
  public def settle_signal_for_skipped!(step_execution)
    return unless GenevaDrive::StepExecution.signal_columns?
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
  public def wake_executions_matching!(signal)
    return [] unless GenevaDrive::StepExecution.signal_columns?
    return [] if paused? || !ongoing?

    # Matcher blocks run on signal.workflow, so point the signal at this very
    # instance instead of letting it load a second copy from the database.
    adopt_signal(signal)
    woken = []

    step_executions.where(state: "waiting").order(created_at: :asc, id: :asc).each do |execution|
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

  # Validates that no other ongoing workflow exists for the same (type, hero).
  # Mirrors the database unique index on (type, hero_type, hero_id) for ongoing workflows.
  #
  # @return [void]
  def validate_unique_ongoing_workflow
    scope = self.class.base_class.where(type: self.class.sti_name, hero_type: hero_type, hero_id: hero_id)
      .where.not(state: %w[finished canceled])
      .where(allow_multiple: false)
    scope = scope.where.not(id: id) if persisted?
    if scope.exists?
      errors.add(:base, "An ongoing workflow of this type already exists for this hero")
    end
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

  # Points a signal's workflow association at this instance, so matcher
  # blocks - which are instance_exec'd on it - see the live object.
  #
  # @param signal [GenevaDrive::Signal]
  # @return [GenevaDrive::Signal] the same signal
  def adopt_signal(signal)
    signal.association(:workflow).target = self
    signal
  end

  # Enqueues the PerformStepJob for an execution that dispatch just flipped
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
      job = GenevaDrive::PerformStepJob
        .set(**job_options)
        .perform_later(execution_id)

      workflow_logger.debug("Enqueued PerformStepJob with job_id=#{job.job_id} for woken step execution #{execution_id}")

      GenevaDrive::StepExecution
        .where(id: execution_id)
        .update_all(job_id: job.job_id)
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
    run_after_commit do
      job = GenevaDrive::PerformStepJob
        .set(**job_options)
        .perform_later(execution_id)

      workflow_logger.debug("Enqueued job #{job.job_id} for step execution #{execution_id}")
    end

    step_execution
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
  public def create_successor_execution!(predecessor, wait: nil)
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
      if GenevaDrive::StepExecution.signal_columns?
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
        job = GenevaDrive::PerformStepJob
          .set(**job_options)
          .perform_later(successor_id)

        workflow_logger.debug("Enqueued PerformStepJob with job_id=#{job.job_id} for successor execution ##{successor_id}")

        GenevaDrive::StepExecution
          .where(id: successor_id)
          .update_all(job_id: job.job_id)
      end

      successor
    end
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

  # Cancels any scheduled or parked step executions so that the execution
  # about to be created is the only one that will run. In-progress executions
  # are left alone - they are being executed.
  #
  # Safe to use update_all because the caller holds the workflow lock, which
  # blocks any executor that would try to start these steps. Parked executions
  # are swept for the same reason: no legitimate path creates a new execution
  # past one that is waiting.
  #
  # @return [Integer] the number of executions canceled
  def cancel_stray_executions!
    canceled_count = step_executions.where(state: %w[scheduled waiting]).update_all(
      state: "canceled",
      outcome: "canceled",
      canceled_at: Time.current
    )
    logger.debug("Canceled #{canceled_count} previously scheduled step execution(s)") if canceled_count > 0
    canceled_count
  end

  # Finishes the workflow.
  #
  # @return [nil]
  def finish_workflow!
    logger.info("Workflow finished successfully")
    transition_to!("finished", current_step_name: nil, next_step_name: nil)
    nil
  end

  # Runs a block either after all transactions commit or immediately.
  #
  # The behavior depends on GenevaDrive.enqueues_deferred?, which checks:
  # - Whether we're inside a GenevaDrive.without_deferred_enqueues block
  # - The GenevaDrive.enqueue_after_commit global setting
  #
  # In production (enqueue_after_commit = true), deferring to
  # after_all_transactions_commit ensures that records written inside the
  # transaction are visible to job workers.
  #
  # In tests (enqueue_after_commit = false), or inside a
  # without_deferred_enqueues block, the block runs immediately.
  #
  # @yield the block to run (typically contains perform_later call)
  # @return [void]
  def run_after_commit(&block)
    if GenevaDrive.enqueues_deferred?
      ActiveRecord.after_all_transactions_commit(&block)
    else
      yield
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
  public def with_logger(logger)
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
  public attr_reader :received_signal

  # Temporarily makes a signal available to step code as +received_signal+
  # for the duration of the block. Injected by the Executor the same way the
  # tagged logger is.
  #
  # @param signal [GenevaDrive::Signal, nil] the attached signal
  # @yield the block to execute with the signal in scope
  # @return [Object] the result of the block
  # @api private
  public def with_received_signal(signal)
    previous_received_signal = @received_signal
    @received_signal = signal
    yield
  ensure
    @received_signal = previous_received_signal
  end

  # Returns the Logger properly tagged to this Workflow
  #
  # @return [Logger]
  public def logger
    @tagged_logger ||= begin
      base_logger = @injected_base_logger || super
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
end
