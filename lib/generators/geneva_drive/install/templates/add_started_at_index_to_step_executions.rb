# frozen_string_literal: true

class AddStartedAtIndexToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  # Partial index scoped to state = 'in_progress'. HousekeepingJob's
  # recover_stuck_in_progress! filters `state = 'in_progress' AND
  # started_at < cutoff LIMIT N`; without this the planner walks the whole
  # in-progress set looking for old rows and trips the caller's
  # statement_timeout on large / mostly-fresh workloads.
  INDEX_NAME = :index_geneva_drive_step_executions_in_progress_started_at

  disable_ddl_transaction!

  def up
    return if index_name_exists?(:geneva_drive_step_executions, INDEX_NAME)

    adapter = connection.adapter_name.downcase

    if adapter.include?("postgresql")
      add_index :geneva_drive_step_executions, :started_at,
        name: INDEX_NAME,
        where: "state = 'in_progress'",
        algorithm: :concurrently
    elsif adapter.include?("sqlite")
      # SQLite supports partial indexes but has no CONCURRENTLY.
      add_index :geneva_drive_step_executions, :started_at,
        name: INDEX_NAME,
        where: "state = 'in_progress'"
    else
      # MySQL does not support partial indexes; fall back to a plain index.
      # Composite (state, started_at) so the planner can seek by state first.
      add_index :geneva_drive_step_executions, [:state, :started_at],
        name: INDEX_NAME
    end
  end

  def down
    return unless index_name_exists?(:geneva_drive_step_executions, INDEX_NAME)

    adapter = connection.adapter_name.downcase
    if adapter.include?("postgresql")
      remove_index :geneva_drive_step_executions,
        name: INDEX_NAME,
        algorithm: :concurrently
    else
      remove_index :geneva_drive_step_executions, name: INDEX_NAME
    end
  end
end
