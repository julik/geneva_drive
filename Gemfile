# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in geneva_drive.gemspec.
gemspec

gem "puma"

# Database
gem "pg"

gem "propshaft"

# Linting with standardrb
gem "standard", "~> 1.0", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
gem "debug", ">= 1.0.0"

gem "yard"
gem "redcarpet" # needed for the yard gem to enable Github Flavored Markdown and for md2html

# Testing with various databases
gem "sqlite3"

# Minitest 5.26 dropped minitest/mock, which the test suite uses for stubbing.
# The appraisal gemfiles carry the same pin.
gem "minitest", "< 5.26"

# Multi-version testing
gem "appraisal"

# The native Sidekiq dispatcher is optional at runtime but tested here.
# Its tests run in Sidekiq::Testing fake mode and need no Redis.
gem "sidekiq", ">= 7.3", "< 9" # keep in line with SidekiqDispatcher::SUPPORTED_SIDEKIQ_VERSIONS
