# GenevaDrive Implementation Plan

## Overview

GenevaDrive is a Rails library for implementing durable workflows. It provides a clean DSL for defining multi-step workflows that execute asynchronously, with strong guarantees around idempotency, concurrency control, and state management.

**Key Design Principles:**
- **Hero-oriented**: Workflows are associated with a polymorphic "hero" (homage to StepperMotor's hero's journey concept)
- **Step Executions as Primitives**: Each step execution is a first-class database record, serving as an idempotency key
- **Database-enforced Constraints**: Uniqueness and concurrency control via database constraints
- **Forward Scheduling Only**: Steps are scheduled immediately as StepExecution records with jobs enqueued
- **Multi-database Support**: Works on PostgreSQL, MySQL, and SQLite with appropriate strategies for each

---

## Database Structure

### Table: `geneva_drive_workflows`

Tracks the overall workflow state and progress.

```ruby
create_table :geneva_drive_workflows do |t|
  # Core identification (STI)
  t.string :type, null: false, index: true

  # Polymorphic association to the hero of the workflow
  # Column types determined dynamically based on existing schema
  t.string :hero_type, null: false
  # hero_id type: detected from schema (bigint, integer, or uuid/string)

  # State machine
  t.string :state, null: false, default: 'ready', index: true
  # States: 'ready', 'performing', 'finished', 'canceled', 'paused'

  # Current position in workflow
  t.string :current_step_name

  # Multiple workflows of same type for same hero
  t.boolean :allow_multiple, default: false, null: false

  # Timestamps
  t.datetime :started_at
  t.datetime :finished_at
  t.datetime :canceled_at
  t.datetime :paused_at

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
  # Values: 'success', 'reattempted', 'skipped_by_condition', 'skipped_by_flow_control',
  #         'canceled_by_flow_control', 'canceled_by_condition', 'paused_by_exception',
  #         'canceled_by_exception', 'skipped_by_exception'
  t.string :outcome

  # Scheduling
  t.datetime :scheduled_for, null: false, index: true

  # Execution tracking
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
```

### Primary/Foreign Key Type Detection

Use `bigint` for all primary keys and foreign keys. Databases handle upcasting on JOINs cheaply, and we don't do arithmetic on IDs.

The only exception is UUID-based schemas - if the schema predominantly uses UUIDs, use `uuid` instead.

```ruby
# lib/geneva_drive/schema_analyzer.rb
module GenevaDrive
  class SchemaAnalyzer
    # Detect if schema uses UUIDs; otherwise default to bigint
    def self.detect_key_type
      return :bigint if no_tables_exist?

      uuid_count = 0
      other_count = 0

      ActiveRecord::Base.connection.tables.each do |table_name|
        next if table_name.start_with?('schema_', 'ar_')

        columns = ActiveRecord::Base.connection.columns(table_name)
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

    private

    def self.no_tables_exist?
      ActiveRecord::Base.connection.tables.reject { |t| t.start_with?('schema_', 'ar_') }.empty?
    end
  end
end
```

Migration template uses this:

```ruby
# In migration template
def change
  key_type = GenevaDrive::SchemaAnalyzer.detect_key_type

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

  create_table :geneva_drive_step_executions, id: key_type do |t|
    t.references :workflow,
                 null: false,
                 type: key_type,
                 foreign_key: { to_table: :geneva_drive_workflows }
    # ... rest of columns
  end
end
```

### Uniqueness Constraints (Database-Specific)

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
1. **Workflow ActiveRecord Model** - The workflow definition and overall state
2. **StepExecution ActiveRecord Model** - The scheduling and execution primitive
3. **Step Definition System** - DSL for defining steps in workflow classes
4. **State Machines** - Both workflow and step execution states
5. **Associations** - Workflow has_many step_executions
6. **Class-inheritable DSL** - Using class_attribute for steps, cancel_conditions, job_options

### Phase 2: Step Execution Engine
7. **Step Executor** - Handles step invocation via StepExecution
8. **Flow Control Methods** - cancel!, pause!, skip!, reattempt!, finished!
9. **Exception Handling** - Configurable error behavior (pause!, cancel!, reattempt!, skip!)
10. **Transactional Semantics** - Lock-guarded transitions on step execution
11. **Skip Condition Evaluation** - Evaluated at execution time, not scheduling time

