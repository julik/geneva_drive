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
      t.string :next_step_name

      # Multiple workflows of same type for same hero
      t.boolean :allow_multiple, default: false, null: false

      # Timestamps
      t.datetime :started_at
      t.datetime :transitioned_at

      t.timestamps
    end

    # Polymorphic index
    add_index :geneva_drive_workflows, [:hero_type, :hero_id]

    # Database-specific uniqueness constraint for ongoing workflows
    # Ensures only one ongoing workflow per (type, hero) unless allow_multiple is true
    adapter = connection.adapter_name.downcase
    if adapter.include?("postgresql")
      execute <<-SQL
        CREATE UNIQUE INDEX index_workflows_unique_ongoing
        ON geneva_drive_workflows (type, hero_type, hero_id)
        WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = false;
      SQL
    elsif adapter.include?("mysql")
      execute <<-SQL
        ALTER TABLE geneva_drive_workflows
        ADD COLUMN ongoing_unique_key VARCHAR(767)
        AS (
          CASE
            WHEN state NOT IN ('finished', 'canceled') AND allow_multiple = 0
            THEN CONCAT(type, '-', hero_type, '-', hero_id)
            ELSE NULL
          END
        ) STORED;
      SQL
      execute <<-SQL
        CREATE UNIQUE INDEX index_workflows_unique_ongoing
        ON geneva_drive_workflows (ongoing_unique_key);
      SQL
    elsif adapter.include?("sqlite")
      execute <<-SQL
        CREATE UNIQUE INDEX index_workflows_unique_ongoing
        ON geneva_drive_workflows (type, hero_type, hero_id)
        WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = 0;
      SQL
    end
  end
end
