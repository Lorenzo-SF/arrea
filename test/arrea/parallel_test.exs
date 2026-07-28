defmodule Arrea.ParallelTest do
  use ExUnit.Case, async: true

  alias Arrea.Parallel

  describe "execute/2" do
    test "executes a function successfully" do
      assert {:ok, %{result: 42, exit_code: 0}} = Parallel.execute(fn -> 42 end)
    end

    test "executes a string command" do
      assert {:ok, result} = Parallel.execute("echo hello")
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "hello")
    end

    test "times out on slow function" do
      {_pid, ref} =
        spawn_monitor(fn ->
          Parallel.execute(fn -> :timer.sleep(100) end, timeout: 10)
        end)

      assert_receive {:DOWN, ^ref, _, _, _}, 500
    end

    test "handles function that raises" do
      assert {:error, %{error: %RuntimeError{message: "boom"}}} =
               Parallel.execute(fn -> raise "boom" end)
    end
  end

  describe "run/2" do
    test "returns ok with batch_id" do
      assert {:ok, batch_id} = Parallel.run([fn -> 1 end], max_workers: 5)
      assert is_binary(batch_id)
    end
  end

  describe "run_sync/2 with functions" do
    test "executes functions in order" do
      results = Parallel.run_sync([fn -> 1 end, fn -> 2 end, fn -> 3 end])

      assert [
               {:ok, %{result: 1, exit_code: 0}},
               {:ok, %{result: 2, exit_code: 0}},
               {:ok, %{result: 3, exit_code: 0}}
             ] = results
    end

    test "respects workers option" do
      results = Parallel.run_sync([fn -> 1 end, fn -> 2 end], workers: 1)
      assert length(results) == 2
    end

    test "respects timeout" do
      results = Parallel.run_sync([fn -> :timer.sleep(100) end], timeout: 10)

      assert [result] = results
      assert elem(result, 0) == :error or match?({:error, _}, result)
    end

    test "handles tagged tasks with atom tags" do
      results =
        Parallel.run_sync([{:vector, fn -> 1 end}, {:bm25, fn -> 2 end}])

      assert [
               {:tagged, :vector, {:ok, %{result: 1, exit_code: 0}}},
               {:tagged, :bm25, {:ok, %{result: 2, exit_code: 0}}}
             ] = results
    end

    test "handles tagged tasks with timeout" do
      results =
        Parallel.run_sync([{:vector, fn -> 1 end, 1000}, {:bm25, fn -> 2 end, 1000}])

      assert [
               {:tagged, :vector, {:ok, %{result: 1, exit_code: 0}}},
               {:tagged, :bm25, {:ok, %{result: 2, exit_code: 0}}}
             ] = results
    end

    test "handles per-task timeout" do
      results = Parallel.run_sync([{fn -> :timer.sleep(100) end, 10}])

      assert [result] = results
      assert elem(result, 0) == :error or match?({:error, _}, result)
    end

    test "handles empty list" do
      assert Parallel.run_sync([]) == []
    end

    test "handles mixed tagged and untagged tasks" do
      results = Parallel.run_sync([{:vector, fn -> 1 end}, fn -> 2 end])

      assert [
               {:tagged, :vector, {:ok, %{result: 1, exit_code: 0}}},
               {:ok, %{result: 2, exit_code: 0}}
             ] = results
    end
  end

  describe "normalize_command/3" do
    test "handles binary command" do
      assert {"echo hi", :idx, 30_000} = Parallel.normalize_command("echo hi", :idx, 30_000)
    end

    test "handles {tag, cmd} tuple" do
      assert {"echo", :mytag, 30_000} = Parallel.normalize_command({:mytag, "echo"}, :idx, 30_000)
    end

    test "handles {cmd, timeout} tuple" do
      assert {"echo", :idx, 5000} = Parallel.normalize_command({"echo", 5000}, :idx, 30_000)
    end

    test "handles {tag, cmd, timeout} tuple" do
      assert {"echo", :mytag, 5000} =
               Parallel.normalize_command({:mytag, "echo", 5000}, :idx, 30_000)
    end

    test "handles function entry" do
      fun = fn -> :ok end
      assert {^fun, :idx, 30_000} = Parallel.normalize_command(fun, :idx, 30_000)
    end
  end

  describe "run_stream/2" do
    test "returns a stream" do
      stream = Parallel.run_stream([fn -> 1 end])
      assert is_struct(stream, Stream)
    end
  end

  describe "run_tasks/3" do
    test "returns list of {idx, cmd, task} tuples" do
      tasks = Parallel.run_tasks([fn -> 1 end, fn -> 2 end])
      assert length(tasks) == 2

      for {idx, _cmd, task} <- tasks do
        assert is_integer(idx)
        assert is_struct(task, Task)
      end
    end
  end
end
