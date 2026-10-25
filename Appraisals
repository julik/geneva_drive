# frozen_string_literal: true

# One appraisal per supported Rails minor. The lowest one must match the
# floor in geneva_drive.gemspec; the highest one is what the default Rake
# task exercises.

appraise "rails-7-2" do
  gem "rails", "~> 7.2.0"
  gem "mysql2"
end

appraise "rails-8-0" do
  gem "rails", "~> 8.0.0"
  gem "mysql2"
end

appraise "rails-8-1" do
  gem "rails", "~> 8.1.0"
  gem "mysql2"
end

# Sidekiq is optional at runtime, so it stays out of the bundles above. These
# two run only the Sidekiq tests (`rake test:sidekiq`), on SQLite, from
# .github/workflows/sidekiq.yml: the oldest supported Sidekiq on the oldest
# Rails, and the newest on the newest. Keep the range in line with
# SidekiqDispatcher::SUPPORTED_SIDEKIQ_VERSIONS.
appraise "sidekiq-7" do
  gem "rails", "~> 7.2.0"
  gem "sidekiq", "~> 7.3"
end

appraise "sidekiq-8" do
  gem "rails", "~> 8.1.0"
  gem "sidekiq", "~> 8.0"
end
