# frozen_string_literal: true

class AddResumableStepSupportToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  include GenevaDrive::MigrationHelpers

  def change
    unless column_exists?(:geneva_drive_step_executions, :cursor)
      # Cursor for resumable steps. Use database-native JSON type:
      # - PostgreSQL: jsonb (indexed, efficient, supports containment queries)
      # - MySQL 5.7+: json (native validation and storage)
      # - SQLite: json (Rails handles as TEXT with serialization)
      if connection.adapter_name.downcase.include?("postgresql")
        add_column :geneva_drive_step_executions, :cursor, :jsonb
      else
        add_column :geneva_drive_step_executions, :cursor, :json
      end
    end

    unless column_exists?(:geneva_drive_step_executions, :continues_from_id)
      # Link successor executions to their predecessor, chaining the execution
      # records of a resumable step. Match the primary key type (bigint or uuid)
      # of the step_executions table.
      # No foreign key constraint - SQLite rewrites the table on add_foreign_key,
      # which can destroy data.
      add_column :geneva_drive_step_executions, :continues_from_id, geneva_drive_key_type
      add_index :geneva_drive_step_executions, :continues_from_id
    end
  end
end
