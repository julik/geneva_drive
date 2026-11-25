# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "tmpdir"
require "generators/geneva_drive/install/install_generator"

# The --orm selection of the install generator, exercised from the
# ActiveRecord dummy app. The Mongoid-side auto-detection (no ActiveRecord
# loaded at all) is covered by test/mongoid/generators.
class InstallGeneratorOrmTest < Rails::Generators::TestCase
  tests GenevaDrive::Generators::InstallGenerator

  setup do
    self.destination_root = Dir.mktmpdir("geneva_drive_install")
    prepare_destination
  end

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  test "defaults to the ActiveRecord backend when ActiveRecord is loaded" do
    run_generator

    assert_migration "db/migrate/create_geneva_drive_workflows.rb"
    assert_file "config/initializers/geneva_drive.rb" do |content|
      refute_match(/geneva_drive\/mongoid/, content)
    end
  end

  test "--orm=mongoid writes the Mongoid initializer and no migrations" do
    run_generator ["--orm=mongoid"]

    assert_file "config/initializers/geneva_drive.rb" do |content|
      assert_match(/^require "geneva_drive\/mongoid"$/, content)
      assert RubyVM::InstructionSequence.compile(content)
    end
    assert_empty Dir.glob(File.join(destination_root, "db", "migrate", "*.rb"))
  end

  test "an unknown --orm is refused" do
    stderr = capture(:stderr) { run_generator ["--orm=cassandra"] }

    assert_match(/Unknown --orm=cassandra/, stderr)
    assert_no_file "config/initializers/geneva_drive.rb"
  end
end
