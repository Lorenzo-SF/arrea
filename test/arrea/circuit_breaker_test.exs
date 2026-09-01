defmodule Arrea.CircuitBreakerTest do
  use ExUnit.Case
  alias Arrea.CircuitBreaker

  @max_failures 3
  @timeout 200

  setup do
    test_id = :circuit_breaker_test

    _ = start_supervised({Registry, keys: :unique, name: Arrea.CircuitBreaker.Registry})

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

  test "exit in call is re-raised and counted as failure", %{test_id: test_id} do
    spawn_monitor(fn ->
      CircuitBreaker.call(test_id, fn -> Process.exit(self(), :kill) end)
    end)

    assert_receive {:DOWN, _, :process, _, :killed}, 100

    Process.sleep(10)
    assert CircuitBreaker.get_state(test_id) == :closed
  end

  test "exception in call returns error tuple", %{test_id: test_id} do
    assert {:error, :execution_failed} = CircuitBreaker.call(test_id, fn -> raise "boom" end)
    Process.sleep(10)
    assert CircuitBreaker.get_state(test_id) == :closed
  end

  # ── AR-5: config validators ─────────────────────────────────────────────

  test "validate_opts/1 accepts valid options" do
    assert :ok = CircuitBreaker.validate_opts(name: :db, threshold: 3, timeout: 100)
  end

  test "validate_opts/1 rejects missing name" do
    assert {:error, %Arrea.Error{code: :invalid_config}} =
             CircuitBreaker.validate_opts(threshold: 3)
  end

  test "validate_opts/1 rejects threshold below 1" do
    assert {:error, %Arrea.Error{code: :invalid_config}} =
             CircuitBreaker.validate_opts(name: :db, threshold: 0)

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             CircuitBreaker.validate_opts(name: :db, threshold: -1)
  end

  test "validate_opts/1 rejects timeout not greater than zero" do
    assert {:error, %Arrea.Error{code: :invalid_config}} =
             CircuitBreaker.validate_opts(name: :db, timeout: 0)

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             CircuitBreaker.validate_opts(name: :db, timeout: -50)
  end

  test "start_link rejects invalid options with typed error" do
    assert {:error, %Arrea.Error{code: :invalid_config, message: msg}} =
             CircuitBreaker.start_link(name: :bad_threshold, threshold: -1)

    assert msg =~ "threshold"

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             CircuitBreaker.start_link(name: :bad_timeout, timeout: 0)

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             CircuitBreaker.start_link(threshold: 3)
  end

  # ── AR-4: single-flight probe in half_open ─────────────────────────────

  test "half_open blocks callers while a probe is in progress",
       %{pid: pid, test_id: test_id} do
    :sys.replace_state(pid, fn state -> %{state | state: :half_open, probe_in_progress: true} end)

    assert {:error, :circuit_open} = CircuitBreaker.call(test_id, fn -> :never_run end)
  end

  test "only the first caller probes in half_open; the rest are blocked",
       %{pid: pid, test_id: test_id} do
    :sys.replace_state(pid, fn state -> %{state | state: :half_open} end)
    parent = self()

    for _i <- 1..10 do
      spawn(fn ->
        result =
          CircuitBreaker.call(test_id, fn ->
            send(parent, :probe_executed)
            :probe
          end)

        send(parent, {:result, result})
      end)
    end

    results =
      for _ <- 1..10 do
        receive do
          {:result, result} -> result
        after
          2_000 -> :no_result
        end
      end

    assert Enum.count(results, &(&1 == {:ok, :probe})) == 1
    assert Enum.count(results, &(&1 == {:error, :circuit_open})) == 9
    assert_receive :probe_executed, 100
    refute_receive :probe_executed, 50
  end

  test "probe flag resets after the probe succeeds", %{pid: pid, test_id: test_id} do
    :sys.replace_state(pid, fn state -> %{state | state: :half_open, probe_in_progress: true} end)

    CircuitBreaker.success(test_id)
    Process.sleep(10)

    # The probe completed successfully, so a new caller is allowed again.
    assert {:ok, :probe} = CircuitBreaker.call(test_id, fn -> :probe end)
    Process.sleep(10)
    assert CircuitBreaker.get_state(test_id) == :closed
  end

  test "probe flag resets after the probe fails", %{pid: pid, test_id: test_id} do
    :sys.replace_state(pid, fn state -> %{state | state: :half_open, probe_in_progress: true} end)

    CircuitBreaker.failure(test_id)
    Process.sleep(10)

    assert CircuitBreaker.get_state(test_id) == :open
  end
end
