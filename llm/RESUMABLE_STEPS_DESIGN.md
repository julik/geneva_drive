# Resumable Steps for GenevaDrive

## Executive Summary

This document proposes adding a `resumable_step` DSL to GenevaDrive that allows steps to iterate over large collections with cursor-based resumption. The block receives an **IterableStep object** with an API compatible with Rails 8.1's `ActiveJob::Continuation::Step`, providing familiar semantics for cursor management and checkpointing.

---

## 1. Background

### 1.1 Prior Art

Two existing solutions inform this design:

**Shopify's [job-iteration](https://github.com/Shopify/job-iteration)**:
- Separates enumeration setup from iteration logic
- Enumerator yields `[object, cursor]` pairs
- Automatic checkpointing between iterations

**Rails 8.1's [ActiveJob::Continuable](https://github.com/rails/rails/pull/55127)**:
- Block receives a `step` object with `cursor`, `set!`, `advance!`, `checkpoint!`
- User controls when to checkpoint
- Clean, explicit API

### 1.2 Why Match Rails 8.1's Step API?

We provide a `GenevaDrive::IterableStep` class that's **API-compatible** with `ActiveJob::Continuation::Step`:

1. **Familiarity** - Rails 8.1 users already know `set!`, `advance!`, `checkpoint!`, `cursor`, `resumed?`
2. **Documentation reuse** - can reference Rails docs for core API semantics
3. **Muscle memory** - same patterns work in both contexts
4. **No dependency** - works with Rails 7.x+, doesn't require Rails 8.1

We add GenevaDrive-specific extensions (like `iter.iterate_over`) on top of the compatible base.

### 1.3 Why Not Fibers?

While Ruby Fibers can suspend execution mid-block, they have critical limitations:

- **Fiber state cannot be serialized**: Can't persist to database, can't survive process restart
- **Fibers are bound to threads**: Can't resume in a different job worker process

The cursor pattern is simpler: on resume, user code rebuilds iteration state using the stored cursor (e.g., `WHERE id > cursor`).

---

## 2. Design Principles

### GenevaDrive Constraints

1. **Step executions are idempotent**: Pessimistic locking ensures no duplicate execution
2. **One active execution per workflow**: Unique constraint in database
3. **Flow control via throw/catch**: Existing mechanism for step interruption
4. **State stored in database**: Not in job serialization (unlike job-iteration)
5. **Steps are the atomic unit**: Resumable steps must remain steps, not become sub-workflows

### New Constraints for Resumable Steps

1. **Checkpoint persists cursor**: Each `checkpoint!` call saves cursor to database
2. **Chained executions**: When a step suspends, it completes and creates a **successor** execution linked via `continues_from_id`
3. **Cursor preserved on reattempt**: By default, `reattempt!` continues from cursor position
4. **Optional rewind**: Use `reattempt!(rewind: true)` to restart from beginning

---

## 3. The IterableStep Object API

### 3.1 Rails 8.1 Compatible Core

The block receives a `GenevaDrive::IterableStep` object with the same core API as `ActiveJob::Continuation::Step`:

| Method | Description |
|--------|-------------|
| `iter.cursor` | Current cursor value (`nil` on first run) |
| `iter.resumed?` | `true` if resuming from prior suspension |
| `iter.advanced?` | `true` if cursor changed during this run |
| `iter.set!(value)` | Set cursor for the **next** iteration, then checkpoint |
| `iter.advance!` | Increment integer cursor via `+ 1`, then checkpoint. **Integers only.** |
| `iter.checkpoint!` | Persist cursor to DB, check for interruption |

### 3.2 Cursor Semantics

**The cursor is the value you'll receive on the next iteration.** When you call `set!(x)`, on resume `iter.cursor` returns exactly `x`. You decide what `x` means for your use case:

```ruby
# Record IDs: save last processed ID, query with > on resume
records.where("id > ?", iter.cursor || 0).find_each do |record|
  process(record)
  iter.set!(record.id)  # Next iteration will see this ID, query > it
end

# Page numbers: save the next page to fetch
iter.set!(page + 1)  # Next iteration starts from this page

# Opaque tokens: save the token for the next API call
iter.set!(response.next_page_token)  # Next iteration uses this token
```

### 3.3 Cursor Types

Cursors are serialized using **ActiveJob serializers**, so any type ActiveJob can serialize works automatically:

