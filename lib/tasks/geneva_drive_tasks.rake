# frozen_string_literal: true

namespace :geneva_drive do
  desc "Run housekeeping to clean up old workflows and recover stuck executions"
  task housekeeping: :environment do
    result = GenevaDrive::HousekeepingJob.perform_now
    puts "Housekeeping completed: #{result}"
  end

  desc "Create the MongoDB indexes for the GenevaDrive collections (Mongoid backend)"
  task create_indexes: :environment do
    unless GenevaDrive.mongoid_backend_loaded?
      abort 'The Mongoid backend is not loaded - add `require "geneva_drive/mongoid"` to an initializer first'
    end
    GenevaDrive.create_indexes!
    puts "GenevaDrive indexes created"
  end
end
