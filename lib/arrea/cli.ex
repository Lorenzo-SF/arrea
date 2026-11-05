defmodule Arrea.CLI do
  @moduledoc """
  Entry point for the Arrea command-line interface.

  Safe to call **in-process**: it returns a value and never halts. A host that
  embeds Arrea calls this and keeps its VM.

  The exit code is somebody else's business, and that somebody is
  `Arrea.CLI.Escript` — the only module in Arrea allowed to halt, because it is
  the `main_module` of the escript and a shell reads its status.

  The DSL's `halt_on_error` is off in `Arrea.CLI.Definition`: it compiles to a
  `System.halt/1`, which is uncatchable and takes the caller's whole VM with it.
  Arrea is a binary *and* a library, and with that flag on only the binary half
  worked. The measurable cost was that `mix test` died partway without printing
  its summary, so nobody could tell how many tests had run. See
  `Arrea.CLI.Definition`.
  """

  alias Arrea.CLI.Definition

  @doc """
  Runs the CLI and returns the result. **Does not halt.**

  Use this from tests and from a host that embeds Arrea.
  """
  @spec main([String.t()]) :: term()
  def main(args), do: Definition.main(args)
end
