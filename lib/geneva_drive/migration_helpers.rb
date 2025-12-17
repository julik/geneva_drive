# frozen_string_literal: true

module GenevaDrive
  # Helper methods for GenevaDrive migrations.
  # Provides automatic detection of primary key types based on the existing schema.
  #
  # @example Using in a migration
  #   class CreateGenevaDriveWorkflows < ActiveRecord::Migration[7.2]
  #     include GenevaDrive::MigrationHelpers
  #
  #     def change
  #       key_type = geneva_drive_key_type
  #       # Use key_type for table creation
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
  end
end
