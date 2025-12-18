# frozen_string_literal: true

# GenevaDrive configuration
#
# GenevaDrive is a durable workflow library for Rails.
# For more information, see: https://github.com/julik/geneva_drive
#
# To create a workflow:
#
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
# To start a workflow:
#
#   SignupWorkflow.create!(hero: current_user)

# == Housekeeping Configuration
#
# GenevaDrive provides a HousekeepingJob that handles cleanup of old workflows
# and recovery of stuck step executions. Schedule it to run periodically
# (e.g., every 30 minutes) using your job scheduler.
#
# Example with solid_queue:
#   # config/recurring.yml
#   housekeeping:
#     class: GenevaDrive::HousekeepingJob
#     schedule: every 30 minutes
#
# Example with sidekiq-cron:
#   Sidekiq::Cron::Job.create(
#     name: 'GenevaDrive Housekeeping',
#     cron: '*/30 * * * *',
#     class: 'GenevaDrive::HousekeepingJob'
#   )

# -- Cleanup Settings --

# How long to keep completed/canceled workflows before automatic deletion.
# Set to nil to disable automatic cleanup (default).
# When enabled, finished and canceled workflows older than this threshold
# will be deleted along with their step execution records.
#
# GenevaDrive.delete_completed_workflows_after = 30.days

# -- Recovery Settings --

# How long a step execution can be in "executing" state before being
# considered stuck. This typically happens when a worker process crashes
# mid-execution. The HousekeepingJob will recover these based on the
# stuck_recovery_action setting.
#
# GenevaDrive.stuck_executing_threshold = 1.hour

# How long a step execution can be past its scheduled_for time while
# still in "scheduled" state before being considered stuck. This can
# happen if jobs fail to enqueue or are lost by the queue backend.
#
# GenevaDrive.stuck_scheduled_threshold = 1.hour

# Action to take when recovering stuck step executions.
# - :reattempt - Mark as recovered and schedule a retry (default)
# - :cancel - Mark as recovered and cancel the workflow
#
# GenevaDrive.stuck_recovery_action = :reattempt

# Maximum number of workflows/step executions to process in a single
# housekeeping run. Prevents runaway processing if there's a large backlog.
#
# GenevaDrive.housekeeping_batch_size = 1000
