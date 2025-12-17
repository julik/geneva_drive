# GenevaDrive Implementation Plan

## Overview

GenevaDrive is a Rails library for implementing durable workflows. It provides a clean DSL for defining multi-step workflows that execute asynchronously, with strong guarantees around idempotency, concurrency control, and state management.

**Key Design Principles:**
- **Hero-oriented**: Workflows are associated with a polymorphic "hero" (homage to StepperMotor's hero's journey concept)
- **Step Executions as Primitives**: Each step execution is a first-class database record, serving as an idempotency key
- **Database-enforced Constraints**: Uniqueness and concurrency control via database constraints (vital, not application-level)
- **Forward Scheduling Only**: Steps are scheduled immediately as StepExecution records with jobs enqueued
- **Multi-database Support**: Works on PostgreSQL, MySQL, and SQLite with appropriate strategies for each

---

## Project Setup & Development Standards

### Ruby & Rails Requirements

- **Ruby Version**: 3.x syntax required (mandate Ruby 3.0+)
- **Rails Version**: 7.2.2 minimum, only test with 7.2.2 for now
- **Structure**: Rails Engine (generated as Rails plugin with `rails plugin new`)

### Project Structure

Generate as a Rails plugin/engine:
```bash
rails plugin new geneva_drive --mountable --skip-test-unit
```

This provides:
- `lib/geneva_drive/engine.rb` for Rails integration
- Generator infrastructure
- Proper gem structure with `geneva_drive.gemspec`

### Testing

- **Primary Database**: PostgreSQL (default for all tests)
- **Test Framework**: Minitest (Rails default)
- **CI Matrix**: Test with PostgreSQL only initially; MySQL and SQLite support verified manually

### Code Quality

- **Linting**: standardrb - install and apply on every change
- **Documentation**: All public methods must have YARD comments
- **Format**: Run `standardrb --fix` before each commit

```ruby
# Gemfile (development dependencies)
gem "standard", "~> 1.0"

# Example YARD documentation
module GenevaDrive
  # Executes a step within a workflow context.
  #
  # @param workflow [GenevaDrive::Workflow] the workflow instance
  # @param step_execution [GenevaDrive::StepExecution] the step to execute
  # @return [void]
  # @raise [InvalidStateError] if step is not in scheduled state
  class Executor
    # ...
  end
end
```

### Generator

The install generator should:
1. Copy migration templates (with database-specific strategies)
2. Create initializer at `config/initializers/geneva_drive.rb`
3. Detect key type from existing schema

```bash
bin/rails generate geneva_drive:install
bin/rails db:migrate
```

---

## Database Structure

### Table: `geneva_drive_workflows`

Tracks the overall workflow state and progress.

```ruby
create_table :geneva_drive_workflows do |t|
  # Core identification (STI)
  t.string :type, null: false, index: true

  # Polymorphic association to the hero of the workflow
  t.string :hero_type, null: false
  # hero_id type: detected from schema (bigint default, uuid if schema uses it)

  # State machine
  t.string :state, null: false, default: 'ready', index: true
  # States: 'ready', 'performing', 'finished', 'canceled', 'paused'

  # Current position in workflow
  t.string :current_step_name

  # Multiple workflows of same type for same hero
  t.boolean :allow_multiple, default: false, null: false

  # Timestamps
  t.datetime :started_at       # When first step began executing
  t.datetime :transitioned_at  # When state last changed to finished/canceled/paused

  t.timestamps
end

# Polymorphic index
add_index :geneva_drive_workflows, [:hero_type, :hero_id]
```

### Table: `geneva_drive_step_executions`

Tracks individual step execution attempts and serves as the scheduling primitive.

```ruby
create_table :geneva_drive_step_executions do |t|
  # Link to workflow
  t.references :workflow,
               null: false,
               foreign_key: { to_table: :geneva_drive_workflows },
               index: true

  # Which step this execution represents
  t.string :step_name, null: false

  # Execution state machine
  t.string :state, null: false, default: 'scheduled', index: true
  # States: 'scheduled', 'executing', 'completed', 'failed', 'canceled', 'skipped'

  # Outcome for audit purposes (how the execution concluded)
  t.string :outcome

  # Scheduling
  t.datetime :scheduled_for, null: false, index: true

  # Execution tracking (individual timestamps for audit trail)
  t.datetime :started_at
  t.datetime :completed_at
  t.datetime :failed_at
  t.datetime :canceled_at
  t.datetime :skipped_at

  # Error tracking
  t.text :error_message
  t.text :error_backtrace

  # Job tracking (for debugging)
  t.string :job_id

  t.timestamps
end

# Index for finding scheduled executions
add_index :geneva_drive_step_executions,
  [:state, :scheduled_for],
  name: 'index_step_executions_scheduled'

# Index for workflow execution history
add_index :geneva_drive_step_executions, [:workflow_id, :created_at]

# Index for common query patterns
add_index :geneva_drive_step_executions, [:workflow_id, :state]
```

