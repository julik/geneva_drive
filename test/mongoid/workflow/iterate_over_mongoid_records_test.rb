# frozen_string_literal: true

# Mongoid tests run only under `rake test:mongoid`, which boots the dummy app
# against MongoDB (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"

# IterableStep's record iteration over a Mongoid criteria: the _id cursor,
# the interruption/successor chain (which sends a BSON::ObjectId cursor
# through ActiveJob serialization and back), and the batched subrelation
# variant.
class IterateOverMongoidRecordsTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class SweepUsersWorkflow < GenevaDrive::MongoidWorkflow
    resumable_step :sweep, max_iterations: 2 do |iter|
      iter.iterate_over_records(MongoUser.all) do |user|
        Thread.current[:swept_emails] << user.email
      end
    end
  end

  class BatchSweepUsersWorkflow < GenevaDrive::MongoidWorkflow
    resumable_step :sweep_batches do |iter|
      iter.iterate_over_subrelations(MongoUser.all, batch_size: 2) do |batch|
        Thread.current[:swept_batches] << batch.pluck(:email).sort
      end
    end
  end

  setup do
    Thread.current[:swept_emails] = []
    Thread.current[:swept_batches] = []
  end

  teardown do
    Thread.current[:swept_emails] = nil
    Thread.current[:swept_batches] = nil
  end

  test "iterate_over_records sweeps a criteria once across interruptions, cursoring on _id" do
    hero = create_user
    4.times { |i| MongoUser.create!(email: "sweep-#{i}@example.com", name: "Sweep #{i}") }

    workflow = SweepUsersWorkflow.create!(hero: hero)
    perform_enqueued_jobs_now

    assert_equal "finished", workflow.reload.state
    assert_equal MongoUser.all.pluck(:email).sort, Thread.current[:swept_emails].sort

    # max_iterations: 2 over five users forces interruptions, so the sweep
    # must have continued through successor executions - which is what sends
    # the BSON::ObjectId cursor through ActiveJob serialization and back.
    sweep_executions = workflow.step_executions.where(step_name: "sweep").to_a
    assert_operator sweep_executions.size, :>, 1
    assert(sweep_executions.any? { |execution| execution.cursor_value.is_a?(BSON::ObjectId) })
  end

  test "iterate_over_subrelations yields criteria batches and finishes" do
    hero = create_user
    4.times { |i| MongoUser.create!(email: "batch-#{i}@example.com", name: "Batch #{i}") }

    workflow = BatchSweepUsersWorkflow.create!(hero: hero)
    perform_enqueued_jobs_now

    assert_equal "finished", workflow.reload.state
    swept = Thread.current[:swept_batches].flatten.sort
    assert_equal MongoUser.all.pluck(:email).sort, swept
    assert(Thread.current[:swept_batches].all? { |batch| batch.size <= 2 })
  end
end
