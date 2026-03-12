# frozen_string_literal: true

class AddMetadataToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  def change
    return if column_exists?(:geneva_drive_step_executions, :metadata)

    adapter = connection.adapter_name.downcase

    if adapter.include?("postgresql")
      add_column :geneva_drive_step_executions, :metadata, :jsonb
    elsif adapter.include?("mysql")
      add_column :geneva_drive_step_executions, :metadata, :text, limit: 4_294_967_295
    else
      add_column :geneva_drive_step_executions, :metadata, :text
    end
  end
end
