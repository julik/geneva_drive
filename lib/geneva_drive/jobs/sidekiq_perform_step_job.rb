# frozen_string_literal: true

require "sidekiq"

# Sidekiq job that executes a scheduled step execution - the native
# counterpart of PerformStepJob, pushed by GenevaDrive::SidekiqDispatcher.
#
# Sidekiq's retries are off, deliberately. The step execution row is the
# retry ledger: exception policies (`on_exception`, `max_reattempts`) decide
# whether a step is reattempted, and a reattempt is a new step execution
# with a job of its own. A Sidekiq retry of this job would find the
# execution already settled and skip it, so all it would add is ghosts in
# the Retry set. The executor still re-raises the step's exception once its
# state is committed, so Sidekiq's error handlers - Sentry, Honeybadger and
# the like - report it as for any other job.
#
# Subclass it to carry your own sidekiq_options, and hand the subclass to
# the dispatcher (see GenevaDrive::SidekiqDispatcher).
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

    with_log_context(step_execution) do
      GenevaDrive::Executor.execute!(step_execution)
    end
  end

  private

  # Sidekiq's own log lines for this job then carry the workflow and step.
  def with_log_context(step_execution, &block)
    return yield unless defined?(::Sidekiq::Context) && ::Sidekiq::Context.respond_to?(:with)

    ::Sidekiq::Context.with(
      geneva_drive_workflow_id: step_execution.workflow_id,
      geneva_drive_step: step_execution.step_name,
      geneva_drive_step_execution_id: step_execution.id,
      &block
    )
  end
end
