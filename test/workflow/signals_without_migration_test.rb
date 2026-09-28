# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Deployments usually ship gem updates before running migrations. Everything
# except actually waiting for a signal must keep working when the signal_id
# and waiting_since columns are absent (simulated here by stubbing the column
# detection, like the resumable step tests do).
class SignalsWithoutMigrationTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class PlainWorkflow < GenevaDrive::Workflow
    step :one do
      Thread.current[:no_sig_one_ran] = true
    end

    step :two do
      Thread.current[:no_sig_two_ran] = true
    end
  end

  class WaitingWorkflow < GenevaDrive::Workflow
    step :await_payment, wait_for: :payment_confirmed do
      Thread.current[:no_sig_waited] = true
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
    %i[no_sig_one_ran no_sig_two_ran no_sig_waited].each { |key| Thread.current[key] = nil }
  end

  test "regular workflows run to completion without the signal columns" do
    GenevaDrive::StepExecution.stub(:signal_columns?, false) do
      workflow = PlainWorkflow.create!(hero: @user)
      speedrun_workflow(workflow)

      assert_equal "finished", workflow.state
      assert Thread.current[:no_sig_one_ran]
      assert Thread.current[:no_sig_two_ran]
    end
  end

  test "executing a waiting step without the columns fails with a clear error" do
    GenevaDrive::StepExecution.stub(:signal_columns?, false) do
      workflow = WaitingWorkflow.create!(hero: @user)

      error = assert_raises(GenevaDrive::StepConfigurationError) { perform_next_step(workflow) }
      assert_match(/geneva_drive:install/, error.message)

      workflow.reload
      assert_equal "paused", workflow.state
      failed = workflow.step_executions.find_by(state: "failed")
      assert_not_nil failed
      assert_match(/wait_for:/, failed.error_message)
      assert_not Thread.current[:no_sig_waited]
    end
  end

  test "signal! still records the event without the columns, it just cannot dispatch" do
    workflow = WaitingWorkflow.create!(hero: @user)

    GenevaDrive::StepExecution.stub(:signal_columns?, false) do
      signal = workflow.signal!(:payment_confirmed, payload: {amount_cents: 1})

      assert signal.persisted?
      assert_equal "pending", signal.reload.state
    end
  end

  test "housekeeping skips the waiting gauges without the columns" do
    GenevaDrive::StepExecution.stub(:signal_columns?, false) do
      assert_nothing_raised { GenevaDrive::HousekeepingJob.perform_now }
    end
  end

  test "housekeeping skips the signal delete pass without the signals table" do
    original = GenevaDrive.delete_completed_workflows_after
    GenevaDrive.delete_completed_workflows_after = 30.days

    GenevaDrive::Signal.stub(:table_available?, false) do
      results = GenevaDrive::HousekeepingJob.perform_now
      assert_equal 0, results[:signals_cleaned_up]
    end
  ensure
    GenevaDrive.delete_completed_workflows_after = original
  end
end