### Phase 3: Scheduling & Jobs
12. **Scheduler** - Creates StepExecution records and enqueues jobs (forward scheduling only)
13. **PerformStepJob** - Receives step_execution_id, loads and executes
14. **Job Options** - Per-workflow queue and priority configuration
15. **Idempotency** - Jobs can be safely retried using step execution state

### Phase 4: Advanced Features
16. **Conditional Steps** - skip_if with symbols/procs/booleans (evaluated at execution)
17. **Blanket Conditions** - cancel_if for workflow-wide cancellation
18. **Step Ordering** - before_step/after_step positioning
19. **Anonymous Steps** - Auto-generated names for inline blocks
20. **Progress Callbacks** - before_step_starts hook
21. **Resume from Pause** - resume! method for paused workflows

### Phase 5: Uniqueness & Querying
22. **Unique Constraints** - One active workflow per hero (with allow_multiple option)
23. **Execution Constraints** - One active step execution per workflow
24. **Execution History** - Query past step executions with outcomes

### Phase 6: Configuration & Tooling
25. **Generator** - Rails generator for installation and migrations
26. **Schema Analyzer** - Detect primary key types from existing schema
27. **Configuration DSL** - Global configuration
28. **Testing Helpers** - speedrun_workflow for test environments
29. **Logging & Instrumentation** - Comprehensive logging of state transitions

---

## Code Structure

### Directory Layout

```
lib/geneva_drive/
├── geneva_drive.rb                    # Main entry point
├── version.rb
├── configuration.rb
├── schema_analyzer.rb                 # Detects PK types from schema
├── workflow.rb                        # Base Workflow class
├── step_execution.rb                  # StepExecution model
├── step_definition.rb                 # Step metadata
├── step_collection.rb                 # Step ordering
├── conditional.rb                     # Conditional evaluation
├── state_machines/
│   ├── workflow_state_machine.rb      # Workflow states
│   └── step_execution_state_machine.rb # Step execution states
├── executor.rb                        # Step execution logic
├── flow_control.rb                    # cancel!, pause!, etc.
├── scheduler.rb                       # Creates step executions
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

---

## Key Classes

### 1. GenevaDrive::Workflow

Base class for all workflows, provides DSL and state management.

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

    # State machine for workflow
    include WorkflowStateMachine

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

    # Instance methods
    def schedule_first_step!
      Scheduler.new(self).schedule_first_step!
    end

    def schedule_next_step!(wait: nil)
      Scheduler.new(self).schedule_next_step!(wait: wait)
    end

    # Resume a paused workflow
    def resume!
      raise InvalidStateError, "Cannot resume a #{state} workflow" unless state == 'paused'

      with_lock do
        update!(state: 'ready', paused_at: nil)
      end

      # Schedule the current step again
      Scheduler.new(self).reschedule_current_step!
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
        update!(attributes.merge(state: new_state))
      end
    end
  end
end
```

**Key Design Decisions:**
- Uses `class_attribute` for inheritable DSL arrays/hashes
- Arrays are duplicated before modification to prevent parent mutation
- `hero` as polymorphic association (homage to StepperMotor)
- `resume!` method for paused workflows
- Scopes for all states plus `for_hero` and `active`

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
      skipped_by_condition
      skipped_by_flow_control
      canceled_by_flow_control
      canceled_by_condition
      paused_by_exception
      canceled_by_exception
      skipped_by_exception
      reattempted_by_exception
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

    def mark_failed!(error, outcome: 'paused_by_exception')
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

    def mark_skipped!(outcome: 'skipped_by_condition')
      with_lock do
        update!(
          state: 'skipped',
          skipped_at: Time.current,
          outcome: outcome
        )
      end
    end

    def mark_canceled!(outcome: 'canceled_by_flow_control')
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
- `outcome` column for audit purposes - tracks HOW the execution concluded
- Outcome is separate from state - state is for logic, outcome is for debugging/audit
- All state transition methods accept outcome parameter

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
      @skip_condition = normalize_condition(options[:skip_if] || options[:if])
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

    def normalize_condition(condition)
      case condition
      when Symbol, Proc, TrueClass, FalseClass, NilClass
        condition
      else
        condition
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

