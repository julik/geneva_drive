# frozen_string_literal: true

class CreateGenevaDriveSignals < ActiveRecord::Migration[7.2]
  include GenevaDrive::MigrationHelpers

  def change
    key_type = geneva_drive_key_type
    adapter = connection.adapter_name.downcase

    # Build reference options - we add the foreign key separately to avoid
    # MySQL type mismatch (see below).
    reference_options = {
      null: false,
      index: true
    }
    reference_options[:type] = key_type if key_type == :uuid

    create_table :geneva_drive_signals, **geneva_drive_table_options do |t|
      # Link to workflow (cascade delete when the workflow is deleted)
      t.references :workflow, **reference_options

      # The event name, as passed to Workflow#signal!
      t.string :name, null: false

      # Optional caller-supplied deduplication key. NULLs are distinct in
      # unique indexes on PostgreSQL, MySQL and SQLite alike, so signals
      # without an idempotency key always insert.
      t.string :idempotency_key

      # pending -> claimed -> consumed
      t.string :state, null: false, default: "pending"

      # Serialized payload. Use the database-native JSON type, same flavor
      # logic as the resumable step cursor:
      # - PostgreSQL: jsonb
      # - MySQL 5.7+: json
      # - SQLite: json (Rails handles as TEXT with serialization)
      if adapter.include?("postgresql")
        t.jsonb :payload
      else
        t.json :payload
      end

      t.datetime :claimed_at
      t.datetime :consumed_at

      t.timestamps
    end

    # Deduplication: one signal per (workflow, name, idempotency_key)
    add_index :geneva_drive_signals, [:workflow_id, :name, :idempotency_key],
      unique: true, name: "index_geneva_drive_signals_dedup"

    # Scanning a workflow's unconsumed signals
    add_index :geneva_drive_signals, [:workflow_id, :state]

    # Add foreign key separately to avoid MySQL type mismatch (UNSIGNED vs SIGNED bigint)
    # MySQL creates primary keys as UNSIGNED but references as SIGNED, causing FK constraint failure
    unless adapter.include?("mysql")
      add_foreign_key :geneva_drive_signals, :geneva_drive_workflows,
        column: :workflow_id, on_delete: :cascade
    end
  end
end
