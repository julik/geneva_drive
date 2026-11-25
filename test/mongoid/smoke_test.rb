# frozen_string_literal: true

# Mongoid tests run only under `rake test:mongoid`, which boots the dummy app
# against MongoDB (GENEVA_DRIVE_ORM=mongoid) - see test/mongoid_helper.rb
return unless ENV["GENEVA_DRIVE_ORM"] == "mongoid"
require "mongoid_helper"

class SmokeTest < ActiveSupport::TestCase
  include GenevaDrive::TestHelpers

  class TwoStepWorkflow < GenevaDrive::MongoidWorkflow
    step :one do
      hero.update!(name: "after one")
    end

    step :two do
      hero.update!(name: "after two")
    end
  end

  test "creates, performs both steps, finishes" do
    user = create_user
    workflow = TwoStepWorkflow.create!(hero: user)
    assert_equal "ready", workflow.state
    assert_equal "one", workflow.next_step_name
    assert workflow.current_execution

    perform_next_step(workflow)
    assert_equal "after one", user.reload.name
    assert_equal "two", workflow.reload.next_step_name

    perform_next_step(workflow)
    assert_equal "after two", user.reload.name
    assert_equal "finished", workflow.reload.state
    assert_equal 2, workflow.step_executions.where(state: "completed").count
  end

  test "speedruns to completion" do
    user = create_user
    workflow = TwoStepWorkflow.create!(hero: user)
    speedrun_workflow(workflow)
    assert_workflow_state(workflow, :finished)
    assert_step_executed(workflow, :one)
    assert_step_executed(workflow, :two)
  end
end
