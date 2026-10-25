# frozen_string_literal: true

# Finds the step execution a job was enqueued for, retrying briefly when it is
# not visible yet. Shared by PerformStepJob and SidekiqPerformStepJob.
#
# @api private
module GenevaDrive::StepExecutionLookup
  private

  # Retries the step execution lookup briefly to handle the (unlikely) case where
  # the job is picked up before the step execution's transaction is visible to this
  # database connection.
  #
  # This is a defense-in-depth measure. The primary protection against visibility
  # issues is the combination of:
  #   1. `after_all_transactions_commit` in Workflow#create_step_execution, which ensures
  #      the dispatcher is only called after the step execution row is committed
  #   2. Both dispatchers pushing synchronously from that callback, rather than
  #      deferring a second time into a callback that may never fire
  #
  # However, this retry handles additional edge cases:
  #   - Database replication lag (read replica hasn't caught up with the writer)
  #   - Future code paths that might enqueue inside a transaction
  #   - Any other visibility delay between the commit and the job worker's read
  #
  # The 500ms total window (5 x 100ms) is generous enough to handle typical
  # replication lag while being short enough to fail fast if the record truly
  # doesn't exist (e.g. it was already deleted by cleanup).
  #
  # @param id [Integer, String] the step execution ID to look up
  # @param attempts [Integer] maximum number of lookup attempts
  # @param delay [Float] seconds to sleep between attempts
  # @return [GenevaDrive::StepExecution, nil] the step execution or nil if not found
  def find_step_execution(id, attempts: 5, delay: 0.1)
    attempts.times do |i|
      record = GenevaDrive::StepExecution.find_by(id: id)
      return record if record
      sleep(delay) if i < attempts - 1
    end
    nil
  end
end
