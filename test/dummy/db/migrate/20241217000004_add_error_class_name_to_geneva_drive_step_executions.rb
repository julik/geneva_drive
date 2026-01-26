# frozen_string_literal: true

class AddErrorClassNameToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  def change
    add_column :geneva_drive_step_executions, :error_class_name, :string, if_not_exists: true
  end
end
