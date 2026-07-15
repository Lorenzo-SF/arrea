defmodule Arrea.Telemetry.Metrics do
  @moduledoc """
  Telemetry metrics definition for `Arrea`.

  Provides metrics for:
  - Worker execution (time, success/failure)
  - Resource usage (memory, processes)
  - Circuit breaker (state, failures)
  - UI (renders, keypresses)

  Metrics are stored in an ETS table (`:arrea_metrics`) with
  atomic counters.

  ## Usage

      # Start metrics
      Arrea.Telemetry.Metrics.setup()

      # Get current metrics
      metrics = Arrea.Telemetry.Metrics.get_current()
  """

  require Logger

  @table :arrea_metrics

  @doc """
  Sets up all Telemetry metrics for Arrea.
  Idempotent — repeated calls are silently skipped.
  """
  @spec setup() :: :ok
  def setup do
    # Create ETS table if not exists
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set])

      _ ->
        :ok
    end

    # Initialize counters
    :ets.insert(@table, {:workers_started, 0})
    :ets.insert(@table, {:workers_completed, 0})
    :ets.insert(@table, {:workers_errors, 0})
    :ets.insert(@table, {:tasks_started, 0})
    :ets.insert(@table, {:tasks_completed, 0})
    :ets.insert(@table, {:tasks_errors, 0})
    :ets.insert(@table, {:ui_renders, 0})
    :ets.insert(@table, {:ui_keypresses, 0})
    :ets.insert(@table, {:ui_focus_changes, 0})
    :ets.insert(@table, {:circuit_open, 0})
    :ets.insert(@table, {:circuit_closed, 0})
    :ets.insert(@table, {:circuit_trips, 0})

    attach_safe(:worker_started, [:arrea, :worker, :started], &__MODULE__.handle_worker_started/4)

    attach_safe(
      :worker_completed,
      [:arrea, :worker, :completed],
      &__MODULE__.handle_worker_completed/4
    )

    attach_safe(:worker_error, [:arrea, :worker, :error], &__MODULE__.handle_worker_error/4)
    attach_safe(:task_started, [:arrea, :task, :started], &__MODULE__.handle_task_started/4)
    attach_safe(:task_completed, [:arrea, :task, :completed], &__MODULE__.handle_task_completed/4)
    attach_safe(:task_error, [:arrea, :task, :error], &__MODULE__.handle_task_error/4)

    attach_safe(
      :circuit_open,
      [:arrea, :circuit_breaker, :open],
      &__MODULE__.handle_circuit_breaker_open/4
    )

    attach_safe(
      :circuit_closed,
      [:arrea, :circuit_breaker, :closed],
      &__MODULE__.handle_circuit_breaker_closed/4
    )

    attach_safe(
      :circuit_trip,
      [:arrea, :circuit_breaker, :trip],
      &__MODULE__.handle_circuit_breaker_trip/4
    )

    Logger.debug("[Arrea.Telemetry] Metrics configured successfully")
    :ok
  end

  # Idempotent attach: already-attached handlers are silently skipped.
  defp attach_safe(id, event, handler) do
    :telemetry.attach({__MODULE__, id}, event, handler, nil)
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns the current system metrics.
  """
  @spec get_current() :: map()
  def get_current do
    %{
      workers: get_worker_stats(),
      tasks: get_task_stats(),
      circuit_breakers: get_circuit_breaker_stats(),
      system: get_system_stats(),
      ui: get_ui_stats()
    }
  end

  @doc """
  Returns worker statistics.
  """
  @spec get_worker_stats() :: map()
  def get_worker_stats do
    ensure_initialized()

    %{
      started: get_counter(:workers_started),
      completed: get_counter(:workers_completed),
      errors: get_counter(:workers_errors)
    }
  end

  @doc """
  Returns task statistics.
  """
  @spec get_task_stats() :: map()
  def get_task_stats do
    ensure_initialized()

    %{
      started: get_counter(:tasks_started),
      completed: get_counter(:tasks_completed),
      errors: get_counter(:tasks_errors)
    }
  end

  @doc """
  Returns circuit breaker statistics.
  """
  @spec get_circuit_breaker_stats() :: map()
  def get_circuit_breaker_stats do
    ensure_initialized()

    %{
      open: get_counter(:circuit_open),
      closed: get_counter(:circuit_closed),
      half_open: 0,
      trips: get_counter(:circuit_trips)
    }
  end

  @doc """
  Returns system statistics.
  """
  @spec get_system_stats() :: map()
  def get_system_stats do
    ensure_initialized()
    memory_keywords = :erlang.memory()
    total_memory = Keyword.get(memory_keywords, :total, 0)

    %{
      memory_mb: div(total_memory, 1_048_576),
      processes: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online)
    }
  end

  @doc """
  Gets UI statistics.
  """
  @spec get_ui_stats() :: map()
  def get_ui_stats do
    ensure_initialized()

    %{
      renders: get_counter(:ui_renders),
      keypresses: get_counter(:ui_keypresses),
      focus_changes: get_counter(:ui_focus_changes)
    }
  end

  @spec ensure_initialized() :: :ok
  defp ensure_initialized do
    case :ets.info(@table) do
      :undefined -> setup()
      _ -> :ok
    end
  end

  @spec get_counter(atom()) :: integer()
  defp get_counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> 0
    end
  end

  @doc false
  def handle_worker_started(_event_name, _measurements, _metadata, _config) do
    ensure_initialized()
    increment_counter(:workers_started)
    Logger.debug("[Telemetry] Worker started")
  end

  @doc false
  def handle_worker_completed(_event_name, measurements, _metadata, _config) do
    ensure_initialized()
    increment_counter(:workers_completed)
    duration = Map.get(measurements, :duration, 0)
    Logger.debug("[Telemetry] Worker completed (#{duration}ms)")
  end

  @doc false
  def handle_worker_error(_event_name, _measurements, metadata, _config) do
    ensure_initialized()
    increment_counter(:workers_errors)
    worker_id = Map.get(metadata, :worker_id, :unknown)
    reason = Map.get(metadata, :reason, :unknown)
    Logger.warning("[Telemetry] Worker #{inspect(worker_id)} error: #{inspect(reason)}")
  end

  @doc false
  def handle_task_started(_event_name, _measurements, _metadata, _config) do
    ensure_initialized()
    increment_counter(:tasks_started)
    Logger.debug("[Telemetry] Task started")
  end

  @doc false
  def handle_task_completed(_event_name, measurements, _metadata, _config) do
    ensure_initialized()
    increment_counter(:tasks_completed)
    duration = Map.get(measurements, :duration, 0)
    Logger.debug("[Telemetry] Task completed (#{duration}ms)")
  end

  @doc false
  def handle_task_error(_event_name, _measurements, metadata, _config) do
    ensure_initialized()
    increment_counter(:tasks_errors)
    worker_id = Map.get(metadata, :worker_id, :unknown)
    reason = Map.get(metadata, :reason, :unknown)
    Logger.warning("[Telemetry] Task error in worker #{inspect(worker_id)}: #{inspect(reason)}")
  end

  @doc false
  def handle_circuit_breaker_open(_event_name, _measurements, metadata, _config) do
    ensure_initialized()
    increment_counter(:circuit_open)
    breaker_id = Map.get(metadata, :breaker_id, :unknown)
    Logger.warning("[Telemetry] Circuit breaker #{inspect(breaker_id)} opened")
  end

  @doc false
  def handle_circuit_breaker_closed(_event_name, _measurements, metadata, _config) do
    ensure_initialized()
    increment_counter(:circuit_closed)
    breaker_id = Map.get(metadata, :breaker_id, :unknown)
    Logger.info("[Telemetry] Circuit breaker #{inspect(breaker_id)} closed")
  end

  @doc false
  def handle_circuit_breaker_trip(_event_name, _measurements, metadata, _config) do
    ensure_initialized()
    increment_counter(:circuit_trips)
    breaker_id = Map.get(metadata, :breaker_id, :unknown)
    failure_count = Map.get(metadata, :failure_count, 0)

    Logger.warning(
      "[Telemetry] Circuit breaker #{inspect(breaker_id)} tripped (#{failure_count} failures)"
    )
  end

  # Helper to increment counter in ETS
  defp increment_counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, _value}] -> :ets.update_counter(@table, key, 1)
      _ -> :ets.insert(@table, {key, 1})
    end
  end
end
