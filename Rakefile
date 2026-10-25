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
end

# The root Gemfile resolves to the newest released Rails and the dummy app
# defaults to SQLite, so a plain `rake` is the "latest Rails on SQLite" run.
# The appraisal gemfiles cover the older Rails minors, and CI additionally
# points DATABASE_URL at PostgreSQL and MySQL.
task default: [:standard, :test]
