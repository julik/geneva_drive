# frozen_string_literal: true

require "test_helper"

# Sidekiq is only in the sidekiq_* appraisals; run these with `rake test:sidekiq`
return unless defined?(::Sidekiq)

begin
  require "sidekiq/test_api"
rescue LoadError
  require "sidekiq/testing"
end

# The job arguments the dispatcher builds must be native JSON types: Sidekiq
# 7/8 strict args verify them at push time (which in production happens inside
# the after-commit flush), and with strict mode off a non-native id would not
# round-trip and the step would be silently dropped. The Mongoid backend's
# step execution ids are BSON::ObjectIds - not JSON-native - so the dispatcher
# stringifies anything that is not a String or Integer.
class SidekiqDispatcherArgsTest < ActiveSupport::TestCase
  # A stand-in for BSON::ObjectId, which is not in the Sidekiq bundles: not a
  # native JSON type, stringifies to the hex form.
  class ObjectIdish
    def initialize(hex)
      @hex = hex
    end

    def to_s
      @hex
    end
  end

  setup do
    Sidekiq::Testing.fake!
    GenevaDrive::SidekiqPerformStepJob.clear
  end

  teardown do
    GenevaDrive::SidekiqPerformStepJob.clear
    Sidekiq::Testing.disable!
  end

  test "a Mongoid-style id is pushed as its string form and passes strict JSON verification" do
    dispatcher = GenevaDrive::SidekiqDispatcher.new
    id = ObjectIdish.new("6b0706361880bb3da111c877")

    # Sidekiq::Client#push runs verify_json on the item (strict args are the
    # default on Sidekiq 7/8), so a non-JSON-native argument would raise here.
    jid = dispatcher.enqueue_step(id, {}, workflow_class_name: nil)
    assert jid

    job = GenevaDrive::SidekiqPerformStepJob.jobs.sole
    assert_equal ["6b0706361880bb3da111c877"], job["args"]
  end

  test "ActiveRecord integer ids pass through untouched" do
    dispatcher = GenevaDrive::SidekiqDispatcher.new

    dispatcher.enqueue_step(42, {}, workflow_class_name: nil)

    assert_equal [42], GenevaDrive::SidekiqPerformStepJob.jobs.sole["args"]
  end

  test "string ids pass through untouched" do
    dispatcher = GenevaDrive::SidekiqDispatcher.new

    dispatcher.enqueue_step("6b0706361880bb3da111c877", {}, workflow_class_name: nil)

    assert_equal ["6b0706361880bb3da111c877"], GenevaDrive::SidekiqPerformStepJob.jobs.sole["args"]
  end
end