- **Integers, Strings**: Work directly
- **Opaque tokens** (API pagination tokens, UUIDs): Work directly
- **Date, Time, DateTime**: Serialized/deserialized automatically
- **BigDecimal, ActiveSupport::Duration**: Supported via AJ serializers

```ruby
# Integer cursor - advance! works
iter.advance!  # cursor 42 becomes 43

# Opaque token - use set! directly
iter.set!(response.next_page_token)  # "CiAKGjBpNDd2Nmp..."

# Date cursor - just works, no manual conversion needed
current = iter.cursor || Date.new(2024, 1, 1)
process_day(current)
iter.set!(current + 1)  # Date is serialized automatically
```

The `advance!` method raises `ArgumentError` if the cursor is not an `Integer`.

### 3.4 GenevaDrive Extensions

| Method | Description |
|--------|-------------|
| `iter.iterate_over(array)` | Iterate over stable array; uses index as cursor |
| `iter.iterate_over_records(relation, cursor: :id)` | Iterate over AR relation; uses `find_each`, column as cursor |
| `iter.iterate_over_subrelations(relation, batch_size:, cursor: :id)` | Iterate over subrelations; yields AR relation with offset |
| `iter.skip_to!(value, wait: nil)` | Set cursor, persist, suspend. Optional `wait:` for delayed re-enqueue |

---

## 4. Proposed DSL

### 4.1 Basic Usage - Manual Cursor Control

```ruby
class BulkNotificationWorkflow < GenevaDrive::Workflow
  belongs_to :campaign, class_name: "MarketingCampaign", foreign_key: :hero_id

  step :prepare_campaign do
    hero.update!(status: "sending")
  end

  resumable_step :send_notifications do |iter|
    hero.subscribers.where("id > ?", iter.cursor || 0).find_each do |subscriber|
      NotificationMailer.campaign(hero, subscriber).deliver_later
      iter.set!(subscriber.id)
    end
  end

  step :finalize do
    hero.update!(status: "sent", completed_at: Time.current)
  end
end
```

### 4.2 Iterating Over Records

For ActiveRecord relations, use `iterate_over_records`:

```ruby
resumable_step :send_notifications do |iter|
  iter.iterate_over_records(hero.subscribers) do |subscriber|
    NotificationMailer.campaign(hero, subscriber).deliver_later
  end
end
```

This:
- Uses `find_each` for memory-efficient batching
- Applies `WHERE id > cursor ORDER BY id`
- Auto-checkpoints after each record
- Checks for interruption after each record

With explicit cursor column:

```ruby
iter.iterate_over_records(hero.subscribers, cursor: :created_at) do |subscriber|
  # ...
end
```

### 4.3 Iterating Over Subrelations

For bulk operations, use `iterate_over_subrelations`. Each iteration yields an ActiveRecord relation with offset applied, enabling efficient bulk operations:

```ruby
resumable_step :bulk_insert_notifications do |iter|
  iter.iterate_over_subrelations(hero.subscribers, batch_size: 500) do |relation_with_offset|
    # relation_with_offset is an AR relation - use bulk operations
    Notification.insert_all(
      relation_with_offset.pluck(:id).map { |id| { subscriber_id: id, campaign_id: hero.id } }
    )
  end
end

resumable_step :bulk_update_status do |iter|
  iter.iterate_over_subrelations(hero.subscribers, batch_size: 1000) do |relation_with_offset|
    # Can call update_all directly on the relation
    relation_with_offset.update_all(notified_at: Time.current)
  end
end
```

### 4.4 Iterating Over Arrays

For stable, in-memory arrays, use `iterate_over`:

```ruby
iter.iterate_over(items_array) do |item|
  process(item)
end
```

Uses index as cursor. **Only for stable arrays** - if the array changes between suspensions, the index will point to wrong items.

For date ranges or other sequences where items have natural cursor values, use manual loops (see section 4.6).

### 4.5 Opaque Token Pagination (e.g., Google APIs)

For APIs that return opaque page tokens, use a plain `loop` with `set!` and `skip_to!`:

```ruby
resumable_step :sync_gmail do |iter|
  loop do
    response = gmail.list_messages(page_token: iter.cursor)

    # skip_to! suspends and re-enqueues - no need for `next`
    iter.skip_to!(response.next_page_token) if response.empty_page?

    response.messages.each { |msg| process(msg) }

    break unless response.next_page_token
    iter.set!(response.next_page_token)
  end
end
```

