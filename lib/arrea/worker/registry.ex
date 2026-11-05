defmodule Arrea.Worker.Registry do
  @moduledoc """
  Registry helper functions for `Arrea.Worker`.

  Splits out the safe Monitor communication logic from `Arrea.Worker` so
  the worker GenServer remains focused on state transitions.

  Not part of the public API — used only by `Arrea.Worker`.
  """

  require Logger

  alias Arrea.Monitor

  @spec safe_register_worker(any(), any()) :: :ok | {:error, term()}
  def safe_register_worker(worker_id, state) do
    case Process.whereis(Arrea.Monitor) do
      pid when is_pid(pid) ->
        try do
          Monitor.register_worker(worker_id, state)
          :ok
        rescue
          e -> {:error, {:monitor_error, e}}
        catch
          :exit, reason -> {:error, {:monitor_exit, reason}}
        end

      nil ->
        {:error, :monitor_not_running}
    end
  end

  @spec safe_update_worker(term(), map()) :: :ok
  def safe_update_worker(worker_id, updates) do
    safe_monitor_call(fn -> Monitor.update_worker(worker_id, updates) end)
  end

  @spec safe_worker_finished(term(), atom(), integer()) :: :ok
  def safe_worker_finished(worker_id, status, duration_ms) do
    safe_monitor_call(fn -> Monitor.worker_finished(worker_id, status, duration_ms) end)
  end

  @spec safe_notify_monitor_finished(term(), term()) :: :ok
  def safe_notify_monitor_finished(worker_id, reason) do
    safe_monitor_call(fn ->
      ended_at = System.monotonic_time(:millisecond)

      status =
        case reason do
          :normal -> :finished
          {:error, _} -> :finished
          _ -> :error
        end

      Monitor.worker_finished(worker_id, status, ended_at)
    end)
  end

  @spec safe_monitor_call((-> :ok | {:ok, term()})) :: :ok
  defp safe_monitor_call(func) do
    func.()
    :ok
  rescue
    e ->
      Logger.error("[Worker] Monitor call failed: #{inspect(e)} — worker stats may be stale")
      :ok
  catch
    :exit, reason ->
      Logger.error("[Worker] Monitor call exited: #{inspect(reason)} — worker stats may be stale")
      :ok
  end
end
