# frozen_string_literal: true

class AddMetadataToGenevaDriveWorkflows < ActiveRecord::Migration[7.2]
  def change
    return if column_exists?(:geneva_drive_workflows, :metadata)

    adapter = connection.adapter_name.downcase

    if adapter.include?("postgresql")
      add_column :geneva_drive_workflows, :metadata, :jsonb
    elsif adapter.include?("mysql")
      add_column :geneva_drive_workflows, :metadata, :text, limit: 4_294_967_295
    else
      add_column :geneva_drive_workflows, :metadata, :text
    end
  end
end
