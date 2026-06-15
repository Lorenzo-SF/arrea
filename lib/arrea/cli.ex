defmodule Arrea.CLI do
  @moduledoc """
  Entry point for the Arrea command-line interface.

  Thin wrapper that delegates to `Arrea.CLI.Definition.main/1`.
  """

  alias Arrea.CLI.Definition

  @doc """
  Main entry point. Delegates to the DSL definition.
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(args), do: Definition.main(args)
end
