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

  describe "subscription and state" do
    test "subscribe/0 adds caller to subscribers list" do
      assert :ok = Monitor.subscribe()
      state = Monitor.get_state()
      assert MapSet.member?(state.subscribers, self())
    end

    test "unsubscribe/0 removes caller from subscribers list" do
      Monitor.subscribe()
      assert :ok = Monitor.unsubscribe()
      state = Monitor.get_state()
      refute MapSet.member?(state.subscribers, self())
    end

    test "get_state/0 returns expected properties" do
      state = Monitor.get_state()
      assert is_map(state.workers)
      assert is_integer(state.total_started)
      assert state.total_started >= 0
    end
  end

  describe "worker lifecycle tracking" do
    test "register_worker/2 updates state and broadcasts" do
      Monitor.subscribe()

      assert :ok = Monitor.register_worker(:worker_1, %{task: "test"})

      # Wait for cast
      assert_receive {:worker_registered, :worker_1}, 500

      state = Monitor.get_state()
      assert Map.has_key?(state.workers, :worker_1)
      assert state.workers.worker_1.status == :started
      assert state.total_started == 1
    end

    test "update_worker/2 with 'finished' updates counters" do
      Monitor.register_worker(:worker_2, %{})

      # Now finish it
      assert :ok = Monitor.worker_finished(:worker_2, :finished, 100)

      # give GenServer cast time to process
      :timer.sleep(50)

      state = Monitor.get_state()
      assert state.total_finished == 1
    end

    test "update_worker/2 with 'error' updates counters" do
      Monitor.register_worker(:worker_3, %{})

      # Now error it
      assert :ok = Monitor.worker_finished(:worker_3, :error, 100)

      # give time
      :timer.sleep(50)

      state = Monitor.get_state()
      assert state.total_errors == 1
    end

    test "update_worker/2 on non-existent worker is a no-op gracefully" do
      assert :ok = Monitor.update_worker(:nonexistent_worker, %{status: :error})
    end
  end
end
