# frozen_string_literal: true

require "test_helper"

class StepSourceLocationTrackingTest < ActiveSupport::TestCase
  # Define a test workflow with steps to verify source location tracking
  class LocationTestWorkflow < GenevaDrive::Workflow
    step :inline_step do
      # This step has an inline block
    end

    step :method_step

    def method_step
      # This step uses a method reference
    end
  end

  test "step definition captures call location" do
    step_def = LocationTestWorkflow.step_definitions.find { |s| s.name == "inline_step" }

    assert_not_nil step_def.call_location, "call_location should be set"
    assert_kind_of Array, step_def.call_location
    assert_equal 2, step_def.call_location.length

    file, line = step_def.call_location
    assert file.end_with?("step_definition_source_location_test.rb"), "should capture the test file path"
    assert_kind_of Integer, line
    assert line > 0
  end

  test "step definition captures block location for inline blocks" do
    step_def = LocationTestWorkflow.step_definitions.find { |s| s.name == "inline_step" }

    assert_not_nil step_def.block_location, "block_location should be set for inline blocks"
    assert_kind_of Array, step_def.block_location
    assert_equal 2, step_def.block_location.length

    file, line = step_def.block_location
    assert file.end_with?("step_definition_source_location_test.rb")
    assert_kind_of Integer, line
  end

  test "step definition has nil block_location for method-based steps" do
    step_def = LocationTestWorkflow.step_definitions.find { |s| s.name == "method_step" }

    assert_not_nil step_def.call_location, "call_location should still be set"
    assert_nil step_def.block_location, "block_location should be nil when no block is provided"
  end

  test "call_location and block_location may differ for inline blocks" do
    step_def = LocationTestWorkflow.step_definitions.find { |s| s.name == "inline_step" }

    # call_location is where `step :name do` is written
    # block_location is where the block's code starts (may be same line or different)
    # Both should reference the same file in this test
    assert_equal step_def.call_location.first, step_def.block_location.first
  end
end
