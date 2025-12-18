# frozen_string_literal: true

module GenevaDrive
  # Helper methods for GenevaDrive migrations.
  # Provides runtime detection of database adapter and primary key format,
  # plus database-specific constraint creation.
  #
  # @example Using in a migration
  #   class CreateGenevaDriveWorkflows < ActiveRecord::Migration[7.2]
  #     include GenevaDrive::MigrationHelpers
  #
  #     def change
  #       create_table :geneva_drive_workflows, **geneva_drive_table_options do |t|
  #         t.references :hero, polymorphic: true, type: geneva_drive_key_type
  #         # ...
  #       end
  #       add_workflow_uniqueness_constraint
  #     end
  #   end
  #
  module MigrationHelpers
    # Detects the appropriate key type for GenevaDrive tables.
    # Returns :uuid if the schema predominantly uses UUIDs, otherwise :bigint.
    #
    # @return [Symbol] :uuid or :bigint
    def geneva_drive_key_type
      tables = connection.tables.reject { |t| t.start_with?("schema_", "ar_") }
      return :bigint if tables.empty?

      uuid_count = 0
      other_count = 0

      tables.each do |table_name|
        columns = connection.columns(table_name)
        id_column = columns.find { |c| c.name == "id" }
        next unless id_column

        if id_column.sql_type.downcase.match?(/uuid|char\(36\)|varchar\(36\)/)
          uuid_count += 1
        else
          other_count += 1
        end
      end

      (uuid_count > other_count) ? :uuid : :bigint
    end

    # Returns options hash for create_table based on detected primary key type.
    #
    # @return [Hash] options for create_table (e.g., {id: :uuid} or {})
    def geneva_drive_table_options
      (geneva_drive_key_type == :uuid) ? {id: :uuid} : {}
    end

    # Returns the current database adapter name.
    #
    # @return [String] the adapter name (e.g., 'postgresql', 'mysql2', 'sqlite3')
    def geneva_drive_adapter
      connection.adapter_name.downcase
    end

    # Checks if the database is PostgreSQL.
    #
    # @return [Boolean] true if PostgreSQL
    def postgresql?
      geneva_drive_adapter.include?("postgresql")
    end

    # Checks if the database is MySQL.
    #
    # @return [Boolean] true if MySQL
    def mysql?
      geneva_drive_adapter.include?("mysql")
    end

    # Checks if the database is SQLite.
    #
    # @return [Boolean] true if SQLite
    def sqlite?
      geneva_drive_adapter.include?("sqlite")
    end

    # Adds the workflow uniqueness constraint.
    # Uses database-specific strategy (partial index or generated column).
    # Ensures only one ongoing workflow per hero (unless allow_multiple).
    #
    # @return [void]
    def add_workflow_uniqueness_constraint
      if postgresql?
        execute <<-SQL
          CREATE UNIQUE INDEX index_workflows_unique_ongoing
          ON geneva_drive_workflows (type, hero_type, hero_id)
          WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = false;
        SQL
      elsif mysql?
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
      elsif sqlite?
        execute <<-SQL
          CREATE UNIQUE INDEX index_workflows_unique_ongoing
          ON geneva_drive_workflows (type, hero_type, hero_id)
          WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = 0;
        SQL
      end
    end

    # Adds the step execution uniqueness constraint.
    # Ensures only one active (scheduled/in_progress) step per workflow.
    #
    # @return [void]
    def add_step_execution_uniqueness_constraint
      if postgresql?
        execute <<-SQL
          CREATE UNIQUE INDEX index_step_executions_one_active
          ON geneva_drive_step_executions (workflow_id)
          WHERE state IN ('scheduled', 'in_progress');
        SQL
      elsif mysql?
        execute <<-SQL
          ALTER TABLE geneva_drive_step_executions
          ADD COLUMN active_unique_key VARCHAR(767)
          AS (
            CASE
              WHEN state IN ('scheduled', 'in_progress')
              THEN CAST(workflow_id AS CHAR)
              ELSE NULL
            END
          ) STORED;
        SQL
        execute <<-SQL
          CREATE UNIQUE INDEX index_step_executions_one_active
          ON geneva_drive_step_executions (active_unique_key);
        SQL
      elsif sqlite?
        execute <<-SQL
          CREATE UNIQUE INDEX index_step_executions_one_active
          ON geneva_drive_step_executions (workflow_id)
          WHERE state IN ('scheduled', 'in_progress');
        SQL
      end
    end
  end
end
