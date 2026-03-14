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

  # @return [ActiveSupport::Duration, Symbol, Proc, nil] wait time or backoff strategy before reattempt
  attr_reader :wait

  # @return [Float, nil] jitter factor for symbol-based backoff strategies (0.0 to 1.0, nil = use default 0.15)
  attr_reader :jitter

  # @return [Integer, nil] maximum consecutive reattempts before pausing (nil = unlimited)
  attr_reader :max_reattempts

  # @return [Symbol] what to do when max_reattempts is exceeded (:pause! or :cancel!)
  attr_reader :terminal_action

  # @return [Array<#===>] exception matchers this policy checks (empty = match all).
  #   Each entry can be an Exception subclass or any object responding to #===.
  attr_reader :exception_matchers

  # @return [Proc, nil] the handler block (imperative mode)
  attr_reader :handler

  # Creates a new exception policy.
  #
  # Valid terminal_action values
  VALID_TERMINAL_ACTIONS = %i[pause! cancel!].freeze

  # @overload initialize(action, wait: nil, max_reattempts: nil, terminal_action: :pause!, jitter: 0.15)
  #   Declarative mode — specify action and options.
  #   @param action [Symbol] the flow control action (:pause!, :cancel!, :reattempt!, :skip!)
  #   @param wait [ActiveSupport::Duration, Symbol, Proc, nil] wait time or backoff strategy.
  #     Symbol values (e.g. :polynomially_longer) use a built-in backoff curve.
  #     Procs receive the attempt count and return a duration.
  #   @param max_reattempts [Integer, nil] max consecutive reattempts (nil = unlimited)
  #   @param terminal_action [Symbol] what to do when max_reattempts is exceeded (:pause! or :cancel!)
  #   @param jitter [Float] jitter factor for symbol-based backoff strategies (0.0–1.0, default 0.15)
  #
  # @overload initialize(&block)
  #   Imperative mode — block receives exception, runs in workflow context.
  #   Must call a flow control method (reattempt!, cancel!, pause!, skip!).
  #   @yield [error] the exception that was raised
  def initialize(action = nil, wait: nil, max_reattempts: nil, terminal_action: :pause!, jitter: nil, &block)
    if block
      if action || wait || max_reattempts || terminal_action != :pause! || jitter
        raise ArgumentError,
          "Cannot pass action, wait, max_reattempts, terminal_action, or jitter when a block is given"
      end
      @handler = block
      @action = nil
      @wait = nil
      @jitter = nil
      @max_reattempts = nil
      @terminal_action = :pause!
    else
      raise ArgumentError, "Either an action or a block is required" unless action
      @handler = nil
      @action = action
      @wait = wait
      @jitter = jitter
      @max_reattempts = max_reattempts
      @terminal_action = terminal_action
      validate!
    end

    @exception_matchers = []
  end

  # Returns true if this is a declarative policy (action symbol, no block).
  #
  # @return [Boolean]
  def declarative?
    handler.nil?
  end

  # Returns true if this policy matches the given error.
  # A policy with no exception classes matches all errors.
  #
  # @param error [Exception] the exception to check
  # @return [Boolean]
  def matches?(error)
    exception_matchers.empty? || exception_matchers.any? { |matcher| matcher === error }
  end

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

  private

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

    if @wait.is_a?(Symbol)
      unless GenevaDrive::BackoffStrategies::STRATEGIES.key?(@wait)
        raise ArgumentError,
          "Unknown backoff strategy: #{@wait.inspect}. " \
          "Valid strategies: #{GenevaDrive::BackoffStrategies::STRATEGIES.keys.join(", ")}"
      end
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