The `skip_to!(value, wait: nil)` method:
- Sets and persists the cursor
- Throws `:interrupt` to suspend the step
- Re-enqueues for continuation from the new cursor
- Optional `wait:` delays the re-enqueue (for rate limiting)
- No need to remember `break` or `next`

### 4.6 Using advance! for Integer Cursors

For simple integer-based pagination:

```ruby
resumable_step :process_batches do |iter|
  total_batches = 100
  current = iter.cursor || 0

  while current < total_batches
    process_batch(current)
    iter.advance!  # cursor 0 becomes 1, etc.
  end
end
```

`advance!` only works with integers. For dates, use `set!` directly (ActiveJob serializers handle Date automatically):

```ruby
resumable_step :process_days do |iter|
  current = iter.cursor || Date.new(2024, 1, 1)

  while current <= Date.current
    process_day(current)
    current += 1
    iter.set!(current)  # Date is serialized automatically
  end
end
```

### 4.7 Rate-Limited APIs with Delayed Retry

For rate-limited APIs, use `skip_to!` with the `wait:` parameter:

```ruby
resumable_step :sync_external_api do |iter|
  page = iter.cursor || 1

  loop do
    response = ExternalApi.fetch(page: page)

    if response.rate_limited?
      # Suspend and retry after the rate limit expires
      iter.skip_to!(page, wait: response.retry_after)
    end

    break if response.empty?
    response.items.each { |item| process(item) }
    page += 1
    iter.set!(page)
  end
end
```

The `wait:` parameter:
- Persists the cursor immediately
- Suspends the step
- Re-enqueues the job with the specified delay
- Uses the same `throw :interrupt` mechanism as immediate `skip_to!`

This is consistent with GenevaDrive's flow control philosophy - all control flow uses `throw`, not exceptions.

### 4.8 DSL Method Signature

```ruby
resumable_step(name = nil,
  max_iterations: nil,         # Optional: interrupt after N total iterations
  max_runtime: nil,            # Optional: interrupt after duration
  on_exception: :pause!,       # Existing option
  **options,                   # Other step options (wait:, skip_if:, etc.)
  &block)                      # Required: block receiving step object
```

---

## 5. Database Schema Changes

### 5.1 Migration

```ruby
class AddResumableStepSupport < ActiveRecord::Migration[7.1]
  def change
    # Use database-native JSON type:
    # - PostgreSQL: jsonb (indexed, efficient, supports containment queries)
    # - MySQL 5.7+: json (native validation and storage)
    # - SQLite: text (with Rails JSON serialization - no native JSON type)
    if connection.adapter_name.downcase.include?('postgresql')
      add_column :geneva_drive_step_executions, :cursor, :jsonb
    else
      add_column :geneva_drive_step_executions, :cursor, :json
    end
  end
end

class AddChainedStepExecutions < ActiveRecord::Migration[7.1]
  def change
    # Link successor executions to their predecessors for resumable steps
    add_column :geneva_drive_step_executions, :continues_from_id, :bigint
    add_index :geneva_drive_step_executions, :continues_from_id
    add_foreign_key :geneva_drive_step_executions, :geneva_drive_step_executions,
                    column: :continues_from_id, on_delete: :nullify
  end
end
```

**Why database-native JSON types?**
- **PostgreSQL JSONB**: Supports indexing, containment queries (`@>`), efficient storage
- **MySQL JSON**: Native validation, JSON path query support
- **SQLite**: Falls back to TEXT with Rails handling serialization transparently
- Rails automatically handles serialization/deserialization per adapter

### 5.2 Fast Checkpoint Updates

Checkpointing happens after every iteration, so it must be fast. Use `update_all` to bypass ActiveRecord callbacks and validations:

```ruby
def persist_cursor!(new_cursor)
  # Serialize cursor value using ActiveJob serializers (handles Date, Time, etc.)
  serialized = new_cursor.nil? ? nil : ActiveJob::Arguments.serialize([new_cursor]).first

  GenevaDrive::StepExecution
    .where(id: @step_execution.id)
    .update_all(cursor: serialized)  # Rails handles JSON encoding per database adapter
end
```

