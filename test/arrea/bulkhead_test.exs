defmodule Arrea.BulkheadTest do
  use ExUnit.Case

  alias Arrea.Bulkhead

  @max_concurrent 2

  setup do
    test_id = :bulkhead_test

    _ = start_supervised({Registry, keys: :unique, name: Arrea.Bulkhead.Registry})

    case Registry.lookup(Arrea.Bulkhead.Registry, test_id) do
      [{existing_pid, _}] ->
        Process.exit(existing_pid, :kill)
        :timer.sleep(10)

      [] ->
        :ok
    end

    {:ok, pid} = Bulkhead.start_link(test_id, @max_concurrent)
    %{pid: pid, test_id: test_id}
  end

  test "runs a function when a slot is available", %{test_id: test_id} do
    assert {:ok, :done} = Bulkhead.run(test_id, fn -> :done end)
    assert Bulkhead.available(test_id) == @max_concurrent
  end

  test "rejects the call above max_concurrent (no queueing)", %{test_id: test_id} do
    parent = self()
    started = :bulkhead_slot_taken

    tasks =
      for i <- 1..@max_concurrent do
        Task.async(fn ->
          Bulkhead.run(test_id, fn ->
            send(parent, {started, i})

            receive do
              {:release_slot, ^i} -> :finished
            after
              2_000 -> :timed_out
            end
          end)
        end)
      end

    for i <- 1..@max_concurrent do
      assert_receive {^started, ^i}, 1_000
    end

    assert Bulkhead.available(test_id) == 0
    assert Bulkhead.run(test_id, fn -> :third end) == {:error, :bulkhead_full}

    for {task, i} <- Enum.with_index(tasks, 1) do
      send(task.pid, {:release_slot, i})
      assert Task.await(task, 1_000) == {:ok, :finished}
    end

    assert Bulkhead.available(test_id) == @max_concurrent
  end

  test "releases the slot even when the function raises", %{test_id: test_id} do
    assert {:error, :execution_failed} = Bulkhead.run(test_id, fn -> raise "boom" end)
    assert Bulkhead.available(test_id) == @max_concurrent
  end

  test "returns :bulkhead_not_found for an unknown bulkhead" do
    assert Bulkhead.run(:unknown_bulkhead, fn -> :nope end) == {:error, :bulkhead_not_found}
    assert Bulkhead.available(:unknown_bulkhead) == 0
    assert Bulkhead.status(:unknown_bulkhead) == nil
  end

  test "status reflects counters", %{test_id: test_id} do
    Bulkhead.run(test_id, fn -> :ok end)
    Bulkhead.run(test_id, fn -> :ok end)
    Bulkhead.run(test_id, fn -> :ok end)
    Bulkhead.run(test_id, fn -> :ok end)

    assert %{name: ^test_id, max_concurrent: 2, active: 0, accepted: 4, rejected: 0} =
             Bulkhead.status(test_id)
  end

  test "emits :rejected telemetry event with typed metadata" do
    test_id = :bulkhead_rejected
    {:ok, _} = Bulkhead.start_link(test_id, 1)
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "bulkhead-test-handler",
      [:arrea, :bulkhead, :rejected],
      fn _event, _measurements, metadata, ^ref -> send(parent, {:rejected, metadata}) end,
      ref
    )

    on_exit(fn -> :telemetry.detach("bulkhead-test-handler") end)

    task =
      Task.async(fn ->
        Bulkhead.run(test_id, fn ->
          send(parent, :held)

          receive do
            :go -> :done
          end
        end)
      end)

    assert_receive :held, 1_000
    assert {:error, :bulkhead_full} = Bulkhead.run(test_id, fn -> :nope end)

    assert_receive {:rejected, %{name: ^test_id, max_concurrent: 1, active: 1}}, 1_000

    send(task.pid, :go)
    Task.await(task, 1_000)
  end

  test "start_link rejects invalid max_concurrent with typed error" do
    assert {:error, %Arrea.Error{code: :invalid_config, message: msg}} =
             Bulkhead.start_link(:bad_bulkhead, 0)

    assert msg =~ "max_concurrent"

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             Bulkhead.start_link(:bad_bulkhead, -3)
  end
end
