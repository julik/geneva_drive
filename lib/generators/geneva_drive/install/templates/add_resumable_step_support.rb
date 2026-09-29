# frozen_string_literal: true

class AddResumableStepSupportToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  include GenevaDrive::MigrationHelpers

  def change
    unless column_exists?(:geneva_drive_step_executions, :cursor)
      # Cursor for resumable steps. Database-native JSON where there is one -
      # jsonb on PostgreSQL, json on MySQL and SQLite - and plain LONGTEXT on
      # MariaDB, which has no JSON type. See geneva_drive_json_column.
      cursor_type, cursor_options = geneva_drive_json_column
      add_column :geneva_drive_step_executions, :cursor, cursor_type, **cursor_options
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
