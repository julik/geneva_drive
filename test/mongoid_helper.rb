# frozen_string_literal: true

# The test helper for the Mongoid suite (test/mongoid/**). Every file in that
# tree guards itself with `return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"`
# before requiring this, so run it through the rake task that sets the
# environment up:
#
#   bundle exec rake test:mongoid
#
# or, for a single file:
#
#   GENEVA_DRIVE_ORM=mongoid bundle exec ruby -Itest test/mongoid/workflow/workflow_test.rb
#
# The dummy app then boots against MongoDB only - ActiveRecord is never
# loaded, which doubles as the proof that the gem does not drag it in.

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"

# The suite must run without ActiveRecord: the dummy app boots Mongoid-only,
# and nothing in the gem's Mongoid side may pull ActiveRecord in. Catch a
# regression right here rather than in a subtle way later.
if defined?(::ActiveRecord) || $LOADED_FEATURES.any? { |path| path.include?("/active_record/") }
  abort "ActiveRecord got loaded in the Mongoid-only test boot - the soft dependency has regressed"
end

# MongoDB needs no migrations: the collections appear on first write. The
# indexes - which carry the uniqueness guarantees - are created once per
# test process here.
unless defined?(GENEVA_DRIVE_TEST_DB_PREPARED)
  GENEVA_DRIVE_TEST_DB_PREPARED = true
  begin
    GenevaDrive.create_indexes!
    MongoUser.create_indexes
  rescue Mongo::Error::NoServerAvailable
    abort <<~MSG
      Could not reach MongoDB. The test suite needs a replica set, e.g.:

        docker run -d --name gd-mongo -p 27017:27017 mongo:8 --replSet rs0
        docker exec gd-mongo mongosh --quiet --eval 'rs.initiate()'

      Point GENEVA_DRIVE_MONGODB_URL at it if it is not on localhost:27017.
    MSG
  end
end

# Mongoid 9 raises Mongoid::Errors::UnrecognizedModelAlias when a polymorphic
# association points at a class that no longer exists; Mongoid 8 constantizes
# and lets the NameError through. This is whichever the running Mongoid raises.
UNKNOWN_MODEL_ERROR = defined?(Mongoid::Errors::UnrecognizedModelAlias) ? Mongoid::Errors::UnrecognizedModelAlias : NameError

# Raised inside enclosing_mongoid_transaction to abort it. Mongoid 9 has a
# marker error for this; on Mongoid 8 the helper rescues this one itself.
RollbackEnclosingTransaction = defined?(Mongoid::Errors::Rollback) ? Mongoid::Errors::Rollback : Class.new(StandardError)

# Test helper methods
class ActiveSupport::TestCase
  # No ActiveRecord, no transactional tests - accept and ignore the knob so
  # tests forked from the SQL suite keep loading.
  def self.use_transactional_tests=(_value)
  end

  # Emulates a caller wrapping GenevaDrive calls in their own MongoDB
  # transaction. Mongoid 9 gained `Model.transaction` (which swallows the
  # Rollback marker); on Mongoid 8 a caller would use the session API
  # directly, so the helper does the same and aborts on the marker itself.
  def enclosing_mongoid_transaction(&block)
    if GenevaDrive::MongoidWorkflow.respond_to?(:transaction)
      GenevaDrive::MongoidWorkflow.transaction(&block)
    else
      GenevaDrive::MongoidWorkflow.with_session do |session|
        session.with_transaction do
          yield
        rescue RollbackEnclosingTransaction
          session.abort_transaction
        end
      end
    end
  end

  # Parallel workers would share one MongoDB database, and the per-test purge
  # below would wipe each other's documents - run single-process.

  # Start every test from empty collections. There are no transactional
  # fixtures on MongoDB; the purge is the isolation.
  setup do
    GenevaDrive::MongoidStepExecution.collection.delete_many({})
    GenevaDrive::MongoidSignal.collection.delete_many({})
    GenevaDrive::MongoidWorkflow.collection.delete_many({})
    MongoUser.collection.delete_many({})
  end

  # Helper to create a test user
  def create_user(attrs = {})
    MongoUser.create!({email: "test@example.com", name: "Test User"}.merge(attrs))
  end

  # Helper to run all pending jobs synchronously. The adapter stores the
  # serialized arguments, so run them back through ActiveJob's argument
  # deserialization - that is what turns a serialized BSON::ObjectId back
  # into an ObjectId.
  def perform_enqueued_jobs_now
    while (job = ActiveJob::Base.queue_adapter.enqueued_jobs.shift)
      job[:job].perform_now(*ActiveJob::Arguments.deserialize(job[:args]))
    end
  end
end
