# frozen_string_literal: true

require "test_helper"

# Deployments usually ship gem updates before running migrations. Everything
# except actually executing a resumable_step must keep working when the
# cursor and continues_from_id columns are absent (simulated here by
# stubbing the column detection, like the metadata column tests do).
class ResumableWithoutMigrationTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class PlainWorkflow < GenevaDrive::Workflow
    step :one do
      Thread.current[:no_mig_one_ran] = true
    end

    step :two do
      Thread.current[:no_mig_two_ran] = true
    end
  end

  class FailingOnceWorkflow < GenevaDrive::Workflow
    step :flaky do
      raise "boom" unless Thread.current[:no_mig_flaky_healed]
      Thread.current[:no_mig_flaky_ran] = true
    end
  end

  class ResumableWorkflow < GenevaDrive::Workflow
    resumable_step :iterate do |iter|
      iter.iterate_over([1, 2, 3]) { |item| }
    end
  end

  setup do
    @user = create_user
    reset_thread_tracking!
  end

  teardown do
    reset_thread_tracking!
  end

  def reset_thread_tracking!
    %i[no_mig_one_ran no_mig_two_ran no_mig_flaky_healed no_mig_flaky_ran].each do |key|
      Thread.current[key] = nil
    end
  end

  test "regular workflows run to completion without the resumable columns" do
    GenevaDrive::StepExecution.stub(:resumable_columns?, false) do
      workflow = PlainWorkflow.create!(hero: @user)
      speedrun_workflow(workflow)

      assert_equal "finished", workflow.state
      assert Thread.current[:no_mig_one_ran]
      assert Thread.current[:no_mig_two_ran]
    end
  end

  test "pause and resume of regular workflows work without the resumable columns" do
    GenevaDrive::StepExecution.stub(:resumable_columns?, false) do
      workflow = FailingOnceWorkflow.create!(hero: @user)

      assert_raises(RuntimeError) { perform_next_step(workflow) }
      workflow.reload
      assert_equal "paused", workflow.state

      Thread.current[:no_mig_flaky_healed] = true
      workflow.resume!
      speedrun_workflow(workflow)

      assert_equal "finished", workflow.state
      assert Thread.current[:no_mig_flaky_ran]
    end
  end

  test "executing a resumable step without the columns fails with a clear error" do
    GenevaDrive::StepExecution.stub(:resumable_columns?, false) do
      workflow = ResumableWorkflow.create!(hero: @user)

      error = assert_raises(GenevaDrive::StepConfigurationError) { perform_next_step(workflow) }
      assert_match(/geneva_drive:install/, error.message)

      workflow.reload
      assert_equal "paused", workflow.state
      failed = workflow.step_executions.find_by(state: "failed")
      assert_not_nil failed
      assert_match(/resumable_step/, failed.error_message)
    end
  end

  test "cursor accessors degrade safely without the columns" do
    workflow = ResumableWorkflow.create!(hero: @user)
    execution = workflow.current_execution

    GenevaDrive::StepExecution.stub(:resumable_columns?, false) do
      execution.cursor_value = 42
      assert_nil execution.cursor_value
      assert_not execution.resuming?
    end
  end
end
