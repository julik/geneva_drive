# frozen_string_literal: true

# Helper methods for GenevaDrive migrations.
# Provides runtime detection of database adapter and primary key format.
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
#     end
#   end
#
module GenevaDrive::MigrationHelpers
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
  # @return [Hash] options for create_table (e.g., `{id: :uuid}` or `{id: :bigint}`)
  def geneva_drive_table_options
    (geneva_drive_key_type == :uuid) ? {id: :uuid} : {id: :bigint}
  end
end
