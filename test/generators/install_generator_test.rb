# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "rails/generators/test_case"
require "tmpdir"
require "generators/geneva_drive/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests GenevaDrive::Generators::InstallGenerator
  # One directory per test: parallel workers would otherwise wipe each other's
  # output in prepare_destination.
  setup do
    self.destination_root = Dir.mktmpdir("geneva_drive_install")
    prepare_destination
  end

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  test "writes the Sidekiq dispatcher when Sidekiq runs the app's jobs" do
    GenevaDrive::SidekiqDispatcher.stub(:recommended?, true) do
      run_generator
    end

    assert_file "config/initializers/geneva_drive.rb" do |content|
      assert_match(/^GenevaDrive\.dispatcher = :sidekiq$/, content)
      refute_match(/<%/, content)
    end
  end

  test "leaves the dispatcher commented out otherwise" do
    GenevaDrive::SidekiqDispatcher.stub(:recommended?, false) do
      run_generator
    end

    assert_file "config/initializers/geneva_drive.rb" do |content|
      assert_match(/^# GenevaDrive\.dispatcher = :active_job$/, content)
      refute_match(/^GenevaDrive\.dispatcher/, content)
    end
  end

  test "the generated initializer is valid Ruby" do
    [true, false].each do |recommended|
      prepare_destination
      GenevaDrive::SidekiqDispatcher.stub(:recommended?, recommended) { run_generator }

      assert_file "config/initializers/geneva_drive.rb" do |content|
        assert RubyVM::InstructionSequence.compile(content), "recommended=#{recommended}"
      end
    end
  end
end
