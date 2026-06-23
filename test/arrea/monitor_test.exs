defmodule Arrea.MonitorTest do
  use ExUnit.Case, async: false
  alias Arrea.Monitor

  setup do
    case Process.whereis(Monitor) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid)
    end

    {:ok, _pid} = GenServer.start_link(Monitor, [], name: Monitor)
    :ok
  end

  describe "state shape" do
    test "get_state/0 returns expected properties" do
      state = Monitor.get_state()
      assert is_map(state.workers)
      assert is_integer(state.total_started)
      assert state.total_started >= 0
      refute Map.has_key?(state, :subscribers)
    end
  end

  describe "worker lifecycle tracking" do
    test "register_worker/2 updates state" do
      assert :ok = Monitor.register_worker(:worker_1, %{task: "test"})

      # give GenServer cast time to process
      :timer.sleep(20)

      state = Monitor.get_state()
      assert Map.has_key?(state.workers, :worker_1)
      assert state.workers.worker_1.status == :started
      assert state.total_started == 1
    end

    test "worker_finished/3 with :finished updates counters" do
      Monitor.register_worker(:worker_2, %{})
      :timer.sleep(20)

      assert :ok = Monitor.worker_finished(:worker_2, :finished, 100)
      :timer.sleep(20)

      state = Monitor.get_state()
      assert state.total_finished == 1
    end

    test "worker_finished/3 with :error updates counters" do
      Monitor.register_worker(:worker_3, %{})
      :timer.sleep(20)

      assert :ok = Monitor.worker_finished(:worker_3, :error, 100)
      :timer.sleep(20)

      state = Monitor.get_state()
      assert state.total_errors == 1
    end

    test "update_worker/2 on non-existent worker is a no-op gracefully" do
      assert :ok = Monitor.update_worker(:nonexistent_worker, %{status: :error})
    end
  end

  describe "get_stats/0" do
    test "returns the expected shape" do
      {:ok, stats} = Monitor.get_stats()
      assert is_integer(stats.total_workers)
      assert is_integer(stats.active_workers)
      assert is_integer(stats.completed_tasks)
      assert is_integer(stats.failed_tasks)
    end
  end
end
