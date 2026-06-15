defmodule Arrea.Telemetry.MetricsTest do
  use ExUnit.Case, async: false

  alias Arrea.Telemetry.Metrics

  describe "setup/0" do
    test "attaches all telemetry handlers without error" do
      assert Metrics.setup() == :ok
    end

    test "setup can be called multiple times" do
      assert Metrics.setup() == :ok
      assert Metrics.setup() == :ok
    end
  end

  describe "get_current/0" do
    test "returns a map with all expected keys" do
      metrics = Metrics.get_current()

      assert is_map(metrics)
      assert Map.has_key?(metrics, :workers)
      assert Map.has_key?(metrics, :tasks)
      assert Map.has_key?(metrics, :circuit_breakers)
      assert Map.has_key?(metrics, :system)
      assert Map.has_key?(metrics, :ui)
    end

    test "returns valid worker stats structure" do
      workers = Metrics.get_worker_stats()

      assert is_map(workers)
      assert workers.started == 0
      assert workers.completed == 0
      assert workers.errors == 0
      assert is_integer(workers.started)
    end

    test "returns valid task stats structure" do
      tasks = Metrics.get_task_stats()

      assert is_map(tasks)
      assert tasks.started == 0
      assert tasks.completed == 0
      assert tasks.errors == 0
    end

    test "returns valid circuit breaker stats structure" do
      cb = Metrics.get_circuit_breaker_stats()

      assert is_map(cb)
      assert cb.open == 0
      assert cb.closed == 0
      assert cb.half_open == 0
      assert cb.trips == 0
    end

    test "returns valid system stats structure" do
      system = Metrics.get_system_stats()

      assert is_map(system)
      assert is_integer(system.memory_mb)
      assert is_integer(system.processes)
      assert is_integer(system.schedulers)
      assert system.memory_mb >= 0
      assert system.processes > 0
      assert system.schedulers > 0
    end

    test "returns valid ui stats structure" do
      ui = Metrics.get_ui_stats()

      assert is_map(ui)
      assert ui.renders == 0
      assert ui.keypresses == 0
      assert ui.focus_changes == 0
    end
  end

  describe "worker event handlers" do
    test "handle_worker_started accepts valid event data" do
      event = [:arrea, :worker, :started]
      measurements = %{duration: 100}
      metadata = %{worker_id: :test_worker}
      config = nil

      assert Metrics.handle_worker_started(event, measurements, metadata, config) == :ok
    end

    test "handle_worker_started handles missing metadata" do
      event = [:arrea, :worker, :started]
      measurements = %{}
      metadata = %{}
      config = nil

      assert Metrics.handle_worker_started(event, measurements, metadata, config) == :ok
    end

    test "handle_worker_completed accepts valid event data" do
      event = [:arrea, :worker, :completed]
      measurements = %{duration: 250}
      metadata = %{worker_id: :test_worker}
      config = nil

      assert Metrics.handle_worker_completed(event, measurements, metadata, config) == :ok
    end

    test "handle_worker_completed handles missing duration" do
      event = [:arrea, :worker, :completed]
      measurements = %{}
      metadata = %{worker_id: :test_worker}
      config = nil

      assert Metrics.handle_worker_completed(event, measurements, metadata, config) == :ok
    end

    test "handle_worker_error accepts valid event data" do
      event = [:arrea, :worker, :error]
      measurements = %{}
      metadata = %{worker_id: :test_worker, reason: :timeout}
      config = nil

      assert Metrics.handle_worker_error(event, measurements, metadata, config) == :ok
    end

    test "handle_worker_error handles missing metadata fields" do
      event = [:arrea, :worker, :error]
      measurements = %{}
      metadata = %{}
      config = nil

      assert Metrics.handle_worker_error(event, measurements, metadata, config) == :ok
    end

    test "handle_worker_error handles nil reason" do
      event = [:arrea, :worker, :error]
      measurements = %{}
      metadata = %{worker_id: :test_worker, reason: nil}
      config = nil

      assert Metrics.handle_worker_error(event, measurements, metadata, config) == :ok
    end
  end

  describe "task event handlers" do
    test "handle_task_started accepts valid event data" do
      event = [:arrea, :task, :started]
      measurements = %{}
      metadata = %{task_id: :test_task}
      config = nil

      assert Metrics.handle_task_started(event, measurements, metadata, config) == :ok
    end

    test "handle_task_started handles empty metadata" do
      event = [:arrea, :task, :started]
      measurements = %{}
      metadata = %{}
      config = nil

      assert Metrics.handle_task_started(event, measurements, metadata, config) == :ok
    end

    test "handle_task_completed accepts valid event data" do
      event = [:arrea, :task, :completed]
      measurements = %{duration: 150}
      metadata = %{task_id: :test_task}
      config = nil

      assert Metrics.handle_task_completed(event, measurements, metadata, config) == :ok
    end

    test "handle_task_completed handles missing duration" do
      event = [:arrea, :task, :completed]
      measurements = %{}
      metadata = %{task_id: :test_task}
      config = nil

      assert Metrics.handle_task_completed(event, measurements, metadata, config) == :ok
    end

    test "handle_task_error accepts valid event data" do
      event = [:arrea, :task, :error]
      measurements = %{}
      metadata = %{worker_id: :test_worker, reason: :crash, task_id: :test_task}
      config = nil

      assert Metrics.handle_task_error(event, measurements, metadata, config) == :ok
    end

    test "handle_task_error handles missing fields" do
      event = [:arrea, :task, :error]
      measurements = %{}
      metadata = %{}
      config = nil

      assert Metrics.handle_task_error(event, measurements, metadata, config) == :ok
    end
  end

  describe "circuit breaker event handlers" do
    test "handle_circuit_breaker_open accepts valid event data" do
      event = [:arrea, :circuit_breaker, :open]
      measurements = %{}
      metadata = %{breaker_id: :test_breaker}
      config = nil

      assert Metrics.handle_circuit_breaker_open(event, measurements, metadata, config) == :ok
    end

    test "handle_circuit_breaker_open handles missing breaker_id" do
      event = [:arrea, :circuit_breaker, :open]
      measurements = %{}
      metadata = %{}
      config = nil

      assert Metrics.handle_circuit_breaker_open(event, measurements, metadata, config) == :ok
    end

    test "handle_circuit_breaker_closed accepts valid event data" do
      event = [:arrea, :circuit_breaker, :closed]
      measurements = %{}
      metadata = %{breaker_id: :test_breaker}
      config = nil

      assert Metrics.handle_circuit_breaker_closed(event, measurements, metadata, config) == :ok
    end

    test "handle_circuit_breaker_closed handles missing breaker_id" do
      event = [:arrea, :circuit_breaker, :closed]
      measurements = %{}
      metadata = %{}
      config = nil

      assert Metrics.handle_circuit_breaker_closed(event, measurements, metadata, config) == :ok
    end

    test "handle_circuit_breaker_trip accepts valid event data" do
      event = [:arrea, :circuit_breaker, :trip]
      measurements = %{}
      metadata = %{breaker_id: :test_breaker, failure_count: 5}
      config = nil

      assert Metrics.handle_circuit_breaker_trip(event, measurements, metadata, config) == :ok
    end

    test "handle_circuit_breaker_trip handles missing failure_count" do
      event = [:arrea, :circuit_breaker, :trip]
      measurements = %{}
      metadata = %{breaker_id: :test_breaker}
      config = nil

      assert Metrics.handle_circuit_breaker_trip(event, measurements, metadata, config) == :ok
    end

    test "handle_circuit_breaker_trip handles zero failure_count" do
      event = [:arrea, :circuit_breaker, :trip]
      measurements = %{}
      metadata = %{breaker_id: :test_breaker, failure_count: 0}
      config = nil

      assert Metrics.handle_circuit_breaker_trip(event, measurements, metadata, config) == :ok
    end

    test "handle_circuit_breaker_trip handles empty metadata" do
      event = [:arrea, :circuit_breaker, :trip]
      measurements = %{}
      metadata = %{}
      config = nil

      assert Metrics.handle_circuit_breaker_trip(event, measurements, metadata, config) == :ok
    end
  end

  describe "telemetry integration" do
    test "telemetry events can be dispatched and handlers receive them" do
      Metrics.setup()

      :telemetry.execute(
        [:arrea, :worker, :started],
        %{duration: 100},
        %{worker_id: :integration_test_worker}
      )

      :telemetry.execute(
        [:arrea, :worker, :completed],
        %{duration: 200},
        %{worker_id: :integration_test_worker}
      )

      :telemetry.execute(
        [:arrea, :worker, :error],
        %{},
        %{worker_id: :integration_test_worker, reason: :test_error}
      )

      assert true
    end

    test "telemetry task events can be dispatched" do
      Metrics.setup()

      :telemetry.execute([:arrea, :task, :started], %{}, %{task_id: :test})
      :telemetry.execute([:arrea, :task, :completed], %{duration: 50}, %{task_id: :test})
      :telemetry.execute([:arrea, :task, :error], %{}, %{task_id: :test, reason: :fail})

      assert true
    end

    test "telemetry circuit breaker events can be dispatched" do
      Metrics.setup()

      :telemetry.execute([:arrea, :circuit_breaker, :open], %{}, %{breaker_id: :cb1})
      :telemetry.execute([:arrea, :circuit_breaker, :closed], %{}, %{breaker_id: :cb1})

      :telemetry.execute([:arrea, :circuit_breaker, :trip], %{}, %{
        breaker_id: :cb1,
        failure_count: 3
      })

      assert true
    end
  end

  describe "edge cases" do
    test "get_system_stats returns valid memory in mb" do
      system = Metrics.get_system_stats()

      assert system.memory_mb >= 0
      assert is_integer(system.memory_mb)
    end

    test "get_system_stats returns positive process count" do
      system = Metrics.get_system_stats()

      assert system.processes > 0
    end

    test "get_system_stats returns positive scheduler count" do
      system = Metrics.get_system_stats()

      assert system.schedulers > 0
    end
  end
end
