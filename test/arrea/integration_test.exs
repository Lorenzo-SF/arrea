defmodule Arrea.IntegrationTest do
  use ExUnit.Case, async: false

  alias Arrea.{CircuitBreaker, Result}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arrea)
    :ok
  end

  test "execute/2 with a function returns the expected result" do
    assert {:ok, %Result{success: true}} =
             Arrea.execute(fn -> {:ok, 42} end)
  end

  test "execute/2 with a shell command returns stdout" do
    assert {:ok, %Result{success: true, data: data}} =
             Arrea.execute("echo integration_test")

    assert data.stdout =~ "integration_test"
    assert data.exit_code == 0
  end

  test "run/2 emits events to a subscriber" do
    :ok = Arrea.subscribe()

    {:ok, _batch_id} = Arrea.run([fn -> :ok end, fn -> :ok end], workers: 2)

    assert_receive {:leader_event, %{type: :worker_started}}, 1_000
    assert_receive {:leader_event, %{type: :finished}}, 1_000

    :ok = Arrea.unsubscribe()
  end

  test "stats/0 reflects workers that have run" do
    {:ok, _batch_id} = Arrea.run([fn -> :ok end], workers: 1)

    Process.sleep(200)

    assert {:ok, stats} = Arrea.stats()
    assert stats.total_workers >= 1
  end

  test "Worker with a retry policy retries on failure" do
    {:ok, _} = ensure_monitor_started()
    {:ok, _} = ensure_registry_started()

    test_pid = self()

    task = fn ->
      send(test_pid, :retry_attempt)
      raise "boom"
    end

    {:ok, _pid} =
      Arrea.Worker.start_link(
        id: :retry_test,
        tasks: [task],
        policy: %{on_error: :retry, max_retries: 2, retry_delay: 10},
        parent: test_pid
      )

    assert_receive {:worker_error, :retry_test, _}, 1_000
  end

  test "CircuitBreaker works as a standalone tool" do
    {:ok, _} = CircuitBreaker.start_link(name: :test_breaker, threshold: 2, timeout: 100)

    CircuitBreaker.failure(:test_breaker)
    CircuitBreaker.failure(:test_breaker)
    assert CircuitBreaker.get_state(:test_breaker) == :open

    Process.sleep(150)

    assert {:ok, :ok} = CircuitBreaker.call(:test_breaker, fn -> :ok end)
    assert CircuitBreaker.get_state(:test_breaker) == :closed
  end

  # Helpers

  defp ensure_monitor_started do
    if Process.whereis(Arrea.Monitor) == nil do
      Arrea.Monitor.start_link([])
    else
      {:ok, Process.whereis(Arrea.Monitor)}
    end
  end

  defp ensure_registry_started do
    if Process.whereis(Arrea.Registry) == nil do
      Registry.start_link(keys: :unique, name: Arrea.Registry)
    else
      {:ok, Process.whereis(Arrea.Registry)}
    end
  end
end
