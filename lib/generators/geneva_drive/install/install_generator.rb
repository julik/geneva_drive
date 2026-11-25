# frozen_string_literal: true

require "rails/generators"

# The migration machinery only exists when ActiveRecord does. In a
# Mongoid-only app the generator still runs - it writes the initializer and
# instructions, no migrations.
if defined?(::ActiveRecord)
  require "rails/generators/active_record"
end

module GenevaDrive
  module Generators
    # Generator for installing GenevaDrive into a Rails application.
    #
    # Supports both persistence backends:
    # - `--orm=active_record` (the default in apps where ActiveRecord is
    #   loaded) creates the migrations and the initializer. If already
    #   installed, any missing migrations will be added to perform an upgrade.
    # - `--orm=mongoid` creates the initializer (with
    #   `require "geneva_drive/mongoid"`) and points at the
    #   `geneva_drive:create_indexes` task - MongoDB needs no migrations.
    #
    # Without an explicit `--orm`, picks mongoid when ::Mongoid is defined and
    # ActiveRecord is not, and active_record otherwise.
    #
    # @example Running the generator
    #   bin/rails generate geneva_drive:install
    #
    # @example Installing the Mongoid backend explicitly
    #   bin/rails generate geneva_drive:install --orm=mongoid
    #
    class InstallGenerator < Rails::Generators::Base
      if defined?(::ActiveRecord::Generators::Migration)
        include ::ActiveRecord::Generators::Migration
      end

      class_option :orm,
        type: :string,
        desc: "Persistence backend: active_record or mongoid (default: auto-detect)"

      source_root File.expand_path("templates", __dir__)

      desc "Creates the GenevaDrive initializer, plus migrations (ActiveRecord) or index setup instructions (Mongoid)."

      # Creates the migration files for workflows and step executions
      # (ActiveRecord flavor only).
      #
      # @return [void]
      def create_migrations
        return unless active_record?

        unless defined?(::ActiveRecord::Generators::Migration)
          raise Thor::Error,
            "--orm=active_record needs ActiveRecord, which is not loaded in this app. " \
            "Use --orm=mongoid for the MongoDB backend."
        end

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
          "add_metadata_to_step_executions.rb",
          "db/migrate/add_metadata_to_geneva_drive_step_executions.rb"
        )

        migration_template(
          "add_metadata_to_workflows.rb",
          "db/migrate/add_metadata_to_geneva_drive_workflows.rb"
        )

        migration_template(
          "allow_null_hero_on_workflows.rb",
          "db/migrate/allow_null_hero_on_geneva_drive_workflows.rb"
        )

        migration_template(
          "add_started_at_index_to_step_executions.rb",
          "db/migrate/add_started_at_index_to_geneva_drive_step_executions.rb"
        )

        migration_template(
          "add_resumable_step_support.rb",
          "db/migrate/add_resumable_step_support_to_geneva_drive_step_executions.rb"
        )

        migration_template(
          "add_signals_support.rb",
          "db/migrate/add_signals_support_to_geneva_drive.rb"
        )
      end

      # Creates the initializer file.
      #
      # @return [void]
      def create_initializer
        template "initializer.rb.tt", "config/initializers/geneva_drive.rb"
      end

      # Points at the index setup (Mongoid flavor only).
      #
      # @return [void]
      def show_mongoid_instructions
        return unless mongoid?

        say <<~MSG

          GenevaDrive is installed. Your workflows subclass
          GenevaDrive::MongoidWorkflow. Create the MongoDB indexes with:

            bin/rails geneva_drive:create_indexes

          Run that task on every deploy that changes GenevaDrive - index
          creation is idempotent. Note that GenevaDrive requires MongoDB to
          run as a replica set (a single-node replica set is fine): its
          transactional guarantees are built on multi-document transactions.
        MSG
      end

      private

      # The resolved persistence backend: the --orm option when given,
      # auto-detection otherwise.
      #
      # @return [String] "active_record" or "mongoid"
      def orm
        @orm ||= begin
          requested = options[:orm].presence
          case requested
          when "active_record", "mongoid"
            requested
          when nil
            (defined?(::Mongoid) && !defined?(::ActiveRecord)) ? "mongoid" : "active_record"
          else
            raise Thor::Error, "Unknown --orm=#{requested}, expected active_record or mongoid"
          end
        end
      end

      # @return [Boolean]
      def active_record?
        orm == "active_record"
      end

      # @return [Boolean]
      def mongoid?
        orm == "mongoid"
      end
    end
  end
end
