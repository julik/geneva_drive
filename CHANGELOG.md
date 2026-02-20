# Changelog

## [Unreleased]

- Add injectable logger support to `Executor.execute!`. Callers (background jobs, controllers) can pass a `logger:` parameter to inject a pre-tagged logger as the base for all workflow logging during step execution. The injected logger will have workflow and step-specific tags added on top. `PerformStepJob` now passes its own logger to the executor.
- Add `GenevaDrive.enqueue_after_commit` configuration setting to control job enqueueing behavior. When `true` (default in production), jobs are enqueued via `after_all_transactions_commit` to ensure records are visible to workers. When `false` (default in test), jobs are enqueued inline to avoid issues with transactional tests that never commit.
- Fix MySQL compatibility in `HousekeepingJob`: wrap LIMIT subqueries in an extra SELECT (MySQL doesn't support LIMIT in IN subqueries), and interpolate LIMIT values directly (MySQL doesn't handle bind parameters for LIMIT clauses).
- Fix MySQL foreign key compatibility in generator: add foreign keys separately using `add_foreign_key` and skip for MySQL due to unsigned/signed bigint type mismatch.
- Fix Rails 8 deprecation: use `false` instead of `:never` for `enqueue_after_transaction_commit` setting.
- Fix double-deferral bug where `PerformStepJob` could silently fail to enqueue with SolidQueue and other adapters that opt into `enqueue_after_transaction_commit`. When `perform_later` was called from inside an `after_all_transactions_commit` callback, ActiveJob could see the transaction as still "open" and defer the queue INSERT into a second callback that never fires — leaving the step execution with a `job_id` but no corresponding job in the queue backend. Fix: set `enqueue_after_transaction_commit = :never` on `PerformStepJob` (GenevaDrive already handles its own transaction-awareness) and add a poll-retry on step execution lookup as defense-in-depth against replication lag.
- Reduce default `stuck_scheduled_threshold` from 1 hour to 15 minutes for faster recovery when jobs are lost.
- Change `pause!` to preserve scheduled step executions instead of canceling them. Previously, calling `pause!` would cancel the scheduled execution with outcome "workflow_paused". Now, the scheduled execution remains in "scheduled" state, making it visible in the timeline as "overdue" if time passes while paused. On `resume!`, the same execution is re-enqueued (or a new one created only if the executor canceled it while paused).
- Improve `HousekeepingJob` to process all eligible records by looping through batches instead of stopping after the first batch. Also uses efficient SQL DELETEs with INNER JOIN for step executions cleanup and fixes cutoff times at the start of each operation for deterministic behavior.

## [0.4.0]

- Preserve original scheduled time when resuming a paused workflow. When a workflow with a future-scheduled step is paused and then resumed before that time, the step is rescheduled for the original time (not run immediately). If the original time has passed, the step runs immediately.
- Add `max_reattempts:` option for steps with `on_exception: :reattempt!` to limit consecutive reattempts before pausing the workflow (default: 100, set to `nil` to disable)
- Handle unexpected exceptions during prepare_execution (e.g., NameError from invalid hero_type) by marking step as failed and transitioning workflow based on on_exception policy

## [0.3.0]

- Fix `resume!` to retry the failed step instead of skipping it
- Trim gem dependencies to only activerecord, activejob, activesupport, and railties (no longer depends on full rails gem)
- Remove unused engine scaffolding (controllers, views, helpers, assets)

## [0.2.0]

- Add source location tracking to step definitions
- Implement STI fallback for workflow classes
- Store exception class name inside step executions
- Add SQLite gotcha evasion to prevent data loss issues
- Document workflow associations from the hero model
- Update README for license information
- Provisions of the Dutch law now apply
- Ignore Playwright files in repository

## [0.1.0]

Initial release of GenevaDrive durable workflow library.

- Core workflow engine with step definitions and execution tracking
- Step ordering with `before_step` and `after_step` options
- Step validation at definition time
- Workflow state management (ready, in_progress, paused, finished, failed)
- Step execution states with automatic transitions
- External flow control with `pause!` and `skip!` methods
- `previous_step_name` to query the previously executed step
- `next_step_name` column for tracking workflow progress
- Graceful handling of missing step definitions
- `before_step_execution`, `after_step_execution`, and `around_step_execution` hooks
- ActiveSupport instrumentation on step execution
- Logging with improved tag format
- Executor as callable object with proper locking and state validation
- StepCollection with `key?` for existence checks
- Housekeeping job and rake task (`geneva_drive:housekeeping`)
- PostgreSQL, MySQL, and SQLite support
- Installation generator with migrations
- Comprehensive test suite
