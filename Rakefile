require "bundler/setup"
require "bundler/gem_tasks"

require "standard/rake"
require "yard"

YARD::Rake::YardocTask.new("yard")

task doc: [:yard] do
  outfile = "doc/MANUAL.html"
  `bin/md2html MANUAL.md #{outfile}`
  warn "#{outfile} written"
end

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

# Rails' own plugin test runner rather than a Rake::TestTask: it is what sets up
# and tears down the per-worker databases that ActiveSupport::TestCase.parallelize
# creates, and a plain Rake::TestTask leaves those workers hanging at exit.
desc "Run the test suite"
task :test do
  ruby "-Itest", "bin/test"
end

# The Sidekiq dispatcher's tests, and the installer that recommends it. Sidekiq
# is only bundled by the sidekiq_* appraisals, so run this under one of them:
#
#   BUNDLE_GEMFILE=gemfiles/sidekiq_8.gemfile bundle exec rake test:sidekiq
#
# Set GENEVA_DRIVE_SIDEKIQ_REDIS_URL to include the tests against a real Redis.
namespace :test do
  desc "Run the Sidekiq tests (needs a sidekiq_* appraisal)"
  task :sidekiq do
    abort "Sidekiq is not in this bundle - use BUNDLE_GEMFILE=gemfiles/sidekiq_8.gemfile" unless Gem.loaded_specs["sidekiq"]
    ruby "-Itest", "bin/test", "test/sidekiq", "test/generators"
  end

  # The Mongoid backend's tests. Mongoid is a soft dependency, bundled by the
  # root Gemfile and pinned by the mongoid_* appraisals. The dummy app boots
  # against MongoDB only (no ActiveRecord), so the suite needs a MongoDB
  # replica set reachable at GENEVA_DRIVE_MONGODB_URL (localhost:27017,
  # replicaSet rs0 by default):
  #
  #   BUNDLE_GEMFILE=gemfiles/mongoid_9.gemfile bundle exec rake test:mongoid
  desc "Run the Mongoid tests (needs MongoDB running as a replica set)"
  task :mongoid do
    abort "Mongoid is not in this bundle" unless Gem.loaded_specs["mongoid"]
    ENV["GENEVA_DRIVE_ORM"] = "mongoid"
    ruby "-Itest", "bin/test", "test/mongoid"
  end

  # The concurrency proof pack: adversarial thread races against a live
  # database (see test/proofs/concurrency_proofs.rb). On the SQL side the
  # proofs need real committed transactions, so they are kept out of the
  # default suite and run here, against whatever engine DATABASE_URL selects
  # (SQLite by default, like the main suite). Under a mongoid_* appraisal the
  # same proofs run against MongoDB instead - they are part of test:mongoid
  # too, since that suite is already non-transactional.
  desc "Run the concurrency proof pack against the selected database"
  task :proofs do
    mongoid_bundle = File.basename(ENV["BUNDLE_GEMFILE"].to_s).start_with?("mongoid")
    if ENV["GENEVA_DRIVE_ORM"] == "mongoid" || mongoid_bundle
      ENV["GENEVA_DRIVE_ORM"] = "mongoid"
      ruby "-Itest", "bin/test", "test/mongoid/concurrency"
    else
      ENV["GENEVA_DRIVE_PROOFS"] = "1"
      # Every racing thread holds its own connection; the dummy app's pool
      # follows RAILS_MAX_THREADS (default 5), which is too small for the
      # eight-way races.
      ENV["RAILS_MAX_THREADS"] ||= "12"
      ruby "-Itest", "bin/test", "test/proofs"
    end
  end
end

# The root Gemfile resolves to the newest released Rails and the dummy app
# defaults to SQLite, so a plain `rake` is the "latest Rails on SQLite" run.
# The appraisal gemfiles cover the older Rails minors, and CI additionally
# points DATABASE_URL at PostgreSQL and MySQL.
task default: [:standard, :test]
