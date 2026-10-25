# frozen_string_literal: true

# One appraisal per supported Rails minor. The lowest one must match the
# floor in geneva_drive.gemspec; the highest one is what the default Rake
# task exercises.
#
# Sidekiq is optional at runtime. The oldest appraisal pins the oldest Sidekiq
# major we support, so the Sidekiq 7 API stays covered alongside 8.

appraise "rails-7-2" do
  gem "rails", "~> 7.2.0"
  gem "mysql2"
  gem "sidekiq", "~> 7.3"
end

appraise "rails-8-0" do
  gem "rails", "~> 8.0.0"
  gem "mysql2"
  gem "sidekiq", "~> 8.0"
end

appraise "rails-8-1" do
  gem "rails", "~> 8.1.0"
  gem "mysql2"
  gem "sidekiq", "~> 8.0"
end
