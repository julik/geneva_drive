# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module GenevaDrive
  module Generators
    # Generator for installing GenevaDrive into a Rails application.
    #
    # @example Running the generator
    #   bin/rails generate geneva_drive:install
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates GenevaDrive migrations and initializer"

      # Creates the migration files for workflows and step executions.
      #
      # @return [void]
      def create_migrations
        migration_template(
          "create_workflows_migration.rb",
          "db/migrate/create_geneva_drive_workflows.rb"
        )

        migration_template(
          "create_step_executions_migration.rb",
          "db/migrate/create_geneva_drive_step_executions.rb"
        )
      end

      # Creates the initializer file.
      #
      # @return [void]
      def create_initializer
        template "initializer.rb.tt", "config/initializers/geneva_drive.rb"
      end
    end
  end
end
