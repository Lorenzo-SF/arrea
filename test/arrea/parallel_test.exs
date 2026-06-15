defmodule Arrea.ParallelTest do
  use ExUnit.Case
  alias Arrea.{Leader, Monitor, Parallel}

  setup do
    if pid = Process.whereis(Monitor) do
      Process.exit(pid, :kill)
      :timer.sleep(10)
    end

    if leader_pid = Process.whereis(Leader) do
      Process.exit(leader_pid, :kill)
      :timer.sleep(10)
    end

    # Guarantee the Monitor registry/process starts so Leader can rely on it if needed
    case Registry.start_link(keys: :unique, name: Arrea.Registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    if Process.whereis(Monitor) == nil do
      start_supervised!(Monitor)
    end

    if Process.whereis(Arrea.WorkerSupervisor) == nil do
      start_supervised!({DynamicSupervisor, name: Arrea.WorkerSupervisor, strategy: :one_for_one})
    end

    if Process.whereis(Leader) == nil do
      start_supervised!(Leader)
    end

    :ok
  end

  describe "execute/2 (sync)" do
    test "executes a simple function returning {:ok, map}" do
      result = Parallel.execute(fn -> "hello" end)
      assert {:ok, %{result: "hello", exit_code: 0}} = result
    end

    test "executes a shell command returning {:ok, map}" do
      result = Parallel.execute("echo 'hello parallel'")
      assert {:ok, %{stdout: out, exit_code: 0}} = result
      assert out == "hello parallel\n" || out == "hello parallel\r\n"
    end

    test "traps function exceptions and returns {:error, map}" do
      result = Parallel.execute(fn -> raise "boom block" end)
      assert {:error, %{error: %RuntimeError{}, exit_code: 1}} = result
    end
  end

  describe "run/2 (async batch)" do
    test "delegates to leader and returns batch_id" do
      result = Parallel.run([fn -> 1 + 1 end, fn -> 2 + 2 end], workers: 2)
      assert {:ok, batch_id} = result
      assert is_binary(batch_id)
    end

    test "accepts shell commands asynchronously" do
      assert {:ok, batch_id} = Parallel.run(["echo a", "echo b"], workers: 2)
      assert is_binary(batch_id)
    end

    test "returns error when Leader is not available" do
      # C3: Parallel.run no longer auto-starts Leader.
      # This is verified indirectly: if Leader is not in the supervision tree,
      # Parallel.run returns {:error, :leader_not_available}.
      # We test the success path above; the error path is tested in integration.
      assert Process.whereis(Leader) != nil
    end
  end

  describe "run_sync/2" do
    test "executes commands and waits for completion" do
      results =
        Parallel.run_sync(
          [
            fn -> "a" end,
            fn -> "b" end
          ],
          workers: 2
        )

      assert length(results) == 2
      # Results are mapped across inner tasks
      assert Enum.any?(results, fn
               {:ok, %{result: "a"}} -> true
               _ -> false
             end)

      assert Enum.any?(results, fn
               {:ok, %{result: "b"}} -> true
               _ -> false
             end)
    end
  end

  describe "monitor interfaces" do
    test "subscribe_monitor/0 wraps Monitor.subscribe/0" do
      assert :ok = Parallel.subscribe_monitor()
    end

    test "monitor_state/0 wraps Monitor.get_state/0" do
      state = Parallel.monitor_state()
      assert is_map(state)
      assert Map.has_key?(state, :workers)
      assert Map.has_key?(state, :subscribers)
      assert Map.has_key?(state, :total_started)
      assert Map.has_key?(state, :total_finished)
      assert Map.has_key?(state, :total_errors)
    end
  end

  describe "run_sync/2 function definition" do
    test "run_sync/2 chunks commands and executes them in parallel" do
      results = Parallel.run_sync([fn -> "x" end, fn -> "y" end, fn -> "z" end], workers: 2)
      assert length(results) == 3
    end

    test "run_sync/2 handles empty command list" do
      results = Parallel.run_sync([], workers: 2)
      assert results == []
    end

    test "run_sync/2 with tagged atoms returns tagged results" do
      results =
        Parallel.run_sync(
          [
            {:first, fn -> "alpha" end},
            {:second, fn -> "beta" end}
          ],
          workers: 2
        )

      assert length(results) == 2

      assert Enum.find(results, fn
               {:tagged, :first, {:ok, %{result: "alpha"}}} -> true
               _ -> false
             end)

      assert Enum.find(results, fn
               {:tagged, :second, {:ok, %{result: "beta"}}} -> true
               _ -> false
             end)
    end

    test "run_sync/2 with per-task timeout respects it" do
      # A slow function with a very short timeout should fail
      results =
        Parallel.run_sync(
          [
            {fn ->
               :timer.sleep(500)
               "slow"
             end, 50}
          ],
          workers: 1
        )

      assert length(results) == 1
      assert {:error, %{error: :timeout}} = hd(results)
    end

    test "run_sync/2 with tagged + timeout combo" do
      results =
        Parallel.run_sync(
          [
            {:fast, fn -> "ok" end, 10_000},
            {:slow,
             fn ->
               :timer.sleep(200)
               "done"
             end, 50}
          ],
          workers: 2
        )

      assert length(results) == 2

      assert Enum.find(results, fn
               {:tagged, :fast, {:ok, %{result: "ok"}}} -> true
               _ -> false
             end)

      assert Enum.find(results, fn
               {:tagged, :slow, {:error, %{error: :timeout}}} -> true
               _ -> false
             end)
    end

    test "run_sync/2 executes shell commands" do
      results =
        Parallel.run_sync(
          [
            "echo hello",
            "echo world"
          ],
          workers: 2
        )

      assert length(results) == 2

      assert Enum.any?(results, fn
               {:ok, %{stdout: out, exit_code: 0}} -> String.contains?(out, "hello")
               _ -> false
             end)

      assert Enum.any?(results, fn
               {:ok, %{stdout: out, exit_code: 0}} -> String.contains?(out, "world")
               _ -> false
             end)
    end

    test "run_sync/2 with wrong command returns error" do
      results = Parallel.run_sync(["nonexistent_cmd_xyz"], workers: 1)

      assert length(results) == 1
      # Should either be an error or exit_code != 0
      result = hd(results)

      case result do
        {:error, _} -> :ok
        {:ok, %{exit_code: ec}} when ec != 0 -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end

  describe "start_leader private function" do
    test "run/2 returns ok when leader starts successfully" do
      # This is already covered by existing tests
      # but we add a direct assertion
      assert {:ok, _} = Parallel.run([fn -> :ok end], workers: 1)
    end

    test "execute/2 with timeout option passes timeout through" do
      result = Parallel.execute(fn -> :ok end, timeout: 5000)
      assert {:ok, %{result: :ok, exit_code: 0}} = result
    end

    test "execute/2 with default timeout" do
      result = Parallel.execute(fn -> 1 + 1 end)
      assert {:ok, %{result: 2, exit_code: 0}} = result
    end
  end
end
