# frozen_string_literal: true

require "test_helper"

class MigrationHelpersTest < ActiveSupport::TestCase
  FakeColumn = Struct.new(:name, :sql_type, :default_function, keyword_init: true)

  # Creates a fresh harness with the given fake columns as the app id columns.
  def build_migration(columns = [])
    harness = Class.new {
      include GenevaDrive::MigrationHelpers

      attr_accessor :fake_columns

      private

      def _geneva_drive_app_id_columns
        fake_columns
      end
    }.new
    harness.fake_columns = columns
    harness
  end

  # --- geneva_drive_key_type ---

  test "returns :bigint when there are no application tables" do
    assert_equal :bigint, build_migration.geneva_drive_key_type
  end

  test "returns :bigint when most tables use integer ids" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "bigint", default_function: nil),
      FakeColumn.new(name: "id", sql_type: "integer", default_function: nil),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "gen_random_uuid()")
    ]
    assert_equal :bigint, build_migration(columns).geneva_drive_key_type
  end

  test "returns :uuid when most tables use uuid ids" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "gen_random_uuid()"),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "gen_random_uuid()"),
      FakeColumn.new(name: "id", sql_type: "bigint", default_function: nil)
    ]
    assert_equal :uuid, build_migration(columns).geneva_drive_key_type
  end

  test "returns :uuid for varchar(36) columns (MySQL-style UUIDs)" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "varchar(36)", default_function: nil),
      FakeColumn.new(name: "id", sql_type: "char(36)", default_function: nil)
    ]
    assert_equal :uuid, build_migration(columns).geneva_drive_key_type
  end

  test "returns :bigint on a tie" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "gen_random_uuid()"),
      FakeColumn.new(name: "id", sql_type: "bigint", default_function: nil)
    ]
    assert_equal :bigint, build_migration(columns).geneva_drive_key_type
  end

  # --- geneva_drive_table_options ---

  test "returns empty hash for bigint key type" do
    assert_equal({}, build_migration.geneva_drive_table_options)
  end

  test "returns id: :uuid without default when uuid columns have no default_function" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: nil),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: nil)
    ]
    assert_equal({id: :uuid}, build_migration(columns).geneva_drive_table_options)
  end

  test "returns id: :uuid with dominant default function" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "uuid_generate_v7()"),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "uuid_generate_v7()"),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "gen_random_uuid()")
    ]
    expected = {id: :uuid, default: "uuid_generate_v7()"}
    assert_equal expected, build_migration(columns).geneva_drive_table_options
  end

  test "returns id: :uuid without default when defaults are tied" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "uuid_generate_v7()"),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "gen_random_uuid()")
    ]
    assert_equal({id: :uuid}, build_migration(columns).geneva_drive_table_options)
  end

  test "returns id: :uuid with default when all uuid columns agree" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "uuidv7()"),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "uuidv7()"),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "uuidv7()")
    ]
    expected = {id: :uuid, default: "uuidv7()"}
    assert_equal expected, build_migration(columns).geneva_drive_table_options
  end

  test "ignores non-uuid columns when determining the default function" do
    columns = [
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "uuidv7()"),
      FakeColumn.new(name: "id", sql_type: "uuid", default_function: "uuidv7()"),
      FakeColumn.new(name: "id", sql_type: "bigint", default_function: nil)
    ]
    expected = {id: :uuid, default: "uuidv7()"}
    assert_equal expected, build_migration(columns).geneva_drive_table_options
  end

  # --- _geneva_drive_app_id_columns (integration with real connection) ---

  test "excludes geneva_drive_ tables from the quorum" do
    tables = ActiveRecord::Base.connection.tables
    assert tables.include?("geneva_drive_workflows"), "precondition: geneva_drive_workflows table must exist"

    real_migration = Class.new(ActiveRecord::Migration::Current) {
      include GenevaDrive::MigrationHelpers
    }.new("test", "20240101000000")

    id_columns = real_migration.send(:_geneva_drive_app_id_columns)

    geneva_drive_table_count = tables.count { |t| t.start_with?("geneva_drive_") }
    all_tables_with_id = tables.reject { |t| t.start_with?("schema_", "ar_") }.count do |t|
      ActiveRecord::Base.connection.columns(t).any? { |c| c.name == "id" }
    end
    app_tables_with_id = all_tables_with_id - geneva_drive_table_count

    assert_equal app_tables_with_id, id_columns.size
  end
end
