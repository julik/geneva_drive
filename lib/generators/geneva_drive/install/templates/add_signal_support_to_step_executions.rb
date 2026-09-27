# frozen_string_literal: true

class AddSignalSupportToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  include GenevaDrive::MigrationHelpers

  def change
    unless column_exists?(:geneva_drive_step_executions, :signal_id)
      # The attachment pin: which signal this execution is processing. One
      # signal may be pinned by many executions, so this lives on the
      # execution side. Match the primary key type (bigint or uuid) of the
      # signals table.
      # No foreign key constraint - SQLite rewrites the table on
      # add_foreign_key, which can destroy data.
      add_column :geneva_drive_step_executions, :signal_id, geneva_drive_key_type
      add_index :geneva_drive_step_executions, :signal_id
    end

    unless column_exists?(:geneva_drive_step_executions, :waiting_since)
      # When the execution parked waiting for a signal, so "waiting for N
      # days" is queryable without abusing updated_at.
      add_column :geneva_drive_step_executions, :waiting_since, :datetime
    end
  end
end
