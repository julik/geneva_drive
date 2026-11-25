require_relative "boot"

# The dummy app boots against one of the two persistence backends the gem
# supports. GENEVA_DRIVE_ORM=mongoid (what `rake test:mongoid` sets) boots a
# Mongoid-only app - deliberately without ActiveRecord, which is what a real
# Mongoid app looks like and what keeps the "no ActiveRecord loaded" check
# honest. The default is a regular ActiveRecord app.
if ENV["GENEVA_DRIVE_ORM"] == "mongoid"
  require "rails"
  require "active_model/railtie"
  require "active_job/railtie"
  require "action_controller/railtie"
  require "mongoid"
else
  require "rails/all"
end

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    # For compatibility with applications that use this config
    config.action_controller.include_all_helpers = false

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    if ENV["GENEVA_DRIVE_ORM"] == "mongoid"
      # Mongoid configuration lives in config/mongoid.yml
      Mongoid.load!(File.expand_path("mongoid.yml", __dir__), Rails.env)

      # What a real Mongoid app puts in its initializer (the install
      # generator writes it there). It lives here in the dummy because
      # config/initializers/geneva_drive.rb is generator-produced and
      # gitignored - a fresh checkout does not have it.
      require "geneva_drive/mongoid"
    end

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
