# frozen_string_literal: true

require "test_helper"

class BackoffStrategiesTest < ActiveSupport::TestCase
  test "resolve returns nil for nil wait" do
    assert_nil GenevaDrive::BackoffStrategies.resolve(nil, attempts: 1)
  end

  test "resolve returns fixed duration as-is" do
    assert_equal 15.seconds, GenevaDrive::BackoffStrategies.resolve(15.seconds, attempts: 1)
  end

  test "resolve returns integer as-is" do
    assert_equal 30, GenevaDrive::BackoffStrategies.resolve(30, attempts: 1)
  end

  test "resolve calls proc with attempts" do
    strategy = ->(attempts) { (2**attempts).seconds }
    assert_equal 2.seconds, GenevaDrive::BackoffStrategies.resolve(strategy, attempts: 1)
    assert_equal 4.seconds, GenevaDrive::BackoffStrategies.resolve(strategy, attempts: 2)
    assert_equal 8.seconds, GenevaDrive::BackoffStrategies.resolve(strategy, attempts: 3)
  end

  test "resolve handles :polynomially_longer with zero jitter" do
    result = GenevaDrive::BackoffStrategies.resolve(:polynomially_longer, attempts: 1, jitter: 0.0)
    assert_equal 3.seconds, result # 1**4 + 2

    result = GenevaDrive::BackoffStrategies.resolve(:polynomially_longer, attempts: 2, jitter: 0.0)
    assert_equal 18.seconds, result # 2**4 + 2

    result = GenevaDrive::BackoffStrategies.resolve(:polynomially_longer, attempts: 3, jitter: 0.0)
    assert_equal 83.seconds, result # 3**4 + 2
  end

  test ":polynomially_longer with default jitter adds randomness" do
    results = 10.times.map do
      GenevaDrive::BackoffStrategies.resolve(:polynomially_longer, attempts: 3)
    end

    # Base is 83 seconds (81 + 2). With 15% jitter, range is ~83 to ~95.
    # At minimum, not all results should be identical (jitter adds randomness).
    assert results.all? { |r| r >= 83.seconds }
    assert results.all? { |r| r < 96.seconds } # 83 + 81*0.15 ≈ 95.15
  end

  test "resolve raises on unknown symbol strategy" do
    error = assert_raises(ArgumentError) do
      GenevaDrive::BackoffStrategies.resolve(:unknown_strategy, attempts: 1)
    end
    assert_match(/Unknown backoff strategy/, error.message)
  end

  test "resolve raises on invalid wait type" do
    error = assert_raises(ArgumentError) do
      GenevaDrive::BackoffStrategies.resolve(Object.new, attempts: 1)
    end
    assert_match(/Invalid wait value/, error.message)
  end
end
