# frozen_string_literal: true

# Signals: external events delivered to a workflow, and the two columns on
# step executions that let one park until a matching event arrives. Both halves
# ship together - a signals table nobody can wait on is useless, and a waiting
# step with nowhere to read its event from is worse - so they are one migration.
class AddSignalsSupportToGenevaDrive < ActiveRecord::Migration[7.2]
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

      # Lifecycle: pending -> claimed -> consumed
      t.string :state, null: false, default: "pending"

      # Serialized payload, same flavour logic as the resumable step cursor:
      # jsonb on PostgreSQL, json on MySQL and SQLite, plain LONGTEXT on
      # MariaDB, which has no JSON type. See geneva_drive_json_column.
      payload_type, payload_options = geneva_drive_json_column
      t.column :payload, payload_type, **payload_options

      t.datetime :claimed_at
      t.datetime :consumed_at

      # How many executions have attached to this signal, and how many of
      # those attached chains have resolved cleanly. For a linear workflow
      # both end at 1 (more claims if the step was retried); when one signal
      # is dispatched onto several concurrent executions the pair is the
      # progress readout of that fan-out. Counters, not the lifecycle state -
      # the `state` column above is what says claimed or consumed.
      t.bigint :claimed, null: false, default: 0
      t.bigint :consumed, null: false, default: 0

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

    unless column_exists?(:geneva_drive_step_executions, :signal_id)
      # The attachment pin: which signal this execution is processing. One
      # signal may be pinned by many executions, so this lives on the
      # execution side. Match the primary key type (bigint or uuid) of the
      # signals table.
      # No foreign key constraint - SQLite rewrites the table on
      # add_foreign_key, which can destroy data.
      add_column :geneva_drive_step_executions, :signal_id, key_type
      add_index :geneva_drive_step_executions, :signal_id
    end

    unless column_exists?(:geneva_drive_step_executions, :waiting_since)
      # When the execution parked waiting for a signal, so "waiting for N
      # days" is queryable without abusing updated_at.
      add_column :geneva_drive_step_executions, :waiting_since, :datetime
    end
  end
end
