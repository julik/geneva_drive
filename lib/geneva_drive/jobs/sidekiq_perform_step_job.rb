# frozen_string_literal: true

require "sidekiq"

# Sidekiq job that executes a scheduled step execution - the native
# counterpart of PerformStepJob, pushed by GenevaDrive::SidekiqDispatcher.
#
# Retries are off because exception policies decide reattempts, each as a new
# step execution. The step's exception is still raised, so error handlers report it.
class GenevaDrive::SidekiqPerformStepJob
  include ::Sidekiq::Job
  include GenevaDrive::StepExecutionLookup

  sidekiq_options queue: "default", retry: false, tags: ["geneva_drive"]

  # @param step_execution_id [Integer, String] the ID of the step execution
  # @return [void]
  def perform(step_execution_id)
    step_execution = find_step_execution(step_execution_id)

    unless step_execution
      logger.warn("StepExecution #{step_execution_id} not found, skipping")
      return
    end

    # So that Sidekiq's own log lines for this job carry the workflow and step
    ::Sidekiq::Context.with(
      geneva_drive_workflow_id: step_execution.workflow_id,
      geneva_drive_step: step_execution.step_name,
      geneva_drive_step_execution_id: step_execution.id
    ) do
      GenevaDrive::Executor.execute!(step_execution)
    end
  end
end
