# frozen_string_literal: true

class CreateGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  def change
    create_table :geneva_drive_step_executions do |t|
      # Link to workflow
      t.references :workflow,
        null: false,
        foreign_key: {to_table: :geneva_drive_workflows},
        index: true

      # Which step this execution represents
      t.string :step_name, null: false

      # Execution state machine
      t.string :state, null: false, default: "scheduled", index: true

      # Outcome for audit purposes
      t.string :outcome

      # Scheduling
      t.datetime :scheduled_for, null: false, index: true

      # Execution tracking (individual timestamps for audit trail)
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.datetime :canceled_at
      t.datetime :skipped_at

      # Error tracking
      t.text :error_message
      t.text :error_backtrace

      # Job tracking (for debugging)
      t.string :job_id

      t.timestamps
    end

    # Index for finding scheduled executions
    add_index :geneva_drive_step_executions,
      [:state, :scheduled_for],
      name: "index_step_executions_scheduled"

    # Index for workflow execution history
    add_index :geneva_drive_step_executions, [:workflow_id, :created_at]

    # Index for common query patterns
    add_index :geneva_drive_step_executions, [:workflow_id, :state]

    # PostgreSQL partial index for uniqueness
    # One active step execution per workflow
    execute <<-SQL
      CREATE UNIQUE INDEX index_step_executions_one_active_per_workflow
      ON geneva_drive_step_executions (workflow_id)
      WHERE state IN ('scheduled', 'executing');
    SQL
  end
end
