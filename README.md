# GenevaDrive

Durable workflows for Rails applications.

GenevaDrive provides a clean DSL for defining multi-step workflows that execute asynchronously, with strong guarantees around idempotency, concurrency control, and state management.

## Features

- **Hero-oriented**: Workflows are associated with a polymorphic "hero" (the subject of the workflow)
- **Step-based execution**: Define workflows as a series of steps with optional wait times
- **Durable**: Steps are persisted to the database, surviving process restarts
- **Idempotent**: Database constraints ensure each step runs exactly once
- **Flow control**: Methods like `cancel!`, `pause!`, `skip!`, `reattempt!`, and `finished!`
- **Exception handling**: Configure per-step exception behavior
- **Multi-database support**: PostgreSQL, MySQL, and SQLite

## Installation

Add this line to your application's Gemfile:

```ruby
gem "geneva_drive"
```

Then install the gem and run the generator:

```bash
bundle install
bin/rails generate geneva_drive:install
bin/rails db:migrate
```

You should also add the housekeeping job to your background job cron table
(below example is for `recurring.yml` in solid_queue):

```yaml
geneva_drive_housekeeping:
  schedule: "*/30 * * * *" # Every 30 minutes
  class: "GenevaDrive::HousekeepingJob"
```



## Usage

### Defining a Workflow

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
```

### Starting a Workflow

```ruby
SignupWorkflow.create!(hero: current_user)
```

### Flow Control

Use flow control methods inside steps to control workflow execution:

```ruby
class PaymentWorkflow < GenevaDrive::Workflow
  step :process_payment do
    result = PaymentGateway.charge(hero)

    case result.status
    when :success
      # Continues to next step
    when :declined
      cancel!  # Workflow canceled
    when :rate_limited
      reattempt!(wait: 5.minutes)  # Retry later
    when :pending
      pause!  # Wait for manual intervention
    end
  end

  step :send_receipt do
    ReceiptMailer.send_receipt(hero).deliver_later
  end
end
```

### Conditional Steps

Skip steps based on conditions:

```ruby
class TrialWorkflow < GenevaDrive::Workflow
  step :send_trial_email do
    TrialMailer.start(hero).deliver_later
  end

  step :charge_card, skip_if: -> { hero.free_tier? } do
    PaymentGateway.charge(hero)
  end

  step :activate_account do
    hero.activate!
  end
end
```

### Blanket Conditions

Cancel workflow if conditions become true:

```ruby
class OnboardingWorkflow < GenevaDrive::Workflow
  cancel_if { hero.deactivated? }
  cancel_if { hero.deleted_at.present? }

  step :step_one do
    # Won't run if hero is deactivated
  end
end
```

### Exception Handling

Configure how exceptions are handled per step:

```ruby
class RobustWorkflow < GenevaDrive::Workflow
  # Retry on any error (default: pause!)
  step :flaky_api, on_exception: :reattempt! do
    ExternalApi.call(hero)
  end

  # Skip step if it fails (non-critical)
  step :send_notification, on_exception: :skip! do
    NotificationService.notify(hero)
  end

  # Cancel workflow if critical step fails
  step :critical_operation, on_exception: :cancel! do
    CriticalService.process(hero)
  end
end
```

### Workflow Inheritance

```ruby
class BaseWorkflow < GenevaDrive::Workflow
  cancel_if { hero.deactivated? }
  set_step_job_options queue: :workflows
end

class PremiumWorkflow < BaseWorkflow
  cancel_if { hero.subscription_expired? }
  set_step_job_options queue: :premium, priority: 10

  step :premium_feature do
    # Inherits cancel_if from parent
  end
end
```

### Hero Deletion Handling

By default, workflows cancel if their hero is deleted:

```ruby
# Default: auto-cancel if hero is deleted
class PaymentWorkflow < GenevaDrive::Workflow
  step :charge do
    hero.charge!  # Won't run if hero was deleted
  end
end

# Allow workflow to continue without hero
class CleanupWorkflow < GenevaDrive::Workflow
  may_proceed_without_hero!

  step :cleanup do
    DataArchive.cleanup(hero&.id)
  end
end
```

### Resuming Paused Workflows

```ruby
# Find and resume paused workflows
PaymentWorkflow.paused.find_each(&:resume!)
```

### Querying Workflows

```ruby
# By state
SignupWorkflow.ready
SignupWorkflow.performing
SignupWorkflow.finished
SignupWorkflow.canceled
SignupWorkflow.paused
SignupWorkflow.ongoing  # Not finished or canceled

# By hero
SignupWorkflow.for_hero(user)
```

### Execution History

```ruby
workflow = SignupWorkflow.find(123)

workflow.execution_history.each do |execution|
  puts "#{execution.step_name}: #{execution.state} (#{execution.outcome})"
  puts "  Error: #{execution.error_message}" if execution.error_message
end
```

## Testing

Include `GenevaDrive::TestHelpers` in your tests:

```ruby
class SignupWorkflowTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  test "completes all steps" do
    workflow = SignupWorkflow.create!(hero: users(:one))
    speedrun_workflow(workflow)

    assert_workflow_state(workflow, :finished)
    assert_step_executed(workflow, :send_welcome_email)
    assert_step_executed(workflow, :send_reminder)
  end

  test "step-by-step execution" do
    workflow = SignupWorkflow.create!(hero: users(:one))

    perform_next_step(workflow)
    assert_equal "send_reminder", workflow.current_step_name

    perform_next_step(workflow)
    assert_equal "complete_onboarding", workflow.current_step_name
  end
end
```

## Database Support

| Feature | PostgreSQL | MySQL | SQLite |
|---------|-----------|-------|--------|
| Workflow Uniqueness | Partial Index | Generated Column | Partial Index |
| Step Execution Uniqueness | Partial Index | Generated Column | Partial Index |

## Requirements

- Ruby 3.0+
- Rails 7.2.2+

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
