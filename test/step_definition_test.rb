# frozen_string_literal: true

require "test_helper"

class StepDefinitionTest < ActiveSupport::TestCase
  # Tests for step validation - requires block or method name
  test "requires either a block or a method name" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step
      end
    end

    assert_match(/requires either a block or a method name/, error.message)
  end

  test "accepts a block as callable" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :my_step do
        # step body
      end
    end

    assert_equal 1, workflow_class.step_definitions.size
    assert_equal "my_step", workflow_class.step_definitions.first.name
  end

  test "accepts a symbol (method name) as callable" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :my_step

      def my_step
        # step body
      end
    end

    assert_equal 1, workflow_class.step_definitions.size
    assert_equal "my_step", workflow_class.step_definitions.first.name
    assert_equal :my_step, workflow_class.step_definitions.first.callable
  end

  test "returns step definition from step DSL call" do
    step_def = nil
    Class.new(GenevaDrive::Workflow) do
      step_def = step :my_step do
        # step body
      end
    end

    assert_kind_of GenevaDrive::StepDefinition, step_def
    assert_equal "my_step", step_def.name
  end

  # Tests for automatic step naming
  test "generates automatic names for anonymous steps" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :named_step do
        # step body
      end

      step do
        # anonymous step 1
      end

      step do
        # anonymous step 2
      end
    end

    names = workflow_class.step_definitions.map(&:name)
    assert_equal ["named_step", "step_2", "step_3"], names
  end

  # Tests for duplicate step names
  test "forbids duplicate step names" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :my_step do
          # first step
        end

        step :my_step do
          # duplicate name
        end
      end
    end

    assert_match(/already defined/, error.message)
    assert_match(/my_step/, error.message)
  end

  test "forbids duplicate step names with string and symbol" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :my_step do
          # first step
        end

        step "my_step" do
          # same name as string
        end
      end
    end

    assert_match(/already defined/, error.message)
  end

  # Tests for wait validation
  test "accepts valid wait durations" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :immediate do
        # no wait
      end

      step :delayed, wait: 2.hours do
        # waits 2 hours
      end

      step :zero_wait, wait: 0 do
        # zero is valid
      end
    end

    assert_equal 3, workflow_class.step_definitions.size
    assert_nil workflow_class.step_definitions[0].wait
    assert_equal 2.hours, workflow_class.step_definitions[1].wait
    assert_equal 0, workflow_class.step_definitions[2].wait
  end

  test "rejects negative wait values" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :invalid_wait, wait: -5.minutes do
          # negative wait
        end
      end
    end

    assert_match(/invalid wait value/, error.message)
    assert_match(/non-negative/, error.message)
  end

  # Tests for on_exception validation
  test "accepts valid exception handlers" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :pause_step, on_exception: :pause! do
      end

      step :cancel_step, on_exception: :cancel! do
      end

      step :reattempt_step, on_exception: :reattempt! do
      end

      step :skip_step, on_exception: :skip! do
      end
    end

    handlers = workflow_class.step_definitions.map(&:on_exception)
    assert_equal [:pause!, :cancel!, :reattempt!, :skip!], handlers
  end

  test "defaults to pause! for on_exception" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :default_handler do
      end
    end

    assert_equal :pause!, workflow_class.step_definitions.first.on_exception
  end

  test "rejects invalid on_exception values" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :invalid_handler, on_exception: :invalid do
        end
      end
    end

    assert_match(/invalid on_exception/, error.message)
    assert_match(/pause!, cancel!, reattempt!, skip!/, error.message)
  end

  # Tests for skip_if validation
  test "accepts valid skip_if conditions" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :symbol_condition, skip_if: :should_skip? do
      end

      step :proc_condition, skip_if: -> { hero.active? } do
      end

      step :true_condition, skip_if: true do
      end

      step :false_condition, skip_if: false do
      end

      step :nil_condition, skip_if: nil do
      end

      step :no_condition do
      end
    end

    assert_equal 6, workflow_class.step_definitions.size
  end

  test "rejects invalid skip_if values" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :invalid_skip, skip_if: "not a valid condition" do
        end
      end
    end

    assert_match(/invalid skip_if/, error.message)
    assert_match(/Symbol, Proc, Boolean, or nil/, error.message)
  end

  # Tests for skip_if and if: mutual exclusion
  test "accepts if: as alias for skip_if with inverse logic" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :with_if, if: :should_run? do
      end
    end

    assert_equal 1, workflow_class.step_definitions.size
  end

  test "forbids specifying both skip_if and if" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :conflicting, skip_if: :skip_condition, if: :run_condition do
        end
      end
    end

    assert_match(/cannot specify both skip_if: and if:/, error.message)
  end

  # Tests for before_step/after_step validation
  test "forbids specifying both before_step and after_step" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :first do
        end

        step :conflicting, before_step: :first, after_step: :first do
        end
      end
    end

    assert_match(/cannot specify both before_step: and after_step:/, error.message)
  end

  test "raises error for non-existent before_step reference" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :orphan, before_step: :nonexistent do
      end
    end

    error = assert_raises(GenevaDrive::StepConfigurationError) do
      workflow_class.step_collection.to_a
    end

    assert_match(/references non-existent step/, error.message)
    assert_match(/nonexistent/, error.message)
    assert_match(/before_step/, error.message)
  end

  test "raises error for non-existent after_step reference" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :orphan, after_step: :nonexistent do
      end
    end

    error = assert_raises(GenevaDrive::StepConfigurationError) do
      workflow_class.step_collection.to_a
    end

    assert_match(/references non-existent step/, error.message)
    assert_match(/nonexistent/, error.message)
    assert_match(/after_step/, error.message)
  end

  # Tests for step definition inheritance
  test "step definitions are inherited from parent class" do
    parent_class = Class.new(GenevaDrive::Workflow) do
      step :parent_step do
      end
    end

    child_class = Class.new(parent_class) do
      step :child_step do
      end
    end

    assert_equal 1, parent_class.step_definitions.size
    assert_equal 2, child_class.step_definitions.size
    assert_equal ["parent_step", "child_step"], child_class.step_definitions.map(&:name)
  end

  test "child class does not modify parent step definitions" do
    parent_class = Class.new(GenevaDrive::Workflow) do
      step :parent_step do
      end
    end

    Class.new(parent_class) do
      step :child_step do
      end
    end

    assert_equal 1, parent_class.step_definitions.size
    assert_equal ["parent_step"], parent_class.step_definitions.map(&:name)
  end

  # Tests for additional options passing
  test "passes additional options to step definition" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :with_options, wait: 1.hour, skip_if: :should_skip?, on_exception: :reattempt! do
      end
    end

    step_def = workflow_class.step_definitions.first
    assert_equal 1.hour, step_def.wait
    assert_equal :should_skip?, step_def.skip_condition
    assert_equal :reattempt!, step_def.on_exception
  end
end
