# frozen_string_literal: true

# The class-level workflow definition DSL and its registry bookkeeping,
# shared verbatim by every persistence backend ({GenevaDrive::Workflow} on
# ActiveRecord and {GenevaDrive::MongoidWorkflow} on Mongoid).
#
# Everything here is ORM-independent: step registration, exception policies,
# cancellation conditions, job options and the step collection. Queries that
# differ per backend (such as +removed_steps_in_flight+) live on the backend
# classes themselves.
#
# @api private
module GenevaDrive::WorkflowDsl
  extend ActiveSupport::Concern

  included do
    # Class-inheritable attributes for DSL
    class_attribute :_step_definitions, instance_writer: false, default: []
    class_attribute :_cancel_conditions, instance_writer: false, default: []
    class_attribute :_step_job_options, instance_writer: false, default: {}
    class_attribute :_may_proceed_without_hero, instance_writer: false, default: false
    class_attribute :_exception_policies, instance_writer: false, default: []
  end

  class_methods do
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

    # Sets job options for step execution jobs. See GenevaDrive::JobOptions
    # for the keys allowed, and the dispatcher for how they are applied.
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
    #   @param wait [ActiveSupport::Duration, Symbol, Proc, nil] wait before reattempt — a fixed
    #     duration, a named backoff strategy (e.g. +:polynomially_longer+), or a Proc receiving
    #     the 1-based attempt count. See {BackoffStrategies}.
    #   @param jitter [Float, nil] jitter factor for named backoff strategies (0.0–1.0, default 0.15)
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
    #
    # @example Progressive backoff with a built-in strategy
    #   on_exception :reattempt!, wait: :polynomially_longer, max_reattempts: 8
    #
    # @example Custom backoff formula
    #   on_exception :reattempt!, wait: ->(attempts) { (2**attempts).seconds }, max_reattempts: 5
    def on_exception(*args, action: nil, wait: nil, max_reattempts: nil, terminal_action: :pause!, report: :always, jitter: nil, &block)
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
        GenevaDrive::ExceptionPolicy.new(action, wait: wait, max_reattempts: max_reattempts, terminal_action: terminal_action, report: report, jitter: jitter)
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
  end
end
