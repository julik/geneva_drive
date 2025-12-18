# frozen_string_literal: true

namespace :geneva_drive do
  desc "Run housekeeping to clean up old workflows and recover stuck executions"
  task housekeeping: :environment do
    result = GenevaDrive::HousekeepingJob.perform_now
    puts "Housekeeping completed: #{result}"
  end
end
