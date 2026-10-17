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
#         t.references :hero, polymorphic: true, type: geneva_drive_hero_key_type
#         # ...
#       end
#     end
#   end
#
module GenevaDrive::MigrationHelpers
  UUID_SQL_TYPE = /uuid|char\(36\)|varchar\(36\)/
  # SQLite reports `id: :string` as a bare "varchar", without a length
  STRING_SQL_TYPE = /char|text|clob/

  # Detects the appropriate key type for GenevaDrive tables.
  # Returns :uuid if the schema predominantly uses UUIDs, otherwise :bigint.
  #
  # @return [Symbol] :uuid or :bigint
  def geneva_drive_key_type
    @_geneva_drive_key_type ||= begin
      id_columns = _geneva_drive_app_id_columns
      return :bigint if id_columns.empty?

      uuid_count = id_columns.count { |col| col.sql_type.downcase.match?(UUID_SQL_TYPE) }
      other_count = id_columns.size - uuid_count

      (uuid_count > other_count) ? :uuid : :bigint
    end
  end

  # Detects the column type for `hero_id` on the workflows table. Unlike
  # {#geneva_drive_key_type}, this also recognizes string primary keys of any
  # length (`varchar`, `char(n)`, `text`), so that heroes with string ids do not
  # get a `hero_id` that casts their ids to integers.
  #
  # Returns :uuid if the schema predominantly uses UUIDs, :string if it predominantly
  # uses UUIDs and string ids taken together, otherwise :bigint.
  #
  # @return [Symbol] :uuid, :string or :bigint
  def geneva_drive_hero_key_type
    @_geneva_drive_hero_key_type ||= begin
      sql_types = _geneva_drive_app_id_columns.map { |col| col.sql_type.downcase }
      uuid_count = sql_types.count { |t| t.match?(UUID_SQL_TYPE) }
      string_count = sql_types.count { |t| !t.match?(UUID_SQL_TYPE) && t.match?(STRING_SQL_TYPE) }
      integer_count = sql_types.size - uuid_count - string_count

      if uuid_count > string_count + integer_count
        :uuid
      elsif uuid_count + string_count > integer_count
        :string # a string column holds UUIDs just as well
      else
        :bigint
      end
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

  # Column type and options for a column that holds a JSON document.
  #
  # PostgreSQL gets jsonb and MySQL gets its native json. MariaDB gets neither:
  # it has no JSON type at all, `json` there being an alias for LONGTEXT with an
  # auto-generated CHECK constraint named after the column. Two things go wrong
  # with that alias. The schema dump comes back as `t.text` plus
  # `t.check_constraint name: "cursor"`, and loading that dump re-emits the
  # constraint name unquoted - `cursor` is reserved in MariaDB, so the load dies
  # on a syntax error, which takes out `db:schema:load` and every parallel test
  # worker with it. And because Rails types the column as text either way, a
  # Hash assigned to it is written out as `#inspect` rather than JSON, which the
  # very same CHECK constraint then rejects. Asking for plain LONGTEXT and doing
  # the JSON encoding in the model (see GenevaDrive::JsonColumn) sidesteps both.
  #
  # @return [Array(Symbol, Hash)] the column type and its options
  def geneva_drive_json_column
    adapter = connection.adapter_name.downcase

    if adapter.include?("postgresql")
      [:jsonb, {}]
    elsif connection.respond_to?(:mariadb?) && connection.mariadb?
      [:text, {limit: 4_294_967_295}]
    else
      [:json, {}]
    end
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
      next unless col.sql_type.downcase.match?(UUID_SQL_TYPE)
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
