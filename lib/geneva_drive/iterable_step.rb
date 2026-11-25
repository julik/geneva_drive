# frozen_string_literal: true

# Object passed to resumable step blocks for cursor-based iteration.
#
# Provides an API compatible with Rails 8.1's ActiveJob::Continuation::Step,
# plus GenevaDrive-specific extensions for iterating over records and batches.
#
# @example Manual cursor control
#   resumable_step :process_records do |iter|
#     hero.records.where("id > ?", iter.cursor || 0).find_each do |record|
#       process(record)
#       iter.set!(record.id)
#     end
#   end
#
# @example Using iterate_over_records helper
#   resumable_step :process_records do |iter|
#     iter.iterate_over_records(hero.records) do |record|
#       process(record)
#     end
#   end
#
class GenevaDrive::IterableStep
  attr_reader :name, :cursor

  # Creates a new IterableStep for a resumable step execution.
  #
  # @param name [String, Symbol] the step name
  # @param cursor [Object, nil] the current cursor value
  # @param execution [GenevaDrive::StepExecution] the step execution record
  # @param resumed [Boolean] whether this is a resumed execution
  # @param interrupter [#should_interrupt?] object to check for interruption
  def initialize(name, cursor, execution:, resumed:, interrupter:)
    @name = name.to_sym
    @cursor = cursor
    @execution = execution
    @resumed = resumed
    @interrupter = interrupter
    @advanced = false
    @iterations = 0
  end

  # Returns the number of iterations completed during this execution
  # (checkpoints via set!, advance! or checkpoint!).
  #
  # @return [Integer]
  attr_reader :iterations

  # === Rails 8.1 ActiveJob::Continuation::Step compatible API ===

  # Returns true if this execution is resuming from a prior suspension.
  #
  # @return [Boolean]
  def resumed?
    @resumed
  end

  # Returns true if the cursor was changed during this execution.
  #
  # @return [Boolean]
  def advanced?
    @advanced
  end

  # Sets the cursor to a new value and checkpoints.
  # The cursor can be any value that ActiveJob can serialize.
  #
  # @param value [Object] the new cursor value
  # @return [void]
  def set!(value)
    @cursor = value
    @advanced = true
    checkpoint!
  end

  # Increments an integer cursor by 1 and checkpoints.
  # Only works with integer cursors.
  #
  # @raise [ArgumentError] if cursor is not an Integer
  # @return [void]
  def advance!
    raise ArgumentError, "advance! requires integer cursor, got #{@cursor.inspect}" unless @cursor.is_a?(Integer)
    set!(@cursor + 1)
  end

  # Persists the current cursor, counts the iteration, and checks for
  # interruption (max_iterations, max_runtime, shutdown, external pause/cancel).
  # Called automatically by set! and advance!.
  #
  # @return [void]
  def checkpoint!
    @iterations += 1
    persist_cursor!
    check_interruption!
  end

  # Returns array representation [name, cursor] for compatibility.
  #
  # @return [Array]
  def to_a
    [name.to_s, cursor]
  end

  # Returns a human-readable description of current position.
  #
  # @return [String]
  def description
    "at '#{name}', cursor '#{cursor.inspect}'"
  end

  # === GenevaDrive Extensions ===

  # Skips to a new cursor position and suspends execution.
  # The job will be re-enqueued to continue from the new cursor.
  #
  # @param value [Object] the new cursor value
  # @param wait [ActiveSupport::Duration, Numeric, nil] optional delay before re-enqueue
  # @return [void] (never returns - throws :interrupt)
  def skip_to!(value, wait: nil)
    @cursor = value
    @advanced = true
    persist_cursor!
    throw :interrupt, wait
  end

  # Iterates over an enumerable using index as cursor.
  # Resumes from the stored cursor position on subsequent runs.
  #
  # @param enumerable [Enumerable] the collection to iterate over
  # @yield [Object] each element in the collection
  # @return [void]
  def iterate_over(enumerable)
    raise ArgumentError, "Must respond to #each" unless enumerable.respond_to?(:each)

    start_index = @cursor || 0
    enumerable.each_with_index do |element, index|
      next if index < start_index
      yield element
      set!(index + 1)
    end
  end

  # Iterates over an ActiveRecord relation (or Mongoid criteria) using a
  # column as cursor. On ActiveRecord uses find_each for memory-efficient
  # batching.
  #
  # @param relation [ActiveRecord::Relation, Mongoid::Criteria] the relation to iterate over
  # @param cursor [Symbol] the column to use as cursor (default: :id)
  # @yield [Object] each record in the relation
  # @return [void]
  def iterate_over_records(relation, cursor: :id)
    if mongoid_criteria?(relation)
      return iterate_over_mongoid_records(relation, cursor: cursor) { |record| yield record }
    end

    filtered = if @cursor
      relation.where(relation.arel_table[cursor].gt(@cursor)).order(cursor => :asc)
    else
      relation.order(cursor => :asc)
    end

    filtered.find_each do |record|
      yield record
      set!(record.public_send(cursor))
    end
  end

  # Iterates over an ActiveRecord relation (or Mongoid criteria) in
  # subrelations (batches). Each subrelation is yielded as a relation scoped
  # to one batch, useful for bulk operations like updates or exports.
  #
  # @param relation [ActiveRecord::Relation, Mongoid::Criteria] the relation to iterate over
  # @param batch_size [Integer] the number of records per subrelation
  # @param cursor [Symbol] the column to use as cursor (default: :id)
  # @yield [ActiveRecord::Relation, Mongoid::Criteria] each subrelation
  # @return [void]
  def iterate_over_subrelations(relation, batch_size:, cursor: :id)
    if mongoid_criteria?(relation)
      return iterate_over_mongoid_subrelations(relation, batch_size: batch_size, cursor: cursor) { |batch| yield batch }
    end

    filtered = if @cursor
      relation.where(relation.arel_table[cursor].gt(@cursor)).order(cursor => :asc)
    else
      relation.order(cursor => :asc)
    end

    filtered.in_batches(of: batch_size) do |relation_with_offset|
      yield relation_with_offset
      last_cursor = relation_with_offset.maximum(cursor)
      set!(last_cursor) if last_cursor
    end
  end

  private

  # @param relation [Object]
  # @return [Boolean] whether the relation is a Mongoid criteria
  def mongoid_criteria?(relation)
    defined?(::Mongoid::Criteria) && relation.is_a?(::Mongoid::Criteria)
  end

  # The Mongoid shape of iterate_over_records.
  #
  # @param relation [Mongoid::Criteria]
  # @param cursor [Symbol]
  # @yield [Mongoid::Document]
  # @return [void]
  def iterate_over_mongoid_records(relation, cursor:)
    field = mongoid_cursor_field_name(cursor)
    filtered = if @cursor
      relation.where(field => {"$gt" => @cursor}).order(field => :asc)
    else
      relation.order(field => :asc)
    end

    filtered.each do |record|
      yield record
      set!(record.public_send(cursor))
    end
  end

  # The Mongoid shape of iterate_over_subrelations: each batch is a criteria
  # scoped to one page of cursor values.
  #
  # @param relation [Mongoid::Criteria]
  # @param batch_size [Integer]
  # @param cursor [Symbol]
  # @yield [Mongoid::Criteria]
  # @return [void]
  def iterate_over_mongoid_subrelations(relation, batch_size:, cursor:)
    field = mongoid_cursor_field_name(cursor)

    loop do
      scope = @cursor ? relation.where(field => {"$gt" => @cursor}) : relation
      batch_values = scope.order(field => :asc).limit(batch_size).pluck(field)
      break if batch_values.empty?

      yield relation.where(field => {"$in" => batch_values})
      set!(batch_values.max)
    end
  end

  # @param cursor [Symbol]
  # @return [String] the MongoDB field name for a cursor symbol
  def mongoid_cursor_field_name(cursor)
    (cursor.to_s == "id") ? "_id" : cursor.to_s
  end

  def persist_cursor!
    serialized = @execution.class.serialize_cursor(@cursor)

    @execution.class
      .where(id: @execution.id)
      .update_all(cursor: serialized)
  end

  def check_interruption!
    throw :interrupt if @interrupter&.should_interrupt?(iterations: @iterations)
  end
end