**Why `update_all`?**
- Bypasses AR instantiation, callbacks, and validations
- Single SQL statement: `UPDATE ... SET cursor = ? WHERE id = ?`
- No `with_lock` needed—atomic update via SQL
- Critical for high-throughput iteration (thousands of items per second)
- Rails automatically encodes to JSONB/JSON/TEXT based on database adapter

### 5.3 Chained Executions Model

Instead of a `suspended` state, resumable steps use **chained executions**. When a step needs to suspend:

1. The current execution is marked `completed` (with outcome indicating why)
2. A new **successor** execution is created with `continues_from_id` pointing to the predecessor
3. The successor inherits the cursor from its predecessor

```ruby
class GenevaDrive::StepExecution < ActiveRecord::Base
  # Links successor executions to their predecessors
  belongs_to :continues_from,
    class_name: "GenevaDrive::StepExecution",
    foreign_key: :continues_from_id,
    optional: true,
    inverse_of: :successor

  has_one :successor,
    class_name: "GenevaDrive::StepExecution",
    foreign_key: :continues_from_id,
    inverse_of: :continues_from

  # Returns true if this execution continues from a previous one
  def resuming?
    continues_from_id.present?
  end
end
```

**Why chained executions instead of a suspended state?**
- **Timeline clarity**: Each execution has clear start/end times, enabling proper visualization
- **Audit trail**: Can see exactly when each chunk of work happened
- **Simpler state machine**: No need for special "suspended" → "in_progress" transitions
- **Consistent semantics**: "Completed" means the execution finished its work, whether it spawned a successor or not

### 5.4 Cursor Serialization

Cursors use ActiveJob's serialization system, which handles Date, Time, DateTime, BigDecimal, and other types automatically. With native JSON columns, Rails handles the JSON encoding/decoding transparently:

```ruby
# StepExecution additions
class GenevaDrive::StepExecution < ActiveRecord::Base
  # Rails automatically serializes/deserializes native JSON columns.
  # We wrap/unwrap for ActiveJob serializer compatibility (Date, Time, etc.)

  def cursor_value
    return nil if cursor.blank?
    ActiveJob::Arguments.deserialize([cursor]).first
  end

  def cursor_value=(value)
    if value.nil?
      self.cursor = nil
    else
      # ActiveJob serializers convert Date/Time/etc. to serializable hashes
      self.cursor = ActiveJob::Arguments.serialize([value]).first
    end
  end
end
```

This means users can store Dates directly without manual ISO8601 conversion:

```ruby
# Before (manual serialization)
current = iter.cursor ? Date.parse(iter.cursor) : start_date
iter.set!(current.iso8601)

# After (automatic via AJ serializers)
current = iter.cursor || start_date
iter.set!(current)
```

---

## 6. Execution Model

### 6.1 Chained Executions (No Suspended State)

Resumable steps use **chained executions** instead of a `suspended` state. Each time work needs to pause and continue later, the current execution completes and a successor execution is created.

**States**: `scheduled`, `in_progress`, `completed`, `failed`, `canceled`, `skipped`

**No `suspended` state** - When a resumable step needs to pause:
1. Current execution transitions to `completed` (outcome indicates it spawned a successor)
2. A new successor execution is created with `continues_from_id` linking to the predecessor
3. Successor inherits the cursor and is scheduled for execution

**Benefits**:
- **Timeline visualization**: Each execution has clear start/end times
- **Audit trail**: Complete history of when each chunk of work happened
- **Simpler state machine**: Standard states, no special transitions

**Active states for unique constraint**: `scheduled`, `in_progress`

### 6.2 State Diagram

```mermaid
stateDiagram-v2
    [*] --> scheduled : Job enqueued
    scheduled --> in_progress : Job starts

    in_progress --> completed : Enumeration exhausted
    in_progress --> completed : Interrupt - creates successor
    in_progress --> failed : Exception with pause
    in_progress --> canceled : Exception with cancel
    in_progress --> skipped : Exception with skip

    completed --> scheduled : Successor created (new execution)

    completed --> [*]
    failed --> [*]
    canceled --> [*]
    skipped --> [*]
```

### 6.3 Full Execution Flow

