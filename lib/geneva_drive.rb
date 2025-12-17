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
  autoload :FlowControl, "geneva_drive/flow_control"
  autoload :StepDefinition, "geneva_drive/step_definition"
  autoload :StepCollection, "geneva_drive/step_collection"
  autoload :Workflow, "geneva_drive/workflow"
  autoload :StepExecution, "geneva_drive/step_execution"
  autoload :Executor, "geneva_drive/executor"
  autoload :MigrationHelpers, "geneva_drive/migration_helpers"
  autoload :TestHelpers, "geneva_drive/test_helpers"

  # Jobs
  autoload :PerformStepJob, "geneva_drive/jobs/perform_step_job"
end
