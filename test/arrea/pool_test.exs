defmodule Arrea.PoolTest do
  use ExUnit.Case

  alias Arrea.Pool

  defmodule TestWorker do
    use GenServer

    @behaviour Arrea.Pool.Worker

    @impl true
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  setup do
    test_id = :pool_test

    _ = start_supervised({Registry, keys: :unique, name: Arrea.Pool.Registry})

    # Kill any leftover pool from a previous test, including its per-pool
    # DynamicSupervisor (registered under {name, :workers}), which survives
    # the pool's death because supervisors trap exit signals.
    for key <- [test_id, {test_id, :workers}] do
      case Registry.lookup(Arrea.Pool.Registry, key) do
        [{existing_pid, _}] ->
          Process.exit(existing_pid, :kill)
          :timer.sleep(10)

        [] ->
          :ok
      end
    end

    {:ok, pid} = Pool.start_link(test_id, TestWorker, size: 2, max_overflow: 1)
    %{pid: pid, test_id: test_id}
  end

  test "starts with size idle workers", %{test_id: test_id} do
    assert %{total: 2, idle: 2, leased: 0} = Pool.status(test_id)
  end

  test "checkout/checkin round trip", %{test_id: test_id} do
    assert {:ok, worker} = Pool.checkout(test_id)
    assert %{total: 2, idle: 1, leased: 1} = Pool.status(test_id)
    assert GenServer.call(worker, :ping) == :pong

    assert :ok = Pool.checkin(test_id, worker)
    assert %{total: 2, idle: 2, leased: 0} = Pool.status(test_id)
  end

  test "spawns an overflow worker when all are leased", %{test_id: test_id} do
    {:ok, w1} = Pool.checkout(test_id)
    {:ok, w2} = Pool.checkout(test_id)
    {:ok, w3} = Pool.checkout(test_id)
    assert %{total: 3, leased: 3, idle: 0} = Pool.status(test_id)

    Pool.checkin(test_id, w1)
    Pool.checkin(test_id, w2)
    Pool.checkin(test_id, w3)
    assert %{total: 3, idle: 3, leased: 0} = Pool.status(test_id)
  end

  test "times out when pool is empty and overflow is exhausted", %{test_id: test_id} do
    {:ok, _w1} = Pool.checkout(test_id)
    {:ok, _w2} = Pool.checkout(test_id)
    {:ok, _w3} = Pool.checkout(test_id)

    assert {:error, :timeout} = Pool.checkout(test_id, 100)
  end

  test "waits for a slot when one becomes available in time", %{test_id: test_id} do
    {:ok, w1} = Pool.checkout(test_id)
    {:ok, _w2} = Pool.checkout(test_id)
    {:ok, _w3} = Pool.checkout(test_id)

    task = Task.async(fn -> Pool.checkout(test_id, 2_000) end)
    Process.sleep(50)

    # Returning a worker serves the waiter directly.
    Pool.checkin(test_id, w1)

    assert {:ok, worker} = Task.await(task, 1_000)
    assert is_pid(worker)
    Pool.checkin(test_id, worker)
  end

  test "with_worker checks out and always checks back in", %{test_id: test_id} do
    result = Pool.with_worker(test_id, fn worker -> GenServer.call(worker, :ping) end)
    assert result == :pong
    assert %{total: 2, idle: 2, leased: 0} = Pool.status(test_id)
  end

  test "with_worker checks back in even when fun raises", %{test_id: test_id} do
    assert_raise(RuntimeError, "boom", fn ->
      Pool.with_worker(test_id, fn _ -> raise "boom" end)
    end)

    assert %{total: 2, idle: 2, leased: 0} = Pool.status(test_id)
  end

  test "dead workers are replaced to keep the pool at size", %{test_id: test_id} do
    {:ok, worker} = Pool.checkout(test_id)
    Process.exit(worker, :kill)

    # The pool monitors leased workers and replaces them.
    wait_until(fn -> %{total: 2, idle: 2} == Map.take(Pool.status(test_id), [:total, :idle]) end)
    assert %{total: 2, idle: 2} = Map.take(Pool.status(test_id), [:total, :idle])
  end

  test "returns :pool_not_found for an unknown pool" do
    assert Pool.checkout(:unknown_pool) == {:error, :pool_not_found}
    assert :ok = Pool.checkin(:unknown_pool, self())
    assert Pool.status(:unknown_pool) == nil
  end

  test "start_link rejects invalid options with typed error" do
    assert {:error, %Arrea.Error{code: :invalid_config, message: msg}} =
             Pool.start_link(:bad_pool, TestWorker, size: 0)

    assert msg =~ "size"

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             Pool.start_link(:bad_pool, TestWorker, max_overflow: -1)

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             Pool.start_link(:bad_pool, TestWorker, checkin_timeout: 0)

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             Pool.start_link(:bad_pool, nil)
  end

  defp wait_until(fun, attempts \\ 100) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition not met in time")
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
