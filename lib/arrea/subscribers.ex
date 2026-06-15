defmodule Arrea.Subscribers do
  @moduledoc false

  @doc """
  Subscribe a PID to the subscriber set, monitoring it for cleanup.
  """
  def subscribe(subscribers, pid) do
    Process.monitor(pid)
    MapSet.put(subscribers, pid)
  end

  @doc """
  Unsubscribe a PID from the subscriber set.
  """
  def unsubscribe(subscribers, pid) do
    MapSet.delete(subscribers, pid)
  end

  @doc """
  Broadcast a message to all alive subscribers, removing dead PIDs from the set.
  Returns the updated subscriber set.
  """
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
  def handle_down(subscribers, pid) do
    MapSet.delete(subscribers, pid)
  end
end
