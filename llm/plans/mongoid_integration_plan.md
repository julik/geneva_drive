# Integrating Mongoid support into geneva_drive (no separate gem)

Goal: the one `geneva_drive` gem supports both ActiveRecord and Mongoid.
`GenevaDrive::Workflow` (ActiveRecord) stays 100% backwards compatible — the
existing suite must stay green with zero test edits. A new
`GenevaDrive::MongoidWorkflow` base class (with `GenevaDrive::MongoidStepExecution`
and `GenevaDrive::MongoidSignal`) provides the same behavior on Mongoid 8/9,
loaded **only** when the app opts in. Transactional guarantees on both sides
are identical (see MONGOID_DESIGN.md in ../../../mongoid_gem for the full
guarantee mapping and verdict — that spike is the DONOR CODEBASE: its models,
DocumentLock, EnumField, Factory fallback, index definitions, tests and
concurrency proofs are already green on Mongoid 8.1.13 and 9.1.2 and should be
transplanted, not rewritten).

## Naming and loading

- Flat names: `GenevaDrive::MongoidWorkflow`, `::MongoidStepExecution`,
  `::MongoidSignal` (avoids `GenevaDrive::Mongoid` shadowing `::Mongoid` in
  constant lookup with our flat-module style).
- `require "geneva_drive/mongoid"` is the single opt-in entry point; it raises
  a clear error if the `mongoid` gem is absent. Nothing under
  `lib/geneva_drive/mongoid*` is required by default. The engine may also
  autoload it lazily when the constant is referenced AND `defined?(::Mongoid)`
  — nice-to-have, not required.
- Gemspec: `mongoid` is NOT a dependency (soft dep, like sidekiq already is).
  **activerecord moves to a soft dependency too** so a Mongoid-only app does
  not drag AR in: remove `activerecord` from the gemspec, add `activemodel`,
  and guard every AR touchpoint (engine initializers, `Workflow` autoload,
  migration helpers, test helpers) behind `defined?(ActiveRecord)`. Rails
  apps using the AR side get AR from Rails itself — document this in the
  CHANGELOG/README as the one install-side change. The AR model files must
  not be loaded when AR is absent (keep them out of the default require path
  or guard the requires).

## Code structure: share by extraction, not duplication

Extract ORM-independent logic out of the AR classes into concerns, then have
both backends include them. The donor repo shows exactly which lines differ —
diff `../../../mongoid_gem/lib/geneva_drive/workflow.rb` (etc.) against ours
to find the persistence seams. Suggested cut:

- `GenevaDrive::WorkflowDsl` — all class-level DSL and registry logic
  (step/resumable_step/removed_step/cancel_if/on_exception/steps/
  set_step_job_options/may_proceed_without_hero!, policy resolution). Shared
  verbatim; `removed_steps_in_flight` stays per-backend (query shapes differ).
