# frozen_string_literal: true

# Pushes step jobs straight to Sidekiq as GenevaDrive::SidekiqPerformStepJob,
# a plain Sidekiq::Job, for apps that use Sidekiq without Active Job.
#
# The push goes through a `Sidekiq::Client` built here, never through
# `perform_async`, and that is deliberate. `Sidekiq.transactional_push!`
# swaps the client that `perform_async` uses for a TransactionAwareClient,
# which defers the push to `ActiveRecord.after_all_transactions_commit`.
# GenevaDrive already calls the dispatcher from inside exactly such a
# callback. That callback fires after the SQL COMMIT, but possibly while
# the transaction is still on the Ruby side's stack, so a second deferral
# registered from inside it can be dropped: the step execution then has no
# job, and sits in "scheduled" until housekeeping recovers it. This is the
# double-deferral described at length in PerformStepJob, and the remedy is
# the same - push synchronously, since we are already past the commit.
#
# Client middleware still runs, so encryption, unique jobs, Batches and the
# app's own middleware see the push as usual. `Sidekiq::Client.via` sharding
# is honoured too, as Sidekiq::Client.new picks up the pool it sets.
#
# @example config/initializers/geneva_drive.rb
#   GenevaDrive.dispatcher = :sidekiq
#
# @example With a subclass carrying your own sidekiq_options
#   class WorkflowStepJob < GenevaDrive::SidekiqPerformStepJob
#     sidekiq_options queue: "workflows", tags: ["geneva_drive", "billing"]
#   end
#   GenevaDrive.dispatcher = GenevaDrive::SidekiqDispatcher.new(job_class: WorkflowStepJob)
#
# @see GenevaDrive.dispatcher
class GenevaDrive::SidekiqDispatcher
  # The Sidekiq versions we test against and support: 7.3 and later 7.x, and 8.x.
  # 9.0 is excluded until we have tested it - Sidekiq majors change APIs we use.
  SUPPORTED_SIDEKIQ_VERSIONS = Gem::Requirement.new(">= 7.3", "< 9")

  # @return [String] the loaded Sidekiq's version
  def self.sidekiq_version
    ::Sidekiq::VERSION
  end

  # @param version [String]
  # @return [Boolean] whether that Sidekiq version is supported
  def self.supported_sidekiq_version?(version = sidekiq_version)
    SUPPORTED_SIDEKIQ_VERSIONS.satisfied_by?(Gem::Version.new(version))
  end

  # Active Job adapters under which every job ends up in Sidekiq anyway.
  # Unset means :async, which loses jobs on restart - no backend at all.
  SIDEKIQ_COMPATIBLE_ADAPTERS = %w[sidekiq async inline test].freeze

  # Whether an app looks like it runs its jobs on Sidekiq: a supported
  # Sidekiq is loaded, and Active Job is not configured for some other real
  # backend. The install generator asks this once, to decide what to write
  # into the initializer. Nothing consults it at runtime, so upgrading the
  # gem never switches an existing app's dispatcher.
  #
  # @param adapter [Symbol, String, Object, nil] Active Job's configured
  #   adapter, from `config.active_job.queue_adapter` by default
  # @return [Boolean]
  def self.recommended?(adapter = Rails.application&.config&.active_job&.queue_adapter)
    return false unless defined?(::Sidekiq::Client) && defined?(::Sidekiq::Job)
    return false unless supported_sidekiq_version?

    name = adapter_name(adapter)
    name.nil? || SIDEKIQ_COMPATIBLE_ADAPTERS.include?(name)
  end

  # @param adapter [Symbol, String, Object, nil] an adapter name, class or instance
  # @return [String, nil] e.g. "sidekiq" for ActiveJob::QueueAdapters::SidekiqAdapter
  # @api private
  def self.adapter_name(adapter)
    case adapter
    when nil
      nil
    when Symbol, String
      adapter.to_s
    else
      klass = adapter.is_a?(Module) ? adapter : adapter.class
      klass.name.to_s.demodulize.delete_suffix("Adapter").underscore
    end
  end

  # @param job_class [Class, nil] a Sidekiq::Job that performs step executions,
  #   GenevaDrive::SidekiqPerformStepJob by default
  # @param client [#push, nil] the client to push with; one is built per push
  #   by default, which is what Sidekiq does itself
  # @raise [LoadError] if Sidekiq is not loaded, or is not a supported version
  def initialize(job_class: nil, client: nil)
    unless defined?(::Sidekiq::Client)
      raise LoadError, "GenevaDrive::SidekiqDispatcher needs the sidekiq gem. Add it to your Gemfile."
    end

    unless self.class.supported_sidekiq_version?
      raise LoadError,
        "GenevaDrive::SidekiqDispatcher supports Sidekiq #{SUPPORTED_SIDEKIQ_VERSIONS}, " \
        "but Sidekiq #{self.class.sidekiq_version} is loaded. Use GenevaDrive.dispatcher = :active_job with this Sidekiq."
    end

    @job_class = job_class
    @client = client
  end

  # @return [Class] the Sidekiq::Job class step jobs are pushed as
  def job_class
    @job_class || GenevaDrive::SidekiqPerformStepJob
  end

  # Pushes the job that performs a step execution.
  #
  # @param step_execution_id [Integer, String] the step execution to perform
  # @param job_options [Hash] validated `queue`, `wait`, `wait_until`
  # @param workflow_class_name [String, nil] added to the job's tags, so the
  #   Busy page and Enterprise metrics can be read per workflow class
  # @param step_name [String, nil] currently unused, accepted for symmetry
  # @return [String, nil] the jid, or nil if client middleware stopped the push
  def enqueue_step(step_execution_id, job_options, workflow_class_name: nil, step_name: nil)
    item = {"class" => job_class, "args" => [step_execution_id]}
    item["queue"] = job_options[:queue].to_s if job_options[:queue]

    if (at = run_at(job_options))
      item["at"] = at.to_f
    end

    if workflow_class_name
      class_tags = Array(job_class.get_sidekiq_options["tags"])
      item["tags"] = (class_tags + [workflow_class_name]).uniq
    end

    (@client || ::Sidekiq::Client.new).push(item)
  end

  # Sidekiq has queues with weights, not job priorities. Rejecting
  # `priority:` here keeps it from being ignored without anyone noticing.
  #
  # @param options [Hash{Symbol=>Object}]
  # @param context [String]
  # @return [void]
  # @raise [GenevaDrive::StepConfigurationError] if `priority` is given
  def validate_job_options!(options, context:)
    return if options[:priority].nil?

    raise GenevaDrive::StepConfigurationError,
      "#{context} sets job_options[:priority], but Sidekiq has no job priority - it has queues with weights. " \
      "Put the steps that must run first on a queue with a higher weight, e.g. `queue: :workflows_urgent`."
  end

  private

  # A time in the past or present returns nil, so the job goes straight onto
  # its queue instead of waiting in the schedule set for the poller.
  def run_at(job_options)
    at = if job_options[:wait_until]
      job_options[:wait_until]
    elsif job_options[:wait]
      Time.current + job_options[:wait]
    end
    return nil unless at

    at = at.respond_to?(:to_time) ? at.to_time : Time.at(at.to_f)
    (at > Time.current) ? at : nil
  end
end