```mermaid
flowchart TD
    A[Job receives step_execution_id] --> B{State is scheduled?}
    B -->|No| Z[Exit - wrong state]
    B -->|Yes| C[Transition to in_progress]

    C --> D[Create IterableStep with cursor]
    D --> D2{resuming? - has continues_from_id?}
    D2 -->|Yes| E[Execute block - iter.resumed? = true]
    D2 -->|No| E2[Execute block - iter.resumed? = false]

    E --> F{Block completes?}
    E2 --> F
    F -->|Yes| G[Mark completed, schedule next step]
    F -->|No - interrupt thrown| H{Has wait value?}
    H -->|Yes| M2[Mark completed, create successor with delay]
    H -->|No| M[Mark completed, create successor immediately]

    E --> I{Exception?}
    E2 --> I
    I -->|Yes| J[Handle via on_exception policy]

    J --> O{Policy}
    O -->|pause!| P[Mark completed outcome=workflow_paused, pause workflow]
    O -->|cancel!| Q[Mark canceled, cancel workflow]
    O -->|skip!| R[Mark skipped, schedule next]
    O -->|reattempt!| S{rewind: true?}
    S -->|Yes| T[Mark completed, create successor with nil cursor]
    S -->|No| M

    M --> N[Successor scheduled - will resume later]
    M2 --> N
    G --> Z2[Done]
```

### 6.4 Interruption Conditions

The step completes and creates a successor when any of these are true:

1. **max_runtime exceeded**: Time-based limit
2. **Queue adapter signals shutdown**: Sidekiq SIGTERM, etc.
3. **Workflow externally paused/canceled**: Checked periodically
4. **`skip_to!` or `suspend!` called**: Explicit suspension by user code

---

## 7. Core Implementation

### 7.1 ResumableStepDefinition

```ruby
class GenevaDrive::ResumableStepDefinition < GenevaDrive::StepDefinition
  attr_reader :block, :max_iterations, :max_runtime

  def initialize(name:, max_iterations: nil, max_runtime: nil, **options, &block)
    @block = block
    @max_iterations = max_iterations
    @max_runtime = max_runtime
    super(name: name, callable: nil, **options)
  end

  def resumable?
    true
  end
end
```

### 7.2 DSL Addition to Workflow

```ruby
class GenevaDrive::Workflow < ActiveRecord::Base
  class << self
    def resumable_step(name = nil, **options, &block)
      raise ArgumentError, "resumable_step requires a block" unless block_given?

      name ||= generate_step_name

      definition = ResumableStepDefinition.new(
        name: name.to_s,
        **options,
        &block
      )

      steps.add(definition)
    end
  end
end
```

### 7.3 GenevaDrive::IterableStep Class

Rails 8.1 API-compatible object passed to resumable step blocks:

```ruby
class GenevaDrive::IterableStep
  attr_reader :name, :cursor

  def initialize(name, cursor, execution:, resumed:, interrupter:)
    @name = name.to_sym
    @cursor = cursor
    @execution = execution
    @resumed = resumed
    @interrupter = interrupter
    @advanced = false
  end

  # === Rails 8.1 ActiveJob::Continuation::Step compatible API ===

  def resumed? = @resumed
  def advanced? = @advanced

  # Set cursor to any value (integer, string, opaque token, etc.)
  def set!(value)
    @cursor = value
    @advanced = true
    checkpoint!
  end

  # Convenience for integer cursors only
  # Raises ArgumentError if cursor is not an Integer
  def advance!
    raise ArgumentError, "advance! requires integer cursor, got #{@cursor.inspect}" unless @cursor.is_a?(Integer)
    set!(@cursor + 1)
  end

  def checkpoint!
    persist_cursor!
    check_interruption!
  end

  def to_a = [name.to_s, cursor]
  def description = "at '#{name}', cursor '#{cursor.inspect}'"

  # === GenevaDrive Extensions ===

  # Skip to a new cursor position and suspend (creates successor execution)
  # Use this in manual loops to jump ahead without forgetting `next` or `break`
  # Optional `wait:` parameter delays the successor execution (for rate limiting)
  def skip_to!(value, wait: nil)
    @cursor = value
    @advanced = true
    persist_cursor!
    throw :interrupt, wait  # nil or duration - complete and create successor
  end

  # Iterate over any Enumerable (array, range, etc.) using index as cursor
  def iterate_over(enumerable)
    raise ArgumentError, "Must respond to #each" unless enumerable.respond_to?(:each)

    start_index = @cursor || 0
    enumerable.each_with_index do |element, index|
      next if index < start_index
      yield element
      set!(index + 1)
    end
  end

  # Iterate over AR relation using find_each, column value as cursor
  def iterate_over_records(relation, cursor: :id)
    filtered = if @cursor
      relation.where("#{cursor} > ?", @cursor).order(cursor => :asc)
    else
      relation.order(cursor => :asc)
    end

    filtered.find_each do |record|
      yield record
      set!(record.public_send(cursor))
    end
  end

  # Iterate over AR relation in subrelations, yielding each as an AR relation with offset
  def iterate_over_subrelations(relation, batch_size:, cursor: :id)
    filtered = if @cursor
      relation.where("#{cursor} > ?", @cursor).order(cursor => :asc)
    else
      relation.order(cursor => :asc)
    end

    filtered.in_batches(of: batch_size) do |relation_with_offset|
      yield relation_with_offset
      # Get the max cursor value from this subrelation
      last_cursor = relation_with_offset.maximum(cursor)
      set!(last_cursor) if last_cursor
    end
  end

  private

  def persist_cursor!
    # Serialize cursor using ActiveJob serializers (handles Date, Time, etc.)
    serialized = @cursor.nil? ? nil : ActiveJob::Arguments.serialize([@cursor]).first

    # Fast update bypassing AR callbacks - critical for high-throughput iteration
    # Rails handles JSON encoding per database adapter (JSONB/JSON/TEXT)
    GenevaDrive::StepExecution
      .where(id: @execution.id)
      .update_all(cursor: serialized)
  end

  def check_interruption!
    throw :interrupt if @interrupter&.should_interrupt?
  end
end
```

