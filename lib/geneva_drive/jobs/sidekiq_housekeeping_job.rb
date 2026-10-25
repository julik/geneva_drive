# frozen_string_literal: true

require "sidekiq"

# Sidekiq job that runs GenevaDrive's housekeeping, for apps that schedule
# periodic work with Sidekiq Enterprise or sidekiq-cron rather than an
# Active Job backend. It runs the same code as HousekeepingJob, in-process.
#
# @example Sidekiq Enterprise periodic jobs
#   Sidekiq.configure_server do |config|
#     config.periodic do |mgr|
#       mgr.register("*/15 * * * *", "GenevaDrive::SidekiqHousekeepingJob")
#     end
#   end
#
# @example sidekiq-cron
#   Sidekiq::Cron::Job.create(
#     name: "GenevaDrive housekeeping",
#     cron: "*/15 * * * *",
#     class: "GenevaDrive::SidekiqHousekeepingJob"
#   )
class GenevaDrive::SidekiqHousekeepingJob
  include ::Sidekiq::Job

  # The next scheduled run is the retry.
  sidekiq_options queue: "default", retry: false, tags: ["geneva_drive"]

  # @return [Hash] summary of actions taken, as returned by HousekeepingJob
  def perform
    GenevaDrive::HousekeepingJob.perform_now
  end
end
