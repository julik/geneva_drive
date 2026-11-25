# frozen_string_literal: true

# Mongoid tests run only under `rake test:mongoid`, which boots the dummy app
# against MongoDB (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"

# After-commit parity for transactions the CALLER owns. When GenevaDrive's
# lock joins an ambient session transaction, the enqueues must still wait for
# that transaction's commit - and vanish with its abort. Uses the raw
# with_session/with_transaction form deliberately: it is the only ambient
# style Mongoid 8 has.
class AmbientTransactionAfterCommitTest < ActiveSupport::TestCase
  class OneStepWorkflow < GenevaDrive::MongoidWorkflow
    step :only_step do
      # Just a simple step
    end
  end

  setup do
    @user = create_user
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  test "no job is enqueued while the caller's transaction is open, exactly one after its commit" do
    enqueued_inside = nil
    workflow = nil

    GenevaDrive::MongoidWorkflow.with_session do |session|
      session.with_transaction do
        workflow = OneStepWorkflow.create!(hero: @user)
        enqueued_inside = ActiveJob::Base.queue_adapter.enqueued_jobs.size
      end
    end

    assert_equal 0, enqueued_inside,
      "the step job must not be enqueued while the caller's transaction is still open"

    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    assert_equal 1, jobs.size, "exactly one job must be enqueued at the caller's commit"
    assert_equal "GenevaDrive::PerformStepJob", jobs.first[:job].name
    assert_equal "scheduled", workflow.reload.current_execution.state
  end

  test "nested gem lock sections inside the caller's transaction do not double-flush" do
    GenevaDrive::MongoidWorkflow.with_session do |session|
      session.with_transaction do
        # Each create! runs its own (joined) lock section with its own
        # run_after_commit registration - two workflows, two callbacks, and
        # they must fire exactly once each at the one commit.
        OneStepWorkflow.create!(hero: @user)
        OneStepWorkflow.create!(hero: create_user(email: "second@example.com"))
      end
    end

    assert_equal 2, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end

  test "aborting the caller's transaction discards the enqueues along with the rows" do
    GenevaDrive::MongoidWorkflow.with_session do |session|
      session.with_transaction do
        OneStepWorkflow.create!(hero: @user)
        session.abort_transaction
      end
    end

    assert_equal 0, GenevaDrive::MongoidWorkflow.count,
      "the aborted transaction must not leave a workflow behind"
    assert_equal 0, ActiveJob::Base.queue_adapter.enqueued_jobs.size,
      "the aborted transaction must not leave an enqueued job behind"
  end

  test "an exception aborting the caller's transaction discards the enqueues" do
    marker_error = Class.new(StandardError)

    assert_raises(marker_error) do
      GenevaDrive::MongoidWorkflow.with_session do |session|
        session.with_transaction do
          OneStepWorkflow.create!(hero: @user)
          raise marker_error, "caller aborts"
        end
      end
    end

    assert_equal 0, GenevaDrive::MongoidWorkflow.count
    assert_equal 0, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end
end