### Outcome Values

Simplified to 6 values (down from 10). The "why" goes in logs, not the database:

```ruby
OUTCOMES = %w[
  success       # Step completed normally
  reattempted   # Step will be retried (by flow control or exception)
  skipped       # Step was skipped (by condition, flow control, or exception)
  canceled      # Step/workflow was canceled (by condition or flow control)
  failed        # Step failed with exception, workflow paused
].freeze
```

### Primary/Foreign Key Type Detection

Key type detection is provided as a migration helper module (not a separate class):

```ruby
# lib/geneva_drive/migration_helpers.rb
module GenevaDrive
  module MigrationHelpers
    # Detect if schema uses UUIDs; otherwise default to bigint
    def geneva_drive_key_type
      tables = connection.tables.reject { |t| t.start_with?('schema_', 'ar_') }
      return :bigint if tables.empty?

      uuid_count = 0
      other_count = 0

      tables.each do |table_name|
        columns = connection.columns(table_name)
        id_column = columns.find { |c| c.name == 'id' }
        next unless id_column

        if id_column.sql_type.downcase.match?(/uuid|char\(36\)|varchar\(36\)/)
          uuid_count += 1
        else
          other_count += 1
        end
      end

      uuid_count > other_count ? :uuid : :bigint
    end
  end
end
```

Migration usage:

```ruby
class CreateGenevaDriveWorkflows < ActiveRecord::Migration[7.0]
  include GenevaDrive::MigrationHelpers

  def change
    key_type = geneva_drive_key_type

    create_table :geneva_drive_workflows, id: key_type do |t|
      t.string :type, null: false, index: true
      t.string :hero_type, null: false

      if key_type == :uuid
        t.uuid :hero_id, null: false
      else
        t.bigint :hero_id, null: false
      end

      # ... rest of columns
    end
  end
end
```

### Uniqueness Constraints (Database-Specific)

**These are vital and cannot be trusted to Rails validations alone.**

#### PostgreSQL Strategy
Uses partial indexes (most efficient):

```sql
-- One active workflow per hero (unless allow_multiple)
CREATE UNIQUE INDEX index_workflows_unique_active
ON geneva_drive_workflows (type, hero_type, hero_id)
WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = false;

-- One active step execution per workflow
CREATE UNIQUE INDEX index_step_executions_one_active_per_workflow
ON geneva_drive_step_executions (workflow_id)
WHERE state IN ('scheduled', 'executing');
```

#### MySQL Strategy
Uses generated columns (partial indexes not supported):

```sql
-- Workflows: Generated column for uniqueness
ALTER TABLE geneva_drive_workflows
ADD COLUMN active_unique_key VARCHAR(767)
AS (
  CASE
    WHEN state NOT IN ('finished', 'canceled') AND allow_multiple = 0
    THEN CONCAT(type, '-', hero_type, '-', hero_id)
    ELSE NULL
  END
) STORED;

CREATE UNIQUE INDEX index_workflows_unique_active
ON geneva_drive_workflows (active_unique_key);

-- Step Executions: Generated column for uniqueness
ALTER TABLE geneva_drive_step_executions
ADD COLUMN active_unique_key VARCHAR(767)
AS (
  CASE
    WHEN state IN ('scheduled', 'executing')
    THEN CAST(workflow_id AS CHAR)
    ELSE NULL
  END
) STORED;

CREATE UNIQUE INDEX index_step_executions_one_active_per_workflow
ON geneva_drive_step_executions (active_unique_key);
```

#### SQLite Strategy
Uses partial indexes with integer booleans:

```sql
-- One active workflow per hero (note: 0 for false, not 'false')
CREATE UNIQUE INDEX index_workflows_unique_active
ON geneva_drive_workflows (type, hero_type, hero_id)
WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = 0;

-- One active step execution per workflow
CREATE UNIQUE INDEX index_step_executions_one_active_per_workflow
ON geneva_drive_step_executions (workflow_id)
WHERE state IN ('scheduled', 'executing');
```

