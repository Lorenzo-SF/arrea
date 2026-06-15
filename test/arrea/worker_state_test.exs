defmodule Arrea.WorkerStateTest do
  use ExUnit.Case, async: true

  alias Arrea.WorkerState

  describe "new/2-3" do
    test "creates state with default values" do
      state = WorkerState.new(:worker_1, [])
      assert state.id == :worker_1
      assert state.tasks == []
      assert state.status == :idle
      assert state.total_tasks == 0
      assert state.progress == 0
      assert state.completed_tasks == 0
      assert state.results == []
      assert state.retry_count == 0
      assert state.warnings == []
      assert is_integer(state.started_at)
    end

    test "creates state with tasks" do
      task_fn = fn -> :work end
      state = WorkerState.new(:w1, [task_fn])
      assert state.total_tasks == 1
      assert length(state.tasks) == 1
    end

    test "creates state with parent pid" do
      parent = self()
      state = WorkerState.new(:w1, [], parent: parent)
      assert state.parent == parent
    end

    test "creates state with log enabled" do
      state = WorkerState.new(:w1, [], log: true)
      assert state.log? == true
    end

    test "creates state with policy" do
      policy = %{on_error: :retry}
      state = WorkerState.new(:w1, [], policy: policy)
      assert state.policy == policy
    end

    test "creates state with multiple options" do
      parent = self()

      state =
        WorkerState.new(:w3, [fn -> 1 end, fn -> 2 end],
          parent: parent,
          log: true,
          policy: %{on_error: :stop}
        )

      assert state.id == :w3
      assert state.total_tasks == 2
      assert state.parent == parent
      assert state.log? == true
      assert state.policy == %{on_error: :stop}
    end

    test "accepts string id" do
      state = WorkerState.new("worker-1", [])
      assert state.id == "worker-1"
    end
  end

  describe "elapsed_time/1" do
    test "returns 0 for invalid state" do
      assert WorkerState.elapsed_time(%WorkerState{}) == 0
    end

    test "returns time between start and end for finished state" do
      state = %WorkerState{started_at: 1000, ended_at: 1500}
      assert WorkerState.elapsed_time(state) == 500
    end

    test "returns current elapsed time for running state" do
      now = System.monotonic_time(:millisecond)
      state = %WorkerState{started_at: now - 100}
      elapsed = WorkerState.elapsed_time(state)
      assert elapsed >= 100
    end
  end

  describe "update_progress/2" do
    test "calculates correct progress percentage" do
      state = WorkerState.new(:w1, [fn -> 1 end, fn -> 2 end])
      updated = WorkerState.update_progress(state, 1)
      assert updated.progress == 50.0
      assert updated.completed_tasks == 1
    end

    test "handles 0 tasks" do
      state = WorkerState.new(:w1, [])
      updated = WorkerState.update_progress(state, 0)
      assert updated.progress == 0
    end

    test "handles partial completion" do
      state = WorkerState.new(:w1, [fn -> 1 end, fn -> 2 end, fn -> 3 end, fn -> 4 end])
      updated = WorkerState.update_progress(state, 2)
      assert updated.progress == 50.0
    end

    test "handles complete completion" do
      state = WorkerState.new(:w1, [fn -> 1 end])
      updated = WorkerState.update_progress(state, 1)
      assert updated.progress == 100.0
    end
  end

  describe "add_result/2" do
    test "adds result to results list" do
      state = WorkerState.new(:w1, [])
      updated = WorkerState.add_result(state, {:ok, :result})
      assert is_list(updated.results)
      assert {:ok, :result} in updated.results
    end

    test "prepends results (newest first)" do
      state = WorkerState.new(:w1, [])
      s1 = WorkerState.add_result(state, :first)
      s2 = WorkerState.add_result(s1, :second)
      assert hd(s2.results) == :second
    end
  end
end
