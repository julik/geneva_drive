# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)

# Ensure GenevaDrive migrations exist and database is prepared.
# The generator is the single source of truth for migrations.
unless defined?(GENEVA_DRIVE_TEST_DB_PREPARED)
  GENEVA_DRIVE_TEST_DB_PREPARED = true

  dummy_root = File.expand_path("../test/dummy", __dir__)
  migrations = Dir.glob("#{dummy_root}/db/migrate/*geneva_drive*.rb")
  tables_exist = begin
    ActiveRecord::Base.connection.table_exists?("geneva_drive_workflows")
  rescue
    false
  end

  if migrations.empty? && !tables_exist
    puts "Generating GenevaDrive migrations..."
    Dir.chdir(dummy_root) do
      system("bin/rails", "generate", "geneva_drive:install", "--skip") || abort("Failed to generate migrations")
      system("bin/rails", "db:migrate") || abort("Failed to run migrations")
    end
  elsif migrations.any? && !tables_exist
    puts "Running pending migrations..."
    Dir.chdir(dummy_root) do
      system("bin/rails", "db:prepare") || abort("Failed to prepare database")
    end
  end
end

require "rails/test_help"

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [File.expand_path("fixtures", __dir__)]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end

# Test helper methods
class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: :number_of_processors)

  # Helper to create a test user
  def create_user(attrs = {})
    User.create!({email: "test@example.com", name: "Test User"}.merge(attrs))
  end

  # Helper to run all pending jobs synchronously
  def perform_enqueued_jobs_now
    while (job = ActiveJob::Base.queue_adapter.enqueued_jobs.shift)
      job[:job].perform_now(*job[:args])
    end
  end
end