---

## Implementation Plan

### Phase 1: Core Infrastructure
1. **Workflow ActiveRecord Model** - The workflow definition, state, and scheduling (Scheduler inlined)
2. **StepExecution ActiveRecord Model** - The scheduling and execution primitive
3. **Step Definition System** - DSL for defining steps in workflow classes
4. **State Machines** - Both workflow and step execution states
5. **Associations** - Workflow has_many step_executions
6. **Class-inheritable DSL** - Using class_attribute for steps, cancel_conditions, job_options

### Phase 2: Step Execution Engine
7. **Executor** - Handles step invocation via StepExecution
8. **Flow Control Methods** - cancel!, pause!, skip!, reattempt!, finished!
9. **Exception Handling** - Configurable error behavior (pause!, cancel!, reattempt!, skip!)
10. **Transactional Semantics** - Lock-guarded transitions on step execution
11. **Skip Condition Evaluation** - Evaluated at execution time, not scheduling time
12. **Hero Existence Check** - Cancel by default if hero deleted, opt-out via `may_proceed_without_hero!`

### Phase 3: Scheduling & Jobs
13. **Scheduling (inlined in Workflow)** - Creates StepExecution records and enqueues jobs
14. **PerformStepJob** - Receives step_execution_id, loads and executes
15. **Job Options** - Per-workflow queue and priority configuration
16. **Idempotency** - Jobs can be safely retried using step execution state

### Phase 4: Advanced Features
17. **Conditional Steps** - skip_if with symbols/procs/booleans (evaluated at execution)
18. **Blanket Conditions** - cancel_if for workflow-wide cancellation
19. **Step Ordering** - before_step/after_step positioning
20. **Anonymous Steps** - Auto-generated names for inline blocks
21. **Progress Callbacks** - before_step_starts hook
22. **Resume from Pause** - resume! method for paused workflows

### Phase 5: Uniqueness & Querying
23. **Unique Constraints** - One active workflow per hero (with allow_multiple option)
24. **Execution Constraints** - One active step execution per workflow
25. **Execution History** - Query past step executions with outcomes

### Phase 6: Configuration & Tooling
26. **Generator** - Rails generator for installation and migrations
27. **MigrationHelpers Module** - Key type detection for migrations
28. **Configuration DSL** - Global configuration
29. **Testing Helpers** - speedrun_workflow for test environments
30. **Logging & Instrumentation** - Comprehensive logging of state transitions

---

## Code Structure

### Directory Layout

```
lib/geneva_drive/
├── geneva_drive.rb                    # Main entry point
├── version.rb
├── configuration.rb
├── migration_helpers.rb               # Key type detection for migrations
├── workflow.rb                        # Base Workflow class (includes scheduling)
├── step_execution.rb                  # StepExecution model
├── step_definition.rb                 # Step metadata
├── step_collection.rb                 # Step ordering
├── executor.rb                        # Step execution logic
├── flow_control.rb                    # cancel!, pause!, etc.
├── jobs/
│   └── perform_step_job.rb            # Receives step_execution_id
├── test_helpers.rb
└── railtie.rb

lib/generators/geneva_drive/
└── install/
    ├── install_generator.rb
    └── templates/
        ├── create_workflows_migration.rb.tt
        ├── create_step_executions_migration.rb.tt
        └── initializer.rb.tt
```

**Note:** Scheduler has been inlined into Workflow as private methods. No separate Scheduler class.

---

## Key Classes

### 1. GenevaDrive::Workflow

Base class for all workflows, provides DSL, state management, and scheduling.

