# frozen_string_literal: true

require "test_helper"

class WithInlineEnqueueTest < ActiveSupport::TestCase
  class SimpleWorkflow < GenevaDrive::Workflow
    step :step_one do
      # Just a simple step
    end
  end

  setup do
    @user = create_user
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
