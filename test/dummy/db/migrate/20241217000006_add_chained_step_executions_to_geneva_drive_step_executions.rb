# frozen_string_literal: true

class AddChainedStepExecutionsToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  include GenevaDrive::MigrationHelpers

  def change
    # Add continues_from_id to link chained step executions.
    # Match the primary key type (bigint or uuid) of the step_executions table.
    # No foreign key constraint — SQLite rewrites the table on add_foreign_key,
    # which can destroy data.
    add_column :geneva_drive_step_executions, :continues_from_id, geneva_drive_key_type
    add_index :geneva_drive_step_executions, :continues_from_id

    # Remove completed_iterations - it's unnecessary bookkeeping
    remove_column :geneva_drive_step_executions, :completed_iterations, :integer

    # Remove 'suspended' state - executions now complete and spawn successors
    reversible do |direction|
      direction.up do
        # Convert any suspended executions to completed
        execute <<-SQL
          UPDATE geneva_drive_step_executions
          SET state = 'completed'
          WHERE state = 'suspended';
        SQL

        # Update unique constraint: only scheduled and in_progress are active
        update_unique_index_without_suspended
      end

      direction.down do
        restore_suspended_unique_index
      end
    end
  end

  private

  def update_unique_index_without_suspended
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

  def restore_suspended_unique_index
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
end
