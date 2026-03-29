# frozen_string_literal: true

class AllowNullHeroOnGenevaDriveWorkflows < ActiveRecord::Migration[7.2]
  def change
    return unless column_exists?(:geneva_drive_workflows, :hero_type)

    adapter = connection.adapter_name.downcase
    if adapter.include?("sqlite")
      allow_null_hero_sqlite
    else
      change_column_null :geneva_drive_workflows, :hero_type, true
      change_column_null :geneva_drive_workflows, :hero_id, true
    end
  end

  private

  def allow_null_hero_sqlite
    reversible do |direction|
      direction.up do
        # SQLite cannot ALTER COLUMN to remove NOT NULL without a full table
        # recreation. We perform an atomic table swap to avoid foreign-key
        # corruption issues. See CLAUDE.md / AGENTS.md for context.

        # 1. Introspect the existing table via ActiveRecord
        old_columns = connection.columns(:geneva_drive_workflows)
        old_pk = connection.primary_key(:geneva_drive_workflows)
        pk_col = old_columns.find { |c| c.name == old_pk }
        data_cols = old_columns.reject { |c| c.name == old_pk }

        # 2. Create the replacement table using the schema DSL
        create_table :geneva_drive_workflows_new, id: pk_col.type do |t|
          data_cols.each do |col|
            nullable = %w[hero_type hero_id].include?(col.name) || col.null
            opts = {null: nullable}
            opts[:default] = col.default_function || col.default unless col.default.nil? && col.default_function.nil?
            t.column col.name, col.type, **opts
          end
        end

        # 3. Copy all data
        col_names = old_columns.map(&:name).join(", ")
        execute "INSERT INTO geneva_drive_workflows_new (#{col_names}) SELECT #{col_names} FROM geneva_drive_workflows"

        # 4. Atomic swap
        drop_table :geneva_drive_workflows
        rename_table :geneva_drive_workflows_new, :geneva_drive_workflows

        # 5. Recreate indexes (they are lost during the swap)
        add_index :geneva_drive_workflows, :type
        add_index :geneva_drive_workflows, :state
        add_index :geneva_drive_workflows, [:hero_type, :hero_id]
        execute <<-SQL
          CREATE UNIQUE INDEX index_geneva_drive_workflows_unique_ongoing
          ON geneva_drive_workflows (type, hero_type, hero_id)
          WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = 0;
        SQL
      end

      direction.down do
        raise ActiveRecord::IrreversibleMigration,
          "Cannot re-add NOT NULL on hero columns in SQLite without risking data loss"
      end
    end
  end
end
