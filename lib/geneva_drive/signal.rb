# frozen_string_literal: true

# A per-workflow event record, on ActiveRecord. Signals are how the outside
# world tells a workflow that something happened: a webhook landed, a human
# clicked "approve", another system finished its part of the job.
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
# The shared logic lives in {GenevaDrive::SignalBehavior}; this class carries
# the table, enum and the SQL-specific pieces.
#
# @example Delivering a signal
#   workflow = OrderFulfillmentWorkflow.ongoing.for_hero(order).first
#   workflow.signal!(:payment_confirmed, payload: {amount_cents: 12_500})
#
class GenevaDrive::Signal < ActiveRecord::Base
  include GenevaDrive::JsonColumn

  self.table_name = "geneva_drive_signals"

  # Signal lifecycle states as enum with string values.
  #
  # Neither predicates nor scopes are generated: the +claimed+ and +consumed+
  # counter columns own those names, and a `Signal.claimed` scope reading the
  # state while `signal.claimed` reads the counter would be a trap. The state
  # is queried explicitly (`where(state: ...)`) and read off the column; the
  # public predicates are {GenevaDrive::SignalBehavior#claimed?} and
  # {GenevaDrive::SignalBehavior#consumed?} over the counters.
  enum :state, {
    pending: "pending",
    claimed: "claimed",
    consumed: "consumed"
  }, instance_methods: false, scopes: false

  belongs_to :workflow,
    class_name: "GenevaDrive::Workflow",
    foreign_key: :workflow_id,
    inverse_of: :signals

  include GenevaDrive::SignalBehavior

  # Signals that may still be attached to a step execution, oldest first.
  # The eligibility rule for both the gate and dispatch: anything that
  # matches and has not been consumed, FIFO.
  scope :attachable, -> { where.not(state: "consumed").order(created_at: :asc, id: :asc) }

  # Chronological ordering with a stable tiebreaker (the Mongoid backend
  # tiebreaks on _id).
  scope :oldest_first, -> { order(created_at: :asc, id: :asc) }

  class << self
    # The step execution model of this backend.
    #
    # @return [Class]
    def step_execution_class
      GenevaDrive::StepExecution
    end

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

    # How the serialized payload is stored: through the JSON column shim,
    # which encodes to a JSON string on databases without a JSON type.
    #
    # @param serialized [Object] the ActiveJob-serialized payload
    # @return [Object] the storable value
    def encode_payload(serialized)
      encode_json_column(:payload, serialized)
    end
  end

  private

  # Reads the stored payload back into its ActiveJob-serialized form.
  #
  # @return [Object, nil]
  def stored_payload_for_deserialization
    self.class.decode_json_column(:payload, self[:payload])
  end
end
