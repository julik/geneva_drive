# frozen_string_literal: true

module GenevaDrive
  # ActiveJob that executes a scheduled step execution.
  # Receives the step execution ID and delegates to the Executor.
  #
  # This job is designed to be idempotent:
  # - Uses pessimistic locking when loading the step execution
  # - Checks if the step is still in 'scheduled' state before executing
  # - Safe to retry if the job fails or is duplicated
  #
  # @example Manual execution (for testing)
  #   PerformStepJob.perform_now(step_execution.id)
  #
  class PerformStepJob < ActiveJob::Base
    queue_as :default

    # Performs the step execution.
    #
    # @param step_execution_id [Integer, String] the ID of the step execution
    # @return [void]
    def perform(step_execution_id)
      # Use lock.find for proper idempotency
      step_execution = GenevaDrive::StepExecution.lock.find(step_execution_id)

      # Idempotency: if already executed, don't execute again
      return unless step_execution.state == "scheduled"

      # Don't execute if scheduled for future (job ran early)
      return if step_execution.scheduled_for > Time.current

      # Execute the step
      step_execution.execute!
    rescue ActiveRecord::RecordNotFound
      # Step execution was deleted, nothing to do
      Rails.logger.warn("GenevaDrive::StepExecution #{step_execution_id} not found")
    end
  end
end
