defmodule Arrea.Telemetry.DebugHandler do
  @moduledoc """
  Debug handler for development.

  Features:
  - Logs all telemetry events
  - Readable format
  - Filtering by component/type
  - Optional enable/disable

  ## Usage

      # Enable in development
      Arrea.Telemetry.DebugHandler.attach()

      # Disable
      Arrea.Telemetry.DebugHandler.detach()
  """

  require Logger

  @doc """
  Attaches the debug handler to all relevant events.
  """
  @spec attach() :: :ok
  def attach do
    events = [
      [:arrea, :worker, :started],
      [:arrea, :worker, :completed],
      [:arrea, :worker, :error],
      [:arrea, :task, :started],
      [:arrea, :task, :completed],
      [:arrea, :task, :error],
      [:arrea, :engine, :execute, :start],
      [:arrea, :engine, :execute, :stop],
      [:arrea, :engine, :execute, :error],
      [:arrea, :engine, :run, :start],
      [:arrea, :engine, :run, :stop],
      [:arrea, :measure],
      [:arrea, :ui, :render],
      [:arrea, :ui, :keypress],
      [:arrea, :ui, :focus_change],
      [:arrea, :app_supervisor, :init],
      [:arrea, :app_supervisor, :transition],
      [:arrea, :app_supervisor, :terminate],
      [:arrea, :application, :stopped]
    ]

    :telemetry.attach_many(
      {__MODULE__, :debug_handler},
      events,
      &__MODULE__.handle_event/4,
      nil
    )

    Logger.info("[Arrea.Telemetry.DebugHandler] Attached to #{length(events)} events")
    :ok
  end

  @doc """
  Removes the debug handler.
  """
  @spec detach() :: :ok
  def detach do
    :telemetry.detach({__MODULE__, :debug_handler})
    Logger.info("[Arrea.Telemetry.DebugHandler] Detached")
    :ok
  end

  @doc """
  Handles a telemetry event.
  """
  @spec handle_event(list(), map(), map(), term()) :: :ok
  def handle_event(event_name, measurements, metadata, _config) do
    Logger.debug(
      "[Arrea.Telemetry] #{format_event_name(event_name)} | measurements: #{inspect(measurements)} | metadata: #{inspect(metadata)}"
    )

    :ok
  end

  defp format_event_name(event_name) do
    Enum.map_join(event_name, ".", &to_string/1)
  end
end
