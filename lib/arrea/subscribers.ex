defmodule Arrea.Subscribers do
  @moduledoc """
  Process subscription set with automatic cleanup on DOWN.

  Maintains a `MapSet` of subscriber PIDs and broadcasts messages to all alive
  members. Dead PIDs are removed automatically via `Process.monitor/1` (in
  `subscribe/2`) and via liveness checks (in `broadcast/2`).
  """

  @doc """
  Subscribe a PID to the subscriber set, monitoring it for cleanup.
  """
  @spec subscribe(MapSet.t(), pid()) :: MapSet.t()
  def subscribe(subscribers, pid) do
    Process.monitor(pid)
    MapSet.put(subscribers, pid)
  end

  @doc """
  Unsubscribe a PID from the subscriber set.
  """
  @spec unsubscribe(MapSet.t(), pid()) :: MapSet.t()
  def unsubscribe(subscribers, pid) do
    MapSet.delete(subscribers, pid)
  end

  @doc """
  Broadcast a message to all alive subscribers, removing dead PIDs from the set.
  Returns the updated subscriber set.
  """
  @spec broadcast(MapSet.t(), term()) :: MapSet.t()
  def broadcast(subscribers, message) do
    Enum.reduce(subscribers, subscribers, fn pid, acc ->
      if Process.alive?(pid) do
        send(pid, message)
        acc
      else
        MapSet.delete(acc, pid)
      end
    end)
  end

  @doc """
  Handle a DOWN message by removing the PID from the subscriber set.
  """
  @spec handle_down(MapSet.t(), pid()) :: MapSet.t()
  def handle_down(subscribers, pid) do
    MapSet.delete(subscribers, pid)
  end
end
