# frozen_string_literal: true

# A per-workflow event record, on Mongoid (MongoDB). Signals are how the
# outside world tells a workflow that something happened: a webhook landed, a
# human clicked "approve", another system finished its part of the job.
#
# The shared logic lives in {GenevaDrive::SignalBehavior}; this class carries
# the fields, the dedup index and the Mongo-specific pieces.
#
# @example Delivering a signal
#   workflow = OrderFulfillmentWorkflow.ongoing.for_hero(order).first
#   workflow.signal!(:payment_confirmed, payload: {amount_cents: 12_500})
#
class GenevaDrive::MongoidSignal
  include Mongoid::Document
  include Mongoid::Timestamps
  include GenevaDrive::EnumField

  store_in collection: "geneva_drive_signals"

  field :name, type: String
  field :idempotency_key, type: String
  field :payload
  field :claimed_at, type: Time
  field :consumed_at, type: Time
  field :claimed, type: Integer, default: 0
  field :consumed, type: Integer, default: 0

  # Signal lifecycle states.
  #
  # Neither predicates nor scopes are generated: the +claimed+ and +consumed+
  # counter fields own those names, and a `MongoidSignal.claimed` scope
  # reading the state while `signal.claimed` reads the counter would be a
  # trap. The state is queried explicitly (`where(state: ...)`) and read off
  # the field; the public predicates are {GenevaDrive::SignalBehavior#claimed?}
  # and {GenevaDrive::SignalBehavior#consumed?} over the counters.
  enum_field :state, %w[pending claimed consumed], default: "pending",
    instance_methods: false, scopes: false

  belongs_to :workflow,
    class_name: "GenevaDrive::MongoidWorkflow",
    foreign_key: :workflow_id,
    inverse_of: :signals

  index({workflow_id: 1})
  index({workflow_id: 1, state: 1})
  # Dedup index. Partial on idempotency_key being an actual string: signals
  # without a key (absent or explicit null) always insert.
  index(
    {workflow_id: 1, name: 1, idempotency_key: 1},
    {unique: true, partial_filter_expression: {idempotency_key: {"$type" => "string"}}}
  )

  include GenevaDrive::SignalBehavior

  # Signals that may still be attached to a step execution, oldest first.
  # The eligibility rule for both the gate and dispatch: anything that
  # matches and has not been consumed, FIFO.
  scope :attachable, -> { where(:state.ne => "consumed").order(created_at: :asc, _id: :asc) }

  # Chronological ordering with a stable tiebreaker. ObjectIds are
  # time-prefixed, so the _id tiebreak keeps the meaning the SQL id had.
  scope :oldest_first, -> { order(created_at: :asc, _id: :asc) }

  class << self
    # The step execution model of this backend.
    #
    # @return [Class]
    def step_execution_class
      GenevaDrive::MongoidStepExecution
    end

    # MongoDB is schemaless: the signals collection is always available.
    # Kept for API compatibility with the SQL implementation.
    #
    # @return [Boolean]
    def table_available?
      true
    end

    # Kept as a no-op for API compatibility with the SQL implementation.
    #
    # @return [void]
    def reset_table_available_cache!
    end

    # The serialized payload is stored natively - MongoDB holds the structure
    # as-is.
    #
    # @param serialized [Object] the ActiveJob-serialized payload
    # @return [Object] the storable value
    def encode_payload(serialized)
      serialized
    end
  end

  private

  # Reads the stored payload back into its ActiveJob-serialized form - which
  # is how it is stored, natively.
  #
  # @return [Object, nil]
  def stored_payload_for_deserialization
    self[:payload]
  end
end
