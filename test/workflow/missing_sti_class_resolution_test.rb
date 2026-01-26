# frozen_string_literal: true

require "test_helper"

class MissingStiClassResolutionTest < ActiveSupport::TestCase
  # A valid workflow subclass for testing STI resolution
  class ValidTestWorkflow < GenevaDrive::Workflow
    step :test_step do
      # Just a test step
    end
  end

  setup do
    @user = create_user
  end

  test "find_sti_class falls back to base Workflow when subclass no longer exists" do
    # Create a workflow with a type that doesn't exist as a Ruby class
    workflow = GenevaDrive::Workflow.create!(
      type: "DeletedOrRenamedWorkflow",
      hero: @user
    )

    # Reload from database - this would raise ActiveRecord::SubclassNotFound
    # without the fallback behavior
    reloaded = GenevaDrive::Workflow.find(workflow.id)

    assert_equal GenevaDrive::Workflow, reloaded.class
    assert_equal "DeletedOrRenamedWorkflow", reloaded.type
  end

  test "find_sti_class still resolves valid subclasses normally" do
    workflow = ValidTestWorkflow.create!(hero: @user)

    reloaded = GenevaDrive::Workflow.find(workflow.id)

    assert_equal ValidTestWorkflow, reloaded.class
    assert_equal "MissingStiClassResolutionTest::ValidTestWorkflow", reloaded.type
  end
end
