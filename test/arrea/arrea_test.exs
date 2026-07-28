defmodule ArreaTest do
  use ExUnit.Case

  alias Arrea

  describe "execute/2" do
    test "executes a function successfully" do
      assert {:ok, result} = Arrea.execute(fn -> 42 end)
      assert result.success
      assert result.data == %{result: 42, exit_code: 0}
      assert result.failures == []
    end

    test "returns error on function failure" do
      assert {:error, error} = Arrea.execute(fn -> raise "boom" end)
      assert error.code == :engine_failure
    end
  end

  describe "run/2" do
    test "returns ok with batch_id" do
      assert {:ok, result} = Arrea.run([fn -> 1 end], max_workers: 5)
      assert result.success
      assert is_binary(result.data.batch_id)
    end
  end

  describe "run_sync/2" do
    test "executes functions in order" do
      results = Arrea.run_sync([fn -> 1 end, fn -> 2 end])

      assert [
               {:ok, %{result: 1, exit_code: 0}},
               {:ok, %{result: 2, exit_code: 0}}
             ] = results
    end

    test "accepts workers option" do
      results = Arrea.run_sync([fn -> 1 end], workers: 1)
      assert length(results) == 1
    end
  end

  describe "stats/0" do
    test "returns monitor statistics" do
      assert {:ok, stats} = Arrea.stats()
      assert is_integer(stats.total_workers)
      assert is_integer(stats.active_workers)
      assert is_integer(stats.completed_tasks)
      assert is_integer(stats.failed_tasks)
    end
  end

  describe "subscribe/unsubscribe" do
    test "subscribe returns :ok" do
      assert Arrea.subscribe() == :ok
      Arrea.unsubscribe()
    end

    test "unsubscribe returns :ok" do
      Arrea.subscribe()
      assert Arrea.unsubscribe() == :ok
    end
  end

  describe "max_workers/0" do
    test "returns a non-negative integer" do
      assert Arrea.max_workers() >= 0
    end
  end
end