```ruby
module GenevaDrive
  class Workflow < ActiveRecord::Base
    self.table_name = 'geneva_drive_workflows'

    # Associations
    belongs_to :hero, polymorphic: true
    has_many :step_executions,
             class_name: 'GenevaDrive::StepExecution',
             foreign_key: :workflow_id,
             dependent: :destroy

    # Class-inheritable attributes for DSL
    class_attribute :_step_definitions, instance_writer: false, default: []
    class_attribute :_cancel_conditions, instance_writer: false, default: []
    class_attribute :_step_job_options, instance_writer: false, default: {}
    class_attribute :_may_proceed_without_hero, instance_writer: false, default: false

    # Flow control
    include FlowControl

    # Scopes
    scope :ready, -> { where(state: 'ready') }
    scope :performing, -> { where(state: 'performing') }
    scope :finished, -> { where(state: 'finished') }
    scope :canceled, -> { where(state: 'canceled') }
    scope :paused, -> { where(state: 'paused') }
    scope :active, -> { where.not(state: %w[finished canceled]) }
    scope :for_hero, ->(hero) { where(hero: hero) }

    # DSL for step definition (class methods)
    class << self
      def step(name = nil, **options, &block)
        # Duplicate parent's array to avoid mutation
        self._step_definitions = _step_definitions.dup

        step_def = StepDefinition.new(
          name: name || generate_step_name,
          callable: block || name,
          **options
        )

        _step_definitions << step_def
      end

      def cancel_if(*conditions, &block)
        # Duplicate parent's array to avoid mutation
        self._cancel_conditions = _cancel_conditions.dup

        _cancel_conditions.concat(conditions)
        _cancel_conditions << block if block_given?
      end

      def set_step_job_options(**options)
        # Merge with parent's options
        self._step_job_options = _step_job_options.merge(options)
      end

      # Allow workflow to continue even if hero is deleted
      def may_proceed_without_hero!
        self._may_proceed_without_hero = true
      end

      def step_definitions
        _step_definitions
      end

      def step_collection
        @step_collection ||= StepCollection.new(_step_definitions)
      end

      private

      def generate_step_name
        @step_counter ||= 0
        @step_counter += 1
        "step_#{@step_counter}"
      end
    end

    # Callbacks
    after_create :schedule_first_step!

    # Public scheduling interface
    def schedule_next_step!(wait: nil)
      next_step = self.class.step_collection.next_after(current_step_name)
      return finish_workflow! unless next_step

      create_step_execution(next_step, wait: wait || next_step.wait)
    end

    def reschedule_current_step!(wait: nil)
      step_def = self.class.step_collection.find_by_name(current_step_name)
      create_step_execution(step_def, wait: wait)
    end

    # Resume a paused workflow
    def resume!
      raise InvalidStateError, "Cannot resume a #{state} workflow" unless state == 'paused'

      with_lock do
        update!(state: 'ready', transitioned_at: nil)
      end

      reschedule_current_step!
    end

    # Current execution (if any)
    def current_execution
      step_executions.where(state: %w[scheduled executing]).first
    end

    # Execution history
    def execution_history
      step_executions.order(:created_at)
    end

    # Hooks (override in subclasses)
    def before_step_starts(step_name)
      # Override in subclasses
    end

    # State transitions
    def transition_to!(new_state, **attributes)
      with_lock do
        attrs = attributes.merge(state: new_state)
        attrs[:transitioned_at] = Time.current if %w[finished canceled paused].include?(new_state)
        update!(attrs)
      end
    end

    private

    def schedule_first_step!
      first_step = self.class.step_definitions.first
      return finish_workflow! unless first_step

      create_step_execution(first_step, wait: first_step.wait)
    end

    def create_step_execution(step_definition, wait: nil)
      scheduled_for = wait ? wait.from_now : Time.current

      with_lock do
        step_execution = step_executions.create!(
          step_name: step_definition.name,
          state: 'scheduled',
          scheduled_for: scheduled_for
        )

        update!(current_step_name: step_definition.name)

        job_options = self.class._step_job_options.dup
        job_options[:wait_until] = scheduled_for if wait

        job = GenevaDrive::PerformStepJob
          .set(job_options)
          .perform_later(step_execution.id)

        step_execution.update!(job_id: job.job_id)
        step_execution
      end
    end

    def finish_workflow!
      transition_to!('finished')
      nil
    end
  end
end
```

**Key Design Decisions:**
- Uses `class_attribute` for inheritable DSL arrays/hashes
- Arrays are duplicated before modification to prevent parent mutation
- `hero` as polymorphic association (homage to StepperMotor)
- `may_proceed_without_hero!` for workflows that can continue without hero
- `resume!` method for paused workflows
- Scheduling inlined as private methods (no separate Scheduler class)
- All scheduling happens within workflow lock (fixes race condition)
- `transitioned_at` auto-set when transitioning to terminal/paused states

### 2. GenevaDrive::StepExecution

Represents a single step execution attempt, serves as idempotency key.

