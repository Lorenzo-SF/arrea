defmodule Arrea.WorkerTest do
  use ExUnit.Case

  alias Arrea.Worker

  setup do
    if Process.whereis(Arrea.Registry) == nil do
      start_supervised!({Registry, keys: :unique, name: Arrea.Registry})
    end

    if Process.whereis(Arrea.Monitor) == nil do
      start_supervised!(Arrea.Monitor)
    end

    :ok
  end

  describe "worker lifecycle" do
    test "processes single function task successfully" do
      parent = self()

      task_fn = fn ->
        send(parent, :worker_task_executed)
        {:ok, :result}
      end

      {:ok, _pid} = Worker.start_link(id: :test_worker_1, tasks: [task_fn], parent: parent)

      assert_receive :worker_task_executed, 500
      assert_receive {:worker_done, :test_worker_1, :result}, 500
    end

    test "handles crashing task gracefully" do
      parent = self()
      Process.flag(:trap_exit, true)

      task_fn = fn ->
        raise "Oops"
      end

      {:ok, pid} =
        Worker.start_link(
          id: :test_worker_faulty,
          tasks: [task_fn],
          parent: parent,
          policy: %{max_retries: 0}
        )

      assert_receive {:worker_error, :test_worker_faulty,
                      {:error, {:exception, %RuntimeError{message: "Oops"}}}},
                     500

      assert_receive {:EXIT, ^pid,
                      {:error, {:error, {:exception, %RuntimeError{message: "Oops"}}}}},
                     500
    end

    test "processes multiple tasks sequentially" do
      parent = self()

      task_fn1 = fn ->
        send(parent, :task1)
        {:ok, 1}
      end

      task_fn2 = fn ->
        send(parent, :task2)
        {:ok, 2}
      end

      Process.flag(:trap_exit, true)

      {:ok, _pid} =
        Worker.start_link(id: :test_worker_multi, tasks: [task_fn1, task_fn2], parent: parent)

      assert_receive :task1, 500
      assert_receive {:worker_done, :test_worker_multi, 1}, 500
      assert_receive :task2, 500
      assert_receive {:worker_done, :test_worker_multi, 2}, 500
    end

    test "supports pause and get_state" do
      task_fn = fn -> :noop end
      {:ok, pid} = Worker.start_link(id: :test_state_worker, tasks: [task_fn])
      assert {:ok, state} = GenServer.call(pid, :get_state)
      assert state.id == :test_state_worker

      assert :ok = GenServer.call(pid, :pause)
    end

    test "handles on_error: :stop policy" do
      parent = self()
      Process.flag(:trap_exit, true)

      task = fn -> raise "fail" end

      {:ok, pid} =
        Worker.start_link(
          id: :test_stop_worker,
          tasks: [task],
          parent: parent,
          policy: %{on_error: :stop, max_retries: 0}
        )

      assert_receive {:worker_error, :test_stop_worker,
                      {:error, {:exception, %RuntimeError{message: "fail"}}}},
                     500

      assert_receive {:EXIT, ^pid,
                      {:error, {:error, {:exception, %RuntimeError{message: "fail"}}}}},
                     500
    end

    test "handles on_error: :continue policy" do
      parent = self()
      Process.flag(:trap_exit, true)

      task = fn -> raise "fail" end

      {:ok, pid} =
        Worker.start_link(
          id: :test_continue_worker,
          tasks: [task],
          parent: parent,
          policy: %{on_error: :continue}
        )

      # With :continue policy, the error is skipped and the worker stops normally
      assert_receive {:EXIT, ^pid, :normal}, 500
    end

    test "handles generic catch in task execution" do
      parent = self()
      Process.flag(:trap_exit, true)

      task = fn -> throw(:some_error) end

      {:ok, pid} =
        Worker.start_link(
          id: :test_catch_worker,
          tasks: [task],
          parent: parent,
          policy: %{max_retries: 0}
        )

      assert_receive {:worker_error, :test_catch_worker, {:error, {:throw, :some_error}}}, 500
      assert_receive {:EXIT, ^pid, {:error, {:error, {:throw, :some_error}}}}, 500
    end
  end
end
