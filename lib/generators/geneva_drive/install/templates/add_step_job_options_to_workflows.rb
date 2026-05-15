# frozen_string_literal: true

class AddStepJobOptionsToGenevaDriveWorkflows < ActiveRecord::Migration[7.2]
  def change
    return if column_exists?(:geneva_drive_workflows, :step_job_options)

    adapter = connection.adapter_name.downcase

    if adapter.include?("postgresql")
      add_column :geneva_drive_workflows, :step_job_options, :jsonb
    elsif adapter.include?("mysql")
      add_column :geneva_drive_workflows, :step_job_options, :text, limit: 4_294_967_295
    else
      add_column :geneva_drive_workflows, :step_job_options, :text
    end
  end
end