```ruby
module GenevaDrive
  class StepExecution < ActiveRecord::Base
    self.table_name = 'geneva_drive_step_executions'

    # Outcome values for audit purposes
    OUTCOMES = %w[
      success
      reattempted
      skipped
      canceled
      failed
    ].freeze

    # Associations
    belongs_to :workflow,
               class_name: 'GenevaDrive::Workflow',
               foreign_key: :workflow_id

    # Validations
    validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

    # Scopes
    scope :scheduled, -> { where(state: 'scheduled') }
    scope :executing, -> { where(state: 'executing') }
    scope :completed, -> { where(state: 'completed') }
    scope :failed, -> { where(state: 'failed') }
    scope :skipped, -> { where(state: 'skipped') }
    scope :canceled, -> { where(state: 'canceled') }
    scope :ready_to_execute, -> {
      where(state: 'scheduled')
        .where('scheduled_for <= ?', Time.current)
    }

    # State transitions
    def start_executing!
      with_lock do
        return false unless state == 'scheduled'
        update!(
          state: 'executing',
          started_at: Time.current
        )
      end
      true
    end

    def mark_completed!(outcome: 'success')
      with_lock do
        update!(
          state: 'completed',
          completed_at: Time.current,
          outcome: outcome
        )
      end
    end

    def mark_failed!(error, outcome: 'failed')
      with_lock do
        update!(
          state: 'failed',
          failed_at: Time.current,
          outcome: outcome,
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
      end
    end

    def mark_skipped!(outcome: 'skipped')
      with_lock do
        update!(
          state: 'skipped',
          skipped_at: Time.current,
          outcome: outcome
        )
      end
    end

    def mark_canceled!(outcome: 'canceled')
      with_lock do
        update!(
          state: 'canceled',
          canceled_at: Time.current,
          outcome: outcome
        )
      end
    end

    # Get the step definition for this execution
    def step_definition
      workflow.class.step_collection.find_by_name(step_name)
    end

    # Execute this step
    def execute!
      Executor.new(workflow, self).execute!
    end
  end
end
```

**Key Design Decisions:**
- `outcome` column for audit purposes - simplified to 5 values
- Individual timestamps kept for step executions (audit trail)
- All state transition methods use `with_lock`

### 3. GenevaDrive::StepDefinition

Metadata about a step definition.

```ruby
module GenevaDrive
  class StepDefinition
    attr_reader :name, :callable, :wait, :skip_condition,
                :on_exception, :before_step, :after_step

    EXCEPTION_HANDLERS = %i[pause! cancel! reattempt! skip!].freeze

    def initialize(name:, callable:, **options)
      @name = name.to_s
      @callable = callable
      @wait = options[:wait]
      @skip_condition = options[:skip_if] || options[:if]
      @on_exception = options[:on_exception] || :pause!
      @before_step = options[:before_step]&.to_s
      @after_step = options[:after_step]&.to_s

      validate!
    end

    def should_skip?(workflow)
      return false unless @skip_condition
      evaluate_condition(@skip_condition, workflow)
    end

    def execute_in_context(workflow)
      if @callable.is_a?(Symbol)
        workflow.send(@callable)
      else
        workflow.instance_exec(&@callable)
      end
    end

    private

    def validate!
      unless EXCEPTION_HANDLERS.include?(@on_exception)
        raise ArgumentError, "on_exception must be one of: #{EXCEPTION_HANDLERS.join(', ')}"
      end
    end

    def evaluate_condition(condition, workflow)
      case condition
      when Symbol
        workflow.send(condition)
      when Proc
        workflow.instance_exec(&condition)
      when TrueClass, FalseClass
        condition
      when NilClass
        false
      else
        !!condition
      end
    end
  end
end
```

### 4. GenevaDrive::Executor

Executes step logic with flow control and exception handling.

