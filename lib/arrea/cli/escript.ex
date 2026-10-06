defmodule Arrea.CLI.Escript do
  @moduledoc """
  The escript boundary, and the only module in Arrea allowed to halt.

  This module is the `main_module` of the escript. A shell reads the exit
  status, and an escript's status comes from *halting* with it: returning an
  integer from `main/1` does nothing, because the generated wrapper calls
  `halt(0)` on the way out whatever came back. That is why `arrea run` could
  report a failed command and still exit 0.

  It lives apart from `Arrea.CLI` on purpose. `Arrea.CLI.main/1` returns and is
  safe to call in-process — that is what the tests do, and what a host embedding
  Arrea needs. If the halt lived there, every test that called it would take the
  test VM down with it. Which is exactly what happened before: `halt_on_error`
  in the DSL killed `mix test` mid-run, with no summary.
  """

  alias Arrea.CLI

  @doc """
  Escript entry point. Runs the CLI and halts with the resulting status.
  """
  @spec main([String.t()]) :: no_return()
  def main(args), do: System.halt(exit_status(CLI.main(args)))

  @doc """
  The exit code a result of `CLI.main/1` should produce.

  Anything that is not plainly `:ok` is a failure. A script cannot tell the
  difference between "it failed" and "it never said anything", so both are 1.
  """
  @spec exit_status(term()) :: 0 | 1
  def exit_status(:ok), do: 0
  def exit_status(_other), do: 1
end
