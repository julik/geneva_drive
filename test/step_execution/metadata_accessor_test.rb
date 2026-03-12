# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class MetadataAccessorTest < ActiveSupport::TestCase
  test "metadata_column? detects the column lazily" do
    GenevaDrive::StepExecution.reset_metadata_column_cache!
    assert GenevaDrive::StepExecution.metadata_column?
  end

  test "write_metadata and read_metadata round-trip a value" do
    user = create_user
    workflow = SimpleWorkflow.create!(hero: user)
    execution = workflow.step_executions.last

    execution.write_metadata("reattempt_reason", "exception_policy")
    execution.save!
    execution.reload

    assert_equal "exception_policy", execution.read_metadata("reattempt_reason")
  end

  test "read_metadata returns nil for absent keys" do
    user = create_user
    workflow = SimpleWorkflow.create!(hero: user)
    execution = workflow.step_executions.last

    assert_nil execution.read_metadata("nonexistent")
  end

  test "reattempt_reason convenience reader delegates to read_metadata" do
    user = create_user
    workflow = SimpleWorkflow.create!(hero: user)
    execution = workflow.step_executions.last

    execution.write_metadata("reattempt_reason", "flow_control")
    assert_equal "flow_control", execution.reattempt_reason
  end

  test "write_metadata is a no-op without the column" do
    GenevaDrive::StepExecution.stub(:metadata_column?, false) do
      user = create_user
      workflow = SimpleWorkflow.create!(hero: user)
      execution = workflow.step_executions.last

      # Should not raise, and should not persist anything
      execution.write_metadata("reattempt_reason", "exception_policy")
      assert_nil execution.read_metadata("reattempt_reason")
    end
  end

  test "read_metadata returns nil without the column" do
    GenevaDrive::StepExecution.stub(:metadata_column?, false) do
      user = create_user
      workflow = SimpleWorkflow.create!(hero: user)
      execution = workflow.step_executions.last

      assert_nil execution.read_metadata("reattempt_reason")
    end
  end

  test "reattempt_reason returns nil without the column" do
    GenevaDrive::StepExecution.stub(:metadata_column?, false) do
      user = create_user
      workflow = SimpleWorkflow.create!(hero: user)
      execution = workflow.step_executions.last

      assert_nil execution.reattempt_reason
    end
  end

  test "exception_info is double-written into metadata on step failure" do
    user = create_user
    workflow = FailingWorkflow.create!(hero: user)

    assert_raises(FailingWorkflow::TestError) do
      GenevaDrive::Executor.execute!(workflow.step_executions.scheduled.last)
    end
    workflow.reload

    # The reattempted execution should have exception info in metadata
    execution = workflow.step_executions.order(:created_at).first
    info = execution.exception_info
    assert_equal "MetadataAccessorTest::FailingWorkflow::TestError", info["class"]
    assert_equal "boom", info["message"]
    assert_kind_of Array, info["backtrace"]
  end

  test "exception_info returns nil without the column" do
    GenevaDrive::StepExecution.stub(:metadata_column?, false) do
      user = create_user
      workflow = SimpleWorkflow.create!(hero: user)
      execution = workflow.step_executions.last

      assert_nil execution.exception_info
    end
  end

  test "consecutive reattempt count includes flow_control reattempts without metadata column" do
    GenevaDrive::StepExecution.stub(:metadata_column?, false) do
      user = create_user
      workflow = FailingWorkflow.create!(hero: user)

      # Create some reattempted step executions with flow_control reason
      # (but since metadata_column? is false, the reason won't be written)
      3.times do
        assert_raises(FailingWorkflow::TestError) do
          GenevaDrive::Executor.execute!(workflow.step_executions.scheduled.last)
        end
        workflow.reload
      end

      # With max_reattempts: 5, but metadata unavailable, the coarser counting
      # will count ALL reattempts including what would have been flow_control ones.
      # The workflow should still be ready (3 reattempts < 5 max).
      assert_equal "ready", workflow.state
    end
  end

  setup do
    GenevaDrive::StepExecution.reset_metadata_column_cache!
  end

  teardown do
    GenevaDrive::StepExecution.reset_metadata_column_cache!
  end

  private

  # Minimal workflow for creating step executions
  class SimpleWorkflow < GenevaDrive::Workflow
    step :first_step do
      # noop
    end
  end

  class FailingWorkflow < GenevaDrive::Workflow
    class TestError < StandardError; end

    on_exception :reattempt!, max_reattempts: 5

    step :failing_step do
      raise TestError, "boom"
    end
  end
end
