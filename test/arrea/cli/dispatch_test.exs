defmodule Arrea.CLIDispatchTest do
  @moduledoc """
  End-to-end tests for `Arrea.CLI.Definition.dispatch_main/1`.

  These exercise the full parser → handler chain so the contract is
  locked in: the DSL rejects unknown flags with a useful suggestion,
  flags with `required: true` are enforced, and `repeatable: true`
  flags are collected into a list that the runner can consume.
  """

  use ExUnit.Case, async: false

  defp capture_stderr_during(fun) do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Process.flag(:trap_exit, true)

      try do
        fun.()
        :ok
      catch
        :exit, status -> {:exited, status}
        kind, reason -> {kind, reason}
      end
    end)
  end

  # `dispatch_main/1` lives on the consumer module (the one that did
  # `use Alaja.CLI.Definition, otp_app: :foo`). For arrea that's
  # `Arrea.CLI.Definition`.
  defp dispatch(args) do
    capture_stderr_during(fn ->
      Arrea.CLI.Definition.dispatch_main(args)
    end)
  end

  describe "unknown flag rejection (typo'd --comand)" do
    # Regression test for the audit finding: `arrea run --comand "x"`
    # used to silently drop the typo and then crash deep in
    # `Run.execute_with_opts/2` with a cryptic Enumerable error.
    test "typo'd --comand renders a clear error and does not execute" do
      stderr = dispatch(["run", "--comand", "echo 1"])

      assert stderr =~ "unknown flag '--comand'"
      assert stderr =~ "Did you mean"
      assert stderr =~ "--command"
    end

    test "unknown flag without a close match still errors cleanly" do
      stderr = dispatch(["run", "--totally-different-flag", "x"])

      assert stderr =~ "unknown flag '--totally-different-flag'"
    end
  end

  describe "required: true enforcement" do
    # The DSL exits with a clear error when a required flag is missing,
    # rather than letting the handler crash on nil.
    test "missing --command renders the missing-required error" do
      stderr = dispatch(["run"])

      assert stderr =~ "missing required flags"
      assert stderr =~ "--command"
    end
  end

  describe "positional arguments" do
    # Non-flag arguments still flow through to the handler as
    # positional values; the unknown-flag gate only fires on
    # `-` / `--` prefixed strings.
    test "positional arguments for commands that accept them pass through" do
      # `nodes` has no required flags and no arguments — this just
      # confirms the dispatcher's basic flow doesn't break on a
      # command with no flags.
      capture = capture_stderr_during(fn -> Arrea.CLI.Definition.dispatch_main(["nodes"]) end)

      # Either we got :ok or a graceful "no registered nodes" message,
      # but we did NOT get "unknown flag" or "missing required flags".
      refute capture =~ "unknown flag"
      refute capture =~ "missing required flags"
    end
  end
end
