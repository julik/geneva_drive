# frozen_string_literal: true

class CreateGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  include GenevaDrive::MigrationHelpers

  def change
    key_type = geneva_drive_key_type
    adapter = connection.adapter_name.downcase

    # Build reference options - we add foreign key separately to avoid MySQL type mismatch
    reference_options = {
      null: false,
      index: true
    }
    reference_options[:type] = key_type if key_type == :uuid

    create_table :geneva_drive_step_executions, **geneva_drive_table_options do |t|
      # Link to workflow (cascade delete when workflow is deleted)
      t.references :workflow, **reference_options

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
      t.string :error_class_name
      t.text :error_message
      t.text :error_backtrace

      # Job tracking (for debugging)
      t.string :job_id

      t.timestamps
    end

    # Index for finding scheduled executions
    add_index :geneva_drive_step_executions,
      [:state, :scheduled_for],
      name: "index_geneva_drive_step_executions_scheduled"

    # Index for workflow execution history
    add_index :geneva_drive_step_executions, [:workflow_id, :created_at]

    # Index for common query patterns
    add_index :geneva_drive_step_executions, [:workflow_id, :state]

    # Add foreign key separately to avoid MySQL type mismatch (UNSIGNED vs SIGNED bigint)
    # MySQL creates primary keys as UNSIGNED but references as SIGNED, causing FK constraint failure
    unless adapter.include?("mysql")
      add_foreign_key :geneva_drive_step_executions, :geneva_drive_workflows,
        column: :workflow_id, on_delete: :cascade
    end

    reversible do |direction|
      direction.up { create_db_specific_indices }
    end
  end

  def create_db_specific_indices
    # Database-specific uniqueness constraint for active step executions
    # Ensures only one active (scheduled/in_progress) step per workflow
    adapter = connection.adapter_name.downcase
    if adapter.include?("postgresql")
      execute <<-SQL
        CREATE UNIQUE INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions (workflow_id)
        WHERE state IN ('scheduled', 'in_progress');
      SQL
    elsif adapter.include?("mysql")
      execute <<-SQL
        ALTER TABLE geneva_drive_step_executions
        ADD COLUMN active_unique_key VARCHAR(767)
        AS (
          CASE
            WHEN state IN ('scheduled', 'in_progress')
            THEN CAST(workflow_id AS CHAR)
            ELSE NULL
          END
        ) STORED;
      SQL
      execute <<-SQL
        CREATE UNIQUE INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions (active_unique_key);
      SQL
    elsif adapter.include?("sqlite")
      execute <<-SQL
        CREATE UNIQUE INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions (workflow_id)
        WHERE state IN ('scheduled', 'in_progress');
      SQL
    end
  end
end
