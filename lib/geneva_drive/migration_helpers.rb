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
    @_geneva_drive_key_type ||= begin
      id_columns = _geneva_drive_app_id_columns
      return :bigint if id_columns.empty?

      uuid_count = id_columns.count { |col| col.sql_type.downcase.match?(/uuid|char\(36\)|varchar\(36\)/) }
      other_count = id_columns.size - uuid_count

      (uuid_count > other_count) ? :uuid : :bigint
    end
  end

  # Returns options hash for create_table based on detected primary key type.
  # When UUIDs are detected, includes the most common default function from
  # existing tables so that new tables match the application's convention
  # (e.g. uuid_generate_v7 instead of gen_random_uuid).
  #
  # @return [Hash] options for create_table (e.g., `{id: :uuid, default: "uuid7()"}` or `{}`)
  def geneva_drive_table_options
    return {} unless geneva_drive_key_type == :uuid

    options = {id: :uuid}
    if (default_function = _geneva_drive_dominant_uuid_default)
      options[:default] = default_function
    end
    options
  end

  private

  # Collects the id column from every application table (excludes system
  # tables and GenevaDrive's own tables so the quorum reflects the
  # application's convention, not our own).
  #
  # @return [Array<ActiveRecord::ConnectionAdapters::Column>]
  def _geneva_drive_app_id_columns
    tables = connection.tables.reject { |t| t.start_with?("schema_", "ar_", "geneva_drive_") }
    tables.filter_map do |table_name|
      connection.columns(table_name).find { |c| c.name == "id" }
    end
  end

  # Finds the most common non-nil default among UUID primary key columns.
  # Returns nil when there is no clear dominant default (or no defaults at all).
  #
  # @return [String, nil] a SQL default expression string, or nil
  def _geneva_drive_dominant_uuid_default
    id_columns = _geneva_drive_app_id_columns
    uuid_defaults = id_columns.filter_map do |col|
      next unless col.sql_type.downcase.match?(/uuid|char\(36\)|varchar\(36\)/)
      col.default_function
    end

    return nil if uuid_defaults.empty?

    # Pick the most frequently occurring default function
    tally = uuid_defaults.tally
    winner, count = tally.max_by { |_fn, c| c }

    # Only use it if it's a clear majority (more than any other single default)
    runner_up_count = tally.reject { |fn, _| fn == winner }.values.max || 0
    (count > runner_up_count) ? winner : nil
  end
end
