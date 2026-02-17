# frozen_string_literal: true

class AddResumableStepSupportToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  def change
    # Use database-native JSON type:
    # - PostgreSQL: jsonb (indexed, efficient, supports containment queries)
    # - MySQL 5.7+: json (native validation and storage)
    # - SQLite: json (Rails handles as TEXT with serialization)
    adapter = connection.adapter_name.downcase
    if adapter.include?("postgresql")
      add_column :geneva_drive_step_executions, :cursor, :jsonb
    else
      add_column :geneva_drive_step_executions, :cursor, :json
    end

    add_column :geneva_drive_step_executions, :completed_iterations, :integer, default: 0, null: false

    reversible do |direction|
      direction.up { update_unique_index_for_suspended_state }
      direction.down { restore_original_unique_index }
    end
  end

  private

  def update_unique_index_for_suspended_state
    # Update unique constraint to include 'suspended' as an active state.
    # The constraint ensures only one active step execution per workflow.
    adapter = connection.adapter_name.downcase

    if adapter.include?("postgresql")
      execute <<-SQL
        DROP INDEX IF EXISTS index_geneva_drive_step_executions_one_active;
      SQL
      execute <<-SQL
        CREATE UNIQUE INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions (workflow_id)
        WHERE state IN ('scheduled', 'in_progress', 'suspended');
      SQL
    elsif adapter.include?("mysql")
      # Drop the old generated column and index
      execute <<-SQL
        DROP INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions;
      SQL
      execute <<-SQL
        ALTER TABLE geneva_drive_step_executions
        DROP COLUMN active_unique_key;
      SQL
      # Create new generated column including suspended state
      execute <<-SQL
        ALTER TABLE geneva_drive_step_executions
        ADD COLUMN active_unique_key VARCHAR(767)
        AS (
          CASE
            WHEN state IN ('scheduled', 'in_progress', 'suspended')
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
        DROP INDEX IF EXISTS index_geneva_drive_step_executions_one_active;
      SQL
      execute <<-SQL
        CREATE UNIQUE INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions (workflow_id)
        WHERE state IN ('scheduled', 'in_progress', 'suspended');
      SQL
    end
  end

  def restore_original_unique_index
    # Restore original unique constraint without 'suspended' state
    adapter = connection.adapter_name.downcase

    if adapter.include?("postgresql")
      execute <<-SQL
        DROP INDEX IF EXISTS index_geneva_drive_step_executions_one_active;
      SQL
      execute <<-SQL
        CREATE UNIQUE INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions (workflow_id)
        WHERE state IN ('scheduled', 'in_progress');
      SQL
    elsif adapter.include?("mysql")
      execute <<-SQL
        DROP INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions;
      SQL
      execute <<-SQL
        ALTER TABLE geneva_drive_step_executions
        DROP COLUMN active_unique_key;
      SQL
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
        DROP INDEX IF EXISTS index_geneva_drive_step_executions_one_active;
      SQL
      execute <<-SQL
        CREATE UNIQUE INDEX index_geneva_drive_step_executions_one_active
        ON geneva_drive_step_executions (workflow_id)
        WHERE state IN ('scheduled', 'in_progress');
      SQL
    end
  end
end
