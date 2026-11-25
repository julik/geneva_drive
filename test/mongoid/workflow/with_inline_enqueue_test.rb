# frozen_string_literal: true

# Mongoid tests run only under `rake test:mongoid`, which boots the dummy app
# against MongoDB (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"

class WithInlineEnqueueTest < ActiveSupport::TestCase
  class SimpleWorkflow < GenevaDrive::MongoidWorkflow
    step :step_one do
      # Just a simple step
    end
  end

  setup do
    @user = create_user
  end

  test "with_inline_enqueue cannot force enqueues inside an open transaction - deferral is mandatory there" do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    enqueued_inside = nil

    GenevaDrive.with_inline_enqueue do
      GenevaDrive::MongoidWorkflow.with_session do |session|
        session.with_transaction do
          SimpleWorkflow.create!(hero: @user)
          enqueued_inside = ActiveJob::Base.queue_adapter.enqueued_jobs.size
        end
      end
    end

    assert_equal 0, enqueued_inside,
      "with_inline_enqueue must not enqueue inside an open transaction on MongoDB"
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size,
      "the enqueue must still happen, exactly once, at the commit"
  end

  test "with_inline_enqueue cannot bypass the gem's own lock transaction deferral" do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    # create! opens GenevaDrive's own lock transaction; the enqueue must ride
    # its commit regardless of the inline flag - but since the lock commits
    # before create! returns, the job is there right after.
    GenevaDrive.with_inline_enqueue do
      SimpleWorkflow.create!(hero: @user)
    end

    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end

  test "enqueues_deferred? returns false in test environment by default" do
    # In test environment, enqueue_after_commit is false by default
    assert_not GenevaDrive.enqueues_deferred?
  end

  test "enqueues_deferred? returns true when enqueue_after_commit is true" do
    original = GenevaDrive.enqueue_after_commit

    begin
      GenevaDrive.enqueue_after_commit = true
      assert GenevaDrive.enqueues_deferred?
    ensure
      GenevaDrive.enqueue_after_commit = original
    end
  end

  test "with_inline_enqueue block causes enqueues_deferred? to return false" do
    original = GenevaDrive.enqueue_after_commit

    begin
      GenevaDrive.enqueue_after_commit = true
      assert GenevaDrive.enqueues_deferred?

      GenevaDrive.with_inline_enqueue do
        assert_not GenevaDrive.enqueues_deferred?
      end

      # After the block, it should be restored
      assert GenevaDrive.enqueues_deferred?
    ensure
      GenevaDrive.enqueue_after_commit = original
    end
  end

  test "with_inline_enqueue restores previous state even on exception" do
    original = GenevaDrive.enqueue_after_commit

    begin
      GenevaDrive.enqueue_after_commit = true

      assert_raises(RuntimeError) do
        GenevaDrive.with_inline_enqueue do
          assert_not GenevaDrive.enqueues_deferred?
          raise "test error"
        end
      end

      # Should be restored after exception
      assert GenevaDrive.enqueues_deferred?
    ensure
      GenevaDrive.enqueue_after_commit = original
    end
  end

  test "with_inline_enqueue can be nested" do
    original = GenevaDrive.enqueue_after_commit

    begin
      GenevaDrive.enqueue_after_commit = true

      GenevaDrive.with_inline_enqueue do
        assert_not GenevaDrive.enqueues_deferred?

        GenevaDrive.with_inline_enqueue do
          assert_not GenevaDrive.enqueues_deferred?
        end

        # Still false after inner block
        assert_not GenevaDrive.enqueues_deferred?
      end

      # Restored after outer block
      assert GenevaDrive.enqueues_deferred?
    ensure
      GenevaDrive.enqueue_after_commit = original
    end
  end

  test "run_after_commit yields immediately inside with_inline_enqueue block" do
    original = GenevaDrive.enqueue_after_commit

    begin
      GenevaDrive.enqueue_after_commit = true
      workflow = SimpleWorkflow.new(hero: @user)

      executed = false
      GenevaDrive.with_inline_enqueue do
        workflow.send(:run_after_commit) { executed = true }
      end

      assert executed, "Block should execute immediately inside with_inline_enqueue"
    ensure
      GenevaDrive.enqueue_after_commit = original
    end
  end

  test "workflow can be created inside with_inline_enqueue block" do
    original = GenevaDrive.enqueue_after_commit

    begin
      GenevaDrive.enqueue_after_commit = true

      workflow = nil
      GenevaDrive.with_inline_enqueue do
        workflow = SimpleWorkflow.create!(hero: @user)
      end

      assert_equal "ready", workflow.state
      assert_equal 1, workflow.step_executions.count
    ensure
      GenevaDrive.enqueue_after_commit = original
    end
  end

  test "with_inline_enqueue returns the block result" do
    result = GenevaDrive.with_inline_enqueue do
      42
    end

    assert_equal 42, result
  end
end
