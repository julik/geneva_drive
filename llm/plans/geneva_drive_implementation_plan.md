# GenevaDrive Implementation Plan

## Overview

GenevaDrive is a Rails library for implementing durable workflows. It provides a clean DSL for defining multi-step workflows that execute asynchronously, with strong guarantees around idempotency, concurrency control, and state management.

**Key Design Principles:**
- **Subject-oriented**: Workflows are associated with a polymorphic "subject" (replaces "hero" terminology)
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
  # Core identification
  t.string :type, null: false, index: true

  # Polymorphic association to the subject of the workflow
  t.string :subject_type, null: false
  t.bigint :subject_id, null: false

  # State machine
  t.string :state, null: false, default: 'ready', index: true
  # States: 'ready', 'performing', 'finished', 'canceled', 'paused'

  # Current position in workflow
  t.string :current_step_name

  # Multiple workflows of same type for same subject
  t.boolean :allow_multiple, default: false, null: false

  # Timestamps
  t.datetime :started_at
  t.datetime :finished_at
  t.datetime :canceled_at
  t.datetime :paused_at

  t.timestamps
end

# Polymorphic index
add_index :geneva_drive_workflows, [:subject_type, :subject_id]
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

### Uniqueness Constraints (Database-Specific)

#### PostgreSQL Strategy
Uses partial indexes (most efficient):

```sql
-- One active workflow per subject (unless allow_multiple)
CREATE UNIQUE INDEX index_workflows_unique_active
ON geneva_drive_workflows (type, subject_type, subject_id)
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
    THEN CONCAT(type, '-', subject_type, '-', subject_id)
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
-- One active workflow per subject (note: 0 for false, not 'false')
CREATE UNIQUE INDEX index_workflows_unique_active
ON geneva_drive_workflows (type, subject_type, subject_id)
WHERE state NOT IN ('finished', 'canceled') AND allow_multiple = 0;

-- One active step execution per workflow
CREATE UNIQUE INDEX index_step_executions_one_active_per_workflow
ON geneva_drive_step_executions (workflow_id)
WHERE state IN ('scheduled', 'executing');
```

