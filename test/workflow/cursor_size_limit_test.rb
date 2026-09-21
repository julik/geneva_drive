# frozen_string_literal: true

require "test_helper"

class CursorSizeLimitTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class PayloadCursorWorkflow < GenevaDrive::Workflow
    resumable_step :process do |iter|
      iter.set!(Thread.current[:cursor_payload])
    end
  end

  setup do
    @user = create_user
    @original_limit = GenevaDrive.max_cursor_size
  end

  teardown do
    GenevaDrive.max_cursor_size = @original_limit
    Thread.current[:cursor_payload] = nil
  end

  test "defaults to 128 KB" do
    assert_equal 128 * 1024, GenevaDrive.max_cursor_size
  end

  test "an oversized cursor raises CursorTooLargeError and pauses the workflow" do
    GenevaDrive.max_cursor_size = 1024
    Thread.current[:cursor_payload] = "x" * 2048

    workflow = PayloadCursorWorkflow.create!(hero: @user)

    error = assert_raises(GenevaDrive::CursorTooLargeError) { perform_next_step(workflow) }
    assert_match(/max_cursor_size/, error.message)

    workflow.reload
    assert_equal "paused", workflow.state
  end

  test "a cursor under the limit passes" do
    GenevaDrive.max_cursor_size = 1024
    Thread.current[:cursor_payload] = "x" * 100

    workflow = PayloadCursorWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    assert_equal "finished", workflow.state
  end

  test "a nil limit disables the check" do
    GenevaDrive.max_cursor_size = nil
    Thread.current[:cursor_payload] = "x" * (256 * 1024)

    workflow = PayloadCursorWorkflow.create!(hero: @user)
    speedrun_workflow(workflow)

    assert_equal "finished", workflow.state
  end

  test "cursor_value= enforces the limit too" do
    GenevaDrive.max_cursor_size = 1024

    workflow = PayloadCursorWorkflow.create!(hero: @user)
    execution = workflow.current_execution

    assert_raises(GenevaDrive::CursorTooLargeError) do
      execution.cursor_value = "x" * 2048
    end

    execution.cursor_value = "x" * 100
    execution.save!
    assert_equal "x" * 100, execution.reload.cursor_value
  end
end
