# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Fake mode keeps pushed jobs in memory, per job class, so none of this needs
# Redis. Sidekiq 8 has a new API for it; 7 only has the old require.
if Sidekiq.respond_to?(:testing!)
  Sidekiq.testing!(:fake)
else
  require "sidekiq/testing"
end
Sidekiq.logger.level = Logger::WARN

class SidekiqDispatcherTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers
  include ActiveJob::TestHelper

  class TwoStepWorkflow < GenevaDrive::Workflow
    step :first do
      Thread.current[:sidekiq_steps] << :first
    end

    step :second, wait: 2.hours do
      Thread.current[:sidekiq_steps] << :second
    end
  end

  class QueuedWorkflow < GenevaDrive::Workflow
    set_step_job_options queue: :workflows
    step(:only, job_options: {queue: :urgent}) {}
  end

  class FailingWorkflow < GenevaDrive::Workflow
    step :explode do
      raise ArgumentError, "kaboom"
    end
  end

  class IteratingWorkflow < GenevaDrive::Workflow
    resumable_step :crunch do |iter|
      iter.iterate_over((1..5).to_a) do |n|
        Thread.current[:sidekiq_steps] << n
      end
    end
  end

  # Stands in for Sidekiq::TransactionAwareClient: it records that it was
  # asked to push, and pushes nothing.
  class RecordingClient
    class << self
      attr_accessor :pushes
    end

    def initialize(**)
    end

    def push(item)
      self.class.pushes << item
      "recorded"
    end
  end

  setup do
    @previous_dispatcher = GenevaDrive.dispatcher
    GenevaDrive.dispatcher = :sidekiq
    Sidekiq::Job.clear_all
    Thread.current[:sidekiq_steps] = []
    @user = create_user
  end

  teardown do
    GenevaDrive.dispatcher = @previous_dispatcher
    GenevaDrive.reset_exit_request!
    Sidekiq::Job.clear_all
    Thread.current[:sidekiq_steps] = nil
  end

  test "dispatcher= maps symbols to the built-in dispatchers" do
    GenevaDrive.dispatcher = :sidekiq
    assert_kind_of GenevaDrive::SidekiqDispatcher, GenevaDrive.dispatcher

    GenevaDrive.dispatcher = :active_job
    assert_kind_of GenevaDrive::ActiveJobDispatcher, GenevaDrive.dispatcher
  end

  test "dispatcher= rejects objects that cannot enqueue steps" do
    error = assert_raises(ArgumentError) { GenevaDrive.dispatcher = :resque }
    assert_match(/:active_job, :sidekiq/, error.message)

    assert_raises(ArgumentError) { GenevaDrive.dispatcher = Object.new }
  end

  test "creating a workflow pushes a native Sidekiq job for the first step" do
    workflow = TwoStepWorkflow.create!(hero: @user)
    execution = workflow.step_executions.sole

    jobs = GenevaDrive::SidekiqPerformStepJob.jobs
    assert_equal 1, jobs.size
    job = jobs.first

    assert_equal "GenevaDrive::SidekiqPerformStepJob", job["class"]
    assert_equal [execution.id], job["args"]
    assert_equal "default", job["queue"]
    assert_equal false, job["retry"]
    assert_nil job["at"], "an immediate step must not wait in the schedule set"
    assert_equal ["geneva_drive", TwoStepWorkflow.name], job["tags"]

    assert_equal job["jid"], execution.reload.job_id
  end

  test "nothing goes through Active Job" do
    assert_no_enqueued_jobs do
      TwoStepWorkflow.create!(hero: @user)
    end
  end

  test "a step with wait: is pushed with an at timestamp" do
    workflow = TwoStepWorkflow.create!(hero: @user)
    GenevaDrive::SidekiqPerformStepJob.perform_one

    second = workflow.step_executions.find_by!(step_name: "second")
    job = GenevaDrive::SidekiqPerformStepJob.jobs.sole

    assert_equal [second.id], job["args"]
    assert_in_delta second.scheduled_for.to_f, job["at"], 1.0
  end

  test "queue options reach the pushed job, step options winning" do
    QueuedWorkflow.create!(hero: @user)
    assert_equal "urgent", GenevaDrive::SidekiqPerformStepJob.jobs.sole["queue"]
  end

  test "draining the queue runs the workflow to the end" do
    workflow = TwoStepWorkflow.create!(hero: @user)

    # The fake queue ignores "at", so the delayed step runs as soon as drained
    GenevaDrive::SidekiqPerformStepJob.drain

    assert_equal [:first, :second], Thread.current[:sidekiq_steps]
    assert workflow.reload.finished?
  end

  test "a step's exception reaches Sidekiq after the executor has settled the step" do
    workflow = FailingWorkflow.create!(hero: @user)

    error = assert_raises(ArgumentError) { GenevaDrive::SidekiqPerformStepJob.perform_one }
    assert_equal "kaboom", error.message

    execution = workflow.step_executions.sole.reload
    assert_equal "failed", execution.state
    assert_empty GenevaDrive::SidekiqPerformStepJob.jobs, "no Sidekiq retry is queued"
  end

  test "a job for a vanished step execution is a no-op" do
    job = GenevaDrive::SidekiqPerformStepJob.new
    job.stub(:sleep, ->(_delay) {}) do
      assert_nothing_raised { job.perform(999_999_999) }
    end
  end

  test "pushes bypass the client_class that Sidekiq.transactional_push! installs" do
    RecordingClient.pushes = []
    options = Sidekiq.default_job_options
    previous = options["client_class"]
    options["client_class"] = RecordingClient

    begin
      TwoStepWorkflow.create!(hero: @user)
    ensure
      previous ? options["client_class"] = previous : options.delete("client_class")
    end

    assert_empty RecordingClient.pushes, "the transaction-aware client would defer the push a second time"
    assert_equal 1, GenevaDrive::SidekiqPerformStepJob.jobs.size
  end

  test "a custom job class and client can be supplied" do
    RecordingClient.pushes = []
    custom_job = Class.new(GenevaDrive::SidekiqPerformStepJob) do
      sidekiq_options queue: "workflows", tags: ["billing"]
    end
    GenevaDrive.dispatcher = GenevaDrive::SidekiqDispatcher.new(job_class: custom_job, client: RecordingClient.new)

    TwoStepWorkflow.create!(hero: @user)

    item = RecordingClient.pushes.sole
    assert_equal custom_job, item["class"]
    assert_equal ["billing", TwoStepWorkflow.name], item["tags"]
    refute item.key?("queue"), "the class's own queue applies when no queue option is set"
  end

  test "priority is rejected under the Sidekiq dispatcher" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) { set_step_job_options priority: 5 }
    end
    assert_match(/queues with weights/, error.message)

    assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) { step(:s, job_options: {priority: 1}) {} }
    end
  end

  test "priority stays allowed under the Active Job dispatcher" do
    GenevaDrive.dispatcher = :active_job
    assert_nothing_raised do
      Class.new(GenevaDrive::Workflow) { set_step_job_options priority: 5 }
    end
  end

  test "housekeeping runs as a Sidekiq job" do
    result = GenevaDrive::SidekiqHousekeepingJob.new.perform
    assert_kind_of Hash, result
    assert result.key?(:stuck_scheduled_recovered)
    assert_equal false, GenevaDrive::SidekiqHousekeepingJob.get_sidekiq_options["retry"]
  end

  test "a shutdown request hands a resumable step off to a successor" do
    workflow = IteratingWorkflow.create!(hero: @user)
    first = workflow.step_executions.sole

    GenevaDrive.request_exit!
    GenevaDrive::SidekiqPerformStepJob.perform_one

    assert_operator Thread.current[:sidekiq_steps].size, :<, 5, "the step must stop early"
    assert_equal "completed", first.reload.state

    successor = workflow.step_executions.find_by!(continues_from_id: first.id)
    assert_equal "scheduled", successor.state
    assert_equal [successor.id], GenevaDrive::SidekiqPerformStepJob.jobs.sole["args"]

    GenevaDrive.reset_exit_request!
    GenevaDrive::SidekiqPerformStepJob.drain
    assert_equal [1, 2, 3, 4, 5], Thread.current[:sidekiq_steps], "the successor picks up from the cursor"
    assert workflow.reload.finished?
  end

  test "Sidekiq is recommended when Active Job is not pointed at another backend" do
    [nil, :async, :inline, :test, :sidekiq, "sidekiq", ActiveJob::QueueAdapters::AsyncAdapter.new].each do |adapter|
      assert GenevaDrive::SidekiqDispatcher.recommended?(adapter), "with adapter #{adapter.inspect}"
    end
  end

  test "Sidekiq is not recommended when Active Job is pointed at another backend" do
    [:solid_queue, :good_job, :resque, "delayed_job"].each do |adapter|
      refute GenevaDrive::SidekiqDispatcher.recommended?(adapter), "with adapter #{adapter.inspect}"
    end
  end

  test "an unset dispatcher is Active Job even where Sidekiq would be recommended" do
    with_active_job_adapter(:sidekiq) do
      GenevaDrive.dispatcher = nil
      assert_kind_of GenevaDrive::ActiveJobDispatcher, GenevaDrive.dispatcher
    end
  end

  test "the supported Sidekiq versions are 7.3 up to, not including, 9" do
    assert GenevaDrive::SidekiqDispatcher.supported_sidekiq_version?("7.3.0")
    assert GenevaDrive::SidekiqDispatcher.supported_sidekiq_version?("8.1.7")
    refute GenevaDrive::SidekiqDispatcher.supported_sidekiq_version?("7.2.4")
    refute GenevaDrive::SidekiqDispatcher.supported_sidekiq_version?("6.5.12")
    refute GenevaDrive::SidekiqDispatcher.supported_sidekiq_version?("9.0.0")
    assert GenevaDrive::SidekiqDispatcher.supported_sidekiq_version?(Sidekiq::VERSION), "the bundled Sidekiq must be supported"
  end

  test "the Sidekiq dispatcher refuses an unsupported Sidekiq" do
    GenevaDrive::SidekiqDispatcher.stub(:sidekiq_version, "6.5.12") do
      error = assert_raises(LoadError) { GenevaDrive::SidekiqDispatcher.new }
      assert_match(/6\.5\.12/, error.message)
      assert_match(/>= 7\.3/, error.message)
    end
  end

  test "Sidekiq is not recommended when the loaded version is unsupported" do
    GenevaDrive::SidekiqDispatcher.stub(:sidekiq_version, "6.5.12") do
      refute GenevaDrive::SidekiqDispatcher.recommended?(:sidekiq)
    end
  end

  test "the engine wires Sidekiq's quiet event to the shutdown request" do
    initializer = GenevaDrive::Engine.instance.initializers.find { |i| i.name == "geneva_drive.sidekiq_lifecycle" }
    assert initializer, "expected the lifecycle initializer to exist"

    events = {}
    fake_config = Object.new
    fake_config.define_singleton_method(:on) { |event, &block| events[event] = block }

    Sidekiq.stub(:configure_server, ->(&blk) { blk.call(fake_config) }) do
      initializer.run(Rails.application)
    end

    refute GenevaDrive.exit_requested?
    events.fetch(:quiet).call
    assert GenevaDrive.exit_requested?
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