### 7.4 ResumableStepExecutor

Orchestrates execution, passes IterableStep object to the block, and creates successor executions when interrupted:

```ruby
class GenevaDrive::ResumableStepExecutor
  def initialize(step_execution)
    @step_execution = step_execution
    @workflow = step_execution.workflow
    @step_definition = @workflow.class.steps.named(step_execution.step_name)
    @start_time = nil
  end

  def execute!
    return unless @step_execution.scheduled?

    transition_to_in_progress!
    @start_time = Time.current

    iter = GenevaDrive::IterableStep.new(
      @step_definition.name,
      @step_execution.cursor_value,
      execution: @step_execution,
      resumed: @step_execution.resuming?,  # True if continues_from_id present
      interrupter: self
    )

    # catch(:interrupt) returns:
    # - :completed if block finishes normally
    # - nil if throw :interrupt (immediate successor)
    # - Duration/Numeric if throw :interrupt, wait (delayed successor)
    result = catch(:interrupt) do
      @workflow.instance_exec(iter, &@step_definition.block)
      :completed
    end

    case result
    when :completed
      complete_step!
    when ActiveSupport::Duration, Numeric
      complete_and_create_successor!(wait: result)
    else
      complete_and_create_successor!
    end

  rescue => e
    handle_exception(e)
  end

  def should_interrupt?
    return true if max_runtime_exceeded?
    return true if job_should_exit?
    return true if workflow_interrupted?
    false
  end

  private

  def transition_to_in_progress!
    @step_execution.with_lock do
      @step_execution.update!(
        state: "in_progress",
        started_at: @step_execution.started_at || Time.current
      )
    end
  end

  def max_runtime_exceeded?
    return false unless @step_definition.max_runtime
    Time.current - @start_time > @step_definition.max_runtime
  end

  def job_should_exit?
    Thread.current[:geneva_drive_should_exit] ||
      (defined?(Sidekiq) && Sidekiq.const_defined?(:CLI) &&
       Sidekiq::CLI.instance&.stopping?)
  end

  def workflow_interrupted?
    @workflow.reload
    @workflow.paused? || @workflow.canceled?
  end

  # Complete current execution and create a successor to continue the work
  def complete_and_create_successor!(wait: nil)
    @step_execution.with_lock do
      @step_execution.update!(
        state: "completed",
        outcome: "success",
        completed_at: Time.current
      )
    end
    @workflow.update!(state: "ready")

    # Create successor execution with cursor inherited from current
    scheduled_for = wait ? wait.from_now : Time.current
    successor = GenevaDrive::StepExecution.create!(
      workflow: @workflow,
      step_name: @step_execution.step_name,
      state: "scheduled",
      scheduled_for: scheduled_for,
      continues_from_id: @step_execution.id,
      cursor: @step_execution.cursor  # Inherit cursor
    )

    job_options = @workflow.class._step_job_options
    job_options = job_options.merge(wait: wait) if wait

    GenevaDrive::PerformStepJob
      .set(job_options)
      .perform_later(successor.id)
  end

  def complete_step!
    @step_execution.with_lock do
      @step_execution.update!(
        cursor: nil,
        state: "completed",
        outcome: "success",
        completed_at: Time.current
      )
    end
    @workflow.schedule_next_step!
  end
end
```

