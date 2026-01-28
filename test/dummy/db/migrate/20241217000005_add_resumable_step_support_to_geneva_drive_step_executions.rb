# frozen_string_literal: true

class AddResumableStepSupportToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  def change
    # Add cursor column for resumable steps to track iteration progress.
    # Uses database-native JSON type:
    # - PostgreSQL: jsonb (indexed, efficient, supports containment queries)
    # - MySQL 5.7+: json (native validation and storage)
    # - SQLite: json (Rails handles as TEXT with serialization)
    adapter = connection.adapter_name.downcase
    if adapter.include?("postgresql")
      add_column :geneva_drive_step_executions, :cursor, :jsonb
    else
      add_column :geneva_drive_step_executions, :cursor, :json
    end

    # Add continues_from_id to link chained step executions.
    # When a resumable step pauses and resumes, a new execution is created
    # that continues from where the previous one left off.
    add_column :geneva_drive_step_executions, :continues_from_id, :bigint
    add_index :geneva_drive_step_executions, :continues_from_id
    add_foreign_key :geneva_drive_step_executions, :geneva_drive_step_executions,
      column: :continues_from_id, on_delete: :nullify
  end
end
