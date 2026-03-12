# Exception Policy: Class-Level `on_exception` Plan

## Problem

`on_exception:` can only be set per-step (defaulting to `:pause!`). Workflows with many steps
sharing the same exception handling policy require repetition on every step definition. There is
also no way to route specific exception classes to different handlers. Additionally, per-step
`on_exception:` is accumulating satellite options (`max_reattempts:`, `wait:`) that make the
step DSL noisy. See: https://github.com/julik/geneva_drive/issues/16

## Design

### ExceptionPolicy value object

A new class `GenevaDrive::ExceptionPolicy` that bundles exception handling configuration into
a single reusable object. Two mutually exclusive modes:

**Declarative mode** (symbol + options):

```ruby
GenevaDrive::ExceptionPolicy.new(:reattempt!, wait: 15.seconds, max_reattempts: 5)
GenevaDrive::ExceptionPolicy.new(:cancel!)
```

**Imperative mode** (block — receives exception, runs in workflow context):

```ruby
GenevaDrive::ExceptionPolicy.new { |error|
  error.respond_to?(:retry_after) ? reattempt!(wait: error.retry_after) : cancel!
}
```

If a block is given, `action:` / `wait:` / `max_reattempts:` must not be passed (raise
`ArgumentError`). The block must call a flow control method (`reattempt!`, `cancel!`,
`pause!`, `skip!`). If it returns without calling one, the executor falls through to `:pause!`.

Attributes:

```ruby
class GenevaDrive::ExceptionPolicy
  attr_reader :action            # Symbol — :reattempt!, :cancel!, :pause!, :skip! (nil when block mode)
  attr_reader :wait              # ActiveSupport::Duration or nil
  attr_reader :max_reattempts    # Integer or nil
  attr_reader :exception_classes # Array<Class> — empty means "match all"
  attr_reader :handler           # Proc or nil (block mode)

  def matches?(error)
    exception_classes.empty? || exception_classes.any? { |klass| error.is_a?(klass) }
  end

  def declarative?
    handler.nil?
  end
end
```

### Class-level `on_exception` DSL

New class method on `GenevaDrive::Workflow`:

```ruby
class SyncGmailWorkflow < GenevaDrive::Workflow
  # Blanket default (no exception class filter)
  on_exception :reattempt!, wait: 15.seconds, max_reattempts: 3

  # Match specific exception classes — declarative
  on_exception OAuth2::Error, Signet::AuthorizationError,
               action: :reattempt!, wait: 15.seconds, max_reattempts: 5

  # Match specific exception classes — imperative (block)
  on_exception Google::Apis::RateLimitError do |error|
    reattempt! wait: error.retry_after.seconds
  end

  on_exception Google::Apis::ClientError, action: :cancel!

  step :sync_via_history do
    # inherits class-level policy
  end
end
```

Signature:

```ruby
def on_exception(*args, action: nil, wait: nil, max_reattempts: nil, &block)
```

Arguments are parsed as follows:
- If the first positional arg is a Symbol (`:reattempt!`, etc.), it's the action. Remaining
  positional args are exception classes.
- If the first positional arg is a Class, all positional args are exception classes, and
  `action:` keyword is required (unless a block is given).
- If no positional args, this is a blanket default.

Each call builds an `ExceptionPolicy` and appends it to a `class_attribute :_exception_policies`
(array). The storage order matters for resolution (see below).

### Step-level `on_exception:` changes

The step keyword `on_exception:` continues to accept a bare Symbol (`:reattempt!`, `:skip!`, etc.)
for the simple case. It now also accepts:

- An `ExceptionPolicy` object (for bundling options without repetition)
- A `Proc` / lambda (imperative mode — same contract as the block form above)

```ruby
TRANSIENT_RETRY = GenevaDrive::ExceptionPolicy.new(:reattempt!, wait: 15.seconds, max_reattempts: 5)

step :call_api, on_exception: TRANSIENT_RETRY do
  # ...
end

# Simple symbol still works
step :cleanup, on_exception: :skip! do
  # ...
end

# Proc for power users
step :flaky, on_exception: ->(e) { e.is_a?(Timeout::Error) ? reattempt! : pause! } do
  # ...
end
```

When `on_exception:` is a Symbol, `StepDefinition` continues to accept `max_reattempts:` and
(in future) `wait:` as separate keyword args — these are convenience shortcuts that internally
construct an `ExceptionPolicy`. When `on_exception:` is already an `ExceptionPolicy` or Proc,
passing `max_reattempts:` raises `StepConfigurationError`.

### Precedence / resolution order

When an exception is raised during step execution, the executor resolves the handling policy in
this order (first match wins):

```
1. Step-level on_exception   (symbol, ExceptionPolicy, or Proc — ALWAYS wins)
2. Class-level policies with exception class filter (most-recently-defined first)
3. Class-level blanket policy (no exception classes)
4. Hardcoded default: :pause!
```

**Step-level always takes precedence**, even over class-level policies defined in a subclass.
The rationale: step-level is the most specific scope — if you explicitly say "this step handles
exceptions with `:skip!`", that overrides any class-wide declaration.

