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

      desc "Creates GenevaDrive migrations and initializer. If already installed, any missing migrations will be added to perform an upgrade."

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

        migration_template(
          "add_finished_at_to_step_executions.rb",
          "db/migrate/add_finished_at_to_geneva_drive_step_executions.rb"
        )

        migration_template(
          "add_error_class_name_to_step_executions.rb",
          "db/migrate/add_error_class_name_to_geneva_drive_step_executions.rb"
        )

        migration_template(
          "add_resumable_step_support.rb",
          "db/migrate/add_resumable_step_support_to_geneva_drive_step_executions.rb"
        )

        migration_template(
          "add_chained_step_executions.rb",
          "db/migrate/add_chained_step_executions_to_geneva_drive_step_executions.rb"
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
