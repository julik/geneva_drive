# frozen_string_literal: true

# The opt-in entry point for the Mongoid (MongoDB) backend:
#
#   # config/initializers/geneva_drive.rb
#   require "geneva_drive/mongoid"
#
# Loads {GenevaDrive::MongoidWorkflow}, {GenevaDrive::MongoidStepExecution}
# and {GenevaDrive::MongoidSignal}, the document lock, the ActiveJob
# BSON::ObjectId serializer and {GenevaDrive.create_indexes!}. Nothing in
# here is loaded unless this file is required, and the mongoid gem is a
# soft dependency - add it to your Gemfile.
#
# A MongoDB **replica set** (single-node is fine) with majority write concern
# is a hard requirement; never connect with `directConnection=true`.

begin
  require "mongoid"
rescue LoadError => e
  raise LoadError,
    "geneva_drive/mongoid needs the mongoid gem (>= 8, < 10), which is not a " \
    "hard dependency of geneva_drive. Add `gem \"mongoid\"` to your Gemfile. (#{e.message})"
end

require "active_job"
require "geneva_drive"
require "geneva_drive/document_lock"
require "geneva_drive/enum_field"
require "geneva_drive/mongoid_metadata_accessor"
require "geneva_drive/mongoid_workflow"
require "geneva_drive/mongoid_step_execution"
require "geneva_drive/mongoid_signal"

# Makes BSON::ObjectId survive the ActiveJob serialization that cursor
# values and signal payloads go through.
class GenevaDrive::ObjectIdSerializer < ActiveJob::Serializers::ObjectSerializer
  def klass
    BSON::ObjectId
  end

  def serialize(object_id)
    super("value" => object_id.to_s)
  end

  def deserialize(hash)
    BSON::ObjectId.from_string(hash["value"])
  end
end

module GenevaDrive
  # Creates the MongoDB indexes for all GenevaDrive collections - the
  # replacement for the SQL install migrations. Call from a deploy task
  # (`rake geneva_drive:create_indexes`) or from test setup.
  #
  # @return [void]
  def self.create_indexes!
    [GenevaDrive::MongoidWorkflow, GenevaDrive::MongoidStepExecution, GenevaDrive::MongoidSignal].each(&:create_indexes)
  end
end

# BSON::ObjectId values pass through ActiveJob serialization in resumable
# step cursors and signal payloads; teach ActiveJob about them whenever it is
# (or gets) loaded.
ActiveSupport.on_load(:active_job) do
  ActiveJob::Serializers.add_serializers(GenevaDrive::ObjectIdSerializer)
end

# Mongoid 9's railtie registers its own BSON::ObjectId serializer, which
# serializes to a plain String - one-way, since a plain String is never
# dispatched back through a deserializer. Ours round-trips (cursor values and
# signal payloads must come back as ObjectIds), and ActiveJob's serializer
# index is last-registered-wins per class, so make sure ours lands after
# Mongoid's by re-registering once the app has finished booting.
if defined?(Rails) && Rails.respond_to?(:application) && Rails.application && !Rails.application.initialized?
  Rails.application.config.after_initialize do
    ActiveSupport.on_load(:active_job) do
      ActiveJob::Serializers.add_serializers(GenevaDrive::ObjectIdSerializer)
    end
  end
end

# Install the removed-subclass fallback (see MongoidWorkflow::FactoryFallback).
Mongoid::Factory.singleton_class.prepend(GenevaDrive::MongoidWorkflow::FactoryFallback)

# Fire after-commit callbacks queued on caller-owned transactions at the
# caller's commit (and drop them on abort) - see DocumentLock::SessionAfterCommit.
Mongo::Session.prepend(GenevaDrive::DocumentLock::SessionAfterCommit)

GenevaDrive.mongoid_backend_loaded!
