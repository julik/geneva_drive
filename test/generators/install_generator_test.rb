# frozen_string_literal: true

require "fileutils"
require "open3"
require "json"
require "minitest/autorun"

# Test that the install generator creates working migrations.
# Uses a separate dummy_install app to avoid conflicts with the main test suite.
class InstallGeneratorTest < Minitest::Test
  DUMMY_INSTALL_PATH = File.expand_path("../dummy_install", __dir__)
  MIGRATIONS_PATH = File.join(DUMMY_INSTALL_PATH, "db/migrate")

  def setup
    # Clean up any existing GenevaDrive migrations
    Dir.glob(File.join(MIGRATIONS_PATH, "*geneva_drive*.rb")).each do |f|
      FileUtils.rm(f)
    end

    # Remove schema.rb to force fresh migration
    FileUtils.rm_f(File.join(DUMMY_INSTALL_PATH, "db/schema.rb"))
  end

  def test_generator_creates_working_migrations
    # Run the generator
    run_in_dummy("bin/rails generate geneva_drive:install --skip")

    # Verify migration files were created
    workflow_migration = Dir.glob(File.join(MIGRATIONS_PATH, "*_create_geneva_drive_workflows.rb")).first
    step_migration = Dir.glob(File.join(MIGRATIONS_PATH, "*_create_geneva_drive_step_executions.rb")).first

    assert workflow_migration, "Workflow migration should be created"
    assert step_migration, "Step execution migration should be created"

    # Drop and recreate database, run migrations
    # For SQLite we skip db:drop since it's just a file
    if sqlite?
      run_in_dummy("bin/rails db:migrate RAILS_ENV=test")
    else
      run_in_dummy("bin/rails db:drop db:create db:migrate RAILS_ENV=test")
    end

    # Query the actual database structure
    schema_info = JSON.parse(run_in_dummy(<<~RUBY))
      bin/rails runner -e test '
        tables = ActiveRecord::Base.connection.tables

        workflow_columns = ActiveRecord::Base.connection.columns("geneva_drive_workflows").map(&:name)
        step_columns = ActiveRecord::Base.connection.columns("geneva_drive_step_executions").map(&:name)

        workflow_indexes = ActiveRecord::Base.connection.indexes("geneva_drive_workflows").map(&:name)
        step_indexes = ActiveRecord::Base.connection.indexes("geneva_drive_step_executions").map(&:name)

        puts({
          tables: tables,
          workflow_columns: workflow_columns,
          step_columns: step_columns,
          workflow_indexes: workflow_indexes,
          step_indexes: step_indexes
        }.to_json)
      '
    RUBY

    # Verify tables exist
    assert_includes schema_info["tables"], "geneva_drive_workflows"
    assert_includes schema_info["tables"], "geneva_drive_step_executions"

    # Verify workflow table columns
    %w[id type hero_type hero_id state current_step_name allow_multiple started_at transitioned_at created_at updated_at].each do |col|
      assert_includes schema_info["workflow_columns"], col, "Workflow table should have #{col} column"
    end

    # Verify step execution table columns
    %w[id workflow_id step_name state outcome scheduled_for started_at completed_at failed_at canceled_at skipped_at error_message error_backtrace job_id created_at updated_at].each do |col|
      assert_includes schema_info["step_columns"], col, "Step execution table should have #{col} column"
    end

    # Verify uniqueness constraint indexes were created
    assert_includes schema_info["workflow_indexes"], "index_geneva_drive_workflows_unique_ongoing",
      "Workflow unique ongoing index should exist"
    assert_includes schema_info["step_indexes"], "index_geneva_drive_step_executions_one_active",
      "Step execution one active index should exist"
  end

  private

  def sqlite?
    database_url&.start_with?("sqlite")
  end

  def database_url
    ENV["DATABASE_URL"]
  end

  # Build a DATABASE_URL for the install test database
  # Changes the database name to avoid conflicts with the main test database
  def install_test_database_url
    url = database_url
    return nil if url.nil?

    if url.start_with?("sqlite")
      # For SQLite, use a different file in the dummy_install directory
      "sqlite3:db/install_test.sqlite3"
    elsif url.start_with?("mysql")
      # For MySQL, change the database name
      url.gsub("geneva_drive_test", "geneva_drive_install_test")
    elsif url.start_with?("postgres")
      # For PostgreSQL, change the database name
      url.gsub("geneva_drive_test", "geneva_drive_install_test")
    else
      url
    end
  end

  def run_in_dummy(command)
    # Set DATABASE_URL for the install test database
    # This ensures we use a separate database from the main test suite
    env = {}
    if (install_url = install_test_database_url)
      env["DATABASE_URL"] = install_url
    end

    stdout, stderr, status = Open3.capture3(
      env,
      command,
      chdir: DUMMY_INSTALL_PATH
    )

    unless status.success?
      flunk "Command failed: #{command}\nSTDOUT: #{stdout}\nSTDERR: #{stderr}"
    end

    stdout
  end
end
