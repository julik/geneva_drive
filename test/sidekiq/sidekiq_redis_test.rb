# frozen_string_literal: true

require "test_helper"

# Sidekiq is only in the sidekiq_* appraisals; run these with `rake test:sidekiq`
return unless defined?(::Sidekiq)

begin
  require "sidekiq/test_api"
rescue LoadError
  require "sidekiq/testing"
end
require "sidekiq/api"

# The Sidekiq dispatcher against a real Redis, end to end: real commits,
# GenevaDrive's own after-commit deferral switched on, and Sidekiq's
# transactional push installed - the combination the dispatcher exists to
# get right. Runs only where GENEVA_DRIVE_SIDEKIQ_REDIS_URL is set, which the
# Sidekiq CI workflow does; the main CI has no Redis and skips these.
class SidekiqRedisTest < ActiveSupport::TestCase
  REDIS_URL = ENV["GENEVA_DRIVE_SIDEKIQ_REDIS_URL"]

  # after_all_transactions_commit never fires inside a test transaction
  self.use_transactional_tests = false

  class CheckoutWorkflow < GenevaDrive::Workflow
    step :reserve_stock do
      Thread.current[:sidekiq_redis_steps] << :reserve_stock
    end

    step :send_reminder, wait: 2.hours do
      Thread.current[:sidekiq_redis_steps] << :send_reminder
    end

    # A queue of its own per test, so nothing else in this Redis is touched
    private def merged_step_job_options(step_definition)
      super.merge(queue: Thread.current[:sidekiq_redis_test_queue])
    end
  end

  setup do
    skip "Set GENEVA_DRIVE_SIDEKIQ_REDIS_URL to run these" unless REDIS_URL

    Sidekiq.configure_client { |config| config.redis = {url: REDIS_URL} }
    Sidekiq::Testing.disable!

    @queue = Thread.current[:sidekiq_redis_test_queue] = "geneva_drive_test_#{SecureRandom.hex(6)}"
    Thread.current[:sidekiq_redis_steps] = []
    @previous_dispatcher = GenevaDrive.dispatcher
    @previous_deferral = GenevaDrive.enqueue_after_commit
    GenevaDrive.dispatcher = :sidekiq
    GenevaDrive.enqueue_after_commit = true
    @user = create_user
  end

  teardown do
    next unless REDIS_URL

    jids = GenevaDrive::StepExecution.where(workflow: @workflow).pluck(:job_id).compact if @workflow
    Array(jids).each { |jid| Sidekiq::ScheduledSet.new.scan(jid).each(&:delete) }
    Sidekiq::Queue.new(@queue).clear

    @workflow&.step_executions&.delete_all
    @workflow&.delete
    @user&.delete

    Sidekiq.default_job_options.delete("client_class")
    GenevaDrive.dispatcher = @previous_dispatcher
    GenevaDrive.enqueue_after_commit = @previous_deferral
    Thread.current[:sidekiq_redis_test_queue] = nil
    Thread.current[:sidekiq_redis_steps] = nil
  end

  test "a workflow created in a transaction lands in Redis once, after the commit" do
    Sidekiq.transactional_push!

    ActiveRecord::Base.transaction do
      @workflow = CheckoutWorkflow.create!(hero: @user)
      assert_equal 0, Sidekiq::Queue.new(@queue).size, "nothing may be pushed before the commit"
    end

    jobs = Sidekiq::Queue.new(@queue).to_a
    assert_equal 1, jobs.size

    execution = @workflow.step_executions.sole
    assert_equal "GenevaDrive::SidekiqPerformStepJob", jobs.first.klass
    assert_equal [execution.id], jobs.first.args
    assert_equal jobs.first.jid, execution.reload.job_id
  end

  test "a step job taken off the queue runs the step and schedules the next one" do
    @workflow = CheckoutWorkflow.create!(hero: @user)

    perform(Sidekiq::Queue.new(@queue).first)
    assert_equal [:reserve_stock], Thread.current[:sidekiq_redis_steps]

    reminder = @workflow.step_executions.find_by!(step_name: "send_reminder")
    scheduled = Sidekiq::ScheduledSet.new.scan(reminder.job_id).first
    assert scheduled, "the delayed step must wait in the Scheduled set"
    assert_in_delta reminder.scheduled_for.to_f, scheduled.score, 1.0

    perform(scheduled)
    assert_equal [:reserve_stock, :send_reminder], Thread.current[:sidekiq_redis_steps]
    assert @workflow.reload.finished?
  end

  private

  # What a Sidekiq processor does with a job, minus the fetching: delete it
  # and run it with the arguments that went through Redis as JSON.
  def perform(record)
    record.delete
    record.klass.constantize.new.perform(*record.args)
  end
end
