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
    # @example With UUID primary keys
    #   bin/rails generate geneva_drive:install --uuid
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      class_option :uuid,
        type: :boolean,
        default: false,
        desc: "Use UUID for primary keys (auto-detected from schema if not specified)"

      desc "Creates GenevaDrive migrations and initializer"

      # Creates the migration files for workflows and step executions.
      #
      # @return [void]
      def create_migrations
        migration_template(
          "create_workflows_migration.rb.tt",
          "db/migrate/create_geneva_drive_workflows.rb"
        )

        migration_template(
          "create_step_executions_migration.rb.tt",
          "db/migrate/create_geneva_drive_step_executions.rb"
        )
      end

      # Creates the initializer file.
      #
      # @return [void]
      def create_initializer
        template "initializer.rb.tt", "config/initializers/geneva_drive.rb"
      end

      private

      # Determines if UUID should be used for primary keys.
      #
      # @return [Boolean] true if UUIDs should be used
      def use_uuid?
        options[:uuid]
      end

      # Returns the key type for migrations.
      #
      # @return [Symbol] :uuid or :bigint
      def key_type
        use_uuid? ? :uuid : :bigint
      end

      # Returns the database adapter name.
      #
      # @return [String] the adapter name
      def adapter_name
        ActiveRecord::Base.connection.adapter_name.downcase
      rescue
        "unknown"
      end

      # Checks if database is PostgreSQL.
      #
      # @return [Boolean]
      def postgresql?
        adapter_name.include?("postgresql")
      end

      # Checks if database is MySQL.
      #
      # @return [Boolean]
      def mysql?
        adapter_name.include?("mysql")
      end

      # Checks if database is SQLite.
      #
      # @return [Boolean]
      def sqlite?
        adapter_name.include?("sqlite")
      end
    end
  end
end
