# frozen_string_literal: true

# Pushes step jobs straight to Sidekiq as GenevaDrive::SidekiqPerformStepJob,
# a plain Sidekiq::Job, for apps that use Sidekiq without Active Job.
#
# Pushes go through a fresh Sidekiq::Client, never `perform_async`, so that
# `Sidekiq.transactional_push!` cannot defer them a second time from inside
# GenevaDrive's own after-commit callback - see PerformStepJob for why that
# loses jobs. Client middleware still runs.
#
# @example config/initializers/geneva_drive.rb
#   GenevaDrive.dispatcher = :sidekiq
#
# @see GenevaDrive.dispatcher
class GenevaDrive::SidekiqDispatcher
  # 7.3 and later 7.x, and 8.x - the versions CI runs. 9.0 stays out until tested.
  SUPPORTED_SIDEKIQ_VERSIONS = Gem::Requirement.new(">= 7.3", "< 9")

  # @return [Boolean] whether the loaded Sidekiq is a supported version
  def self.supported_sidekiq_version?
    SUPPORTED_SIDEKIQ_VERSIONS.satisfied_by?(Gem::Version.new(::Sidekiq::VERSION))
  end

  # Whether the install generator should write `GenevaDrive.dispatcher = :sidekiq`
  # into the initializer it creates: a supported Sidekiq is loaded, and the app
  # has pointed Active Job at Sidekiq. An unset adapter does not count - the
  # generator runs in development, and production may well use another backend.
  #
  # @param adapter [Symbol, String, Object, nil] Active Job's configured adapter
  # @return [Boolean]
  def self.recommended?(adapter = Rails.application&.config&.active_job&.queue_adapter)
    return false unless defined?(::Sidekiq::Client) && supported_sidekiq_version?

    adapter.to_s == "sidekiq" || adapter.class.name.to_s.end_with?("SidekiqAdapter")
  end

  # @param job_class [Class, nil] a Sidekiq::Job that performs step executions,
  #   GenevaDrive::SidekiqPerformStepJob by default
  # @raise [LoadError] if Sidekiq is not loaded
  # @raise [ArgumentError] if the loaded Sidekiq is not a supported version
  def initialize(job_class: nil)
    unless defined?(::Sidekiq::Client)
      raise LoadError, "GenevaDrive::SidekiqDispatcher needs the sidekiq gem. Add it to your Gemfile."
    end

    unless self.class.supported_sidekiq_version?
      raise ArgumentError,
        "GenevaDrive::SidekiqDispatcher supports Sidekiq #{SUPPORTED_SIDEKIQ_VERSIONS}, " \
        "but Sidekiq #{::Sidekiq::VERSION} is loaded. Use GenevaDrive.dispatcher = :active_job with this Sidekiq."
    end

    @job_class = job_class
  end

  # @return [Class] the Sidekiq::Job class step jobs are pushed as
  def job_class
    @job_class || GenevaDrive::SidekiqPerformStepJob
  end

  # Pushes the job that performs a step execution.
  #
  # @param step_execution_id [Integer, String] the step execution to perform
  # @param job_options [Hash] validated `queue`, `wait`, `wait_until`
  # @param workflow_class_name [String, nil] added to the job's tags, for the Web UI
  # @return [String, nil] the jid, or nil if client middleware stopped the push
  def enqueue_step(step_execution_id, job_options, workflow_class_name: nil)
    item = {"class" => job_class, "args" => [step_execution_id]}
    item["queue"] = job_options[:queue].to_s if job_options[:queue]

    if (at = run_at(job_options))
      item["at"] = at.to_f
    end

    if workflow_class_name
      class_tags = Array(job_class.get_sidekiq_options["tags"])
      item["tags"] = (class_tags + [workflow_class_name]).uniq
    end

    ::Sidekiq::Client.new.push(item)
  end

  # Sidekiq has queues with weights, not job priorities. Rejecting
  # `priority:` keeps it from being ignored without anyone noticing.
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

  # Workflow already drops an overdue wait_until; this also covers callers that
  # pass a time in the past, which would otherwise wait for the scheduled-set poller.
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
