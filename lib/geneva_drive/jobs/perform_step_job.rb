# frozen_string_literal: true

# ActiveJob that executes a scheduled step execution.
# This is a thin wrapper that delegates all logic to the Executor.
#
# Idempotency is guaranteed by the Executor, which:
# - Acquires locks on both workflow and step execution
# - Reloads records after acquiring locks to get fresh state
# - Only proceeds if state is still "scheduled"
# - Transitions state atomically while holding locks
#
# @example Manual execution (for testing)
#   PerformStepJob.perform_now(step_execution.id)
#
class GenevaDrive::PerformStepJob < ActiveJob::Base
  queue_as :default

  # Performs the step execution.
  #
  # @param step_execution_id [Integer, String] the ID of the step execution
  # @return [void]
  def perform(step_execution_id)
    step_execution = GenevaDrive::StepExecution.find_by(id: step_execution_id)

    unless step_execution
      logger.warn("StepExecution #{step_execution_id} not found, skipping")
      return
    end

    step_execution.logger.debug("PerformStepJob starting execution")
    GenevaDrive::Executor.execute!(step_execution)
  end
end