**Key Design Decisions:**
- Supports `on_exception: :skip!` (now validated)
- All four exception handlers: `:pause!`, `:cancel!`, `:reattempt!`, `:skip!`

### 4. GenevaDrive::Scheduler

Creates StepExecution records and enqueues jobs. Does NOT evaluate skip conditions.

```ruby
module GenevaDrive
  class Scheduler
    def initialize(workflow)
      @workflow = workflow
    end

    def schedule_first_step!
      first_step = @workflow.class.step_definitions.first
      return finish_workflow! unless first_step

      schedule_step(first_step, wait: first_step.wait)
    end

    def schedule_next_step!(wait: nil)
      current_step_name = @workflow.current_step_name
      next_step = @workflow.class.step_collection.next_after(current_step_name)

      return finish_workflow! unless next_step

      # NOTE: We do NOT evaluate skip_if here!
      # Skip conditions are evaluated at execution time by the Executor.
      # This ensures conditions are evaluated with current state, not stale state.

      schedule_step(next_step, wait: wait || next_step.wait)
    end

    def reschedule_current_step!(wait: nil)
      current_step_name = @workflow.current_step_name
      step_def = @workflow.class.step_collection.find_by_name(current_step_name)

      schedule_step(step_def, wait: wait)
    end

    private

    def schedule_step(step_definition, wait: nil)
      scheduled_for = wait ? wait.from_now : Time.current

      # Create the step execution
      step_execution = @workflow.step_executions.create!(
        step_name: step_definition.name,
        state: 'scheduled',
        scheduled_for: scheduled_for
      )

      # Update workflow's current step
      @workflow.update!(current_step_name: step_definition.name)

      # Enqueue the job
      job_options = @workflow.class._step_job_options.dup
      job_options[:wait_until] = scheduled_for if wait

      job = GenevaDrive::Jobs::PerformStepJob
        .set(job_options)
        .perform_later(step_execution.id)

      # Store job ID for debugging
      step_execution.update!(job_id: job.job_id)

      step_execution
    end

    def finish_workflow!
      @workflow.transition_to!('finished', finished_at: Time.current)
      nil
    end
  end
end
```

**Key Design Decisions:**
- Does NOT evaluate skip_if - that's the Executor's job
- Clear comment explaining why skip conditions aren't evaluated here

### 5. GenevaDrive::Executor

