# frozen_string_literal: true

# A gravestone left in place of a step that has been taken out of a workflow.
#
# Deleting a `step` outright is not safe while workflows are in flight: an
# execution row already scheduled for that name finds no definition when its
# job runs, and the workflow pauses with StepNotDefinedError. Declaring
# `removed_step :name` in the position the step used to occupy keeps the name
# resolvable, so those executions are skipped instead of stranding the
# workflow, while scheduling never spools a new execution for it again.
#
# A removed step holds nothing but a name - no block, no wait, no conditions.
# There is nothing left to configure about a step that does not run.
#
# @api private
class GenevaDrive::RemovedStepDefinition < GenevaDrive::StepDefinition
  # Creates a gravestone for a step that no longer exists.
  #
  # The parent is handed a callable that never runs: a removed step is
  # intercepted by the executor before it would be performed.
  #
  # @param name [String, Symbol] the name of the step that was removed
  # @param call_location [Array<String, Integer>, nil] source location of the removed_step call
  def initialize(name:, call_location: nil)
    super(name: name, callable: :__removed_step_never_runs, call_location: call_location)
  end

  # Returns true to mark this as a gravestone rather than a runnable step.
  #
  # @return [Boolean]
  def removed?
    true
  end
end
