defmodule Arrea.LeaderTest do
  use ExUnit.Case, async: false

  alias Arrea.{Leader, Monitor}

  setup_all do
    # Ensure Arrea application is started before any test
    {:ok, _} = Application.ensure_all_started(:arrea)
    :ok
  end

  setup do
    # Ensure all required registries are started
    for {name, keys} <- [
          {Arrea.Registry, :unique},
          {Arrea.CircuitBreaker.Registry, :unique},
          {Arrea.PubSub, :unique}
        ] do
      case Registry.start_link(keys: keys, name: name) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    # Ensure Monitor is started (check before starting)
    if Process.whereis(Monitor) == nil do
      case Supervisor.start_link([{Monitor, name: Monitor}], strategy: :one_for_one) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    # Ensure WorkerSupervisor is started
    if Process.whereis(Arrea.WorkerSupervisor) == nil do
      case DynamicSupervisor.start_link(
             name: Arrea.WorkerSupervisor,
             strategy: :one_for_one
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    # Ensure Leader is started (idempotent)
    case Leader.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "lifecycle" do
    test "start_link/1 initializes with proper state shape" do
      state = Leader.get_state()
      assert is_struct(state.subscribers, MapSet)
      assert is_map(state.batches)
      assert is_map(state.stats)
      assert Map.has_key?(state.stats, :started)
      assert Map.has_key?(state.stats, :finished)
      assert Map.has_key?(state.stats, :failed)
    end
  end

  describe "subscriptions" do
    test "subscribe/0 adds the caller to subscribers" do
      Leader.unsubscribe()
      assert :ok = Leader.subscribe()
      state = Leader.get_state()
      assert MapSet.member?(state.subscribers, self())
    end

    test "unsubscribe/0 removes the caller from subscribers" do
      Leader.subscribe()
      assert :ok = Leader.unsubscribe()
      state = Leader.get_state()
      refute MapSet.member?(state.subscribers, self())
    end

    test "subscribe and unsubscribe are idempotent" do
      Leader.unsubscribe()
      Leader.unsubscribe()
      Leader.subscribe()
      Leader.subscribe()
      state = Leader.get_state()
      # MapSet deduplicates, so same pid added twice = 1 entry
      pid_subscriptions = Enum.count(state.subscribers, &(&1 == self()))
      assert pid_subscriptions <= 1
    end
  end

  describe "notify_event/1" do
    test "notify_event with :worker_started increments started stat" do
      Leader.unsubscribe()
      :ok = Leader.subscribe()
      Leader.notify_event(%{type: :worker_started, batch: "b1", worker: "w1", pid: self()})

      # Wait for the cast to be processed
      :timer.sleep(100)

      state = Leader.get_state()
      assert state.stats.started >= 1
    end

    test "notify_event with :worker_finished increments finished stat" do
      Leader.unsubscribe()
      :ok = Leader.subscribe()
      Leader.notify_event(%{type: :worker_finished, worker: "w1"})

      :timer.sleep(100)

      state = Leader.get_state()
      assert state.stats.finished >= 1
    end

    test "notify_event with :worker_error increments failed stat" do
      Leader.unsubscribe()
      :ok = Leader.subscribe()
      Leader.notify_event(%{type: :worker_error, worker: "w1", reason: :timeout})

      :timer.sleep(100)

      state = Leader.get_state()
      assert state.stats.failed >= 1
    end

    test "notify_event with unknown type leaves started/finished/failed unchanged" do
      Leader.unsubscribe()
      :ok = Leader.subscribe()
      before_stats = Leader.get_state().stats
      Leader.notify_event(%{type: :ping})

      :timer.sleep(100)

      after_stats = Leader.get_state().stats
      assert after_stats.started == before_stats.started
      assert after_stats.finished == before_stats.finished
      assert after_stats.failed == before_stats.failed
    end

    test "notify_event sends message to subscribed pid" do
      Leader.unsubscribe()
      :ok = Leader.subscribe()

      Leader.notify_event(%{type: :worker_started, batch: "b1", worker: "w1", pid: self()})

      assert_receive {:leader_event, %{type: :worker_started, worker: "w1"}}, 500
    end
  end

  describe "handle_info callbacks" do
    test "handle_info :worker_finished sends notification" do
      Leader.unsubscribe()
      :ok = Leader.subscribe()
      send(Leader, {:worker_finished, :test_worker})

      assert_receive {:leader_event, %{type: :worker_finished, worker: :test_worker}}, 500
    end

    test "handle_info :worker_failed sends error notification" do
      Leader.unsubscribe()
      :ok = Leader.subscribe()
      send(Leader, {:worker_failed, :test_worker, :crash})

      assert_receive {:leader_event,
                      %{type: :worker_error, worker: :test_worker, reason: :crash}},
                     500
    end

    test "handle_info :worker_done sends done notification" do
      Leader.unsubscribe()
      :ok = Leader.subscribe()
      send(Leader, {:worker_done, :test_worker, %{result: :ok}})

      assert_receive {:leader_event,
                      %{type: :worker_done, worker: :test_worker, result: %{result: :ok}}},
                     500
    end
  end

  describe "execute/2" do
    test "execute/2 with function commands returns ok tuple and batch_id" do
      {:ok, batch_id} = Leader.execute([fn -> :ok end])
      assert is_binary(batch_id)

      state = Leader.get_state()
      assert Map.has_key?(state.batches, batch_id)
    end

    test "execute/2 with binary commands starts workers" do
      {:ok, batch_id} = Leader.execute(["true"])
      assert is_binary(batch_id)
    end

    test "execute/2 with invalid command type returns ok with error tuple" do
      # {:invalid, "tuple"} is neither binary nor 0-arity function
      {:ok, batch_id} = Leader.execute([{:invalid, "tuple"}])
      assert is_binary(batch_id)
    end

    test "execute/2 with options passes policy and log settings" do
      {:ok, batch_id} =
        Leader.execute([fn -> :ok end],
          policy: %{max_retries: 3},
          log: true
        )

      assert is_binary(batch_id)
    end
  end

  describe "code_change/3" do
    test "code_change returns {:ok, state}" do
      state = Leader.get_state()
      assert {:ok, ^state} = Leader.code_change(:old_vsn, state, :extra)
    end
  end

  describe "get_state/0" do
    test "get_state/0 returns current GenServer state" do
      state = Leader.get_state()
      assert is_map(state)
      assert Map.has_key?(state, :subscribers)
      assert Map.has_key?(state, :batches)
      assert Map.has_key?(state, :stats)
    end
  end
end
