# frozen_string_literal: true

# A per-workflow event record. Signals are how the outside world tells a
# workflow that something happened: a webhook landed, a human clicked
# "approve", another system finished its part of the job.
#
# A signal is always addressed to one workflow instance and is persisted
# before any processing happens, so it can never be lost between arriving
# and being noticed - a signal that arrives before the waiting step even
# exists simply sits in the table until the step's gate picks it up.
#
# The lifecycle, in the +state+ column, is +pending+ -> +claimed+ -> +consumed+:
#
# - +pending+: persisted, nobody is working on it
# - +claimed+: attached to at least one step execution, at least one of which
#   has not resolved yet
# - +consumed+: every attached chain resolved cleanly; no new execution may attach
#
# Alongside the state there are two counters, +claimed+ and +consumed+: how
# many executions have attached to this event, and how many attached chains
# have resolved cleanly.
#
# @example Delivering a signal
#   workflow = OrderFulfillmentWorkflow.ongoing.for_hero(order).first
#   workflow.signal!(:payment_confirmed, payload: {amount_cents: 12_500})
#
class GenevaDrive::Signal < ActiveRecord::Base
  self.table_name = "geneva_drive_signals"

  # Signal lifecycle states as enum with string values.
  #
  # Neither predicates nor scopes are generated: the +claimed+ and +consumed+
  # counter columns own those names, and a `Signal.claimed` scope reading the
  # state while `signal.claimed` reads the counter would be a trap. The state
  # is queried explicitly (`where(state: ...)`) and read off the column; the
  # public predicates are {#claimed?} and {#consumed?} over the counters.
  enum :state, {
    pending: "pending",
    claimed: "claimed",
    consumed: "consumed"
  }, instance_methods: false, scopes: false

  # Step execution states that mean "this chain has not come to rest yet".
  ACTIVE_EXECUTION_STATES = %w[waiting scheduled in_progress].freeze

  # Outcomes that resolve an attached chain cleanly, so the signal can be
  # considered handled by it.
  CLEAN_OUTCOMES = %w[success skipped].freeze

  belongs_to :workflow,
    class_name: "GenevaDrive::Workflow",
    foreign_key: :workflow_id,
    inverse_of: :signals

  validates :name, presence: true

  # Signals that may still be attached to a step execution, oldest first.
  # The eligibility rule for both the gate and dispatch: anything that
  # matches and has not been consumed, FIFO.
  scope :attachable, -> { where.not(state: "consumed").order(created_at: :asc, id: :asc) }

  class << self
    # Lazily checks whether the signals table has been migrated. Never hits
    # the database at class definition time - only on the first runtime call.
    #
    # Deployments usually ship the gem update before running migrations, so
    # everything except actually sending or waiting for a signal must keep
    # working when the table is absent.
    #
    # @return [Boolean]
    def table_available?
      if defined?(@_table_available)
        return @_table_available
      end

      @_table_available = table_exists?
    end

    # Clears the cached table detection result. Call this in tests or after
    # running migrations in-process so the next access re-checks.
    #
    # @return [void]
    def reset_table_available_cache!
      remove_instance_variable(:@_table_available) if defined?(@_table_available)
    end

    # Serializes a payload using ActiveJob serializers (handles Date, Time,
    # and other types) and enforces GenevaDrive.max_signal_payload_size on
    # the serialized JSON. The single serialization path for payload writes.
    #
    # @param value [Object, nil] the payload
    # @return [Object, nil] the serialized payload
    # @raise [SignalPayloadTooLargeError] if the serialized JSON exceeds the limit
    def serialize_payload(value)
      return nil if value.nil?

      serialized = ActiveJob::Arguments.serialize([value]).first

      limit = GenevaDrive.max_signal_payload_size
      if limit
        bytesize = JSON.generate(serialized).bytesize
        if bytesize > limit
          raise GenevaDrive::SignalPayloadTooLargeError,
            "Serialized signal payload is #{bytesize} bytes, exceeding " \
            "GenevaDrive.max_signal_payload_size (#{limit} bytes). A payload describes the " \
            "event, it is not a place to ship the data the step should be working on - " \
            "write what matters onto the hero instead. Set " \
            "GenevaDrive.max_signal_payload_size to nil to disable this check."
        end
      end

      serialized
    end
  end

  # Returns the deserialized payload. Hashes come back with indifferent
  # access, because webhook senders produce string keys while Ruby senders
  # produce symbols and matchers should not have to know which.
  #
  # @return [Object, nil] the payload
  def payload
    raw = self[:payload]
    return nil if raw.nil?

    value = ActiveJob::Arguments.deserialize([raw]).first
    value.is_a?(Hash) ? ActiveSupport::HashWithIndifferentAccess.new(value) : value
  end

  # Sets the payload, serializing it through ActiveJob serializers.
  #
  # @param value [Object, nil] the payload
  # @raise [SignalPayloadTooLargeError] if the serialized JSON exceeds the limit
  # @return [void]
  def payload=(value)
    self[:payload] = self.class.serialize_payload(value)
  end

  # Whether this instance was returned from a deduplicated delivery - that
  # is, {GenevaDrive::Workflow#signal!} found an existing row with the same
  # idempotency key instead of inserting a new one. Not a column: it is a
  # fact about this call, not about the record.
  #
  # @return [Boolean]
  def duplicate_delivery?
    !!@duplicate_delivery
  end

  # Flags this instance as the result of a deduplicated delivery.
  #
  # @return [void]
  # @api private
  def duplicate_delivery!
    @duplicate_delivery = true
  end

  # Whether at least one execution has ever attached to this signal. Reads
  # the counter, not the lifecycle state, so it stays true after the signal
  # has been consumed - "this event was picked up" rather than "is being
  # handled right now".
  #
  # @return [Boolean]
  def claimed? = claimed > 0

  # Whether at least one attached chain has resolved cleanly. Reads the
  # counter, so for a one-to-many dispatch it goes true with the first
  # resolved branch, while the state only flips once the last one resolves.
  #
  # @return [Boolean]
  def consumed? = consumed > 0

  # Records one execution attaching to this signal, bumping the claimed
  # count. The pending -> claimed state flip and claimed_at happen on the
  # first claim only, so the timestamp keeps meaning "when this event started
  # being handled". A retry attaching to a still-claimed signal counts as a
  # new claim; a successor continuing the same chain does not (it carries the
  # pin over rather than acquiring it).
  #
  # @return [void]
  # @api private
  def claim!
    attrs = {claimed: claimed + 1}
    if state == "pending"
      attrs[:state] = "claimed"
      attrs[:claimed_at] = Time.current
    end
    update!(attrs)
  end

  # Records one attached execution chain resolving cleanly, bumping the
  # consumed count. The state flips to consumed - closing the signal to new
  # attachments - only once every attached chain has resolved, which for a
  # single claimant is the same moment.
  #
  # @return [void]
  # @api private
  def record_consumption!
    attrs = {consumed: consumed + 1}
    if state == "claimed" && fully_resolved?
      attrs[:state] = "consumed"
      attrs[:consumed_at] = Time.current
    end
    update!(attrs)
  end

  # Whether every execution chain attached to this signal has come to a
  # clean stop. A chain that is still running (or parked), and one whose
  # latest attached execution failed or was canceled, both keep the state at
  # claimed - the failed chain's retry re-attaches to it and reads the same
  # payload.
  #
  # Only the most recent attached execution per step counts: the earlier ones
  # in a chain end with `continued` or `reattempted` precisely because they
  # handed the work to the next one.
  #
  # @return [Boolean]
  # @api private
  def fully_resolved?
    attached = step_executions.order(created_at: :asc, id: :asc).to_a
    return true if attached.empty?
    return false if attached.any? { |execution| ACTIVE_EXECUTION_STATES.include?(execution.state) }

    attached.group_by(&:step_name).all? do |_step_name, chain|
      CLEAN_OUTCOMES.include?(chain.last.outcome)
    end
  end

  # Step executions pinned to this signal.
  #
  # @return [ActiveRecord::Relation<GenevaDrive::StepExecution>]
  def step_executions
    GenevaDrive::StepExecution.where(signal_id: id)
  end
end