```ruby
module GenevaDrive
  class Executor
    def initialize(workflow, step_execution)
      @workflow = workflow
      @step_execution = step_execution
    end

    def execute!
      # 1. Transition step execution to executing (with lock)
      return unless @step_execution.start_executing!

      # 2. Transition workflow to performing
      @workflow.transition_to!('performing') if @workflow.state == 'ready'

      # 3. Check hero exists (unless workflow opts out)
      unless @workflow.class._may_proceed_without_hero
        unless @workflow.hero
          @step_execution.mark_canceled!(outcome: 'canceled')
          @workflow.transition_to!('canceled')
          return
        end
      end

      # 4. Check blanket cancel_if conditions
      if should_cancel_workflow?
        handle_blanket_cancellation
        return
      end

      # 5. Get step definition
      step_def = @step_execution.step_definition

      # 6. Check skip_if condition (evaluated at execution time!)
      if step_def.should_skip?(@workflow)
        handle_skip_by_condition
        return
      end

      # 7. Invoke before_step_starts hook
      @workflow.before_step_starts(step_def.name)

      # 8. Execute step with flow control
      flow_result = catch(:flow_control) do
        begin
          step_def.execute_in_context(@workflow)
          :completed # Default: step completed successfully
        rescue StandardError => e
          handle_exception(e, step_def)
        end
      end

      # 9. Handle flow control result
      handle_flow_control(flow_result)
    end

    private

    def should_cancel_workflow?
      @workflow.class._cancel_conditions.any? do |condition|
        evaluate_condition(condition)
      end
    end

    def evaluate_condition(condition)
      case condition
      when Symbol
        @workflow.send(condition)
      when Proc
        @workflow.instance_exec(&condition)
      else
        !!condition
      end
    end

    def handle_blanket_cancellation
      @step_execution.mark_canceled!(outcome: 'canceled')
      @workflow.transition_to!('canceled')
    end

    def handle_skip_by_condition
      @step_execution.mark_skipped!(outcome: 'skipped')
      @workflow.transition_to!('ready')
      @workflow.schedule_next_step!
    end

    def handle_exception(error, step_def)
      Rails.logger.error("Step execution #{@step_execution.id} failed: #{error.message}")
      Rails.error.report(error)

      case step_def.on_exception
      when :reattempt!
        @step_execution.mark_completed!(outcome: 'reattempted')
        @workflow.transition_to!('ready')
        @workflow.reschedule_current_step!

      when :cancel!
        @step_execution.mark_failed!(error, outcome: 'canceled')
        @workflow.transition_to!('canceled')

      when :skip!
        @step_execution.mark_skipped!(outcome: 'skipped')
        @workflow.transition_to!('ready')
        @workflow.schedule_next_step!

      when :pause!
        @step_execution.mark_failed!(error, outcome: 'failed')
        @workflow.transition_to!('paused')

      else
        # Default: pause
        @step_execution.mark_failed!(error, outcome: 'failed')
        @workflow.transition_to!('paused')
      end

      nil # Indicate exception was handled
    end

    def handle_flow_control(signal)
      return if signal.nil? # Exception was already handled

      case signal
      when :completed
        @step_execution.mark_completed!(outcome: 'success')
        @workflow.transition_to!('ready')
        schedule_next_or_finish!

      when FlowControlSignal
        case signal.action
        when :cancel
          @step_execution.mark_canceled!(outcome: 'canceled')
          @workflow.transition_to!('canceled')

        when :pause
          @step_execution.mark_canceled!(outcome: 'canceled')
          @workflow.transition_to!('paused')

        when :reattempt
          @step_execution.mark_completed!(outcome: 'reattempted')
          @workflow.transition_to!('ready')
          @workflow.reschedule_current_step!(wait: signal.options[:wait])

        when :skip
          @step_execution.mark_skipped!(outcome: 'skipped')
          @workflow.transition_to!('ready')
          schedule_next_or_finish!

        when :finished
          @step_execution.mark_completed!(outcome: 'success')
          @workflow.transition_to!('finished')
        end
      end
    end

    def schedule_next_or_finish!
      @workflow.schedule_next_step!
    end
  end
end
```

**Key Design Decisions:**
- NO ensure block that blindly transitions to 'ready'
- Each path explicitly sets the correct workflow state
- Hero existence check at step 3 (before cancel_if conditions)
- Skip conditions evaluated at execution time (step 6)
- All four exception handlers implemented
- Simplified outcome tracking

### 5. GenevaDrive::PerformStepJob

ActiveJob that receives step_execution_id and executes the step.

```ruby
module GenevaDrive
  class PerformStepJob < ActiveJob::Base
    queue_as :default

    def perform(step_execution_id)
      step_execution = GenevaDrive::StepExecution.lock.find(step_execution_id)

      # Idempotency: if already executed, don't execute again
      return unless step_execution.state == 'scheduled'

      # Don't execute if scheduled for future (job ran early)
      return if step_execution.scheduled_for > Time.current

      # Execute the step
      step_execution.execute!
    rescue ActiveRecord::RecordNotFound
      # Step execution was deleted, nothing to do
      Rails.logger.warn("StepExecution #{step_execution_id} not found")
    end
  end
end
```

