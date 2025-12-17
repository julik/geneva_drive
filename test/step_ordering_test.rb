# frozen_string_literal: true

require "test_helper"

class StepOrderingTest < ActiveSupport::TestCase
  # Basic before_step tests
  test "allows inserting step before another step using string" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step :second, before_step: "third" do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
  end

  test "allows inserting step before another step using symbol" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step :second, before_step: :third do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
  end

  # Basic after_step tests
  test "allows inserting step after another step using string" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step :second, after_step: "first" do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
  end

  test "allows inserting step after another step using symbol" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step :second, after_step: :first do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
  end

  # Edge case: inserting at beginning
  test "allows inserting step at the beginning using before_step" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :second do
      end

      step :third do
      end

      step :first, before_step: :second do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
  end

  # Edge case: inserting at end
  test "allows inserting step at the end using after_step" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :second do
      end

      step :third, after_step: :second do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
  end

  # Complex ordering with multiple insertions
  test "allows complex step ordering with multiple insertions" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :step_1 do
      end

      step :step_4 do
      end

      step :step_2, after_step: :step_1 do
      end

      step :step_3, before_step: :step_4 do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["step_1", "step_2", "step_3", "step_4"], names
  end

  # Test with timing options
  test "maintains existing wait: timing functionality" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first, wait: 5.minutes do
      end

      step :second, wait: 10.minutes do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second"], names
    assert_equal 5.minutes, workflow_class.steps[0].wait
    assert_equal 10.minutes, workflow_class.steps[1].wait
  end

  test "allows mixing step ordering with timing" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first, wait: 1.minute do
      end

      step :third, after_step: :first do
      end

      step :second, before_step: :third, wait: 2.minutes do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
    assert_equal 1.minute, workflow_class.steps[0].wait
    assert_equal 2.minutes, workflow_class.steps[1].wait
    assert_nil workflow_class.steps[2].wait
  end

  # Test with method name instead of block
  test "allows inserting step with method name" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step :second, after_step: :first

      def second
        # method body
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
  end

  # Test with automatic name generation
  test "allows inserting step with automatic name generation" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step before_step: :third do
        # anonymous step gets auto-generated name
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "step_3", "third"], names
  end

  # Test with additional options
  test "allows inserting step with additional options" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step :second, after_step: :first, on_exception: :skip! do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "second", "third"], names
    assert_equal :skip!, workflow_class.steps[1].on_exception
  end

  # Inheritance tests
  test "allows inserting steps before or after steps defined in superclass" do
    parent_class = Class.new(GenevaDrive::Workflow) do
      step :parent_first do
      end

      step :parent_last do
      end
    end

    child_class = Class.new(parent_class) do
      step :child_before, before_step: :parent_first do
      end

      step :child_after, after_step: :parent_last do
      end

      step :child_middle, after_step: :parent_first do
      end
    end

    names = child_class.steps.map(&:name)
    assert_equal ["child_before", "parent_first", "child_middle", "parent_last", "child_after"], names
  end

  # Error cases (already tested in step_definition_test.rb but good to have here too)
  test "raises error when both before_step and after_step are specified" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :first do
        end

        step :second, before_step: :first, after_step: :first do
        end
      end
    end

    assert_match(/cannot specify both before_step: and after_step:/, error.message)
  end

  test "raises error when before_step references non-existent step" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :first, before_step: :nonexistent do
        end
      end
    end

    assert_match(/references non-existent step/, error.message)
    assert_match(/nonexistent/, error.message)
    assert_match(/already been defined/, error.message)
  end

  test "raises error when after_step references non-existent step" do
    error = assert_raises(GenevaDrive::StepConfigurationError) do
      Class.new(GenevaDrive::Workflow) do
        step :first, after_step: :nonexistent do
        end
      end
    end

    assert_match(/references non-existent step/, error.message)
    assert_match(/nonexistent/, error.message)
    assert_match(/already been defined/, error.message)
  end

  # Test step collection navigation
  test "step collection next_after works with ordered steps" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step :second, after_step: :first do
      end
    end

    collection = workflow_class.steps

    assert_equal "second", collection.next_after("first").name
    assert_equal "third", collection.next_after("second").name
    assert_nil collection.next_after("third")
  end

  test "step collection named works with ordered steps" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :first do
      end

      step :third do
      end

      step :second, after_step: :first do
      end
    end

    collection = workflow_class.steps

    assert_equal "first", collection.named(:first).name
    assert_equal "second", collection.named("second").name
    assert_equal "third", collection.named(:third).name
  end

  # Multiple positioned steps in sequence
  test "handles multiple positioned steps in definition order" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :middle do
      end

      step :first, before_step: :middle do
      end

      step :last, after_step: :middle do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["first", "middle", "last"], names
  end

  # Test that unpositioned steps maintain definition order
  test "unpositioned steps maintain definition order" do
    workflow_class = Class.new(GenevaDrive::Workflow) do
      step :alpha do
      end

      step :beta do
      end

      step :gamma do
      end
    end

    names = workflow_class.steps.map(&:name)
    assert_equal ["alpha", "beta", "gamma"], names
  end
end