**Exception class matching** at class level: policies are checked in reverse definition order
(last defined = checked first), consistent with Rails' `rescue_from`. Subclass policies are
checked before superclass policies. Among class-level policies, those with exception class
filters are checked before blanket defaults.

**Inheritance:** `_exception_policies` is a `class_attribute` (array). Subclasses inherit
the parent's policies. When a subclass defines its own, it dups the array and appends. The
resolution walk is: subclass class-match policies → superclass class-match policies →
subclass blanket → superclass blanket → `:pause!`.

```ruby
class BaseSync < GenevaDrive::Workflow
  on_exception :pause!                                     # blanket, parent
end

class GmailSync < BaseSync
  on_exception :reattempt!, max_reattempts: 3              # blanket, subclass (wins over parent)
  on_exception Google::Apis::ClientError, action: :cancel! # class-level match

  step :sync, on_exception: :skip! do
    # Google::Apis::ClientError here → :skip!  (step-level wins)
  end

  step :notify do
    # Google::Apis::ClientError here → :cancel! (class-level match)
    # Random StandardError here      → :reattempt! (subclass blanket)
  end
end
```

### Executor changes

The `capture_exception` method currently reads `step_def.on_exception` to determine the policy.
This changes to a resolution method:

```ruby
def resolve_exception_policy(error, step_def)
  # 1. Step-level (always wins if set explicitly — not the default :pause!)
  return step_def.exception_policy if step_def.has_explicit_exception_policy?

  # 2. Walk class-level policies (reverse order, class-match first, then blanket)
  workflow.class.resolve_exception_policy(error)

  # 3. Fallback
  || ExceptionPolicy.new(:pause!)
end
```

For declarative policies, the executor uses `policy.action`, `policy.wait`, `policy.max_reattempts`
in the existing `handle_captured_exception` switch.

For imperative policies (block/proc), the executor calls the handler in the workflow context:

```ruby
if policy.handler
  catch(:flow_control) do
    workflow.instance_exec(error, &policy.handler)
    # If handler didn't call a flow control method, fall through to :pause!
    :pause_fallback
  end
else
  # existing declarative switch
end
```

### `StepDefinition` changes

- New method `has_explicit_exception_policy?` — returns `true` if `on_exception:` was explicitly
  passed (not the default `:pause!`). This is needed so the executor knows whether step-level
  should override class-level.
- New method `exception_policy` — returns an `ExceptionPolicy` object, either the one passed
  directly or one constructed from the symbol + `max_reattempts` + `wait`.
- Validation: if `on_exception:` is an `ExceptionPolicy` or `Proc`, reject `max_reattempts:`
  as a separate kwarg.

Implementation note: we need to track whether `on_exception:` was explicitly provided vs.
defaulted. Suggested approach: use a sentinel value (e.g., `NOT_SET = Object.new.freeze`) as
the default instead of `:pause!`, so `has_explicit_exception_policy?` checks
`@on_exception != NOT_SET`.

## Step Execution `metadata` column

### Motivation

Step executions keep accumulating new columns for each feature (`finished_at`, `error_class_name`,
now `reattempt_reason`). A freeform JSON column absorbs future needs without migrations.

### What goes in `metadata` vs. a real column

- **Real columns:** anything queried at the SQL level — `state`, `scheduled_for`, `outcome`,
  `step_name`. These need indexes and WHERE clauses.
- **`metadata`:** executor bookkeeping read back in Ruby — `reattempt_reason`, which policy
  matched, wait duration applied, etc. Small result sets scoped to one workflow + step name,
  so Ruby filtering is fine.

Existing error columns (`error_message`, `error_backtrace`, `error_class_name`) stay as real
columns. No migration of existing data.

### Migration

The column type must be chosen per adapter to get the best native JSON support where available,
and the largest possible text type where not. No database-level default is set — this avoids
table rewrites on SQLite and MySQL (adding a column with a default triggers a full table
recreation on SQLite). The Ruby-side default handles NULL → `{}`.

```ruby
# frozen_string_literal: true

class AddMetadataToGenevaDriveStepExecutions < ActiveRecord::Migration[7.2]
  def change
    adapter = connection.adapter_name.downcase

    if adapter.include?("postgresql")
      # Native jsonb — supports indexing and querying if ever needed
      add_column :geneva_drive_step_executions, :metadata, :jsonb
    elsif adapter.include?("mysql")
      # MySQL TEXT is only 64KB. LONGTEXT (4GB) via limit: avoids silent truncation
      # of large metadata payloads. MySQL's native JSON type would also work but
      # LONGTEXT is safer for maximum compatibility with older MySQL versions.
      add_column :geneva_drive_step_executions, :metadata, :text, limit: 4_294_967_295
    else
      # SQLite — TEXT has no length limit, stores as-is
      add_column :geneva_drive_step_executions, :metadata, :text
    end
  end
end
```

No index needed — we never query into metadata at the SQL level.

The `create_step_executions_migration.rb` template (for fresh installs) should use the same
adapter-aware approach inside the `create_table` block. Since `create_table` already does
adapter detection for the uniqueness index, this is consistent.