Executes step logic with flow control and exception handling. Evaluates skip_if at execution time.

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

      # 3. Check blanket cancel_if conditions
      if should_cancel_workflow?
        handle_blanket_cancellation
        return
      end

      # 4. Get step definition
      step_def = @step_execution.step_definition

      # 5. Check skip_if condition (evaluated at execution time!)
      if step_def.should_skip?(@workflow)
        handle_skip_by_condition
        return
      end

      # 6. Invoke before_step_starts hook
      @workflow.before_step_starts(step_def.name)

      # 7. Execute step with flow control
      flow_result = catch(:flow_control) do
        begin
          step_def.execute_in_context(@workflow)
          :completed # Default: step completed successfully
        rescue StandardError => e
          handle_exception(e, step_def)
        end
      end

      # 8. Handle flow control result
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
      @step_execution.mark_canceled!(outcome: 'canceled_by_condition')
      @workflow.transition_to!('canceled', canceled_at: Time.current)
    end

    def handle_skip_by_condition
      @step_execution.mark_skipped!(outcome: 'skipped_by_condition')
      @workflow.transition_to!('ready')
      Scheduler.new(@workflow).schedule_next_step!
    end

    def handle_exception(error, step_def)
      Rails.logger.error("Step execution #{@step_execution.id} failed: #{error.message}")
      Rails.error.report(error)

      case step_def.on_exception
      when :reattempt!
        @step_execution.mark_completed!(outcome: 'reattempted_by_exception')
        @workflow.transition_to!('ready')
        Scheduler.new(@workflow).reschedule_current_step!

      when :cancel!
        @step_execution.mark_failed!(error, outcome: 'canceled_by_exception')
        @workflow.transition_to!('canceled', canceled_at: Time.current)

      when :skip!
        @step_execution.mark_skipped!(outcome: 'skipped_by_exception')
        @workflow.transition_to!('ready')
        Scheduler.new(@workflow).schedule_next_step!

      when :pause!
        @step_execution.mark_failed!(error, outcome: 'paused_by_exception')
        @workflow.transition_to!('paused', paused_at: Time.current)

      else
        # Default: pause
        @step_execution.mark_failed!(error, outcome: 'paused_by_exception')
        @workflow.transition_to!('paused', paused_at: Time.current)
      end

      # Return nil to indicate exception was handled (don't process as flow control)
      nil
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
          @step_execution.mark_canceled!(outcome: 'canceled_by_flow_control')
          @workflow.transition_to!('canceled', canceled_at: Time.current)

        when :pause
          @step_execution.mark_canceled!(outcome: 'canceled_by_flow_control')
          @workflow.transition_to!('paused', paused_at: Time.current)

        when :reattempt
          @step_execution.mark_completed!(outcome: 'reattempted')
          @workflow.transition_to!('ready')
          Scheduler.new(@workflow).reschedule_current_step!(wait: signal.options[:wait])

        when :skip
          @step_execution.mark_skipped!(outcome: 'skipped_by_flow_control')
          @workflow.transition_to!('ready')
          schedule_next_or_finish!

        when :finished
          @step_execution.mark_completed!(outcome: 'success')
          @workflow.transition_to!('finished', finished_at: Time.current)
        end
      end
    end

    def schedule_next_or_finish!
      next_scheduled = Scheduler.new(@workflow).schedule_next_step!
      # schedule_next_step! returns nil and finishes workflow if no next step
    end
  end
end
```

**Key Design Decisions:**
- NO ensure block that blindly transitions to 'ready'
- Each path explicitly sets the correct workflow state
- Skip conditions evaluated at execution time (step 5)
- All four exception handlers implemented: `:pause!`, `:cancel!`, `:reattempt!`, `:skip!`
- Clear outcome tracking for every execution path

### 6. GenevaDrive::Jobs::PerformStepJob

ActiveJob that receives step_execution_id and executes the step.

```ruby
module GenevaDrive
  module Jobs
    class PerformStepJob < ActiveJob::Base
      queue_as :default

      def perform(step_execution_id)
        step_execution = GenevaDrive::StepExecution.find(step_execution_id)

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
end
```

### 7. GenevaDrive::FlowControl

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
# 3. Scheduler creates first StepExecution record
#    - step_name: 'send_welcome_email'
#    - state: 'scheduled'
#    - scheduled_for: Time.current (or Time.current + wait)
# 4. PerformStepJob enqueued with step_execution.id
# 5. Workflow.current_step_name set to 'send_welcome_email'
```

### 2. Job Executes

```ruby
# PerformStepJob.perform(step_execution_id)
# 1. Load StepExecution by ID
# 2. Check if state == 'scheduled' (idempotency)
# 3. Check if scheduled_for <= now
# 4. Call step_execution.execute!
```

### 3. Step Execution (via Executor)

```ruby
# Executor#execute!
# 1. Lock step execution, transition to 'executing'
# 2. Transition workflow to 'performing'
# 3. Check cancel_if conditions -> cancel if any true
# 4. Check skip_if condition -> skip if true (EVALUATED HERE, not at scheduling!)
# 5. Call before_step_starts hook
# 6. Execute step block (catch flow control signals)
# 7. Handle result and set appropriate outcome:
#    - :completed -> outcome: 'success', schedule next
#    - :cancel -> outcome: 'canceled_by_flow_control', cancel workflow
#    - :reattempt -> outcome: 'reattempted', reschedule same step
#    - :skip -> outcome: 'skipped_by_flow_control', schedule next
#    - :finished -> outcome: 'success', finish workflow
#    - exception -> depends on on_exception config
```

### 4. Resuming a Paused Workflow

