# Signals Design

- **Status:** design proposal, v1. Grounded in `strategy/llm/signals_and_events.md` (requirements R1–R11) and the existing execution machinery (`Executor`, `create_step_execution`, `continues_from_id` chains from `RESUMABLE_STEPS_DESIGN.md`).
- **Scope:** external events delivered to a workflow, a step primitive that parks until a matching event arrives, and the plumbing between them. Designed so the DAG work (PR #5) can dispatch one signal onto multiple concurrent step executions without schema changes.
- **Date:** 2026-09-27.

## 1. Decisions this design commits to

1. `Workflow#signal!(signal_name, payload: {}, idempotency_key: nil)` is the one delivery avenue. `signal_name` is a Symbol at the API surface, stored as a string. Returns a persisted `GenevaDrive::Signal`.
2. Signals are rows in `geneva_drive_signals`, persisted before any processing (R1). The row is the buffer for early arrivals (R3).
3. Idempotency: a unique index on `(workflow_id, name, idempotency_key)`. A duplicate insert is a database-level no-op that returns the existing row (R2, SagaForge shape).
4. A step definition opts into waiting with `wait_for:`, which takes a signal name, a `GenevaDrive::SignalMatcher`, or any object responding to `#matches?(signal)`. Payload narrowing is a block on the matcher, not a second step kwarg.
5. Waiting is a first-class step-execution state (`waiting`), holds no queue slot, and is visible to scopes, gauges, and the Admin (R5).
6. The signal lifecycle is `pending → claimed → consumed` (see §4 — two states are not enough).
7. Wake is push: `signal!` scans waiting executions under the workflow row lock and enqueues jobs for the matches (R4, R9). No polling anywhere.
8. Signals are wiped with the workflow (`dependent: :delete_all` plus the housekeeping batch delete).
9. Timeouts are deferred from v1, with the seam left open and mandatory visibility mitigations shipped in v1 (§9, satisfying R6 without a timer).

## 2. The mental model

A signal is a **per-workflow event record**. It is not a message queue entry and not a broadcast bus: it is addressed to one workflow instance (the caller already holds the record — R8's "addressing follows the hero" is satisfied by construction, because you find the workflow the way you find anything in Rails: `SignupWorkflow.ongoing.for_hero(user).first`).

A step that declares `wait_for:` gates its own execution on the presence of a matching, not-yet-consumed signal. The two sides meet at a **rendezvous** with exactly two meeting points:

- **Gate** (receiver side): when the step's job runs `prepare_execution`, it scans for a matching signal. Found → attach and run. Not found → park (`scheduled → waiting`), and the job ends. Nothing is enqueued; the parked row costs nothing (R5).
- **Dispatch** (sender side): `signal!` persists the row, then — under the workflow lock — scans `waiting` executions. Every match is attached, flipped `waiting → scheduled`, and its `PerformStepJob` is enqueued after commit.

Both sides run under the workflow row lock, the same lock `create_step_execution` and the Executor's `with_execution_lock` already take. Whichever side commits second sees the other side's write. There is no window in which a signal can be lost between "not yet parked" and "parked" (R9, the ajdc lock discipline).

```
sender arrives first:                    receiver arrives first:

signal!                                  PerformStepJob → prepare
  INSERT signal (pending)                  gate: scan signals → none
  lock wf: scan waiting → none             park: scheduled → waiting  [job ends]
  [row buffered]                         signal!
PerformStepJob → prepare                   INSERT signal (pending)
  gate: scan signals → match!              lock wf: scan waiting → match!
  attach, run step                         attach, waiting → scheduled, enqueue job
                                         PerformStepJob → prepare
                                           signal already attached → run step
```

## 3. Schema

### 3.1 `geneva_drive_signals`

```ruby
create_table :geneva_drive_signals, **geneva_drive_table_options do |t|
  t.references :workflow, null: false, index: true   # type: geneva_drive_key_type when uuid
  t.string :name, null: false
  t.string :idempotency_key                          # nullable; NULLs are distinct on PG/MySQL/SQLite
  t.string :state, null: false, default: "pending"   # lifecycle: pending / claimed / consumed
  # payload: jsonb on PG, json elsewhere — same flavor logic as the cursor column
  t.jsonb/:json :payload
  t.datetime :claimed_at
  t.datetime :consumed_at
  t.bigint :claimed, null: false, default: 0         # counter, not the state
  t.bigint :consumed, null: false, default: 0        # counter, not the state
  t.timestamps
end

add_index :geneva_drive_signals, [:workflow_id, :name, :idempotency_key],
  unique: true, name: "index_geneva_drive_signals_dedup"
add_index :geneva_drive_signals, [:workflow_id, :state]

# Foreign key with on_delete: :cascade on PG/SQLite-at-creation only, same policy
# as step_executions (never added later on SQLite, never on MySQL).
```

Notes:

- The dedup index works with nullable `idempotency_key` on all three databases: PG, MySQL, and SQLite all treat NULLs as distinct in unique indexes, so IK-less signals insert freely while `(workflow, name, ik)` collides exactly when it should.
- `payload` is serialized through `ActiveJob::Arguments` — the same path as the resumable cursor — and bounded by a new `GenevaDrive.max_signal_payload_size` (default 128 KiB, same as `max_cursor_size`; `nil` disables). Nobody in the field enforces a payload bound; we do (R10).
- `Signal#payload` deserializes and, when the value is a Hash, wraps it in `ActiveSupport::HashWithIndifferentAccess`. Webhook senders produce string keys, Ruby senders produce symbols; matchers should not have to know which.
- The `claimed` and `consumed` **counters** are the fan-out readout: how many executions attached to this event, and how many attached chains have resolved cleanly. In a linear workflow they end at `1 / 1` (`N / 1` if the step was retried); for a DAG salvo across five nodes they end at `5 / 5`, and watching them diverge is how one tells "three branches still working" from "three branches wedged". Cheap enough to be worth having on the row rather than derived by a join every time the Admin renders a signal.
- The counters take the names the state enum would otherwise have claimed, which is deliberate but demands care. Throughout this document, **"state claimed" / "state consumed"** means the lifecycle value in the `state` column, and **"the claimed count" / "the consumed count"** means the counters. In code the enum is declared `instance_methods: false, scopes: false`, so no `Signal.claimed` scope or generated `consumed?` predicate exists to be confused with a counter; the lifecycle is queried explicitly (`where(state: ...)`), and `Signal#claimed?` / `#consumed?` are hand-written as `claimed > 0` / `consumed > 0` — "picked up at least once" / "resolved at least once", which is the question application code actually asks.

### 3.2 Additions to `geneva_drive_step_executions`

These land in the same migration as the table above — a signals table nobody can wait on and a waiting step with nowhere to read its event from are each useless alone.

```ruby
add_column :geneva_drive_step_executions, :signal_id, geneva_drive_key_type  # no FK (SQLite rule)
add_index  :geneva_drive_step_executions, :signal_id
add_column :geneva_drive_step_executions, :waiting_since, :datetime
```

- `signal_id` is the **attachment pin**: which signal this execution consumed/is consuming. It is the checkpoint that makes payload delivery replay-safe (R3): a reattempt or successor execution reads the payload through the pin, never by re-scanning. It is deliberately on the execution, not the signal — one signal can be pinned by many executions, which is exactly the DAG fan-out shape (one signal → N step executions).
- `waiting_since` records when the execution parked, so "waiting for N days" is queryable (R6) without abusing `updated_at`.
- Detection follows the `resumable_columns?` pattern: `signal_columns?`, lazily checked, degrading safely — a `wait_for:` step executing without the columns fails loudly with a "run the install generator" message, exactly like resumable steps do.

### 3.3 The one-active unique index: deliberately not touched

The partial unique index `(workflow_id) WHERE state IN ('scheduled','in_progress')` does **not** get `waiting` added to it in v1:

- Recreating it is trivial on PG/SQLite but on MySQL it is a STORED generated-column rewrite — a full table rebuild.
- PR #5 replaces this index wholesale with a per-`(workflow, node)` variant. Paying a MySQL table rebuild for an index the DAG work deletes is waste.
- The index was always the backstop, not the mechanism: single-activeness is enforced by `create_step_execution`'s cancel-strays sweep under the workflow lock. A `waiting` execution coexisting with a `scheduled` one is prevented by the same code paths that prevent two `scheduled` ones, and — unlike two `scheduled` rows — there is no job racing to execute a `waiting` row, so the failure mode the index guards against does not apply to it.

When the DAG index lands, `waiting` joins its state list.

## 4. Signal lifecycle: why three states, not two

The instinct "mark consumed only after the step completes or skips cleanly, in the post-step transactioned block" is right about **when consumption finalizes**, but a bare `pending/consumed` pair breaks in the window between dispatch and completion:

- If the signal stays `pending` while its step is in flight, a second gate (a retried step, or under DAGs a sibling) cannot tell "fresh, unhandled event" from "event currently being handled".
- If it flips `consumed` at dispatch, a step that fails mid-processing has consumed an event it never acted on, and the audit lies.

So: **`pending → claimed → consumed`**, with `claimed_at` / `consumed_at`.

| Transition | When | Where (transaction) |
|---|---|---|
| state `pending → claimed` | first execution attaches (gate or dispatch); the claimed count increments on **every** attach, `claimed_at` only on the first | inside the workflow lock of the gate / `signal!` |
| state `claimed → consumed` | the **last** attached chain finalizes with a clean outcome (`completed/success`, `skipped`, `finished!`); the consumed count increments on every clean finalize | the Executor's `finalize_with_lock` — the existing post-step transactioned block |
| state stays `claimed` | an attached chain reattempts, fails→pause, or is canceled — or any other attached chain is still unresolved | — |

**Consumption rule, precisely.** On a clean finalize of an execution carrying a `signal_id`, the consumed count is incremented unconditionally (one increment per resolved chain, because only a chain's terminal execution finalizes cleanly), and the state flips to `consumed` only if both hold:

1. no execution attached to the signal is still active (`waiting` / `scheduled` / `in_progress`), and
2. for every attached step, its most recent attached execution ended cleanly (`success` or `skipped`).

Earlier executions in a chain end `continued` or `reattempted` precisely because they handed the work on, so "most recent per step" is what "did this chain resolve" means. A failed-and-paused chain therefore keeps the state at claimed *and* the signal attachable, which is exactly what makes its retry work. With a single attached chain — every v1 workflow — this is behaviorally identical to "the first clean completion consumes it"; it only starts to differ once one signal is dispatched onto several executions, which is the DAG case (§8).

Both the counter increments and the state flip happen under the workflow lock `finalize_with_lock` already holds, so plain arithmetic updates are safe — no read-modify-write race to worry about.

**Attachment eligibility rule (the whole matching semantics in one sentence):** a gate or dispatch may attach an execution to any signal that matches and is **not consumed** — oldest first (`created_at ASC, id ASC`; FIFO like everyone credible in the field).

This one rule replaces what would otherwise be three special cases:

1. *Reattempt/retry redelivery:* step X claimed signal S, failed, workflow paused. `resume!` creates a fresh execution for X; its gate finds S (claimed, not consumed, matches) and re-attaches. Same payload, checkpointed by the pin. No "release the claim on cancel" bookkeeping anywhere.
2. *Housekeeping recovery:* a dispatch whose enqueue got lost is recovered by the existing stuck-`scheduled` sweep (dispatch sets `scheduled_for = Time.current`, see §6.2); the recovery reschedule's fresh execution re-attaches through the same rule. The row is the obligation, the enqueue a hint, housekeeping the guarantee (R4) — with zero new sweeper code.
3. *DAG fan-out:* N waiting executions attach to one signal at dispatch, and the signal stays attachable for as long as any of them is unresolved — so a sibling that parks late, or a sibling whose first attempt failed, still gets the same event. The signal closes when the whole salvo has come to a clean stop.

**Documented edge (DAG-era):** a straggler that parks only after the *entire* wavefront has resolved finds the signal `consumed` and waits for a fresh one. The generalized rule shrinks this window from "the fastest sibling" to "all siblings", which removes the ordering sensitivity for every realistic fan-out (the PR #5 scheduler creates all dependency-satisfied sibling executions together anyway). For the pathological remainder the escape hatches are unchanged: a payload matcher that selects per branch, or distinct idempotency keys so each branch gets its own row. Not a v1 concern at all — v1 has at most one active execution.

Duplicate signals (same name, different IK) while one is in state claimed: the duplicate sits `pending` and is never matched unless a future waiter wants it. Visible in the audit, never silently swallowed (R2 — the anti-Stepped).

## 5. API

### 5.1 Sending

```ruby
workflow.signal!(:payment_confirmed,
  payload: {order_id: 42, amount_cents: 12_500},
  idempotency_key: event["id"])   # => GenevaDrive::Signal
```

Behavior, in order:

1. **Validate.** `signal_name` must be present; unknown keyword options raise (`**any_future_options` is reserved surface, not a junk drawer — raising now keeps it usable later). The payload is serialized and bounded here, before anything is written.
2. **Take the workflow lock.** `workflow.with_lock` wraps *everything* that follows — steps 3 to 5 share one transaction. The lock comes **before** the INSERT, not between INSERT and dispatch: persisting first and dispatching second would mean two commits, and a crash between them leaves a `pending` signal beside a `waiting` execution with nothing left to introduce them. Delivery is all-or-nothing (§6.2).
3. **Terminal check with dedup escape** (under the lock, so it reads the workflow's committed state). On a `finished`/`canceled` workflow: if `(name, idempotency_key)` matches an existing row, return that row (a webhook retry of the very event that finished the workflow is a no-op, not an error). Otherwise raise `GenevaDrive::WorkflowNotOngoing`. Loud beats silent (the Stepped no-op is the named worst-in-field); callers who want lenience rescue one exception class.
4. **Persist.** INSERT inside a nested `requires_new: true` savepoint; `rescue ActiveRecord::RecordNotUnique` → fetch and return the existing row without dispatching. The savepoint is what keeps a duplicate from poisoning the enclosing transaction — ours, and the caller's if they had one open (on PG a failed statement otherwise aborts everything after it). The returned duplicate is flagged on the instance (`signal.duplicate_delivery?` — not a column) so the controller can log it.
5. **Dispatch** (skipped when the workflow is `paused` — see §7). Scan `step_executions.waiting`, evaluate each one's matcher against the signal, and for every match: attach (`signal_id`, state `pending→claimed` if first, claimed count +1), flip `waiting → scheduled` with `scheduled_for: Time.current` and `waiting_since: nil`, and enqueue `PerformStepJob` via `run_after_commit` with the step's merged job options — the exact enqueue discipline `create_step_execution` uses today.
6. Return the Signal.

`signal!` may be called from anywhere: a controller, another job, another workflow's step, even a step of this workflow (it buffers; nothing is waiting while the caller itself is the active step). It holds the workflow lock for the whole delivery, but never while enqueueing — the enqueue is deferred to after commit.

Matcher blocks run at dispatch time in the sender's process. That is a deliberate trade (the DurableFlow wart, accepted knowingly): the scan is over at most a handful of `waiting` rows for one workflow, and the alternative — a dispatcher job — buys latency and a new moving part. A matcher that raises at dispatch raises to the sender; that is an application bug surfacing at the right doorstep.

### 5.2 Declaring the wait

```ruby
# Name match - sugar for wait_for: GenevaDrive::SignalMatcher.new(:payment_confirmed)
step :capture, wait_for: :payment_confirmed do
  hero.capture!(received_signal.payload[:amount_cents])
end

# Name + payload narrowing; the block is instance_exec'd on signal.workflow
# (hero is in scope). A matcher is a plain object, so it can be a shared constant.
step :capture,
  wait_for: GenevaDrive::SignalMatcher.new(:payment_confirmed) { |payload| payload[:order_id] == hero.order_id } do
  ...
end

# Bring-your-own matcher: any object responding to matches?(signal)
step :capture, wait_for: PaymentMatcher.new(min_cents: 100) do
  ...
end
```

- `wait_for:` accepts a Symbol/String, a `GenevaDrive::SignalMatcher`, or any object responding to `#matches?(signal)`. A bare name is normalized into `GenevaDrive::SignalMatcher.new(name)`; everything else is stored as given on the `StepDefinition`. The matcher protocol is one argument — `matches?(signal)` — and workflow context is reached through `signal.workflow`, which keeps custom matchers trivial to write and lets a matcher be shared between steps and workflows as a constant. `step_def.waits_for_signal?` is the flag the Executor checks. There is deliberately no second step kwarg for narrowing: one option, one object.
- **Mixed-up `wait:` / `wait_for:` arguments raise `StepConfigurationError` at class load.** The two kwargs read alike and take disjoint types, so `StepDefinition` validation enforces the disjointness in both directions with an error message that names the kwarg the author meant:
  - `wait_for:` given a duration-shaped value (`ActiveSupport::Duration`, `Numeric`, `Time`/`Date`-like) → `"Step 'x' has wait_for: 2 days — wait_for: takes a signal name or matcher; to delay the step, use wait:"`.
  - `wait:` given a signal-shaped value (Symbol, String, or anything responding to `#matches?`) → `"Step 'x' has wait: :payment_confirmed — wait: takes a duration; to wait for a signal, use wait_for:"`. This closes a today-silent trap: the existing `validate_wait!` accepts any value responding to `#to_i`, so `wait: "payment_confirmed"` currently passes as a zero-second wait instead of erroring. The String arm of this check tightens `wait:` for everyone, not just signal users (a duration-shaped String like `"7200"` is still rejected — durations are numbers or `Duration`s, never Strings).
- `SignalMatcher` blocks receive the (indifferent-access) payload and are `instance_exec`'d on `signal.workflow`. `inverse_of:` is declared on both sides of the Workflow/Signal association and candidate signals are handed the live workflow instance explicitly (`Workflow#attachable_signals`), so a matcher never triggers a second load of the workflow it is already running for. Blocks must be side-effect free and cheap — they run at dispatch (sender's process) and at the gate. Document this with the same severity as the `skip_if` purity expectation.
- `wait: 2.days, wait_for: :sig` composes for free and means "no earlier than 2 days, and only once signaled": the execution is scheduled for `scheduled_for` as today; the gate runs when the job first runs; a signal arriving during the delay is simply buffered and claimed at gate time. Zero special code.
- `resumable_step` + `wait_for:` is allowed: the gate runs once, on the first execution of the chain; `create_successor_execution!` copies `signal_id` alongside `cursor`, so successors never re-park and `received_signal` stays stable across the whole chain.
- `received_signal` is the accessor in step bodies (a `GenevaDrive::Signal` or nil), injected by the Executor the same way the tagged logger is (`workflow.with_received_signal(signal) { ... }`). Not named `signal` — `Workflow#signal!` is the writer, and bare `Signal` is a Ruby core constant; the extra word buys unambiguity in both directions. The payload lands in the step body, which writes what matters onto the hero — the signal row is audit, not a parallel state store (R10).

## 6. Mechanics

### 6.1 The gate lives in `prepare_execution`, not in `create_step_execution`

The original sketch ("when a step execution gets prepared and persisted, scan for signals") puts the scan at creation time — inside the **previous** step's `finalize_with_lock` transaction, because that is where `schedule_next_step!` runs. That placement has a real failure mode: a user matcher raising there rolls back the previous step's completion, which then re-runs a step whose side effects already happened. User code must never execute inside another step's finalization.

Instead, the execution is created and enqueued exactly as today, and the gate runs in the step's **own** `prepare_execution`, after `cancel_if`/`skip_if`, before `in_progress`:

```
prepare_execution (under workflow + execution locks), new segment:
  if step_def.waits_for_signal?
    if step_execution.signal_id.present?      # dispatched, inherited, or successor-copied
      @received_signal = step_execution.signal
    elsif (signal = oldest matching non-consumed signal)
      attach(signal, step_execution)          # pin + pending→claimed
      @received_signal = signal
    else
      transition_step!("waiting")             # scheduled → waiting
      step_execution.update!(waiting_since: Time.current)
      next nil                                # job ends; nothing enqueued
    end
  end
```

What this buys:

- **The user's "earlier steps haven't completed yet" case solves itself.** A signal arriving while the workflow is three steps away from the waiter is just a `pending` row (R1/R3). When the waiting step's execution eventually runs, its gate finds the row and never parks. No scan at creation, no scan on a schedule — the buffer plus two rendezvous points cover every arrival order.
- Matcher exceptions at the gate flow through the **existing** prepare-exception machinery: policy resolution, `Rails.error` reporting, pause-by-default. No new failure channel (R7's spirit).
- One queue hop of latency when the signal arrived early. Against webhook timescales, irrelevant.
- `skip_if` is evaluated before the gate, so a step that would be skipped skips *immediately* instead of waiting indefinitely for a signal it would then ignore ("wait for signature — unless the contract was pre-signed"). It is evaluated again if the step later wakes (dispatch re-runs the full prepare) — conditions are always checked at execution time, now documented with one more reason why.

### 6.2 Dispatch details

- **Delivery is one transaction.** The signal INSERT, the `waiting → scheduled` flip, the `signal_id` pin, `scheduled_for` / `waiting_since`, the signal's state and its claimed counter are all written inside the single transaction `signal!` opens with the workflow lock. The crash contract follows from that: either the event is delivered in full, or no row moved at all and the sender's retry re-delivers. There is no in-between state for housekeeping to reason about, which is why there is no reconciliation sweeper for signals.
- The job enqueue is deliberately **not** in that transaction: it fires after commit (`run_after_commit`), because a queue INSERT that rolls back is a job that never runs, and a queue INSERT that commits ahead of its row is a job that cannot find one. The gap this leaves — committed rows, lost enqueue — is covered by `scheduled_for = Time.current` plus the existing stuck-`scheduled` housekeeping sweep, below.
- Dispatch flips `waiting → scheduled` **and rewrites `scheduled_for` to now**. This is what plugs the lost-enqueue hole: a dispatched execution whose job evaporated is picked up by the existing stuck-`scheduled` housekeeping sweep after `stuck_scheduled_threshold`, recovered through `reschedule_current_step!`, and the fresh execution's gate re-attaches via the §4 eligibility rule. Push is the mechanism, housekeeping the guarantee, no new sweeper (R4).
- A duplicate `PerformStepJob` firing against a `waiting` execution hits the existing "already `waiting`, skipping duplicate job" guard in prepare — no worker slot burned beyond the no-op (the anti-ChronoForge).
- Two signals racing each other: serialized by the workflow lock. The first wakes the waiter; the second finds no `waiting` execution and buffers. The gate's oldest-first order makes delivery deterministic.

### 6.3 State machine additions

```ruby
# StepExecution
enum :state, {..., waiting: "waiting"}

# Executor::STEP_TRANSITIONS
"scheduled" => %w[scheduled waiting in_progress canceled skipped failed completed],
"waiting"   => %w[scheduled canceled skipped],
```

`waiting → scheduled` is performed by dispatch (under the workflow lock), `waiting → canceled/skipped` by the external verbs and terminal transitions. `current_execution` widens to `%w[scheduled in_progress waiting]` — this single change makes most operator verbs behave correctly for free (§7). The stray-cancel sweep in `create_step_execution` / `create_successor_execution!` widens to sweep `waiting` rows too (defense in depth; no legitimate path creates a new execution past a waiting one).

### 6.4 Consumption (the post-step transactioned block)

In `finalize_with_lock`, on outcomes `success` (including `finished!`) and `skipped`: if the execution has a `signal_id`, bump the consumed count and flip the state to `consumed` with `consumed_at` if the §4 resolution test passes, in the same transaction as the step's own transition. The call sits **after** the step's terminal transition so the resolution test reads one consistent picture (the finalizing execution included) instead of having to special-case "everything except me". Crash before commit → nothing resolved, nothing completed, replay is coherent. Reattempt outcomes leave the state at `claimed` (the retry re-attaches). Failure→pause leaves it there too (resume re-attaches), and so does cancel — a truthful audit record ("dispatched, never processed") on a workflow that is terminal anyway.

## 7. Interaction with every existing verb

| Verb / mechanism | Behavior with a waiting execution or in-flight signal |
|---|---|
| `pause!` (external) | Waiting execution is left intact, exactly like a scheduled one. `signal!` while paused **persists but does not dispatch** — dispatching would enqueue a job whose prepare cancels the execution on the "workflow not ready/performing" guard, destroying the waiter. The row buffers. |
| `resume!` | New branch: if `current_execution` is `waiting`, re-run the rendezvous under the lock — matching non-consumed signal exists → dispatch it; none → leave it waiting. Signals that arrived during the pause are therefore delivered on resume. The existing branches (scheduled execution, resumable continuations) are unchanged and ordered before it. |
| `cancel!` (external) | `current_execution&.mark_canceled!` already covers the waiter once `current_execution` includes `waiting`. Attached signals stay in state `claimed`. |
| `skip!` (external) | Marks the waiting execution `skipped` and schedules the next step — the operator's manual override for "stop waiting, move on". This is the v1 timeout escape hatch. If the execution had an attached signal (dispatched but not yet run), finalization-on-skip does not run (no executor involved), so the signal stays in state `claimed`; document. |
| `reattempt!` / exception-policy reattempt | Fresh or successor execution; gate re-attaches to the same still-claimed signal (or successor carries the copied `signal_id`). Same payload delivered — reattempt means "process this event again", not "wait for a new event". |
| `finished!` from the step body | Clean outcome → consumes the attached signal, then finishes. |
| `suspend!` / resumable interruption | Successor copies `signal_id`; no re-park, no re-match. |
| `cancel_if` | Evaluated at prepare — i.e. at park time and again at wake time. A parked workflow does **not** re-evaluate `cancel_if` while it sleeps; the check runs when the signal wakes it. Document. |
| `skip_if` | Evaluated before the gate (skip beats wait), and again at wake. |
| Hero deleted while parked | Checked at wake (prepare's hero guard), workflow cancels then — same timing semantics as `cancel_if`. |
| Housekeeping recovery | `waiting` is neither `scheduled` nor `in_progress`, so the stuck sweeps ignore parked rows by construction — waiting indefinitely is a legitimate state, not a stuck one. Dispatched-but-lost executions are `scheduled`+overdue and get recovered normally. |
| Housekeeping cleanup / wipe | `has_many :signals, dependent: :delete_all` on Workflow, plus a third batched `DELETE ... INNER JOIN` pass in `cleanup_completed_workflows!` (signals deleted before workflows, same pattern as step executions). |
| Gauges | `report_workflow_gauges!` grows: `geneva_drive.waiting_step_executions` (count, per workflow class) and `geneva_drive.waiting_overdue` — waiting rows with `waiting_since` older than a configurable `GenevaDrive.waiting_visibility_threshold` (default 7 days). This is the R6 no-silent-stall floor and ships in v1, non-negotiably. |

## 8. DAG forward-compatibility (PR #5 alignment)

- Dispatch already iterates **all** matching waiting executions; v1's single-active model just makes the loop trivially short. When node executions multiply, the same scan wakes every parked branch.
- The attachment pin (`step_executions.signal_id`, many-to-one) is the fan-out relationship. No join table, no signal-side execution pointer to outgrow.
- Consumption ("the signal closes when the last attached chain resolves cleanly; a chain that failed keeps it open") is defined for N claimants from day one (§4). The motivating case is a salvo of nodes waiting on one signal name: they attach together at dispatch, each runs at its own pace, and the event is only spent once the whole wavefront is done — with the claimed / consumed counters on the row as the progress readout. The one remaining pathological straggler (a node parking after the entire wavefront resolved) stays documented, with matcher and distinct-idempotency-key escape hatches, rather than discovered in production.
- The one-active index is left for the DAG migration to replace; `waiting` joins the new per-node index's state list there (§3.3).
- Per PR #5's own column rubric ("real column if the scheduler queries it"), `signal_id` and `waiting_since` are real columns, not metadata entries. The claimed / consumed counters are real columns for the same reason the resolution test is a query and not a guess.

## 9. Timeouts: deferred, with the seam kept warm

All timeout mechanisms are some flavor of ugly; v1 ships without one, and this is defensible **only** because waiting is loud (R6): a distinct state, a `waiting_since` column, gauges with an overdue threshold, Admin visibility, and three working escape hatches that exist without any gem code:

1. Operator: `skip!` (move on) / `cancel!` (give up) on the workflow.
2. Application-level deadline: any scheduled job may call `workflow.signal!(:payment_confirmed, payload: {timed_out: true}, idempotency_key: "deadline-#{workflow.id}")` — the step body inspects the payload. The queue is already the clock; nothing stops an app from using it today.
3. `cancel_if`/`skip_if` re-evaluated at wake — stale workflows die at the moment they'd act.

The seam for a real `timeout:` later, so nothing in v1 has to move:

```ruby
step :capture, wait_for: :payment_confirmed, timeout: 3.days, on_timeout: :skip!
```

At park time, enqueue a nudge job `set(wait_until: waiting_since + timeout)`. On fire: execution no longer `waiting` → no-op and discard (the SagaForge version-fence shape, with the execution id + state as the fence). Still `waiting` → raise `GenevaDrive::SignalWaitTimeout` **into the existing exception-policy machinery** for this step: `on_timeout:` is sugar for a policy matching that one exception class. Timeout expiry is thereby an unambiguous, first-class outcome in the vocabulary we already have — never a nil-shaped sentinel (R7, the anti-ajdc) — the clock is the queue (R4), and an `on_exception:` reattempt ladder composes with it for free. Nothing in the v1 schema or state machine needs to change to add this; it is purely additive.

## 10. Test helpers and Admin

- In tests (`enqueue_after_commit = false` / `without_deferred_enqueues`), `signal!` dispatch enqueues synchronously like everything else, so the existing job-draining helpers work unchanged.
- New helpers: `assert_waiting_for_signal(workflow, :name)`; the step-driving helpers (`perform_next_step`-style) raise a descriptive error when the next execution parks, telling the test to `signal!` — a hang disguised as a green helper is the failure mode to prevent.
- Admin (separate app, follow-up work): `waiting` badge with `waiting_since` age; a Signals panel on the workflow page showing name / state / IK / claimed-consumed timestamps and the claiming execution(s); the timeline interleaves signal arrivals with executions.

## 11. Explicit non-goals for v1

- **Signal-with-start** (create-if-absent then signal). `signal!` is an instance method; existence is the caller's fact, not a race. Revisit only with concrete demand.
- **Workflow-to-workflow channels, cross-workflow broadcast.** Fan-out across workflows is the caller's loop. The schema does not preclude either.
- **Class-level address helpers** (`SignupWorkflow.signal!(hero:, ...)`) — sugar over `ongoing.for_hero`, add later if the docs keep repeating the two-liner.
- **Multiple simultaneous waits per step** (`wait_for: [:a, :b]` any/all). Under DAGs this is two parked nodes; adding per-step multi-wait semantics now would duplicate that machinery. A single step waiting on "either of two names" can be served by a custom matcher object (name-set matching) without new API — document that instead.
- **Per-attempt fresh-signal semantics** (reattempt waits for a *new* signal instead of re-reading the claimed one). Niche; a `rewind`-flavored option can be added to the gate later.

## 12. Edge-case catalog (defined, not accidental)

| # | Case | Behavior |
|---|---|---|
| 1 | Signal before the waiting step's execution exists | Buffered `pending` row; claimed at the gate. Structurally impossible to lose (R1). |
| 2 | Signal races the park | Workflow lock serializes; whichever commits second sees the other. |
| 3 | Duplicate delivery, same IK | Unique-index no-op in a savepoint; existing row returned, flagged `duplicate_delivery?`; no dispatch. |
| 4 | Duplicate delivery, no IK | Two rows; oldest wins at the gate; the newer one buffers (auditable, R2). |
| 5 | Two sequential steps wait on the same name | First consumes its signal on clean completion (it is the only attached chain); second parks for a fresh one. Consume-once per event. |
| 6 | `signal!` on paused workflow | Persist, no dispatch; delivered by `resume!`'s rendezvous. |
| 7 | `signal!` on finished/canceled workflow | Return existing row on IK match; otherwise raise `WorkflowNotOngoing`. |
| 8 | `signal!` on a workflow whose class was removed (STI fallback) | Row ops only; matcher evaluation requires step definitions, so dispatch scan treats undefinable steps as non-matching; buffering still works. |
| 9 | Matcher raises at dispatch | Raises to the sender (app bug at the sender's doorstep) and rolls the whole delivery back — no row, no attach, no counter bump. The sender's retry re-delivers. |
| 10 | Matcher raises at the gate | Existing prepare-exception machinery: policy → report → pause by default. |
| 11 | Dispatch enqueue lost | Execution is `scheduled` + overdue → existing housekeeping recovery; fresh execution re-attaches via §4 rule. |
| 12 | Worker crashes mid-step after attach | Stuck-in-progress recovery → reattempt path → re-attach (claimed, not consumed) → same payload. Consumption checkpointed only with completion. |
| 13 | Workflow paused between dispatch and job run | Prepare's paused-guard cancels the execution; signal stays in state claimed; `resume!` → new execution → gate re-attaches. |
| 14 | Payload too large | `SignalPayloadTooLargeError` at `signal!`, before persist — mirror of `CursorTooLargeError`. |
| 15 | Payload key type mismatch (string vs symbol) | `payload` reader returns indifferent-access hashes; matchers see one shape. |
| 16 | `wait:` + `wait_for:` on one step | Compose: run no earlier than `scheduled_for`, and only once signaled (§5.2). |
| 16a | `wait_for: 2.days` or `wait: :payment_confirmed` | `StepConfigurationError` at class load, message pointing to the kwarg the author meant (§5.2). |
| 17 | `skip_if` true on a waiting step | Skips at park time — never parks. Also re-checked at wake. |
| 18 | First step of the workflow has `wait_for:` | Works; workflow parks immediately after creation. No signal-with-start race since `signal!` needs the instance. |
| 19 | Resumable step chain with `wait_for:` | Gate runs once; `signal_id` copied to every successor with the cursor. |
| 20 | Same-name signal while a claimed one is in flight (linear) | Impossible to double-deliver: single active execution; the newcomer buffers (see #4). |

## 13. Implementation surface (for the plan that follows)

New files: `signal.rb` (model), `signal_matcher.rb`; one migration template `add_signals_support.rb` — the signals table and the two step-execution columns ship together, so they are one migration (+ dummy-app mirror). Touched: `workflow.rb` (`signal!`, `has_many :signals`, resume branch, successor `signal_id` copy, stray-sweep widening), `step_definition.rb` (+`wait_for:` validation and normalization, `waits_for_signal?`), `step_execution.rb` (enum value, `signal` association, `signal_columns?`), `executor.rb` (gate segment, consumption in finalize, transitions table, `received_signal` injection), `flow_control.rb` (external verbs already flow through `current_execution` — verify each against §7), `housekeeping_job.rb` (signal delete pass, waiting gauges), `test_helpers.rb`, `geneva_drive.rb` (config accessors), MANUAL chapter.