---

## 8. Flow Control Integration

### 8.1 Enhanced reattempt!

```ruby
module GenevaDrive::FlowControl
  def reattempt!(wait: nil, rewind: false)
    # rewind: true creates successor with nil cursor (start from beginning)
    # rewind: false (default) creates successor with current cursor (continue)
    throw :flow_control, FlowControlSignal.new(:reattempt, wait: wait, rewind: rewind)
  end
end
```

When `rewind: true`, the successor execution is created with a `nil` cursor, causing iteration to start from the beginning.

### 8.2 New suspend! Method

For manual suspension within iteration (completes current execution and creates a successor):

```ruby
module GenevaDrive::FlowControl
  def suspend!(wait: nil)
    # Completes current execution and creates a successor with the current cursor
    throw :flow_control, FlowControlSignal.new(:suspend, wait: wait)
  end
end
```

### 8.3 Existing Flow Control Still Works

Inside resumable steps, existing flow control methods work as expected:

```ruby
resumable_step :process_items do |iter|
  iter.iterate_over_records(hero.items) do |item|
    if item.invalid?
      skip!  # Skips entire step, moves to next step
    end

    if emergency_stop_requested?
      pause!  # Pauses entire workflow
    end

    process(item)
  end
end
```

---

## 9. Edge Cases

### 9.1 Empty Collection

If the collection is empty, the step completes immediately with zero iterations:

```ruby
resumable_step :process_items do |iter|
  iter.iterate_over_records(hero.items) do |item|  # If empty, block never executes
    process(item)
  end
end  # Step completes successfully
```

### 9.2 First-Run vs Resume

Use `iter.resumed?` to detect resumption:

```ruby
resumable_step :import do |iter|
  if iter.resumed?
    Rails.logger.info "Resuming import from cursor #{iter.cursor}"
  else
    Rails.logger.info "Starting import from beginning"
  end

  iter.iterate_over_records(records) { |r| import(r) }
end
```

### 9.3 Cursor Validation

Handle deleted records gracefully with manual iteration:

```ruby
resumable_step :process_records do |iter|
  start_id = iter.cursor || 0

  # Verify cursor is still valid (record might have been deleted)
  if iter.cursor && !Record.exists?(id: iter.cursor)
    Rails.logger.warn "Cursor record #{iter.cursor} deleted, finding next"
    start_id = Record.where("id > ?", iter.cursor).minimum(:id) || iter.cursor
  end

  Record.where("id > ?", start_id).find_each do |record|
    process(record)
    iter.set!(record.id)
  end
end
```

### 9.4 Runaway Step Detection

Use `max_runtime` to limit how long a single execution can run:

```ruby
resumable_step :process_items, max_runtime: 5.minutes do |iter|
  iter.iterate_over_records(huge_collection) { |item| process(item) }
end
```

When exceeded, the step completes and creates a successor. Housekeeping can detect steps with many chained executions that may indicate infinite loops.

---

## 10. Testing Helpers

### 10.1 Extensions to TestHelpers

```ruby
module GenevaDrive::TestHelpers
  # Run the current step to completion without advancing to the next step.
  # For resumable steps, disables interruption checks and runs until complete.
  def speedrun_current_step(workflow, max_executions: 100)
    workflow.reload
    step_execution = workflow.current_execution
    return nil unless step_execution

    executions = 0
    config = GenevaDrive::InterruptConfiguration.new(respect_interruptions: false)

    loop do
      step_execution.reload
      break if step_execution.completed? || step_execution.failed? || step_execution.canceled?

      step_execution.execute!(interrupt_configuration: config)
      executions += 1

      raise "speedrun_current_step exceeded max_executions" if executions >= max_executions
    end

    workflow.reload
    step_execution
  end

  # Assert cursor position on current execution
  def assert_cursor(workflow, expected_cursor)
    workflow.reload
    actual = workflow.current_execution&.cursor_value
    assert_equal expected_cursor, actual,
      "Expected cursor #{expected_cursor.inspect}, got #{actual.inspect}"
  end

  # Assert that a step completed and has a scheduled successor
  def assert_step_has_successor(workflow, step_name)
    workflow.reload
    completed = workflow.step_executions.find_by(step_name: step_name.to_s, state: "completed")
    assert completed, "Expected completed execution for step #{step_name}"

    successor = completed.successor
    assert successor, "Expected successor execution for step #{step_name}"
    assert successor.scheduled?, "Expected successor to be scheduled, but was #{successor.state}"
  end
end
```

