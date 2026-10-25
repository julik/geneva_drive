# frozen_string_literal: true

require "test_helper"
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

  test "writes the Sidekiq dispatcher when Active Job is set up for Sidekiq" do
    skip "Sidekiq is only in the sidekiq_* appraisals" unless defined?(::Sidekiq)

    with_active_job_adapter(:sidekiq) { run_generator }

    assert_file "config/initializers/geneva_drive.rb" do |content|
      assert_match(/^GenevaDrive\.dispatcher = :sidekiq$/, content)
      assert RubyVM::InstructionSequence.compile(content)
    end
  end

  test "leaves the dispatcher commented out for any other adapter" do
    [nil, :solid_queue, :test].each do |adapter|
      prepare_destination
      with_active_job_adapter(adapter) { run_generator }

      assert_file "config/initializers/geneva_drive.rb" do |content|
        assert_match(/^# GenevaDrive\.dispatcher = :active_job$/, content)
        refute_match(/^GenevaDrive\.dispatcher/, content, "with adapter #{adapter.inspect}")
        assert RubyVM::InstructionSequence.compile(content)
      end
    end
  end

  private

  def with_active_job_adapter(adapter)
    config = Rails.application.config.active_job
    previous = config.queue_adapter
    config.queue_adapter = adapter
    yield
  ensure
    config.queue_adapter = previous
  end
end
