# frozen_string_literal: true

# Bundles exception handling configuration into a reusable object.
# Can be used at both class level (via `on_exception`) and step level
# (via the `on_exception:` keyword argument).
#
# Supports two mutually exclusive modes:
#
# **Declarative mode** — specify an action symbol and options:
#   ExceptionPolicy.new(:reattempt!, wait: 15.seconds, max_reattempts: 5)
#
# **Imperative mode** — provide a block that receives the exception
# and calls flow control methods in the workflow context:
#   ExceptionPolicy.new { |error| reattempt!(wait: error.retry_after) }
#
# Policies can optionally target specific exception classes via the +matching:+
# keyword. A policy without +matching:+ is a "blanket" policy that matches any
# exception. A policy with +matching:+ is a "specific" policy that only fires
# for errors matching the given class(es).
#
# Multiple policies can be composed into an array and passed to a step's
# +on_exception:+ option. GenevaDrive wraps the array in a
# {CombinedExceptionPolicy} that walks specific policies first, then falls back
# to the first blanket policy. If no policy in the array matches, resolution
# continues at the class level.
#
# @example Declarative policy with exception matching
#   ExceptionPolicy.new(:reattempt!, matching: Net::OpenTimeout, max_reattempts: 5)
#
# @example Composing multiple policies for a step
#   step :sync, on_exception: [
#     ExceptionPolicy.new(:reattempt!, matching: Timeout::Error, max_reattempts: 10),
#     ExceptionPolicy.new(:cancel!,    matching: OAuth2::Error),
#     ExceptionPolicy.new(:skip!)  # blanket fallback
#   ] do
#     ExternalApi.sync(hero)
#   end
#
# @see CombinedExceptionPolicy
# @api public
class GenevaDrive::ExceptionPolicy
  # Matches exceptions by class name without requiring the constant to be
  # loaded at definition time. The class lookup happens lazily on each #===
  # call. If the constant cannot be resolved, the matcher returns false
  # (no match) rather than raising.
  #
  # @example
  #   on_exception "SomeLib::TransientError", action: :reattempt!
  #
  # @api private
  class LazyExceptionMatcher
    # @param class_name [String] fully-qualified exception class name
    def initialize(class_name)
      @class_name = class_name.to_s.freeze
    end

    # @param error [Exception]
    # @return [Boolean]
    def ===(error)
      klass = @class_name.safe_constantize
      klass ? error.is_a?(klass) : false
    end

    def inspect
      "#<LazyExceptionMatcher #{@class_name}>"
    end
  end

  # Valid action values (same as StepDefinition::EXCEPTION_HANDLERS)
  VALID_ACTIONS = %i[pause! cancel! reattempt! skip!].freeze

  # @return [Symbol, nil] the action (:pause!, :cancel!, :reattempt!, :skip!) — nil in imperative mode
  attr_reader :action

  # @return [ActiveSupport::Duration, nil] wait time before reattempt
  attr_reader :wait

  # @return [Integer, nil] maximum consecutive reattempts before pausing (nil = unlimited)
  attr_reader :max_reattempts

  # @return [Symbol] what to do when max_reattempts is exceeded (:pause!, :cancel!, or :skip!)
  attr_reader :terminal_action

  # @return [Array<#===>] exception matchers this policy checks (empty = match all).
  #   Each entry can be an Exception subclass or any object responding to #===.
  attr_reader :exception_matchers

  # @return [Symbol] when to report the exception via Rails.error.report (:always, :never, or :terminal_only)
  attr_reader :report

  # @return [Proc, nil] the handler block (imperative mode)
  attr_reader :handler

  # Creates a new exception policy.
  #
  # Valid terminal_action values
  VALID_TERMINAL_ACTIONS = %i[pause! cancel! skip!].freeze

  # Valid report values
  VALID_REPORT_OPTIONS = %i[always never terminal_only].freeze

  # @overload initialize(action, matching: nil, wait: nil, max_reattempts: nil, terminal_action: :pause!, report: :always)
  #   Declarative mode — specify action and options.
  #   @param action [Symbol] the flow control action (:pause!, :cancel!, :reattempt!, :skip!)
  #   @param matching [Class, String, #===, Array<Class, String, #===>, nil] exception classes
  #     this policy applies to. When +nil+ (the default), the policy matches any exception
  #     (blanket policy). When set, only errors matching the given class(es) trigger this policy
  #     (specific policy). Strings are resolved lazily via +safe_constantize+, so the exception
  #     class does not need to be loaded at definition time.
  #   @param wait [ActiveSupport::Duration, nil] wait time before reattempt
  #   @param max_reattempts [Integer, nil] max consecutive reattempts (nil = unlimited)
  #   @param terminal_action [Symbol] what to do when max_reattempts is exceeded (:pause!, :cancel!, or :skip!)
  #   @param report [Symbol] when to report the exception to +Rails.error.report+.
  #     - +:always+ (default) — report every exception regardless of what action is taken
  #     - +:never+ — never report; the exception is expected and handled by the policy
  #     - +:terminal_only+ — suppress reports while the step is being reattempted, but
  #       report when reattempts are exhausted and the +terminal_action+ fires
  #
  # @overload initialize(matching: nil, report: :always, &block)
  #   Imperative mode — block receives exception, runs in workflow context.
  #   Must call a flow control method (reattempt!, cancel!, pause!, skip!).
  #   Can be combined with +matching:+ and +report:+ to target specific exception classes
  #   and control error reporting.
  #   @param matching [Class, String, #===, Array<Class, String, #===>, nil] exception classes
  #   @param report [Symbol] when to report the exception (+:always+, +:never+, or +:terminal_only+)
  #   @yield [error] the exception that was raised
  #
  # @example Blanket reattempt policy
  #   ExceptionPolicy.new(:reattempt!, wait: 30.seconds, max_reattempts: 5)
  #
  # @example Specific policy matching a single exception class
  #   ExceptionPolicy.new(:reattempt!, matching: Net::OpenTimeout, max_reattempts: 10)
  #
  # @example Specific policy matching multiple exception classes
  #   ExceptionPolicy.new(:cancel!, matching: [OAuth2::Error, "Faraday::ConnectionFailed"])
  #
  # @example Imperative policy
  #   ExceptionPolicy.new { |error| reattempt!(wait: error.retry_after) }
  #
  # @example Imperative policy with exception matching
  #   ExceptionPolicy.new(matching: Timeout::Error) { |error| reattempt!(wait: error.retry_after) }
  #
  # @example Suppress error reporting for expected exceptions
  #   ExceptionPolicy.new(:reattempt!, matching: RateLimitError, report: :never)
  #
  # @example Only report when reattempts are exhausted
  #   ExceptionPolicy.new(:reattempt!, matching: Net::OpenTimeout, max_reattempts: 5, report: :terminal_only)
  def initialize(action = nil, wait: nil, max_reattempts: nil, terminal_action: :pause!, matching: nil, report: :always, &block)
    @report = report
    unless VALID_REPORT_OPTIONS.include?(@report)
      raise ArgumentError,
        "report: must be one of #{VALID_REPORT_OPTIONS.join(", ")}, got #{@report.inspect}"
    end
    if block
      if action || wait || max_reattempts || terminal_action != :pause!
        raise ArgumentError,
          "Cannot pass action, wait, max_reattempts, or terminal_action when a block is given"
      end
      @handler = block
      @action = nil
      @wait = nil
      @max_reattempts = nil
      @terminal_action = :pause!
    else
      raise ArgumentError, "Either an action or a block is required" unless action
      @handler = nil
      @action = action
      @wait = wait
      @max_reattempts = max_reattempts
      @terminal_action = terminal_action
      validate!
    end

    @exception_matchers = build_matchers(matching)
  end

  # Returns true if this is a declarative policy (action symbol, no block).
  #
  # @return [Boolean]
  def declarative?
    handler.nil?
  end

  # Returns true if this policy captures the given error.
  # A policy with no exception matchers captures all errors (blanket policy).
  # A policy with matchers only captures errors matching the given class(es).
  #
  # @param error [Exception] the exception to check
  # @return [Boolean]
  def captures?(error)
    exception_matchers.empty? || exception_matchers.any? { |matcher| matcher === error }
  end

  alias_method :matches?, :captures?

  # Returns true if this policy has exception matchers.
  #
  # @return [Boolean]
  def specific?
    exception_matchers.any?
  end

  # Returns true if this is a blanket policy (no exception matchers).
  #
  # @return [Boolean]
  def blanket?
    exception_matchers.empty?
  end

  # Applies this policy to the given error and returns a result Hash describing
  # the action to take.
  #
  # For declarative policies, checks the reattempt limit and returns the
  # appropriate action. For imperative policies, executes the handler block
  # in the workflow context and translates the resulting flow control signal
  # into a result.
  #
  # The returned Hash always contains +:action+ (Symbol without +!+),
  # +:error+ (the original exception), and +:report+ (the reporting mode).
  # Reattempt results also include +:wait+. When the terminal action fires
  # (reattempt limit exceeded), +:terminal+ is set to +true+.
  #
  # @param error [Exception] the exception that was raised
  # @param reattempt_count [Integer] consecutive reattempts so far for this step
  # @param workflow [GenevaDrive::Workflow] the workflow instance (needed for imperative handlers)
  # @return [Hash] result with +:action+, +:error+, and optionally +:wait+ keys
  #
  # @example Declarative policy result
  #   policy = ExceptionPolicy.new(:reattempt!, wait: 5.seconds, max_reattempts: 3)
  #   policy.apply(error, reattempt_count: 0, workflow: wf)
  #   # => { action: :reattempt, wait: 5.seconds, error: error }
  #
  # @see CombinedExceptionPolicy#apply
  def apply(error, reattempt_count:, workflow:)
    if handler
      apply_imperative(error, workflow)
    else
      apply_declarative(error, reattempt_count)
    end
  end

  # Returns this policy wrapped in an Array for uniform iteration.
  #
  # {CombinedExceptionPolicy} stores its children in an Array via {#policies}.
  # This method lets callers use +exception_policy.policies+ on either type
  # without branching, producing a flat list of leaf policies.
  #
  # @return [Array<GenevaDrive::ExceptionPolicy>]
  # @see CombinedExceptionPolicy#policies
  def policies
    [self]
  end

  private

  # Applies an imperative policy by executing the handler block in the workflow
  # context. The block must call a flow control method (reattempt!, cancel!, etc.).
  # If it doesn't, defaults to :pause.
  #
  # @param error [Exception]
  # @param workflow [GenevaDrive::Workflow]
  # @return [Hash]
  def apply_imperative(error, workflow)
    signal = catch(:flow_control) do
      workflow.instance_exec(error, &handler)
      nil
    end

    if signal.is_a?(GenevaDrive::FlowControlSignal)
      {action: signal.action, wait: signal.options[:wait], error: error, report: @report}
    else
      {action: :pause, error: error, report: @report}
    end
  end

  # Applies a declarative policy by checking the reattempt limit and returning
  # the appropriate action.
  #
  # @param error [Exception]
  # @param reattempt_count [Integer]
  # @return [Hash]
  def apply_declarative(error, reattempt_count)
    if action == :reattempt! && max_reattempts && reattempt_count >= max_reattempts
      terminal = terminal_action.to_s.chomp("!").to_sym
      {action: terminal, error: error, report: @report, terminal: true}
    else
      {action: action.to_s.chomp("!").to_sym, wait: wait, error: error, report: @report}
    end
  end

  # Builds an array of exception matchers from the matching: argument.
  # Strings become LazyExceptionMatcher, classes must be Exception subclasses,
  # and anything else must respond to #===.
  #
  # @param raw [Class, String, #===, Array, nil]
  # @return [Array<#===>]
  def build_matchers(raw)
    return [] if raw.nil?

    Array(raw).map do |matcher|
      if matcher.is_a?(String)
        LazyExceptionMatcher.new(matcher)
      elsif matcher.is_a?(Class)
        unless matcher <= Exception
          raise ArgumentError,
            "Expected an Exception subclass, got #{matcher.inspect}"
        end
        matcher
      elsif matcher.respond_to?(:===)
        matcher
      else
        raise ArgumentError,
          "Expected an exception matcher (Exception subclass, String, or object responding to #===), got #{matcher.inspect}"
      end
    end
  end

  # Validates declarative mode configuration.
  #
  # @raise [ArgumentError] if configuration is invalid
  def validate!
    unless VALID_ACTIONS.include?(@action)
      raise ArgumentError,
        "Invalid action #{@action.inspect}: must be one of #{VALID_ACTIONS.join(", ")}"
    end

    if @wait && @action != :reattempt!
      raise ArgumentError,
        "wait: only makes sense with action: :reattempt!"
    end

    if @max_reattempts
      unless @action == :reattempt!
        raise ArgumentError,
          "max_reattempts: only makes sense with action: :reattempt!"
      end

      unless @max_reattempts.is_a?(Integer) && @max_reattempts > 0
        raise ArgumentError,
          "max_reattempts: must be a positive integer or nil"
      end
    end

    unless VALID_TERMINAL_ACTIONS.include?(@terminal_action)
      raise ArgumentError,
        "terminal_action: must be one of #{VALID_TERMINAL_ACTIONS.join(", ")}, got #{@terminal_action.inspect}"
    end

    if @terminal_action != :pause! && @action != :reattempt!
      raise ArgumentError,
        "terminal_action: only makes sense with action: :reattempt!"
    end
  end
end
