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
# The lifecycle is +pending+ -> +claimed+ -> +consumed+:
#
# - +pending+: persisted, nobody is working on it
# - +claimed+: attached to at least one step execution which is processing it
# - +consumed+: an attached execution finished cleanly; no new execution may attach
#
# @example Delivering a signal
#   workflow = OrderFulfillmentWorkflow.ongoing.for_hero(order).first
#   workflow.signal!(:payment_confirmed, payload: {amount_cents: 12_500})
#
class GenevaDrive::Signal < ActiveRecord::Base
  self.table_name = "geneva_drive_signals"

  # Signal states as enum with string values.
  # Provides: pending?, claimed?, consumed? predicates and matching scopes.
  enum :state, {
    pending: "pending",
    claimed: "claimed",
    consumed: "consumed"
  }

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

  # Claims the signal for processing. No-op unless the signal is pending,
  # so that a second execution attaching to the same signal leaves the
  # original claimed_at intact.
  #
  # @return [void]
  # @api private
  def claim!
    return unless pending?
    update!(state: "claimed", claimed_at: Time.current)
  end

  # Marks the signal consumed. No-op unless the signal is claimed - a
  # signal is only ever consumed by an execution that attached to it.
  #
  # @return [void]
  # @api private
  def consume!
    return unless claimed?
    update!(state: "consumed", consumed_at: Time.current)
  end

  # Step executions pinned to this signal.
  #
  # @return [ActiveRecord::Relation<GenevaDrive::StepExecution>]
  def step_executions
    GenevaDrive::StepExecution.where(signal_id: id)
  end
end
