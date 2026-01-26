# Changelog

## [Unreleased]

- Add source location tracking to step definitions
- Implement STI fallback for workflow classes
- Store exception class name inside step executions
- Add SQLite gotcha evasion to prevent data loss issues
- Document workflow associations from the hero model
- Update README for license information
- Provisions of the Dutch law now apply
- Ignore Playwright files in repository

## [0.0.1]

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
