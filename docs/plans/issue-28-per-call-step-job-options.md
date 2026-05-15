---
status: completed
created: 2026-05-15
origin: https://github.com/julik/geneva_drive/issues/28
---

# Per-Call Step Job Options

## Problem

GenevaDrive currently supports `set_step_job_options` only at the workflow class level. That makes queue and priority choices global for every instance of a workflow class. Issue #28 asks for a per-call override so a single workflow class can serve both background pollers and user-triggered actions without splitting into subclasses and losing the existing uniqueness guarantee for ongoing workflows.

## Scope

Implement explicit `step_job_options:` support on `GenevaDrive::Workflow.create` and `create!`. The override should merge with class-level `_step_job_options`, persist on the workflow row, and be used whenever the workflow enqueues step jobs, including initial steps, scheduled future steps, and reattempts.

The shorthand `queue:` / `priority:` create API is out of scope for this pass. The explicit hash mirrors the existing class-level setter and avoids collisions with Rails model attributes or future workflow creation options.

## Requirements Traceability

- Issue #28 requires overrides to merge into, not replace, class-level options.
- Issue #28 requires workflow class identity and `validate_unique_ongoing_workflow` behavior to stay unchanged.
- Issue #28 prefers persistence so reattempts and resumed/scheduled steps keep the override.
- Issue #28 calls out ActiveJob `set` compatibility for `queue`, `priority`, `wait`, and `wait_until`.

## Implementation Units

### 1. Persist Per-Workflow Job Options

Files:
- `lib/geneva_drive/workflow.rb`
- `lib/generators/geneva_drive/install/templates/create_workflows_migration.rb`
- `lib/generators/geneva_drive/install/templates/add_step_job_options_to_workflows.rb`
- `lib/generators/geneva_drive/install/install_generator.rb`

Add a nullable `step_job_options` column to the workflows table using JSONB on PostgreSQL, large text on MySQL, and text on SQLite. This is an additive migration and avoids SQLite table rewrites. Existing installs should receive an upgrade migration from the install generator, and new installs should get the column in the create-table template.

In `GenevaDrive::Workflow`, provide guarded serialization helpers similar in spirit to `GenevaDrive::StepExecution::MetadataAccessor`: handle JSON text storage, tolerate the column being absent during upgrade windows, and normalize options into a hash with symbol keys before enqueueing.

### 2. Accept `step_job_options:` During Creation

Files:
- `lib/geneva_drive/workflow.rb`
- `test/workflow/workflow_test.rb`

Teach workflow instances to accept the `step_job_options:` attribute through normal ActiveRecord creation. Validate option keys against the ActiveJob `set` options supported by the requested behavior: `queue`, `priority`, `wait`, and `wait_until`. Invalid keys should fail validation rather than being silently ignored.

The stored override should not participate in uniqueness lookup. The existing `validate_unique_ongoing_workflow` query should continue to scope only by workflow type, hero, state, and `allow_multiple`.

### 3. Use Merged Options for Every Step Enqueue

Files:
- `lib/geneva_drive/workflow.rb`
- `test/workflow/workflow_test.rb`

Replace direct uses of `self.class._step_job_options.dup` in `create_step_execution` and `enqueue_scheduled_execution` with a helper that merges class-level options and instance-level overrides. Runtime scheduling should still set `wait_until` after that merge so the step's actual schedule cannot be accidentally overridden by persisted creation options.

## Existing Patterns

- `set_step_job_options` in `lib/geneva_drive/workflow.rb` already defines class-level defaults and should remain the base layer.
- `create_step_execution` and `enqueue_scheduled_execution` are the only current enqueue points that call `PerformStepJob.set`.
- `GenevaDrive::StepExecution::MetadataAccessor` demonstrates guarded JSON/text storage during upgrade windows.
- Generator templates already use adapter-specific JSONB/text choices for metadata without adding SQLite foreign keys or forcing table rewrites.

## Test Scenarios

- Creating a workflow with `step_job_options: { queue: :high }` persists the override and enqueues the initial step job on `high`.
- Class-level options and per-call options merge, for example class priority plus instance queue.
- Per-call options override conflicting class-level values.
- A delayed or scheduled later step keeps the per-workflow queue/priority while using the step's runtime `wait_until`.
- An invalid `step_job_options` key makes workflow creation invalid.
- A duplicate workflow for the same class and hero is still rejected even when `step_job_options` differ.
- Serialization round-trips through reload so persisted overrides are available after the workflow object is reloaded.

## Risks

- ActiveJob adapters may serialize queue names as strings even when the caller passes symbols, so tests should assert observable queue names in adapter-compatible form.
- The upgrade window before the new column exists should not break existing apps that create workflows without overrides.
- Persisting `wait` or `wait_until` as a default option could conflict with step scheduling. Runtime scheduling must remain authoritative for actual step timing.