---

## 11. Comparison

| Aspect | job-iteration | Rails 8.1 Continuable | GenevaDrive |
|--------|---------------|----------------------|-------------|
| **API Style** | `build_enumerator` + `each_iteration` | `step` object in block | `IterableStep` object (Rails 8.1 compatible) |
| **Scope** | Any ActiveJob | Any ActiveJob | Workflow steps only |
| **State Storage** | Job serialization | Job serialization | `step_executions` table (chained records) |
| **Checkpoint** | Configurable | Manual `set!`/`advance!` | Manual or auto via `iterate_over_*` |
| **Cursor Type** | Primitives only | Any serializable | Any AJ-serializable (native JSON/JSONB) |
| **Flow Control** | Limited | Limited | Full (cancel!, pause!, skip!, suspend!, reattempt!) |
| **Rewind Support** | N/A | N/A | `reattempt!(rewind: true)` |
| **Timeline Visibility** | Single job | Single job | Each execution chunk has clear start/end times |

---

## 12. Implementation Plan

### Phase 1: Foundation ✅
1. Add migration for `cursor` column (JSON/JSONB)
2. Add migration for `continues_from_id` column for chained executions
3. Add `continues_from` and `successor` associations to `StepExecution`
4. Add `resuming?` method to check for predecessor link
5. Add cursor serialization helpers to `StepExecution`

### Phase 2: IterableStep Class ✅
6. Create `GenevaDrive::IterableStep` class (Rails 8.1 API compatible)
7. Implement `cursor`, `set!`, `advance!`, `checkpoint!`, `resumed?`, `advanced?`
8. Implement `skip_to!(value, wait:)` for cursor jump with optional delayed successor
9. Implement `iterate_over` for Enumerables
10. Implement `iterate_over_records` for AR relations
11. Implement `iterate_over_subrelations` for batch processing

### Phase 3: Flow Control ✅
12. Enhance `reattempt!` with `rewind:` option
13. Add `suspend!` flow control method
14. Update ResumableStepExecutor to create successor executions

### Phase 4: Testing ✅
15. Extend `TestHelpers` for resumable steps (`speedrun_current_step`, `assert_cursor`, `assert_step_has_successor`)
16. Add comprehensive test suite

### Phase 5: Documentation
17. Document DSL usage
18. Add examples for common patterns

---

## 13. Open Questions

1. **Should there be a `progress` callback?**
   - Could report `(cursor)` for progress tracking
   - Useful for UI progress bars

2. **Should we support nested cursors?**
   - For multi-level iteration (e.g., iterate accounts, then transactions per account)
   - Cursor becomes an array of positions `[account_id, transaction_id]`
   - Adds complexity—perhaps defer to v2

3. **Should `iterate_over` support `[item, cursor]` pairs from Enumerators?**
   - Would allow custom Enumerators to specify their own cursor values
   - Currently uses index as cursor for all Enumerables

4. **How to visualize execution chains in the UI?**
   - Each execution has its own timeline entry
   - Could link them visually to show continuation
   - Query: `workflow.step_executions.where(step_name: "x").order(:created_at)`

---

## 14. Summary

This design brings job-iteration's proven resumable iteration pattern to GenevaDrive while:

- Maintaining GenevaDrive's database-centric state model
- Preserving all existing flow control capabilities
- Guaranteeing safe resumption via per-iteration checkpointing
- **Using chained executions for timeline visibility**: Each execution attempt creates a separate record with clear start/end times
- Providing a clean DSL that mirrors the existing `step` definition pattern

The **chained executions model** (linked via `continues_from_id`) enables:
- Clear timeline visualization showing when each chunk of work happened
- Complete audit trail of execution history
- Simpler state machine (no `suspended` state needed)

The `rewind: true` option for `reattempt!` gives developers explicit control over whether to continue from the cursor or start fresh—a capability job-iteration doesn't offer.