### Model changes

Use ActiveRecord's `attribute` API with the `:json` type rather than `serialize`. This gives
us proper JSON casting on read/write across all adapters (ActiveRecord handles the
text↔Hash round-trip for SQLite/MySQL TEXT columns, and uses native jsonb for Postgres).
The `default:` proc ensures NULL columns present as `{}` in Ruby — no nil-checking needed
by callers.

```ruby
class GenevaDrive::StepExecution < ActiveRecord::Base
  attribute :metadata, :json, default: -> { {} }

  def reattempt_reason
    metadata.dig("reattempt_reason")
  end
end
```

Key behaviors:
- **NULL in DB → `{}` in Ruby.** The `default:` proc fires when the column is NULL, so
  existing records (pre-migration) and new records both get an empty hash. No need for
  safe-navigation (`&.dig`) anywhere.
- **`has_attribute?(:metadata)` guard in executor.** If the migration hasn't run yet, the
  column doesn't exist and the executor skips metadata writes. Same pattern as
  `error_class_name`. Once the column exists, `attribute :metadata` kicks in automatically.
- **No `serialize`.** `attribute :metadata, :json` is the modern Rails approach (Rails 7.2+).
  It uses `ActiveModel::Type::Json` which calls `JSON.parse` / `JSON.generate` and handles
  nil → default correctly.

### Reattempt reason tracking

Three `reattempt_reason` values, set by the executor when `outcome: "reattempted"`:

| Executor call site              | Meaning                              | `reattempt_reason` |
|---------------------------------|--------------------------------------|--------------------|
| `handle_flow_control_signal`    | Step code called `reattempt!`        | `"flow_control"`   |
| `handle_captured_exception`     | on_exception policy reattempted      | `"exception_policy"` |
| `handle_precondition_exception` | cancel_if/skip_if eval failed, policy reattempted | `"precondition"` |

`consecutive_reattempt_count` (used for `max_reattempts` enforcement) changes to only count
reattempts with `reattempt_reason` of `"exception_policy"` or `"precondition"`. Flow-control
reattempts are business logic and do not count toward the limit.

If the `metadata` column is not yet present (`has_attribute?` returns false), the executor
falls back to counting all reattempts (current behavior) — safe degradation.

### Generator changes

Add the new migration to `InstallGenerator#create_migrations`:

```ruby
migration_template(
  "add_metadata_to_step_executions.rb",
  "db/migrate/add_metadata_to_geneva_drive_step_executions.rb"
)
```

Also update `create_step_executions_migration.rb` template so fresh installs get the column
from the start. Use the same adapter-aware approach inside the `create_table` block:

```ruby
# Inside create_table block, after t.string :job_id
adapter = connection.adapter_name.downcase
if adapter.include?("postgresql")
  t.jsonb :metadata
elsif adapter.include?("mysql")
  t.text :metadata, limit: 4_294_967_295
else
  t.text :metadata
end
```

## Implementation order

1. **Migration + model:** Add `metadata` column, `serialize`, and `has_attribute?` guard.
   Update the install generator. Write tests for serialization round-trip.

2. **ExceptionPolicy class:** New file `lib/geneva_drive/exception_policy.rb`. Declarative
   and imperative modes, validation, `matches?`. Unit tests.

3. **Class-level `on_exception` DSL:** Add `_exception_policies` class_attribute, the
   `on_exception` class method, and `resolve_exception_policy` class method. Tests for
   registration, inheritance, and resolution order.

4. **StepDefinition changes:** Accept `ExceptionPolicy` and `Proc` in `on_exception:`.
   Track explicit vs. default. Construct policy from symbol + options. Validation. Tests.

5. **Executor changes:** New `resolve_exception_policy` method. Wire up declarative and
   imperative policy execution. Write `reattempt_reason` to metadata. Update
   `consecutive_reattempt_count` to filter by reason. Integration tests.

6. **Documentation:** Update MANUAL with class-level `on_exception` examples.

## Files to create or modify

| File | Action |
|------|--------|
| `lib/geneva_drive/exception_policy.rb` | **Create** |
| `lib/geneva_drive/workflow.rb` | Modify — add `_exception_policies` class_attribute, `on_exception` class method, `resolve_exception_policy` |
| `lib/geneva_drive/step_definition.rb` | Modify — accept ExceptionPolicy/Proc, track explicit flag, `exception_policy` accessor |
| `lib/geneva_drive/executor.rb` | Modify — new resolution method, imperative handler execution, metadata writes, reattempt counting |
| `lib/geneva_drive/step_execution.rb` | Modify — add `serialize :metadata`, `reattempt_reason` accessor |
| `lib/geneva_drive.rb` | Modify — require `exception_policy` |
| `lib/generators/.../templates/add_metadata_to_step_executions.rb` | **Create** |
| `lib/generators/.../templates/create_step_executions_migration.rb` | Modify — add `t.text :metadata` |
| `lib/generators/.../install_generator.rb` | Modify — register new migration template |
| `test/` | New test files for ExceptionPolicy, class-level DSL, integration |