- `GenevaDrive::WorkflowBehavior` — instance orchestration (schedule_next_step!,
  reschedule_current_step!, resume!, resume_at!, signal!, wake/rendezvous,
  create_step_execution, create_successor_execution!, transition_to!,
  run_after_commit, logger plumbing, hooks). Persistence-specific operations
  become small template methods the module calls and each backend implements:
  e.g. `insert_signal_with_dedup!(...)` (AR: savepoint + rescue
  RecordNotUnique; Mongoid: read-before-insert + E11000 backstop),
  `cancel_stray_executions!` (AR: update_all; Mongoid: pluck-ids + update_all
  clearing active_key — NEVER Criteria#count inside the transaction),
  `after_commit_hook(&block)` (AR: ActiveRecord.after_all_transactions_commit;
  Mongoid: DocumentLock deferred queue).
- Executor: make it backend-agnostic by routing class references through the
  instances: `step_execution.class.resumable_columns?` / `.signal_columns?` /
  `.count_error_reattempts`, and `consecutive_reattempt_count` moves its
  query into a StepExecution class method per backend (AR keeps `id >`,
  Mongoid uses the donor's `_id` comparison).
- StepExecution/Signal: shared concerns for the pure logic (metadata
  accessors, claim!/record_consumption!/fully_resolved!, payload
  serialization + size cap, logger, predicates); fields/associations/
  scopes/locking per backend. Mongoid side carries `active_key` /
  `ongoing_key` / `lock_version` and the index declarations with `$type`
  partial filters, exactly as in the donor.
- `GenevaDrive::DocumentLock`, `GenevaDrive::EnumField` (name it so it
  doesn't collide with the AR enum usage), the Mongoid Factory fallback, and
  the ActiveJob ObjectId serializer come over from the donor unchanged apart
  from class renames (including the Mongoid 8/9 session-arity branch).
- TestHelpers: parameterize the model class references so helpers work for
  both backends (they currently hardcode GenevaDrive::StepExecution).

## Job routing between backends

`PerformStepJob#perform(step_execution_id)` gains an optional second arg
`step_execution_class_name = "GenevaDrive::StepExecution"` (in-flight jobs
keep working). Dispatchers thread it through (`enqueue_step` already receives
`workflow_class_name:` — add the execution class or derive it from the
workflow class's `step_execution_class`). Each Workflow backend exposes
`self.step_execution_class` / `signal_class`; `StepExecutionLookup` takes the
class as a parameter. Same for the Sidekiq job and HousekeepingJob (the
housekeeping job should sweep whichever backends are loaded).

## Generators / install

`geneva_drive:install` gains ORM selection (`--orm=active_record|mongoid`,
default: auto-detect — mongoid if ::Mongoid is defined and AR isn't, else
active_record). Mongoid flavor writes the initializer (including
`require "geneva_drive/mongoid"`) and instructions/rake task
`geneva_drive:create_indexes` (add `GenevaDrive.create_indexes!` from the
donor) instead of migrations. AR flavor unchanged. Generators use nested
module syntax (repo rule).

## Tests

- Existing AR suite: must pass UNMODIFIED (this is the regression gate).
  Mirror the sidekiq-optional pattern already in this repo: Mongoid tests
  are their own tree + rake task + appraisals.
- `test/mongoid/**` — transplant the donor's suite (it is a full port of the
  behavioral suite plus `test/concurrency/atomic_transitions_test.rb` with
  the four atomicity proofs), renaming classes. Own helper
  (`test/mongoid_helper.rb` or similar) that configures Mongoid against
  `GENEVA_DRIVE_MONGODB_URL` (default
  `mongodb://localhost:27017/geneva_drive_test?replicaSet=rs0`, majority
  write concern, NO directConnection), purges collections per test, creates
  indexes once. The dummy app gains Mongoid hero models and a mongoid.yml but
  must not require Mongoid when running the AR suite.
- `rake test:mongoid` runs that tree; appraisals `mongoid_8` and `mongoid_9`
  (mongoid ~> 8.0 with Rails 7.2 components / ~> 9.0 with Rails 8.x) run only
  it, exactly like sidekiq_7/sidekiq_8 run only test:sidekiq.
- compose.yaml gains a `mongo` service: `mongo:8` with
  `--replSet rs0` + healthcheck that runs `rs.initiate` (single-node RS).
  bin/matrix learns the mongo engine for the mongoid appraisals, or a
  dedicated `.github/workflows/mongoid.yml` mirrors sidekiq.yml — pick
  whichever fits the existing matrix plumbing better.
  (A live RS already runs locally in docker container gd-mongo on 27017.)

## Acceptance for this phase

1. `bundle exec rake` (AR/SQLite) green with no test-file changes outside
   additions.
2. `rake test:mongoid` green under both mongoid_8 and mongoid_9 appraisals,
   including 3 consecutive green runs of the concurrency proofs per version.
3. A Mongoid-only smoke: a script/test that loads the gem WITHOUT
   activerecord available (e.g. `bundle exec ruby` with a minimal gemfile or
   `Gem::Specification` trickery is overkill — at minimum assert
   `require "geneva_drive"` does not require activerecord by checking
   `$LOADED_FEATURES`/`defined?(ActiveRecord)` in a subprocess).
4. Donor parity: no behavior regressions vs the spike (the donor's README of
   deviations is MONGOID_DESIGN.md §Verdict — the known gaps stay known, no
   new ones).
