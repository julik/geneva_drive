# frozen_string_literal: true

# Job that performs housekeeping tasks for GenevaDrive workflows.
#
# This job handles two main responsibilities:
# 1. **Cleanup**: Deletes completed/canceled workflows (with their step executions)
#    that are older than the configured threshold.
# 2. **Recovery**: Recovers stuck step executions that are:
#    - In "in_progress" state for too long (process crashed)
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
#   GenevaDrive.stuck_in_progress_threshold = 1.hour
#   GenevaDrive.stuck_scheduled_threshold = 15.minutes
#   GenevaDrive.stuck_recovery_action = :reattempt # or :cancel
#
class GenevaDrive::HousekeepingJob < ActiveJob::Base
  queue_as :default

  # Performs housekeeping tasks.
  #
  # @return [Hash] summary of actions taken
  def perform
    results = {
      workflows_cleaned_up: 0,
      step_executions_cleaned_up: 0,
      stuck_in_progress_recovered: 0,
      stuck_scheduled_recovered: 0
    }

    cleanup_completed_workflows!(results)
    recover_stuck_step_executions!(results)

    logger.info("Completed: #{results}")
    results
  end

  private

  # Cleans up completed/canceled workflows older than the configured threshold.
  # Uses efficient batched SQL DELETEs - step executions are deleted first via
  # INNER JOIN, then workflows. Loops until all eligible records are deleted.
  #
  # @param results [Hash] results hash to update
  # @return [void]
  def cleanup_completed_workflows!(results)
    threshold = GenevaDrive.delete_completed_workflows_after
    if threshold.blank?
      logger.info("GenevaDrive.delete_completed_workflows_after is set to nil, so no old workflows will be deleted from the DB for now")
      return
    end

    # Fix cutoff time at start to ensure cleanup completes deterministically
    cutoff_time = threshold.ago
    batch_size = GenevaDrive.housekeeping_batch_size

    # First pass: delete all step executions for old workflows using INNER JOIN
    loop do
      deleted_count = delete_step_executions_batch(cutoff_time, batch_size)
      logger.info("Deleted #{deleted_count} step executions")
      results[:step_executions_cleaned_up] += deleted_count
      break if deleted_count < batch_size
    end

    # Second pass: delete the workflows themselves
    loop do
      deleted_count = delete_workflows_batch(cutoff_time, batch_size)
      logger.info("Deleted #{deleted_count} workflows")
      results[:workflows_cleaned_up] += deleted_count
      break if deleted_count < batch_size
    end

    logger.info(
      "Cleaned up #{results[:workflows_cleaned_up]} workflows " \
      "and #{results[:step_executions_cleaned_up]} step executions older than #{cutoff_time}"
    )
  end

  # Deletes a batch of step executions belonging to old workflows.
  #
  # @param cutoff_time [Time] workflows transitioned before this time are eligible
  # @param batch_size [Integer] maximum records to delete in this batch
  # @return [Integer] number of records deleted
  def delete_step_executions_batch(cutoff_time, batch_size)
    GenevaDrive::StepExecution.connection_pool.with_connection do |conn|
      step_executions_table = conn.quote_table_name(GenevaDrive::StepExecution.table_name)
      workflows_table = conn.quote_table_name(GenevaDrive::Workflow.table_name)

      sql = <<~SQL.squish
        DELETE FROM #{step_executions_table}
        WHERE id IN (
          SELECT se.id
          FROM #{step_executions_table} se
          INNER JOIN #{workflows_table} w ON w.id = se.workflow_id
          WHERE w.state IN ('finished', 'canceled')
          AND w.transitioned_at < ?
          LIMIT ?
        )
      SQL

      conn.delete(GenevaDrive::StepExecution.sanitize_sql([sql, cutoff_time, batch_size]))
    end
  end

  # Deletes a batch of old workflows.
  #
  # @param cutoff_time [Time] workflows transitioned before this time are eligible
  # @param batch_size [Integer] maximum records to delete in this batch
  # @return [Integer] number of records deleted
  def delete_workflows_batch(cutoff_time, batch_size)
    GenevaDrive::Workflow.connection_pool.with_connection do |conn|
      workflows_table = conn.quote_table_name(GenevaDrive::Workflow.table_name)

      sql = <<~SQL.squish
        DELETE FROM #{workflows_table}
        WHERE id IN (
          SELECT id FROM #{workflows_table}
          WHERE state IN ('finished', 'canceled')
          AND transitioned_at < ?
          LIMIT ?
        )
      SQL

      conn.delete(GenevaDrive::Workflow.sanitize_sql([sql, cutoff_time, batch_size]))
    end
  end

  # Recovers stuck step executions.
  # Handles two scenarios:
  # 1. Steps stuck in "in_progress" state (process crashed mid-execution)
  # 2. Steps stuck in "scheduled" state past their scheduled_for time (job never ran)
  #
  # @param results [Hash] results hash to update
  # @return [void]
  def recover_stuck_step_executions!(results)
    recover_stuck_in_progress!(results)
    recover_stuck_scheduled!(results)
  end

  # Recovers step executions stuck in "in_progress" state.
  # Loops until all eligible records are processed.
  #
  # @param results [Hash] results hash to update
  # @return [void]
  def recover_stuck_in_progress!(results)
    # Fix cutoff time at start to ensure recovery completes deterministically
    cutoff_time = GenevaDrive.stuck_in_progress_threshold.ago
    batch_size = GenevaDrive.housekeeping_batch_size

    loop do
      stuck_executions = GenevaDrive::StepExecution
        .in_progress
        .where("started_at < ?", cutoff_time)
        .limit(batch_size)
        .to_a

      break if stuck_executions.empty?

      stuck_executions.each do |step_execution|
        recover_step_execution!(step_execution)
        results[:stuck_in_progress_recovered] += 1
      rescue => e
        logger.error("Failed to recover step execution #{step_execution.id}: #{e.message}")
        Rails.error.report(e)
      end
    end
  end

  # Recovers step executions stuck in "scheduled" state past their scheduled_for time.
  # Loops until all eligible records are processed.
  #
  # @param results [Hash] results hash to update
  # @return [void]
  def recover_stuck_scheduled!(results)
    # Fix cutoff time at start to ensure recovery completes deterministically
    cutoff_time = GenevaDrive.stuck_scheduled_threshold.ago
    batch_size = GenevaDrive.housekeeping_batch_size

    loop do
      stuck_executions = GenevaDrive::StepExecution
        .scheduled
        .where("scheduled_for < ?", cutoff_time)
        .limit(batch_size)
        .to_a

      break if stuck_executions.empty?

      stuck_executions.each do |step_execution|
        recover_step_execution!(step_execution)
        results[:stuck_scheduled_recovered] += 1
      rescue => e
        logger.error("Failed to recover step execution #{step_execution.id}: #{e.message}")
        Rails.error.report(e)
      end
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

    logger.info("Recovered step execution #{step_execution.id} with action: #{action}")
  end

  # Reattempts a stuck step execution by marking it as completed and scheduling a retry.
  #
  # @param step_execution [GenevaDrive::StepExecution]
  # @param workflow [GenevaDrive::Workflow]
  # @return [void]
  def reattempt_step_execution!(step_execution, workflow)
    # with_lock automatically reloads the record before yielding
    workflow.with_lock do
      step_execution.with_lock do
        # Only recover if still stuck
        return unless step_execution.scheduled? || step_execution.in_progress?

        step_execution.update!(
          state: "completed",
          outcome: "recovered",
          completed_at: Time.current
        )

        workflow.update!(state: "ready") if workflow.performing?
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
    # with_lock automatically reloads the record before yielding
    workflow.with_lock do
      step_execution.with_lock do
        # Only recover if still stuck
        return unless step_execution.scheduled? || step_execution.in_progress?

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
