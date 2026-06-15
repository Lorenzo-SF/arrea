defmodule Arrea.CircuitBreakerTest do
  use ExUnit.Case
  alias Arrea.CircuitBreaker

  @max_failures 3
  @timeout 200

  setup %{test: test_name} do
    test_id = :"worker_#{test_name}"

    # Ensure Registry is started. We ignore errors if already started.
    # Ensure Registry is started.
    _ = start_supervised({Registry, keys: :unique, name: Arrea.CircuitBreaker.Registry})

    # Try stopping any potential existing breaker for this test_id
    case Registry.lookup(Arrea.CircuitBreaker.Registry, test_id) do
      [{existing_pid, _}] ->
        Process.exit(existing_pid, :kill)
        :timer.sleep(10)

      [] ->
        :ok
    end

    {:ok, pid} =
      CircuitBreaker.start_link(
        id: test_id,
        name: test_id,
        threshold: @max_failures,
        timeout: @timeout
      )

    %{pid: pid, test_id: test_id}
  end

  test "starts in closed state", %{test_id: test_id} do
    assert CircuitBreaker.get_state(test_id) == :closed
  end

  test "transitions to open after threshold failures", %{test_id: test_id} do
    assert CircuitBreaker.get_state(test_id) == :closed

    CircuitBreaker.failure(test_id)
    CircuitBreaker.failure(test_id)
    assert CircuitBreaker.get_state(test_id) == :closed

    CircuitBreaker.failure(test_id)
    assert CircuitBreaker.get_state(test_id) == :open
  end

  test "transitions to half_open during protected call if timeout expired", %{test_id: test_id} do
    CircuitBreaker.failure(test_id)
    CircuitBreaker.failure(test_id)
    CircuitBreaker.failure(test_id)
    assert CircuitBreaker.get_state(test_id) == :open

    # Wait for the timeout
    Process.sleep(@timeout + 50)

    # State remains open until someone calls `CircuitBreaker.call/3` and it succeeds.
    # We will invoke call/3.
    assert {:ok, :hello} = CircuitBreaker.call(test_id, fn -> :hello end)

    # Wait for the asynchronous :success cast to be processed
    Process.sleep(10)

    # State evaluates to closed after success
    assert CircuitBreaker.get_state(test_id) == :closed
  end

  test "transitions from half_open back to closed on success", %{test_id: test_id} do
    CircuitBreaker.failure(test_id)
    CircuitBreaker.failure(test_id)
    CircuitBreaker.failure(test_id)

    Process.sleep(@timeout + 50)
    # The call triggers the success
    assert {:ok, :hello} = CircuitBreaker.call(test_id, fn -> :hello end)

    Process.sleep(10)
    assert CircuitBreaker.get_state(test_id) == :closed
  end

  test "remains open if call fails after timeout", %{test_id: test_id} do
    CircuitBreaker.failure(test_id)
    CircuitBreaker.failure(test_id)
    CircuitBreaker.failure(test_id)

    Process.sleep(@timeout + 50)

    assert {:error, :execution_failed} = CircuitBreaker.call(test_id, fn -> raise "error" end)

    assert CircuitBreaker.get_state(test_id) == :open
  end

  test "half_open state correctly transitions to closed on success", %{pid: pid, test_id: test_id} do
    :sys.replace_state(pid, fn state -> %{state | state: :half_open} end)
    assert CircuitBreaker.get_state(test_id) == :half_open

    assert {:ok, :hello} = CircuitBreaker.call(test_id, fn -> :hello end)
    Process.sleep(10)
    assert CircuitBreaker.get_state(test_id) == :closed
  end

  test "half_open state correctly transitions to open on failure", %{pid: pid, test_id: test_id} do
    :sys.replace_state(pid, fn state -> %{state | state: :half_open} end)
    assert CircuitBreaker.get_state(test_id) == :half_open

    assert {:error, :execution_failed} = CircuitBreaker.call(test_id, fn -> raise "error" end)
    Process.sleep(10)
    assert CircuitBreaker.get_state(test_id) == :open
  end

  test "handles unregistered breaker" do
    unregistered_id = :not_a_real_breaker
    assert CircuitBreaker.get_state(unregistered_id) == :closed
    # should_retry? defaults to true for unregistered
    assert {:ok, :hello} = CircuitBreaker.call(unregistered_id, fn -> :hello end)
  end
end
