# frozen_string_literal: true

class CreateGenevaDriveWorkflows < ActiveRecord::Migration[7.2]
  include GenevaDrive::MigrationHelpers

  def change
    create_table :geneva_drive_workflows, **geneva_drive_table_options do |t|
      # Core identification (STI)
      t.string :type, null: false, index: true

      # Polymorphic association to the hero of the workflow
      t.string :hero_type, null: false
      t.column :hero_id, geneva_drive_key_type, null: false

      # State machine
      t.string :state, null: false, default: "ready", index: true

      # Current position in workflow
      t.string :current_step_name

      # Multiple workflows of same type for same hero
      t.boolean :allow_multiple, default: false, null: false

      # Timestamps
      t.datetime :started_at
      t.datetime :transitioned_at

      t.timestamps
    end

    # Polymorphic index
    add_index :geneva_drive_workflows, [:hero_type, :hero_id]

    # Database-specific uniqueness constraint
    add_workflow_uniqueness_constraint
  end
end
