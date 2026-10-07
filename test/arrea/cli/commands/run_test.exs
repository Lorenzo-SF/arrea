defmodule Arrea.CLI.Commands.RunTest do
  @moduledoc """
  Tests for the `arrea run` command's public surface and the
  pre-validation helpers that `execute_with_opts/2` invokes before
  handing control to the executor.

  The full CLI parse path (including the DSL's `required: true` gate
  and unknown-flag rejection) is exercised by `Arrea.CLIDispatchTest`,
  which drives `Arrea.CLI.Definition.dispatch_main/1` end-to-end.
  """

  use ExUnit.Case, async: false

  alias Arrea.CLI.Commands.Run

  describe "help/0" do
    test "prints usage" do
      output = ExUnit.CaptureIO.capture_io(fn -> Run.help() end)
      assert output =~ "arrea run"
      assert output =~ "--command"
      assert output =~ "--parallel"
      assert output =~ "--timeout"
    end
  end

  describe "normalise_commands/1" do
    # The DSL hands us one of three shapes for a `repeatable: true`
    # flag:
    #
    #   * `nil`       — flag never passed (caught upstream by
    #                   `required: true` if it applies, but the
    #                   helper is defensive)
    #   * `"cmd"`     — flag passed exactly once
    #   * `["a","b"]` — flag passed multiple times
    #
    # The helper normalises to a list so downstream code never has to
    # branch on the shape.
    test "nil becomes an empty list" do
      assert Run.normalise_commands(nil) == []
    end

    test "a single command becomes a one-element list" do
      assert Run.normalise_commands("echo hello") == ["echo hello"]
    end

    test "a list passes through unchanged" do
      assert Run.normalise_commands(["echo a", "echo b"]) == ["echo a", "echo b"]
    end
  end

  describe "validate_commands!/1" do
    test "an empty list halts with a clear stderr message" do
      capture = ExUnit.CaptureIO.capture_io(:stderr, fn ->
        try do
          Run.validate_commands!([])
        catch
          :exit, _ -> :halted
        end
      end)

      assert capture =~ "at least one --command is required"
    end

    test "a list of safe commands returns :ok without halting" do
      capture = ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert :ok = Run.validate_commands!(["echo hello", "echo world"])
      end)

      refute capture =~ "command validation failed"
    end
  end
end
