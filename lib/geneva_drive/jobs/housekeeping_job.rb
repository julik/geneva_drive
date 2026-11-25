# frozen_string_literal: true

# Job that performs housekeeping tasks for GenevaDrive workflows, sweeping
# every persistence backend that is loaded (ActiveRecord always when
# ActiveRecord itself is present; Mongoid once `require "geneva_drive/mongoid"`
# ran).
#
# This job handles two main responsibilities:
# 1. **Cleanup**: Deletes completed/canceled workflows (with their step executions)
#    that are older than the configured threshold.
# 2. **Recovery**: Recovers stuck step executions that are:
#    - In "in_progress" state for too long (process crashed)
#    - In "scheduled" state past their scheduled_for time (job never ran)
#
# The ORM-specific queries live on the model classes of each backend
# (+housekeeping_state_type_counts+, +sweep_terminal_workflows!+,
# +stuck_in_progress+, +stuck_scheduled+, +counts_by_workflow_type+,
# +waiting_overdue+); this job owns the orchestration.
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
      signals_cleaned_up: 0,
      stuck_in_progress_recovered: 0,
      stuck_scheduled_recovered: 0
    }

    GenevaDrive.workflow_backends.each do |workflow_class|
      unless workflow_class.housekeeping_available?
        logger.info("Skipping housekeeping for #{workflow_class.name} - its storage is not available")
        next
      end

      cleanup_completed_workflows!(workflow_class, results)
      recover_stuck_step_executions!(workflow_class, results)
      report_workflow_gauges!(workflow_class)
      report_waiting_gauges!(workflow_class)
    end

    logger.info("Completed: #{results}")
    results
  end

  private

  # Reports workflow count gauges to Measurometer.
  # For each state present in the workflows table (e.g. ready, paused,
  # performing, finished, canceled), sets:
  # - A total gauge `geneva_drive.<state>` without tags (summed across all classes)
  # - Per-workflow-class gauges `geneva_drive.<state>` tagged with `workflow: ClassName`
  #
  # Additionally emits a normalized `geneva_drive.paused_ratio` gauge per
  # workflow class — a float in `0.0..1.0` equal to that class's `paused` count
  # divided by that class's total population (all states). This is easier to
  # alert on than absolute paused counts (50 paused of 50 is a fire; 50 of
  # 500,000 is noise). All gauges are derived from a single grouped query.
  #
  # @param workflow_class [Class] the backend's workflow model
  # @return [void]
  def report_workflow_gauges!(workflow_class)
    counts = workflow_class.housekeeping_state_type_counts

    counts.each_with_object(Hash.new(0)) { |((state, _type), count), totals| totals[state] += count }
      .each do |state, total|
        Measurometer.set_gauge("geneva_drive.#{state}", total)
      end

    counts.each do |(state, type), count|
      Measurometer.set_gauge("geneva_drive.#{state}", count, workflow: type)
    end

    # Per-class paused ratio (paused ÷ total population), deliberately bounded 0..1.
    # Both accumulators default to 0 so a class with no paused workflows yields a clean 0.0.
    totals_by_type = Hash.new(0)
    paused_by_type = Hash.new(0)
    counts.each do |(state, type), count|
      totals_by_type[type] += count
      paused_by_type[type] += count if state == "paused"
    end

    totals_by_type.each do |type, total|
      # A type only appears here when it has >= 1 row, so total is always >= 1.
      # Guard against division by zero anyway as belt-and-suspenders.
      next if total.zero?
      Measurometer.set_gauge("geneva_drive.paused_ratio", paused_by_type[type].to_f / total, workflow: type)
    end
  end

  # Reports gauges for step executions parked waiting for a signal.
  #
  # Waiting indefinitely is a legitimate state, not a stuck one, so the stuck
  # sweeps ignore parked rows. These gauges are what keeps a stalled
  # rendezvous from being silent:
  # - `geneva_drive.waiting_step_executions` - parked rows, total and per class
  # - `geneva_drive.waiting_overdue` - parked longer than
  #   GenevaDrive.waiting_visibility_threshold, total and per class
  #
  # @param workflow_class [Class] the backend's workflow model
  # @return [void]
  def report_waiting_gauges!(workflow_class)
    step_execution_class = workflow_class.step_execution_class
    return unless step_execution_class.signal_columns?

    report_waiting_gauge!(workflow_class, "geneva_drive.waiting_step_executions", step_execution_class.waiting)

    threshold = GenevaDrive.waiting_visibility_threshold
    return if threshold.blank?

    overdue = step_execution_class.waiting_overdue(threshold.ago)
    report_waiting_gauge!(workflow_class, "geneva_drive.waiting_overdue", overdue)
  end

  # Sets one gauge per workflow class plus an untagged total for the scope.
  #
  # @param workflow_class [Class] the backend's workflow model
  # @param gauge_name [String] the Measurometer gauge name
  # @param scope [Enumerable] a step execution scope
  # @return [void]
  def report_waiting_gauge!(workflow_class, gauge_name, scope)
    counts = workflow_class.step_execution_class.counts_by_workflow_type(scope)

    Measurometer.set_gauge(gauge_name, counts.values.sum)
    counts.each do |type, count|
      Measurometer.set_gauge(gauge_name, count, workflow: type)
    end
  end

  # Cleans up completed/canceled workflows older than the configured threshold.
  # The batched deletion itself lives on the workflow model, whose backend
  # knows the efficient shape (JOINed SQL DELETEs vs. id-batched Mongo deletes).
  #
  # @param workflow_class [Class] the backend's workflow model
  # @param results [Hash] results hash to update
  # @return [void]
  def cleanup_completed_workflows!(workflow_class, results)
    threshold = GenevaDrive.delete_completed_workflows_after
    if threshold.blank?
      logger.info("GenevaDrive.delete_completed_workflows_after is set to nil, so no old workflows will be deleted from the DB for now")
      return
    end

    # Fix cutoff time at start to ensure cleanup completes deterministically
    cutoff_time = threshold.ago
    batch_size = GenevaDrive.housekeeping_batch_size

    swept = workflow_class.sweep_terminal_workflows!(cutoff_time, batch_size, logger: logger)
    results[:workflows_cleaned_up] += swept[:workflows]
    results[:step_executions_cleaned_up] += swept[:step_executions]
    results[:signals_cleaned_up] += swept[:signals]

    logger.info(
      "Cleaned up #{swept[:workflows]} workflows, " \
      "#{swept[:step_executions]} step executions and " \
      "#{swept[:signals]} signals older than #{cutoff_time}"
    )
  end

  # Recovers stuck step executions.
  # Handles two scenarios:
  # 1. Steps stuck in "in_progress" state (process crashed mid-execution)
  # 2. Steps stuck in "scheduled" state past their scheduled_for time (job never ran)
  #
  # @param workflow_class [Class] the backend's workflow model
  # @param results [Hash] results hash to update
  # @return [void]
  def recover_stuck_step_executions!(workflow_class, results)
    recover_stuck_in_progress!(workflow_class, results)
    recover_stuck_scheduled!(workflow_class, results)
  end

  # Recovers step executions stuck in "in_progress" state.
  # Loops until all eligible records are processed.
  #
  # @param workflow_class [Class] the backend's workflow model
  # @param results [Hash] results hash to update
  # @return [void]
  def recover_stuck_in_progress!(workflow_class, results)
    # Fix cutoff time at start to ensure recovery completes deterministically
    cutoff_time = GenevaDrive.stuck_in_progress_threshold.ago
    batch_size = GenevaDrive.housekeeping_batch_size

    loop do
      stuck_executions = workflow_class.step_execution_class
        .stuck_in_progress(cutoff_time)
        .order(started_at: :asc)
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
  # @param workflow_class [Class] the backend's workflow model
  # @param results [Hash] results hash to update
  # @return [void]
  def recover_stuck_scheduled!(workflow_class, results)
    # Fix cutoff time at start to ensure recovery completes deterministically
    cutoff_time = GenevaDrive.stuck_scheduled_threshold.ago
    batch_size = GenevaDrive.housekeeping_batch_size

    loop do
      stuck_executions = workflow_class.step_execution_class
        .stuck_scheduled(cutoff_time)
        .order(scheduled_for: :asc)
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
  # Resumable step executions carry a cursor; those are continued via a
  # successor execution so recovery does not restart the iteration from zero.
  #
  # @param step_execution [GenevaDrive::StepExecution]
  # @param workflow [GenevaDrive::Workflow]
  # @return [void]
  def reattempt_step_execution!(step_execution, workflow)
    # with_lock automatically reloads the record before yielding. No `return`
    # inside the lock: on MongoDB a non-local exit out of the lock transaction
    # aborts it instead of committing.
    workflow.with_lock do
      step_execution.with_lock do
        # Only recover if still stuck
        if step_execution.scheduled? || step_execution.in_progress?
          step_execution.update!(
            state: "completed",
            outcome: "recovered",
            completed_at: Time.current
          )

          workflow.update!(state: "ready") if workflow.performing?

          if step_execution.step_definition&.resumable? && step_execution.class.resumable_columns?
            workflow.create_successor_execution!(step_execution)
          else
            workflow.reschedule_current_step!
          end
        end
      end
    end
  end

  # Cancels a stuck step execution and its workflow.
  #
  # @param step_execution [GenevaDrive::StepExecution]
  # @param workflow [GenevaDrive::Workflow]
  # @return [void]
  def cancel_step_execution!(step_execution, workflow)
    # with_lock automatically reloads the record before yielding. No `return`
    # inside the lock: on MongoDB a non-local exit out of the lock transaction
    # aborts it instead of committing.
    workflow.with_lock do
      step_execution.with_lock do
        # Only recover if still stuck
        if step_execution.scheduled? || step_execution.in_progress?
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
