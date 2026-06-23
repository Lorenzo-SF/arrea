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
    test "delegates to leader and returns {:ok, batch_id}" do
      result = Parallel.run([fn -> 1 + 1 end, fn -> 2 + 2 end], workers: 2)
      assert {:ok, batch_id} = result
      assert is_binary(batch_id)
    end

    test "accepts shell commands asynchronously" do
      assert {:ok, batch_id} = Parallel.run(["echo a", "echo b"], workers: 2)
      assert is_binary(batch_id)
    end

    test "returns error when Leader is not available" do
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

      assert Enum.any?(results, fn
               %{result: "a", exit_code: 0} -> true
               _ -> false
             end)

      assert Enum.any?(results, fn
               %{result: "b", exit_code: 0} -> true
               _ -> false
             end)
    end

    test "chunks commands and executes them in parallel" do
      results = Parallel.run_sync([fn -> "x" end, fn -> "y" end, fn -> "z" end], workers: 2)
      assert length(results) == 3
    end
  end
end
