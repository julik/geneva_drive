# frozen_string_literal: true

# Enqueues step jobs through Active Job, onto whatever adapter the app uses.
# This is the default dispatcher.
#
# GenevaDrive calls the dispatcher from an `after_all_transactions_commit`
# callback, once the step execution row is visible to other connections.
# PerformStepJob opts out of Active Job's own transaction deferral for that
# reason - see the comment there.
#
# @see GenevaDrive.dispatcher
class GenevaDrive::ActiveJobDispatcher
  # Enqueues the job that performs a step execution.
  #
  # @param step_execution_id [Integer, String] the step execution to perform
  # @param job_options [Hash] validated `queue`, `priority`, `wait`, `wait_until`
  # @param workflow_class_name [String, nil] unused here
  # @param step_name [String, nil] unused here
  # @return [String, nil] the Active Job job_id, or nil if the enqueue was aborted
  def enqueue_step(step_execution_id, job_options, workflow_class_name: nil, step_name: nil)
    job = GenevaDrive::PerformStepJob.set(**job_options).perform_later(step_execution_id)
    # perform_later returns false, not nil, when a callback aborts the enqueue
    return nil unless job
    job.job_id
  end

  # Every key GenevaDrive::JobOptions allows maps onto Active Job's `set`.
  #
  # @param options [Hash{Symbol=>Object}]
  # @param context [String]
  # @return [void]
  def validate_job_options!(options, context:)
  end
end
