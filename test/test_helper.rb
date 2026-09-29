# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)

# Bring the dummy app's database in line with the migrations the install
# generator produces, recreating it from scratch whenever it has drifted.
#
# Rebuilding rather than migrating forward is deliberate. The generated
# migrations are gitignored and get fresh timestamps every time they are
# regenerated, so a database left behind by an earlier generation records
# versions that no longer exist on disk: every migration reads as pending, and
# replaying them onto the existing tables just fails on "table already exists".
unless defined?(GENEVA_DRIVE_TEST_DB_PREPARED)
  GENEVA_DRIVE_TEST_DB_PREPARED = true

  dummy_root = File.expand_path("../test/dummy", __dir__)
  db_config = ActiveRecord::Base.connection_db_config
  # Adapter-specific, and deliberately so - see the comment in the dummy app's
  # config/database.yml. Ask Rails for the path rather than rebuilding it here.
  schema_file = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config)

  # The generator is the single source of truth for migrations.
  if Dir.glob("#{dummy_root}/db/migrate/*geneva_drive*.rb").empty?
    puts "Generating GenevaDrive migrations..."
    Dir.chdir(dummy_root) do
      system("bin/rails", "generate", "geneva_drive:install", "--skip") || abort("Failed to generate migrations")
    end
  end

  on_disk = Dir.glob("#{dummy_root}/db/migrate/*.rb").map { |path| File.basename(path)[/\A\d+/] }
  applied = begin
    ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations").map(&:to_s)
  rescue
    [] # No database, or no schema_migrations in it yet
  end

  if (on_disk - applied).any? || !File.exist?(schema_file)
    puts "Recreating the #{db_config.adapter} test database..."
    # db:migrate seeds an empty database from the schema dump before applying
    # anything, so the outdated dump has to go first - otherwise it recreates
    # exactly the tables the migrations are about to create.
    File.delete(schema_file) if File.exist?(schema_file)
    # bin/rails cannot drop a database this process still holds a connection to.
    ActiveRecord::Base.connection_handler.clear_all_connections!
    Dir.chdir(dummy_root) do
      # One bin/rails per task, deliberately. Asking a single process to drop,
      # recreate and migrate carries its column cache across the drop, and the
      # schema it then dumps silently loses column defaults.
      system("bin/rails", "db:drop") || abort("Failed to drop the test database")
      system("bin/rails", "db:prepare") || abort("Failed to recreate the test database")
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

# Rails 8.1 clears Active Record's connections before forking the parallel test
# workers. 7.2 and 8.0 fork with them still open, and a libpq connection
# inherited across the fork takes the child down with a segfault in
# PG::Connection#connect_start as it opens its own - a race, so it only bites
# some of the time, which makes it maddening rather than merely broken. Where
# upstream has no pre-fork hook to register on, wrap the fork point itself.
unless ActiveSupport::Testing::Parallelization.respond_to?(:before_fork_hook)
  ActiveSupport::Testing::Parallelization.prepend(Module.new do
    def start
      ActiveRecord::Base.connection_handler.clear_all_connections!
      super
    end
  end)
end

# Test helper methods
class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: :number_of_processors)

  # Reset the metadata column detection cache before each test so that
  # stubs in one test don't poison the cache for subsequent tests in the
  # same parallel process.
  setup do
    GenevaDrive::StepExecution.reset_metadata_column_cache!
    GenevaDrive::StepExecution.reset_resumable_columns_cache!
    GenevaDrive::StepExecution.reset_signal_columns_cache!
    GenevaDrive::Signal.reset_table_available_cache!
    GenevaDrive::Workflow.reset_metadata_column_cache!
  end

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
