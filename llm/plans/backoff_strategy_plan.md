# Backoff Strategy Support for `wait:` in ExceptionPolicy

## Problem

Currently `wait:` on `ExceptionPolicy` and `reattempt!` only accepts a fixed
`ActiveSupport::Duration`. There's no support for progressive backoff (e.g., wait longer
on each successive reattempt). Rails' ActiveJob `retry_on` supports `:polynomially_longer`
and Proc-based wait strategies — we should support the same vocabulary.

## Rails' implementation

ActiveJob (8.1) has one built-in strategy:

- **`:polynomially_longer`** — `executions**4 + jitter + 2` seconds
  - Sequence: ~3s, ~18s, ~83s, ~258s...
  - Jitter: configurable (default 15%), prevents thundering herd

The logic lives in `ActiveJob::Exceptions#determine_delay` (private method, ~20 lines).
It also accepts Duration/Integer (fixed) and Proc (dynamic). **Not extractable** — it's
private, tightly coupled to `job.executions`.

## Proposed design

Extend `ExceptionPolicy#wait` (and `reattempt!(wait:)`) to accept:

```ruby
# Fixed (already works)
ExceptionPolicy.new(:reattempt!, wait: 15.seconds)

# Symbol — built-in backoff strategy
ExceptionPolicy.new(:reattempt!, wait: :polynomially_longer)

# Proc — receives reattempt count, returns duration
ExceptionPolicy.new(:reattempt!, wait: ->(attempts) { (2 ** attempts).seconds })
```

### Built-in strategies

Reimplement (not copy-paste) the polynomial backoff from Rails:

```ruby
module GenevaDrive::BackoffStrategies
  POLYNOMIALLY_LONGER = ->(attempts, jitter: 0.15) {
    delay = attempts**4
    delay_jitter = jitter > 0 ? Kernel.rand * delay * jitter : 0.0
    (delay + delay_jitter + 2).seconds
  }

  STRATEGIES = {
    polynomially_longer: POLYNOMIALLY_LONGER
  }.freeze

  def self.resolve(wait, attempts:)
    case wait
    when Symbol
      strategy = STRATEGIES.fetch(wait) {
        raise ArgumentError, "Unknown backoff strategy: #{wait.inspect}"
      }
      strategy.call(attempts)
    when Proc
      wait.call(attempts)
    when ActiveSupport::Duration, Integer, Float
      wait
    when nil
      nil
    else
      raise ArgumentError, "Invalid wait value: #{wait.inspect}"
    end
  end
end
```

### Executor changes

When the executor calls `workflow.reschedule_current_step!(wait:)`, it needs to resolve
the wait value first:

```ruby
resolved_wait = GenevaDrive::BackoffStrategies.resolve(
  policy.wait,
  attempts: consecutive_reattempt_count(step_def.name) + 1
)
workflow.reschedule_current_step!(wait: resolved_wait)
```

The `attempts` value comes from `consecutive_reattempt_count` which already exists and
now correctly filters by `reattempt_reason` (so business-logic reattempts don't inflate
the backoff).

### ExceptionPolicy validation changes

- `wait:` validation relaxes to accept Symbol, Proc, Duration, Integer, or nil
- Validation of Symbol values happens against `BackoffStrategies::STRATEGIES.keys`
- Proc validation: arity must be >= 1 (receives attempts count)

### Flow control `reattempt!(wait:)` changes

`reattempt!(wait:)` in flow control could also accept symbols/procs, but this is less
useful since step code can compute the wait itself. Keep it simple — `reattempt!(wait:)`
in flow control only accepts Duration/Integer (current behavior). Backoff strategies are
an ExceptionPolicy feature.

### Optional: jitter parameter

Add optional `jitter:` to `ExceptionPolicy`:

```ruby
ExceptionPolicy.new(:reattempt!, wait: :polynomially_longer, jitter: 0.15)
```

Default jitter: 0.15 (15%) when using a Symbol strategy, 0.0 for fixed/Proc. This
matches Rails' default.

## Files to create or modify

| File | Action |
|------|--------|
| `lib/geneva_drive/backoff_strategies.rb` | **Create** — strategy resolution module |
| `lib/geneva_drive.rb` | Modify — autoload BackoffStrategies |
| `lib/geneva_drive/exception_policy.rb` | Modify — relax wait validation, add jitter attr |
| `lib/geneva_drive/executor.rb` | Modify — resolve wait via BackoffStrategies before rescheduling |
| `test/dsl/backoff_strategies_test.rb` | **Create** |
| `test/workflow/backoff_integration_test.rb` | **Create** |

## Implementation order

1. `BackoffStrategies` module with `resolve` and built-in `:polynomially_longer`
2. `ExceptionPolicy` — relax `wait:` validation, add optional `jitter:`
3. Executor — resolve wait before calling `reschedule_current_step!`
4. Tests
