# frozen_string_literal: true

module GenevaDrive
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
  class Workflow < ActiveRecord::Base
    self.table_name = "geneva_drive_workflows"

    # Workflow states
    STATES = %w[ready performing finished canceled paused].freeze

    # Associations
    belongs_to :hero, polymorphic: true, optional: true
    has_many :step_executions,
      class_name: "GenevaDrive::StepExecution",
      foreign_key: :workflow_id,
      inverse_of: :workflow,
      dependent: :destroy

    # Class-inheritable attributes for DSL
    class_attribute :_step_definitions, instance_writer: false, default: []
    class_attribute :_cancel_conditions, instance_writer: false, default: []
    class_attribute :_step_job_options, instance_writer: false, default: {}
    class_attribute :_may_proceed_without_hero, instance_writer: false, default: false

    # Include flow control methods
    include FlowControl

    # Validations
    validates :state, presence: true, inclusion: {in: STATES}

    # Scopes for querying workflows by state
    scope :ready, -> { where(state: "ready") }
    scope :performing, -> { where(state: "performing") }
    scope :finished, -> { where(state: "finished") }
    scope :canceled, -> { where(state: "canceled") }
    scope :paused, -> { where(state: "paused") }
    scope :active, -> { where.not(state: %w[finished canceled]) }
    scope :for_hero, ->(hero) { where(hero: hero) }

    # Callbacks
    after_create :schedule_first_step!

    class << self
      # Defines a step in the workflow.
      #
      # @param name [String, Symbol, nil] the step name (auto-generated if nil)
      # @param wait [ActiveSupport::Duration, nil] delay before execution
      # @param skip_if [Proc, Symbol, Boolean, nil] condition for skipping
      # @param on_exception [Symbol] exception handler (:pause!, :cancel!, :reattempt!, :skip!)
      # @param before_step [String, Symbol, nil] position before this step
      # @param after_step [String, Symbol, nil] position after this step
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
        # Duplicate parent's array to avoid mutation
        self._step_definitions = _step_definitions.dup

        step_def = StepDefinition.new(
          name: name || generate_step_name,
          callable: block || name,
          **options
        )

        _step_definitions << step_def
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
      def step_collection
        @step_collection ||= StepCollection.new(_step_definitions)
      end

      private

      # Generates an auto-incrementing step name.
      #
      # @return [String] the generated step name
      def generate_step_name
        @step_counter ||= 0
        @step_counter += 1
        "step_#{@step_counter}"
      end
    end

    # Schedules the next step in the workflow.
    #
    # @param wait [ActiveSupport::Duration, nil] override wait time
    # @return [StepExecution, nil] the created step execution or nil if finished
    def schedule_next_step!(wait: nil)
      next_step = self.class.step_collection.next_after(current_step_name)
      return finish_workflow! unless next_step

      create_step_execution(next_step, wait: wait || next_step.wait)
    end

    # Reschedules the current step for another attempt.
    #
    # @param wait [ActiveSupport::Duration, nil] delay before retry
    # @return [StepExecution] the created step execution
    def reschedule_current_step!(wait: nil)
      step_def = self.class.step_collection.find_by_name(current_step_name)
      create_step_execution(step_def, wait: wait)
    end

    # Resumes a paused workflow.
    # Creates a new step execution for the current step.
    #
    # @return [StepExecution] the created step execution
    # @raise [InvalidStateError] if workflow is not paused
    def resume!
      raise InvalidStateError, "Cannot resume a #{state} workflow" unless state == "paused"

      with_lock do
        update!(state: "ready", transitioned_at: nil)
      end

      reschedule_current_step!
    end

    # Returns the current active step execution, if any.
    #
    # @return [StepExecution, nil] the current execution
    def current_execution
      step_executions.where(state: %w[scheduled executing]).first
    end

    # Returns all step executions in chronological order.
    #
    # @return [ActiveRecord::Relation<StepExecution>] the execution history
    def execution_history
      step_executions.order(:created_at)
    end

    # Hook called before each step starts executing.
    # Override in subclasses to add custom behavior.
    #
    # @param step_name [String] the name of the step about to execute
    # @return [void]
    def before_step_starts(step_name)
      # Override in subclasses
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

    # Schedules the first step after workflow creation.
    #
    # @return [StepExecution, nil] the created step execution
    def schedule_first_step!
      first_step = self.class.step_definitions.first
      return finish_workflow! unless first_step

      create_step_execution(first_step, wait: first_step.wait)
    end

    # Creates a step execution and enqueues the job.
    # Any existing scheduled/executing step executions are canceled first.
    #
    # @param step_definition [StepDefinition] the step to execute
    # @param wait [ActiveSupport::Duration, nil] delay before execution
    # @return [StepExecution] the created step execution
    def create_step_execution(step_definition, wait: nil)
      scheduled_for = wait ? wait.from_now : Time.current

      with_lock do
        # Cancel any existing active step executions to maintain uniqueness
        step_executions.where(state: %w[scheduled executing]).find_each do |exec|
          exec.mark_canceled!(outcome: "canceled")
        end

        step_execution = step_executions.create!(
          step_name: step_definition.name,
          state: "scheduled",
          scheduled_for: scheduled_for
        )

        update!(current_step_name: step_definition.name)

        job_options = self.class._step_job_options.dup
        job_options[:wait_until] = scheduled_for if wait

        job = GenevaDrive::PerformStepJob
          .set(**job_options)
          .perform_later(step_execution.id)

        step_execution.update!(job_id: job.job_id)
        step_execution
      end
    end

    # Finishes the workflow.
    #
    # @return [nil]
    def finish_workflow!
      transition_to!("finished")
      nil
    end
  end
end
