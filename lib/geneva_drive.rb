# frozen_string_literal: true

require "geneva_drive/version"
require "geneva_drive/engine"

# GenevaDrive provides durable workflows for Rails applications.
#
# It offers a clean DSL for defining multi-step workflows that execute
# asynchronously, with strong guarantees around idempotency, concurrency
# control, and state management.
#
# @example Defining a workflow
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
# @example Starting a workflow
#   SignupWorkflow.create!(hero: current_user)
#
module GenevaDrive
  # Core classes
  autoload :FlowControlSignal, "geneva_drive/flow_control"
  autoload :InvalidStateError, "geneva_drive/flow_control"
  autoload :StepConfigurationError, "geneva_drive/flow_control"
  autoload :StepExecutionError, "geneva_drive/flow_control"
  autoload :StepNotDefinedError, "geneva_drive/flow_control"
  autoload :StepFailedError, "geneva_drive/flow_control"
  autoload :PreconditionError, "geneva_drive/flow_control"
  autoload :FlowControl, "geneva_drive/flow_control"
  autoload :StepDefinition, "geneva_drive/step_definition"
  autoload :ResumableStepDefinition, "geneva_drive/resumable_step_definition"
  autoload :StepCollection, "geneva_drive/step_collection"
  autoload :Workflow, "geneva_drive/workflow"
  autoload :StepExecution, "geneva_drive/step_execution"
  autoload :IterableStep, "geneva_drive/iterable_step"
  autoload :InterruptConfiguration, "geneva_drive/interrupt_configuration"
  autoload :Executor, "geneva_drive/executor"
  autoload :ResumableStepExecutor, "geneva_drive/resumable_step_executor"
  autoload :MigrationHelpers, "geneva_drive/migration_helpers"
  autoload :TestHelpers, "geneva_drive/test_helpers"

  # Jobs
  autoload :PerformStepJob, "geneva_drive/jobs/perform_step_job"
  autoload :HousekeepingJob, "geneva_drive/jobs/housekeeping_job"

  class << self
    # How long to keep completed workflows before cleanup.
    # Set to nil to disable automatic cleanup.
    # @return [ActiveSupport::Duration, nil]
    attr_accessor :delete_completed_workflows_after

    # How long a step execution can be in "in_progress" state before being
    # considered stuck and eligible for recovery.
    # @return [ActiveSupport::Duration]
    attr_accessor :stuck_in_progress_threshold

    # How long a step execution can be past its scheduled_for time while
    # still in "scheduled" state before being considered stuck.
    # @return [ActiveSupport::Duration]
    attr_accessor :stuck_scheduled_threshold

    # Maximum number of workflows to process in a single housekeeping run.
    # Prevents runaway processing if there's a large backlog.
    # @return [Integer]
    attr_accessor :housekeeping_batch_size

    # Default recovery action for stuck step executions.
    # Can be :reattempt or :cancel
    # @return [Symbol]
    attr_accessor :stuck_recovery_action

    # Whether to defer job enqueueing to after the database transaction commits.
    # When true (the default in non-test environments), jobs are enqueued inside
    # an `after_all_transactions_commit` callback to ensure the step execution
    # record is visible to the job worker.
    #
    # When false (the default in test environments), jobs are enqueued immediately.
    # This is necessary for transactional tests (especially with SQLite) where the
    # outermost test transaction never commits, causing after_commit callbacks to
    # misbehave or not fire at all.
    #
    # @return [Boolean]
    attr_accessor :enqueue_after_commit
  end

  # Set default configuration values
  self.delete_completed_workflows_after = 30.days
  self.stuck_in_progress_threshold = 1.hour
  self.stuck_scheduled_threshold = 15.minutes
  self.housekeeping_batch_size = 1000
  self.stuck_recovery_action = :reattempt
  self.enqueue_after_commit = !Rails.env.test?
end
