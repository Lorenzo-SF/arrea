defmodule Arrea.RateLimiterTest do
  use ExUnit.Case

  alias Arrea.RateLimiter

  setup do
    test_id = :rate_limiter_test

    _ = start_supervised({Registry, keys: :unique, name: Arrea.RateLimiter.Registry})

    case Registry.lookup(Arrea.RateLimiter.Registry, test_id) do
      [{existing_pid, _}] ->
        Process.exit(existing_pid, :kill)
        :timer.sleep(10)

      [] ->
        :ok
    end

    # Reset the underlying apero bucket too: buckets are global and keep
    # their consumed tokens between tests.
    case Registry.lookup(Apero.RateLimit.Registry, test_id) do
      [{bucket_pid, _}] ->
        Process.exit(bucket_pid, :kill)
        :timer.sleep(10)

      [] ->
        :ok
    end

    {:ok, pid} = RateLimiter.start_link(test_id, capacity: 2, refill_per_second: 1.0)
    %{pid: pid, test_id: test_id}
  end

  test "allows up to capacity and denies beyond it", %{test_id: test_id} do
    assert RateLimiter.check(test_id, 1) == :ok
    assert RateLimiter.check(test_id, 1) == :ok
    assert RateLimiter.check(test_id, 1) == {:error, :rate_limited}
  end

  test "respects n larger than capacity", %{test_id: test_id} do
    assert RateLimiter.check(test_id, 3) == {:error, :rate_limited}
  end

  test "allow?/2 returns a boolean and consumes tokens", %{test_id: test_id} do
    assert RateLimiter.allow?(test_id, 2)
    refute RateLimiter.allow?(test_id, 1)
  end

  test "refills tokens over time", %{test_id: test_id} do
    # capacity 2, refill 1.0/s → after 1.2s the bucket has refilled 1 token
    assert RateLimiter.check(test_id, 2) == :ok
    assert RateLimiter.check(test_id, 1) == {:error, :rate_limited}
    Process.sleep(1_200)
    assert RateLimiter.check(test_id, 1) == :ok
  end

  test "emits :denied telemetry event with typed metadata", %{test_id: test_id} do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "rate-limiter-test-handler",
      [:arrea, :rate_limiter, :denied],
      fn _event, _measurements, metadata, ^ref -> send(parent, {:denied, metadata}) end,
      ref
    )

    on_exit(fn -> :telemetry.detach("rate-limiter-test-handler") end)

    RateLimiter.check(test_id, 2)
    assert RateLimiter.check(test_id, 1) == {:error, :rate_limited}

    assert_receive {:denied, %{name: ^test_id, capacity: 2, n: 1}}, 1_000
  end

  test "start_link rejects invalid options with typed error" do
    assert {:error, %Arrea.Error{code: :invalid_config, message: msg}} =
             RateLimiter.start_link(:bad_limiter, capacity: 0)

    assert msg =~ "capacity"

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             RateLimiter.start_link(:bad_limiter, refill_per_second: -1.0)

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             RateLimiter.start_link(:bad_limiter, bucket: :quantum)

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             RateLimiter.start_link(:bad_limiter, capacity: "ten")
  end

  test "returns :limiter_not_found for an unknown limiter" do
    assert RateLimiter.check(:unknown_limiter) == {:error, :limiter_not_found}
    refute RateLimiter.allow?(:unknown_limiter)
  end
end