**Why This Works:**
- **PostgreSQL & SQLite**: Partial indexes only include rows matching the WHERE clause
- **MySQL**: Generated columns compute to unique key when active, NULL when inactive (NULLs don't conflict)
- **All databases**: Uniqueness enforced at database level, zero application coordination needed

---

## Implementation Plan

### Phase 1: Core Infrastructure
1. **Workflow ActiveRecord Model** - The workflow definition and overall state
2. **StepExecution ActiveRecord Model** - The scheduling and execution primitive
3. **Step Definition System** - DSL for defining steps in workflow classes
4. **State Machines** - Both workflow and step execution states
5. **Associations** - Workflow has_many step_executions

### Phase 2: Step Execution Engine
6. **Step Executor** - Handles step invocation via StepExecution
7. **Flow Control Methods** - cancel!, pause!, skip!, reattempt!, finished!
8. **Exception Handling** - Configurable error behavior, tracked on step execution
9. **Transactional Semantics** - Lock-guarded transitions on step execution

### Phase 3: Scheduling & Jobs
10. **Scheduler** - Creates StepExecution records and enqueues jobs (forward scheduling only)
11. **PerformStepJob** - Receives step_execution_id, loads and executes
12. **Job Options** - Per-workflow queue and priority configuration
13. **Idempotency** - Jobs can be safely retried using step execution state

### Phase 4: Advanced Features
14. **Conditional Steps** - skip_if with symbols/procs/booleans
15. **Blanket Conditions** - cancel_if for workflow-wide cancellation
16. **Step Ordering** - before_step/after_step positioning
17. **Anonymous Steps** - Auto-generated names for inline blocks
18. **Progress Callbacks** - before_step_starts hook

### Phase 5: Uniqueness & Querying
19. **Unique Constraints** - One active workflow per subject (with allow_multiple option)
20. **Execution Constraints** - One active step execution per workflow
21. **Presence Queries** - Helper methods for checking existing workflows
22. **Execution History** - Query past step executions

### Phase 6: Configuration & Tooling
23. **Generator** - Rails generator for installation and migrations
24. **Configuration DSL** - Global configuration
25. **Testing Helpers** - speedrun_workflow for test environments
26. **Logging & Instrumentation** - Comprehensive logging of state transitions

---

## Code Structure

### Directory Layout

```
lib/geneva_drive/
├── geneva_drive.rb                    # Main entry point
├── version.rb
├── configuration.rb
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
    belongs_to :subject, polymorphic: true
    has_many :step_executions,
             class_name: 'GenevaDrive::StepExecution',
             foreign_key: :workflow_id,
             dependent: :destroy

    # State machine for workflow
    include WorkflowStateMachine

    # Flow control
    include FlowControl

    # DSL for step definition (class methods)
    class << self
      def step(name = nil, **options, &block)
        step_collection.add(
          StepDefinition.new(
            name: name || generate_step_name,
            callable: block || name,
            **options
          )
        )
      end

      def cancel_if(*conditions, &block)
        cancel_conditions.concat(conditions)
        cancel_conditions << block if block_given?
      end

      def set_step_job_options(**options)
        @step_job_options = (@step_job_options || {}).merge(options)
      end

      def step_collection
        @step_collection ||= StepCollection.new
      end

      def step_definitions
        step_collection.all
      end
    end

    # Instance methods
    def schedule_first_step!
      Scheduler.new(self).schedule_first_step!
    end

    def schedule_next_step!(wait: nil)
      Scheduler.new(self).schedule_next_step!(wait: wait)
    end

    # Current execution (if any)
    def current_execution
      step_executions.where(state: %w[scheduled executing]).first
    end

    # Execution history
    def execution_history
      step_executions.order(:created_at)
    end

    # Hooks
    def before_step_starts(step_name)
      # Override in subclasses
    end
  end
end
```

**Key Responsibilities:**
- Define workflow DSL (step, cancel_if, set_step_job_options)
- Manage associations to subject and step executions
- Provide hooks for subclasses
- Coordinate with Scheduler for step scheduling

### 2. GenevaDrive::StepExecution

Represents a single step execution attempt, serves as idempotency key.

```ruby
module GenevaDrive
  class StepExecution < ActiveRecord::Base
    self.table_name = 'geneva_drive_step_executions'

    # Associations
    belongs_to :workflow,
               class_name: 'GenevaDrive::Workflow',
               foreign_key: :workflow_id

    # State machine
    include StepExecutionStateMachine

    # Scopes
    scope :scheduled, -> { where(state: 'scheduled') }
    scope :executing, -> { where(state: 'executing') }
    scope :completed, -> { where(state: 'completed') }
    scope :failed, -> { where(state: 'failed') }
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

    def mark_completed!
      with_lock do
        update!(
          state: 'completed',
          completed_at: Time.current
        )
      end
    end

    def mark_failed!(error)
      with_lock do
        update!(
          state: 'failed',
          failed_at: Time.current,
          error_message: error.message,
          error_backtrace: error.backtrace&.join("\n")
        )
      end
    end

    def mark_skipped!
      with_lock do
        update!(
          state: 'skipped',
          skipped_at: Time.current
        )
      end
    end

    def mark_canceled!
      with_lock do
        update!(
          state: 'canceled',
          canceled_at: Time.current
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

**Key Responsibilities:**
- Track state of individual step execution
- Provide idempotency via state checks
- Store error information on failure
- Link to workflow and step definition

### 3. GenevaDrive::StepDefinition

Metadata about a step definition.

```ruby
module GenevaDrive
  class StepDefinition
    attr_reader :name, :callable, :wait, :skip_condition,
                :on_exception, :before_step, :after_step

    def initialize(name:, callable:, **options)
      @name = name
      @callable = callable
      @wait = options[:wait]
      @skip_condition = normalize_condition(options[:skip_if] || options[:if])
      @on_exception = options[:on_exception] || :pause!
      @before_step = options[:before_step]
      @after_step = options[:after_step]
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

**Key Responsibilities:**
- Store step metadata (name, wait time, conditions, error handling)
- Evaluate skip conditions in workflow context
- Execute step block in workflow context

### 4. GenevaDrive::Scheduler

Creates StepExecution records and enqueues jobs.

```ruby
module GenevaDrive
  class Scheduler
    def initialize(workflow)
      @workflow = workflow
    end

    def schedule_first_step!
      first_step = @workflow.class.step_definitions.first
      return unless first_step

      schedule_step(first_step, wait: first_step.wait)
    end

    def schedule_next_step!(wait: nil)
      current_step_name = @workflow.current_step_name
      next_step = @workflow.class.step_collection.next_after(current_step_name)

      return unless next_step

      # Skip conditional steps
      while next_step && next_step.should_skip?(@workflow)
        next_step = @workflow.class.step_collection.next_after(next_step.name)
      end

      return unless next_step

      schedule_step(next_step, wait: wait || next_step.wait)
    end

    def reschedule_current_step!(wait: nil)
      current_step_name = @workflow.current_step_name
      step_def = @workflow.class.step_collection.find_by_name(current_step_name)

      schedule_step(step_def, wait: wait || step_def.wait)
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
      job_options = @workflow.class.instance_variable_get(:@step_job_options) || {}
      job_options = job_options.merge(wait_until: scheduled_for) if wait

      job = GenevaDrive::Jobs::PerformStepJob
        .set(job_options)
        .perform_later(step_execution.id)

      # Store job ID for debugging
      step_execution.update!(job_id: job.job_id)

      step_execution
    end
  end
end
```

**Key Responsibilities:**
- Create StepExecution records
- Enqueue PerformStepJob with proper timing
- Handle step ordering and conditional skipping
- Support rescheduling for reattempt!

### 5. GenevaDrive::Executor

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

      # 3. Check blanket cancel_if conditions
      if should_cancel_workflow?
        handle_cancellation
        return
      end

      # 4. Get step definition
      step_def = @step_execution.step_definition

      # 5. Invoke before_step_starts hook
      @workflow.before_step_starts(step_def.name)

      # 6. Execute step with flow control
      flow_result = catch(:flow_control) do
        begin
          step_def.execute_in_context(@workflow)
          :completed # Default: step completed successfully
        rescue StandardError => e
          handle_exception(e, step_def)
        end
      end

      # 7. Handle flow control result
      handle_flow_control(flow_result)

    ensure
      # Always release workflow from performing state
      @workflow.reload
      @workflow.transition_to!('ready') if @workflow.state == 'performing'
    end

    private

    def should_cancel_workflow?
      conditions = @workflow.class.instance_variable_get(:@cancel_conditions) || []
      conditions.any? { |condition| evaluate_condition(condition) }
    end

    def handle_exception(error, step_def)
      Rails.logger.error("Step execution #{@step_execution.id} failed: #{error.message}")
      Rails.error.report(error)

      case step_def.on_exception
      when :reattempt!
        FlowControlSignal.new(:reattempt, error: error)
      when :cancel!
        FlowControlSignal.new(:cancel, error: error)
      when :pause!
        @step_execution.mark_failed!(error)
        @workflow.transition_to!('paused')
        return :paused
      else
        # Default: pause
        @step_execution.mark_failed!(error)
        @workflow.transition_to!('paused')
        return :paused
      end
    end

    def handle_flow_control(signal)
      case signal
      when :completed
        @step_execution.mark_completed!
        Scheduler.new(@workflow).schedule_next_step!

      when FlowControlSignal
        case signal.action
        when :cancel
          @step_execution.mark_canceled!
          @workflow.transition_to!('canceled', canceled_at: Time.current)

        when :pause
          @step_execution.mark_canceled!
          @workflow.transition_to!('paused', paused_at: Time.current)

        when :reattempt
          @step_execution.mark_completed! # Current execution completed
          Scheduler.new(@workflow).reschedule_current_step!(wait: signal.options[:wait])

        when :skip
          @step_execution.mark_skipped!
          Scheduler.new(@workflow).schedule_next_step!

        when :finished
          @step_execution.mark_completed!
          @workflow.transition_to!('finished', finished_at: Time.current)
        end
      end

      # If no next step was scheduled and workflow is still ready, mark it finished
      if @workflow.reload.state == 'ready' && !@workflow.current_execution
        @workflow.transition_to!('finished', finished_at: Time.current)
      end
    end

    def handle_cancellation
      @step_execution.mark_canceled!
      @workflow.transition_to!('canceled', canceled_at: Time.current)
    end
  end
end
```

**Key Responsibilities:**
- Coordinate step execution with proper locking
- Handle flow control signals (cancel!, pause!, etc.)
- Manage exception handling per step configuration
- Transition workflow and step execution states
- Ensure workflow always returns to 'ready' state

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

        # Don't execute if scheduled for future
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

**Key Responsibilities:**
- Load StepExecution by ID (idempotency key)
- Check execution state (idempotency guard)
- Delegate to StepExecution#execute!
- Handle missing records gracefully

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

**Key Responsibilities:**
- Provide flow control DSL within steps
- Use throw/catch for non-local returns (like Rails redirect)
- Pass options (wait time for reattempt!)

---

## Execution Flow

### 1. Creating and Starting a Workflow

```ruby
# User code
workflow = SignupWorkflow.create!(subject: current_user)

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

### 3. Step Execution

```ruby
# StepExecution#execute! -> Executor#execute!
# 1. Lock step execution, transition to 'executing'
# 2. Transition workflow to 'performing'
# 3. Check cancel_if conditions
# 4. Call before_step_starts hook
# 5. Execute step block (catch flow control signals)
# 6. Handle result:
#    - :completed -> mark step completed, schedule next step
#    - :cancel -> mark step canceled, cancel workflow
#    - :reattempt -> mark step completed, reschedule same step
#    - :skip -> mark step skipped, schedule next step
#    - exception -> mark step failed, pause workflow
# 7. Transition workflow back to 'ready' (in ensure)
```

### 4. Scheduling Next Step

```ruby
# Scheduler#schedule_next_step!
# 1. Find next step definition in order
# 2. Skip any conditional steps (skip_if)
# 3. Create new StepExecution for that step
# 4. Update workflow.current_step_name
# 5. Enqueue PerformStepJob with wait time
```

### 5. Workflow Completion

```ruby
# When no next step to schedule:
# - Workflow transitions to 'finished'
# - finished_at timestamp set
# - No more step executions created
```

---

## Idempotency Guarantees

### 1. Job-level Idempotency
- PerformStepJob receives `step_execution_id`, not `workflow_id`
- If job retries, it checks `step_execution.state == 'scheduled'`
- If already executing/completed, job returns early

### 2. Step Execution Uniqueness
- Database constraint ensures only one active step execution per workflow
- Cannot create second scheduled/executing step while one exists

### 3. State Transitions are Locked
- `with_lock` ensures atomic state changes
- No race conditions between concurrent job attempts

### 4. Workflow State Machine
- Only transitions through valid states
- performing → ready happens in ensure block

---

## Feature Parity Checklist

### Core Features
- [ ] ActiveRecord-backed workflows (STI)
- [ ] Polymorphic subject association
- [ ] Step DSL (named and anonymous)
- [ ] Wait times between steps
- [ ] State machine (ready/performing/finished/canceled/paused)
- [ ] Lock-guarded execution
- [ ] Single execution guarantee per workflow

### Step Definition
- [ ] Named steps with blocks
- [ ] Anonymous steps with auto-naming
- [ ] Instance method steps (`step :method_name`)
- [ ] Inline method definition (`step def method_name`)
- [ ] Step ordering (before_step/after_step)

### Conditional Logic
- [ ] skip_if with symbols/callables/booleans
- [ ] cancel_if for blanket conditions
- [ ] Class-inheritable cancel_if

### Flow Control
- [ ] cancel! - mark workflow canceled
- [ ] pause! - pause for manual intervention
- [ ] reattempt! - retry current step with optional wait
- [ ] skip! - skip current/next step
- [ ] finished! - mark workflow complete

### Scheduling
- [ ] Forward scheduler (enqueue jobs early)
- [ ] No cyclic scheduler (excluded from design)

### ActiveJob Integration
- [ ] PerformStepJob for step execution
- [ ] set_step_job_options for queue/priority
- [ ] step_job_options_for_next_step hook

### Exception Handling
- [ ] on_exception: :pause! (default)
- [ ] on_exception: :cancel!
- [ ] on_exception: :reattempt!
- [ ] Store error message/backtrace

### Uniqueness
- [ ] One workflow per subject by default
- [ ] allow_multiple flag for concurrent workflows
- [ ] Database-enforced constraints (PostgreSQL, MySQL, SQLite)

### Querying
- [ ] presence_sql_for(model) helper
- [ ] State scopes (ready, paused, etc.)
- [ ] for_subject scope

### Hooks & Callbacks
- [ ] before_step_starts(step_name)

### Rails Integration
- [ ] Generator for installation
- [ ] Migration templates with database detection
- [ ] UUID support flag
- [ ] Configuration initializer

### Testing
- [ ] speedrun_workflow helper
- [ ] Reload between steps in tests

---

## API Examples

### Basic Usage

```ruby
class SignupWorkflow < GenevaDrive::Workflow
  step :send_welcome_email do
    WelcomeMailer.welcome(subject).deliver_later
  end

  step :send_reminder, wait: 2.days do
    ReminderMailer.remind(subject).deliver_later
  end

  step :complete_onboarding, wait: 7.days do
    subject.update!(onboarding_completed: true)
  end
end

# Create workflow
SignupWorkflow.create!(subject: current_user)
```

### Advanced Features

```ruby
class OnboardingWorkflow < GenevaDrive::Workflow
  # Blanket cancellation conditions
  cancel_if { subject.deactivated? }
  cancel_if :account_closed?

  # Custom queue and priority
  set_step_job_options queue: :critical, priority: 0

  # Conditional steps
  step :setup_profile, skip_if: -> { subject.profile.present? } do
    ProfileBuilder.build(subject)
  end

  # Step ordering
  step :send_email, after_step: :setup_profile, wait: 1.hour do
    OnboardingMailer.welcome(subject).deliver_later
  end

  # Exception handling with retry
  step :call_api, on_exception: :reattempt! do
    ExternalAPI.provision(subject)
  rescue RateLimitError => e
    reattempt!(wait: e.retry_after)
  rescue InvalidDataError => e
    cancel! # Unrecoverable error
  end

  # Progress tracking
  def before_step_starts(step_name)
    subject.update(onboarding_step: step_name)
    NotificationService.broadcast_progress(subject, step_name)
  end
end
```

### Polling Pattern

```ruby
class CheckResponseWorkflow < GenevaDrive::Workflow
  # Check within the first hour
  step(wait: 5.minutes) { check_for_response }

  # Check every 2 hours for the first day
  12.times do
    step(wait: 2.hours) { check_for_response }
  end

  # Check once a day after the first day
  7.times do
    step(wait: 1.day) { check_for_response }
  end

  def check_for_response
    cancel! if subject.response.present?
    CheckResponseJob.perform_later(subject.id)
  end
end
```

### Complex Multi-Step Process

```ruby
class EmailProcessingWorkflow < GenevaDrive::Workflow
  cancel_if { subject.nil? }

  step :classify_email do
    classification = ClassifierService.new(subject).run
    subject.update!(
      category: classification.category,
      needs_response: classification.needs_response
    )
  end

  step :generate_summary, skip_if: -> { !subject.needs_summary? } do
    SummarizeEmailJob.perform_now(subject.id)
  end

  step :create_embeddings, skip_if: -> { subject.archived? } do
    EmbedEmailBodyJob.perform_now(subject.id)
  end

  step :generate_response, skip_if: -> { !subject.needs_response? } do
    GenerateResponseJob.perform_now(subject.id)
  end

  step :sync_with_external do
    SyncExternalSystemJob.perform_now(subject.id)
  end
end
```

---

## Testing

### RSpec Example

```ruby
RSpec.describe SignupWorkflow do
  describe 'execution' do
    it 'completes all steps in order' do
      user = create(:user)
      workflow = SignupWorkflow.create!(subject: user)

      # Fast-forward through all steps
      speedrun_workflow(workflow)

      expect(workflow.reload).to be_finished
      expect(workflow.execution_history.count).to eq(3)
      expect(workflow.execution_history.pluck(:step_name)).to eq([
        'send_welcome_email',
        'send_reminder',
        'complete_onboarding'
      ])
    end

    it 'handles cancellation' do
      user = create(:user)
      workflow = SignupWorkflow.create!(subject: user)

      # Deactivate user before first step completes
      user.update!(deactivated: true)

      perform_enqueued_jobs

      expect(workflow.reload).to be_canceled
    end
  end
end
```

---

## Migration Generator

### Installation

```bash
# Generate migrations
rails generate geneva_drive:install

# With UUID support
rails generate geneva_drive:install --uuid

# Run migrations
rails db:migrate
```

### Generated Files

```
db/migrate/
  20240101000000_create_geneva_drive_workflows.rb
  20240101000001_create_geneva_drive_step_executions.rb
config/initializers/
  geneva_drive.rb
```

---

## Configuration

```ruby
# config/initializers/geneva_drive.rb
GenevaDrive.configure do |config|
  # Configure default job options
  config.default_job_options = { queue: :workflows }

  # Configure logging
  config.logger = Rails.logger
end
```

---

## Database Support Summary

| Feature | PostgreSQL | MySQL | SQLite |
|---------|-----------|-------|--------|
| Uniqueness Constraints | Partial Index | Generated Column | Partial Index |
| Performance | Excellent | Good | Good |
| Concurrent Access | Excellent | Good | Limited |
| Production Ready | ✅ Yes | ✅ Yes | ⚠️ Dev/Test Only |

**Recommendation**: Use PostgreSQL in production for best performance and concurrency.
