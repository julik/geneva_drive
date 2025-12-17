# frozen_string_literal: true

class CreateGenevaDriveWorkflows < ActiveRecord::Migration[7.2]
  def change
    create_table :geneva_drive_workflows do |t|
      # Core identification (STI)
      t.string :type, null: false, index: true

      # Polymorphic association to the hero of the workflow
      t.string :hero_type, null: false
      t.bigint :hero_id, null: false

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

    # PostgreSQL partial index for uniqueness
    # One active workflow per hero (unless allow_multiple)
    execute <<-SQL
      CREATE UNIQUE INDEX index_workflows_unique_active
      ON geneva_drive_workflows (type, hero_type, hero_id)
      WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = false;
    SQL
  end
end
