# frozen_string_literal: true

module GenevaDrive
  # Job that performs housekeeping tasks for GenevaDrive workflows.
  #
  # This job handles two main responsibilities:
  # 1. **Cleanup**: Deletes completed/canceled workflows (with their step executions)
  #    that are older than the configured threshold.
  # 2. **Recovery**: Recovers stuck step executions that are:
  #    - In "executing" state for too long (process crashed)
  #    - In "scheduled" state past their scheduled_for time (job never ran)
  #
  # @example Running the housekeeping job
  #   GenevaDrive::HousekeepingJob.perform_later
  #
  # @example Scheduling with good-job or sidekiq-cron
  #   # Run every 30 minutes
  #   GenevaDrive::HousekeepingJob.set(cron: "*/30 * * * *").perform_later
  #
  # @example Configuration
  #   # config/initializers/geneva_drive.rb
  #   GenevaDrive.delete_completed_workflows_after = 30.days
  #   GenevaDrive.stuck_executing_threshold = 1.hour
  #   GenevaDrive.stuck_scheduled_threshold = 1.hour
  #   GenevaDrive.stuck_recovery_action = :reattempt # or :cancel
  #
  class HousekeepingJob < ApplicationJob
    queue_as :default

    # Performs housekeeping tasks.
    #
    # @return [Hash] summary of actions taken
    def perform
      results = {
        workflows_cleaned_up: 0,
        step_executions_cleaned_up: 0,
        stuck_executing_recovered: 0,
        stuck_scheduled_recovered: 0
      }

      cleanup_completed_workflows!(results)
      recover_stuck_step_executions!(results)

      Rails.logger.info("[GenevaDrive::HousekeepingJob] Completed: #{results}")
      results
    end

    private

    # Cleans up completed/canceled workflows older than the configured threshold.
    # Uses delete_all for efficiency - step executions are deleted via dependent: :destroy
    # or a separate bulk delete for performance.
    #
    # @param results [Hash] results hash to update
    # @return [void]
    def cleanup_completed_workflows!(results)
      threshold = GenevaDrive.delete_completed_workflows_after
      return unless threshold

      cutoff_time = threshold.ago
      batch_size = GenevaDrive.housekeeping_batch_size

      # Find workflows eligible for cleanup
      workflows_to_delete = Workflow
        .where(state: %w[finished canceled])
        .where("transitioned_at < ?", cutoff_time)
        .limit(batch_size)

      workflow_ids = workflows_to_delete.pluck(:id)
      return if workflow_ids.empty?

      # Delete step executions first (more efficient than dependent: :destroy for bulk)
      step_exec_count = StepExecution
        .where(workflow_id: workflow_ids)
        .delete_all

      # Then delete workflows
      workflow_count = Workflow
        .where(id: workflow_ids)
        .delete_all

      results[:workflows_cleaned_up] = workflow_count
      results[:step_executions_cleaned_up] = step_exec_count

      Rails.logger.info(
        "[GenevaDrive::HousekeepingJob] Cleaned up #{workflow_count} workflows " \
        "and #{step_exec_count} step executions older than #{cutoff_time}"
      )
    end

    # Recovers stuck step executions.
    # Handles two scenarios:
    # 1. Steps stuck in "executing" state (process crashed mid-execution)
    # 2. Steps stuck in "scheduled" state past their scheduled_for time (job never ran)
    #
    # @param results [Hash] results hash to update
    # @return [void]
    def recover_stuck_step_executions!(results)
      recover_stuck_executing!(results)
      recover_stuck_scheduled!(results)
    end

    # Recovers step executions stuck in "executing" state.
    #
    # @param results [Hash] results hash to update
    # @return [void]
    def recover_stuck_executing!(results)
      threshold = GenevaDrive.stuck_executing_threshold
      batch_size = GenevaDrive.housekeeping_batch_size
      cutoff_time = threshold.ago

      stuck_executions = StepExecution
        .where(state: "executing")
        .where("started_at < ?", cutoff_time)
        .limit(batch_size)

      stuck_executions.find_each do |step_execution|
        recover_step_execution!(step_execution)
        results[:stuck_executing_recovered] += 1
      rescue => e
        Rails.logger.error(
          "[GenevaDrive::HousekeepingJob] Failed to recover step execution " \
          "#{step_execution.id}: #{e.message}"
        )
        Rails.error.report(e)
      end
    end

    # Recovers step executions stuck in "scheduled" state past their scheduled_for time.
    #
    # @param results [Hash] results hash to update
    # @return [void]
    def recover_stuck_scheduled!(results)
      threshold = GenevaDrive.stuck_scheduled_threshold
      batch_size = GenevaDrive.housekeeping_batch_size
      cutoff_time = threshold.ago

      stuck_executions = StepExecution
        .where(state: "scheduled")
        .where("scheduled_for < ?", cutoff_time)
        .limit(batch_size)

      stuck_executions.find_each do |step_execution|
        recover_step_execution!(step_execution)
        results[:stuck_scheduled_recovered] += 1
      rescue => e
        Rails.logger.error(
          "[GenevaDrive::HousekeepingJob] Failed to recover step execution " \
          "#{step_execution.id}: #{e.message}"
        )
        Rails.error.report(e)
      end
    end

    # Recovers a single stuck step execution based on the configured recovery action.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @return [void]
    def recover_step_execution!(step_execution)
      workflow = step_execution.workflow
      action = GenevaDrive.stuck_recovery_action

      case action
      when :reattempt
        reattempt_step_execution!(step_execution, workflow)
      when :cancel
        cancel_step_execution!(step_execution, workflow)
      else
        raise ArgumentError, "Unknown stuck_recovery_action: #{action}"
      end

      Rails.logger.info(
        "[GenevaDrive::HousekeepingJob] Recovered step execution #{step_execution.id} " \
        "with action: #{action}"
      )
    end

    # Reattempts a stuck step execution by marking it as completed and scheduling a retry.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @return [void]
    def reattempt_step_execution!(step_execution, workflow)
      workflow.with_lock do
        step_execution.with_lock do
          step_execution.reload
          workflow.reload

          # Only recover if still stuck
          return unless %w[scheduled executing].include?(step_execution.state)

          step_execution.update!(
            state: "completed",
            outcome: "recovered",
            completed_at: Time.current
          )

          workflow.update!(state: "ready") if workflow.state == "performing"
          workflow.reschedule_current_step!
        end
      end
    end

    # Cancels a stuck step execution and its workflow.
    #
    # @param step_execution [GenevaDrive::StepExecution]
    # @param workflow [GenevaDrive::Workflow]
    # @return [void]
    def cancel_step_execution!(step_execution, workflow)
      workflow.with_lock do
        step_execution.with_lock do
          step_execution.reload
          workflow.reload

          # Only recover if still stuck
          return unless %w[scheduled executing].include?(step_execution.state)

          step_execution.update!(
            state: "canceled",
            outcome: "recovered",
            canceled_at: Time.current
          )

          workflow.update!(
            state: "canceled",
            transitioned_at: Time.current
          )
        end
      end
    end
  end
end