```ruby
# workflow.resume!
# 1. Verify workflow is in 'paused' state
# 2. Lock and transition to 'ready'
# 3. Clear paused_at timestamp
# 4. Reschedule current step (creates new StepExecution)
# 5. Enqueue new job
```

### 5. Workflow Completion

```ruby
# When Scheduler.schedule_next_step! has no next step:
# - Workflow transitions to 'finished'
# - finished_at timestamp set
# - No more step executions created
```

---

## Outcome Values Reference

| Outcome | Meaning |
|---------|---------|
| `success` | Step executed and completed normally |
| `reattempted` | Step called `reattempt!`, will run again |
| `skipped_by_condition` | Step's `skip_if` condition was true |
| `skipped_by_flow_control` | Step called `skip!` |
| `canceled_by_flow_control` | Step called `cancel!` |
| `canceled_by_condition` | Workflow's `cancel_if` condition was true |
| `paused_by_exception` | Exception raised, `on_exception: :pause!` |
| `canceled_by_exception` | Exception raised, `on_exception: :cancel!` |
| `skipped_by_exception` | Exception raised, `on_exception: :skip!` |
| `reattempted_by_exception` | Exception raised, `on_exception: :reattempt!` |

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

### Scheduling
- [ ] Forward scheduler (enqueue jobs early)

### ActiveJob Integration
- [ ] PerformStepJob for step execution
- [ ] set_step_job_options for queue/priority
- [ ] Class-inheritable job options

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
- [ ] Schema analyzer for PK type detection
- [ ] Configuration initializer

### Audit Trail
- [ ] Step execution history preserved
- [ ] Outcome column for debugging
- [ ] Error message/backtrace storage

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
  # All subclasses will check this condition
  cancel_if { hero.deactivated? }

  # All subclasses will use this queue
  set_step_job_options queue: :workflows
end

class PremiumOnboardingWorkflow < BaseWorkflow
  # Adds to parent's cancel conditions
  cancel_if { hero.subscription_expired? }

  # Overrides queue but inherits other options
  set_step_job_options queue: :premium

  step :send_premium_welcome do
    PremiumMailer.welcome(hero).deliver_later
  end
end
```

### Exception Handling

```ruby
class PaymentWorkflow < GenevaDrive::Workflow
  # Retry on transient errors
  step :initiate_payment, on_exception: :reattempt! do
    PaymentGateway.charge(hero)
  rescue PaymentGateway::InvalidCard => e
    # Unrecoverable - cancel the workflow
    cancel!
  rescue PaymentGateway::RateLimited => e
    # Explicit retry with backoff
    reattempt!(wait: e.retry_after)
  end

  # Skip this step if it fails (non-critical)
  step :send_receipt, on_exception: :skip! do
    ReceiptMailer.send_receipt(hero).deliver_later
  end

  # Cancel workflow if this fails
  step :update_inventory, on_exception: :cancel! do
    InventoryService.decrement(hero.items)
  end
end
```

### Resuming Paused Workflows

```ruby
# Find paused workflows
paused = PaymentWorkflow.paused.where(hero: user)

# Resume after fixing the issue
paused.each(&:resume!)
```

### Checking Execution History

```ruby
workflow = SignupWorkflow.find(123)

# See all executions
workflow.execution_history.each do |execution|
  puts "#{execution.step_name}: #{execution.state} (#{execution.outcome})"
  if execution.failed?
    puts "  Error: #{execution.error_message}"
  end
end

# Output:
# send_welcome_email: completed (success)
# send_reminder: completed (reattempted)
# send_reminder: completed (success)
# complete_onboarding: skipped (skipped_by_condition)
```

---

## Database Support Summary

| Feature | PostgreSQL | MySQL | SQLite |
|---------|-----------|-------|--------|
| Uniqueness Constraints | Partial Index | Generated Column | Partial Index |
| PK Type Detection | ✅ Yes | ✅ Yes | ✅ Yes |
| Performance | Excellent | Good | Good |
| Concurrent Access | Excellent | Good | Limited |
| Production Ready | ✅ Yes | ✅ Yes | ⚠️ Dev/Test Only |

**Recommendation**: Use PostgreSQL in production for best performance and concurrency.
