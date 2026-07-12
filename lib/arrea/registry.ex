defmodule Arrea.Registry do
  @moduledoc """
  Helper module to interact with the Elixir Registry registered as
  `Arrea.Registry` in the application supervisor.

  Provides convenient wrappers for common queries.
  """

  @registry_name Arrea.Registry

  @doc "Return a map of registered worker names and their PIDs."
  @spec all() :: %{atom() => pid()}
  def all do
    Registry.select(@registry_name,
      [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
      ]
    )
    |> Enum.into(%{}, fn {name, pid} -> {name, pid} end)
  end

  @doc "Return the number of entries in the registry."
  @spec count() :: non_neg_integer()
  def count do
    Registry.select(@registry_name,
      [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$1"}}]}
      ]
    )
    |> length()
  end

  @doc "Return a list of PID(s) for the given key."
  @spec lookup(atom()) :: [pid()]
  def lookup(key) do
    Registry.lookup(@registry_name, key)
  end
end
