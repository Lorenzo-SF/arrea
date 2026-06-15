defmodule Arrea.Telemetry do
  @moduledoc """
  Telemetry module for `Arrea`.

  Provides measurement and event emission functions to monitor
  engine operations. Delegates to submodules:

  - `Arrea.Telemetry.Metrics` — Metrics collection via ETS
  - `Arrea.Telemetry.Events` — Definition and emission of categorized events
  - `Arrea.Telemetry.DebugHandler` — Debug handler for development

  ## Usage

      # Execute with telemetry measurement
      Arrea.Telemetry.measure(fn ->
        # Your code here
      end)

      # Configure all metric handlers
      Arrea.Telemetry.setup()
  """

  alias Arrea.Telemetry.{DebugHandler, Events, Metrics}

  @doc """
  Executes a function with telemetry measurement.

  ## Options
    - `:metadata` - Additional metadata for the event

  ## Examples

      iex> Arrea.Telemetry.measure(fn -> Process.sleep(10) end)
      :ok

  """
  @spec measure(fun(), map() | keyword()) :: term()
  def measure(fun, opts \\ []) when is_function(fun, 0) do
    metadata =
      case opts do
        %{} = map -> map
        _ -> Keyword.get(opts, :metadata, %{})
      end

    start = System.monotonic_time(:microsecond)

    try do
      result = fun.()
      {:ok, result}
    rescue
      e ->
        {:error, e}
    after
      stop = System.monotonic_time(:microsecond)
      duration = stop - start
      :telemetry.execute([:arrea, :measure], %{duration: duration}, metadata)
    end
  end

  @doc """
  Emits a custom telemetry event.

  ## Parameters
    - type - The type/name of the event
    - measurements - Map of measurement values
    - metadata - Map of metadata

  ## Examples

      iex> Arrea.Telemetry.emit(:custom_event, %{value: 1}, %{tag: "test"})
      :ok

  """
  @spec emit(atom(), map(), map()) :: :ok
  def emit(type, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute([:arrea, type], measurements, metadata)
  end

  @doc """
  Executes a function and returns the result, measuring execution time.

  ## Examples

      iex> Arrea.Telemetry.measure_with_result(fn -> {:ok, "data"} end)
      {:ok, "data", 0}

  """
  @spec measure_with_result(fun()) ::
          {:ok, term(), non_neg_integer()} | {:error, term(), non_neg_integer()}
  def measure_with_result(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:microsecond)

    try do
      result = fun.()
      stop = System.monotonic_time(:microsecond)
      duration = stop - start
      :telemetry.execute([:arrea, :measure], %{duration: duration}, %{status: :ok})
      {:ok, result, duration}
    rescue
      e ->
        stop = System.monotonic_time(:microsecond)
        duration = stop - start

        :telemetry.execute([:arrea, :measure], %{duration: duration}, %{status: :error, error: e})

        {:error, Exception.message(e), duration}
    end
  end

  defdelegate setup(), to: Metrics
  defdelegate get_current(), to: Metrics
  defdelegate attach(), to: DebugHandler
  defdelegate detach(), to: DebugHandler

  defdelegate emit_worker(type, measurements, metadata), to: Events
  defdelegate emit_communication(type, measurements, metadata), to: Events
  defdelegate emit_validation(type, measurements, metadata), to: Events
  defdelegate emit_ui(type, measurements, metadata), to: Events
end