**Key Design Decisions:**
- Uses `lock.find` for proper idempotency (per Kieran's review)
- Simple job that delegates to StepExecution#execute!

### 6. GenevaDrive::FlowControl

Module providing flow control methods via throw/catch.

```ruby
module GenevaDrive
  class FlowControlSignal
    attr_reader :action, :options

    def initialize(action, **options)
      @action = action
      @options = options
    end
  end

  class InvalidStateError < StandardError; end

  module FlowControl
    def cancel!
      throw :flow_control, FlowControlSignal.new(:cancel)
    end

    def pause!
      throw :flow_control, FlowControlSignal.new(:pause)
    end

    def reattempt!(wait: nil)
      throw :flow_control, FlowControlSignal.new(:reattempt, wait: wait)
    end

    def skip!
      throw :flow_control, FlowControlSignal.new(:skip)
    end

    def finished!
      throw :flow_control, FlowControlSignal.new(:finished)
    end
  end
end
```

---

## Execution Flow

### 1. Creating and Starting a Workflow

```ruby
# User code
workflow = SignupWorkflow.create!(hero: current_user)

# What happens internally:
# 1. Workflow record created in 'ready' state
# 2. after_create callback calls schedule_first_step!
# 3. Within workflow lock:
#    - StepExecution created (state: 'scheduled')
#    - Workflow.current_step_name updated
#    - PerformStepJob enqueued
```

### 2. Job Executes

```ruby
# PerformStepJob.perform(step_execution_id)
# 1. Load StepExecution with lock
# 2. Check if state == 'scheduled' (idempotency)
# 3. Check if scheduled_for <= now
# 4. Call step_execution.execute!
```

### 3. Step Execution (via Executor)

```ruby
# Executor#execute!
# 1. Lock step execution, transition to 'executing'
# 2. Transition workflow to 'performing'
# 3. Check hero exists (unless may_proceed_without_hero!)
# 4. Check cancel_if conditions -> cancel if any true
# 5. Check skip_if condition -> skip if true
# 6. Call before_step_starts hook
# 7. Execute step block (catch flow control signals)
# 8. Handle result and set appropriate outcome
```

### 4. Hero Deletion Handling

```ruby
# Default: workflow cancels if hero is deleted
class PaymentWorkflow < GenevaDrive::Workflow
  step :charge do
    hero.charge!  # If hero deleted, workflow auto-cancels before reaching here
  end
end

# Opt-out: workflow may continue without hero
class CleanupWorkflow < GenevaDrive::Workflow
  may_proceed_without_hero!

  step :archive_data do
    # hero might be nil here, workflow handles it
    ArchiveService.archive(hero_id: hero&.id)
  end
end
```

### 5. Resuming a Paused Workflow

```ruby
# workflow.resume!
# 1. Verify workflow is in 'paused' state
# 2. Lock and transition to 'ready'
# 3. Clear transitioned_at timestamp
# 4. Reschedule current step (creates new StepExecution)
```

---

## Feature Parity Checklist

### Core Features
- [ ] ActiveRecord-backed workflows (STI)
- [ ] Polymorphic hero association
- [ ] Step DSL (named and anonymous)
- [ ] Wait times between steps
- [ ] State machine (ready/performing/finished/canceled/paused)
- [ ] Lock-guarded execution
- [ ] Single execution guarantee per workflow
- [ ] Class-inheritable DSL (steps, cancel_if, job_options)

### Step Definition
- [ ] Named steps with blocks
- [ ] Anonymous steps with auto-naming
- [ ] Instance method steps (`step :method_name`)
- [ ] Inline method definition (`step def method_name`)
- [ ] Step ordering (before_step/after_step)

### Conditional Logic
- [ ] skip_if with symbols/callables/booleans
- [ ] skip_if evaluated at execution time (not scheduling)
- [ ] cancel_if for blanket conditions
- [ ] Class-inheritable cancel_if

### Flow Control
- [ ] cancel! - mark workflow canceled
- [ ] pause! - pause for manual intervention
- [ ] reattempt! - retry current step with optional wait
- [ ] skip! - skip current step, proceed to next
- [ ] finished! - mark workflow complete
- [ ] resume! - resume paused workflow

### Hero Handling
- [ ] Cancel by default if hero deleted
- [ ] may_proceed_without_hero! opt-out

### Scheduling
- [ ] Forward scheduler (inlined in Workflow)
- [ ] Scheduling within workflow lock (atomic)

### ActiveJob Integration
- [ ] PerformStepJob for step execution
- [ ] set_step_job_options for queue/priority
- [ ] Class-inheritable job options
- [ ] Lock-based idempotency in job

### Exception Handling
- [ ] on_exception: :pause! (default)
- [ ] on_exception: :cancel!
- [ ] on_exception: :reattempt!
- [ ] on_exception: :skip!
- [ ] Store error message/backtrace

### Uniqueness
- [ ] One workflow per hero by default
- [ ] allow_multiple flag for concurrent workflows
- [ ] Database-enforced constraints (PostgreSQL, MySQL, SQLite)

### Querying
- [ ] State scopes (ready, paused, finished, etc.)
- [ ] for_hero scope
- [ ] active scope

### Hooks & Callbacks
- [ ] before_step_starts(step_name)

### Rails Integration
- [ ] Generator for installation
- [ ] Migration templates with database detection
- [ ] MigrationHelpers module for key type detection
- [ ] Configuration initializer

### Audit Trail
- [ ] Step execution history preserved
- [ ] Outcome column (5 values)
- [ ] Error message/backtrace storage
- [ ] Individual timestamps on step executions

### Testing
- [ ] speedrun_workflow helper
- [ ] Reload between steps in tests

---

## API Examples

### Basic Usage

```ruby
class SignupWorkflow < GenevaDrive::Workflow
  step :send_welcome_email do
    WelcomeMailer.welcome(hero).deliver_later
  end

  step :send_reminder, wait: 2.days do
    ReminderMailer.remind(hero).deliver_later
  end

  step :complete_onboarding, wait: 7.days do
    hero.update!(onboarding_completed: true)
  end
end

# Create workflow
SignupWorkflow.create!(hero: current_user)
```

### Inheritance

```ruby
class BaseWorkflow < GenevaDrive::Workflow
  cancel_if { hero.deactivated? }
  set_step_job_options queue: :workflows
end

class PremiumOnboardingWorkflow < BaseWorkflow
  cancel_if { hero.subscription_expired? }
  set_step_job_options queue: :premium

  step :send_premium_welcome do
    PremiumMailer.welcome(hero).deliver_later
  end
end
```

### Hero Deletion Handling

```ruby
# Default: auto-cancel if hero deleted
class PaymentWorkflow < GenevaDrive::Workflow
  step :charge do
    hero.charge!
  end
end

# Opt-out for cleanup workflows
class DataCleanupWorkflow < GenevaDrive::Workflow
  may_proceed_without_hero!

  step :cleanup do
    # Safe to run even if hero was deleted
    DataArchive.cleanup_for_hero_id(hero&.id || hero_id)
  end
end
```

### Exception Handling

```ruby
class PaymentWorkflow < GenevaDrive::Workflow
  step :initiate_payment, on_exception: :reattempt! do
    PaymentGateway.charge(hero)
  rescue PaymentGateway::InvalidCard => e
    cancel!
  rescue PaymentGateway::RateLimited => e
    reattempt!(wait: e.retry_after)
  end

  step :send_receipt, on_exception: :skip! do
    ReceiptMailer.send_receipt(hero).deliver_later
  end

  step :update_inventory, on_exception: :cancel! do
    InventoryService.decrement(hero.items)
  end
end
```

### Resuming Paused Workflows

```ruby
paused = PaymentWorkflow.paused.where(hero: user)
paused.each(&:resume!)
```

### Checking Execution History

```ruby
workflow = SignupWorkflow.find(123)

workflow.execution_history.each do |execution|
  puts "#{execution.step_name}: #{execution.state} (#{execution.outcome})"
  if execution.failed?
    puts "  Error: #{execution.error_message}"
  end
end
```

---

## Database Support Summary

| Feature | PostgreSQL | MySQL | SQLite |
|---------|-----------|-------|--------|
| Workflow Uniqueness | Partial Index | Generated Column | Partial Index |
| Step Execution Uniqueness | Partial Index | Generated Column | Partial Index |
| PK Type Detection | ✅ Yes | ✅ Yes | ✅ Yes |
| Performance | Excellent | Good | Good |
| Concurrent Access | Excellent | Good | Limited |
| Production Ready | ✅ Yes | ✅ Yes | ⚠️ Dev/Test Only |

**All uniqueness constraints are database-enforced. Application-level validations are not sufficient.**
