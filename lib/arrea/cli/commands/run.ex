defmodule Arrea.CLI.Commands.Run do
  @moduledoc """
  `arrea run` — Execute shell commands using the Arrea engine.
  """

  alias Alaja.Components.{Header, Separator, Table}
  alias Arrea.CLI.Commands.Run.Execution
  alias Arrea.Validation.Validator

  @doc false
  @spec execute_with_opts(map(), keyword()) :: :ok | no_return()
  def execute_with_opts(opts, exec_opts) do
    commands = Map.get(opts, :command, [])
    validate_commands!(commands)
    exec_opts = merge_shell_opt(opts, exec_opts)
    Execution.execute(opts, exec_opts)
  end

  defp validate_commands!(commands) do
    if commands == [] do
      IO.puts(:stderr, "Error: at least one --command is required")
      System.halt(1)
    end

    errors =
      commands
      |> Enum.with_index()
      |> Enum.reduce([], fn {cmd, idx}, acc ->
        case Validator.validate_command(cmd) do
          {:ok, _} -> acc
          {:error, reason} -> acc ++ ["[#{idx + 1}] #{cmd}: #{inspect(reason)}"]
        end
      end)

    if errors != [] do
      IO.puts(:stderr, "Error: command validation failed")
      Enum.each(errors, fn e -> IO.puts(:stderr, "  #{e}") end)
      System.halt(1)
    end
  end

  defp merge_shell_opt(opts, exec_opts) do
    case opts[:shell] do
      nil -> exec_opts
      shell -> Keyword.put(exec_opts, :shell, shell)
    end
  end

  @doc false
  @spec help() :: :ok
  def help do
    Header.print("Arrea Run",
      subtitle: "Execute shell commands with the Arrea engine",
      size: :small
    )

    IO.puts("")

    Separator.print("DESCRIPTION", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  Execute one or more shell commands using the Arrea async")
    IO.puts("  process orchestrator. Supports parallel execution with worker")
    IO.puts("  pools, command validation, timeouts, progress tracking, custom")
    IO.puts("  shell selection, and asdf/mise runtime version management.")
    IO.puts("")

    Separator.print("USAGE", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  arrea run --command <cmd> [options]")
    IO.puts("  arrea run --command <cmd1> --command <cmd2> [options]")
    IO.puts("")

    Separator.print("REQUIRED", char: "━", width: 50, color: {0, 180, 216})

    Table.print(
      headers: ["Option", "Type", "Description"],
      rows: [
        ["--command CMD", "string (repeatable)", "Shell command to execute."]
      ],
      table_border: :none,
      padding: 1
    )

    IO.puts("")

    Separator.print("OPTIONS", char: "━", width: 50, color: {0, 180, 216})

    Table.print(
      headers: ["Option", "Type", "Default", "Description"],
      rows: [
        ["--parallel N", "integer", "4", "Maximum commands in parallel"],
        ["--timeout MS", "integer", "30000", "Timeout per command in ms"],
        ["--quiet, -q", "boolean", "false", "Suppress progress output"],
        ["--header TEXT", "string", "Arrea Run", "Header text"],
        ["--header-color C", "string", "", "Header color"],
        ["--subtitle TEXT", "string", "N command(s)", "Subtitle text"],
        ["--subtitle-color C", "string", "", "Subtitle color"],
        ["--shell SHELL", "string", "user shell", "Shell to use (e.g. bash, zsh)"],
        ["--asdf-<runtime> V", "string", "", "Runtime version via asdf env vars (repeatable)"],
        ["--mise-<runtime> V", "string", "", "Runtime version via mise exec (repeatable)"]
      ],
      table_border: :none,
      padding: 1
    )

    IO.puts("")

    Separator.print("SECURITY", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  Arrea validates all commands before execution, blocking")
    IO.puts("  dangerous patterns (rm -rf /, sudo, dd, mkfs, fork bombs,")
    IO.puts("  command injection, wget|sh, curl|bash).")
    IO.puts("")

    Separator.print("EXAMPLES", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("# Single command\n  arrea run --command \"echo hello\"")

    IO.puts(~S|# Multiple commands (parallel)
  arrea run --command "echo a" --command "echo b"|)

    IO.puts(~S|# With worker limit
  arrea run --command "sleep 1" --command "sleep 2" --parallel 2|)

    IO.puts("# Custom timeout\n  arrea run --command \"sleep 10\" --timeout 5000")
    IO.puts("# Quiet mode\n  arrea run --command \"echo done\" --quiet")

    IO.puts(~S|# Custom header
  arrea run --command "mix test" --header "Tests" --header-color cyan|)

    IO.puts("# Custom shell\n  arrea run --command \"echo \$0\" --shell zsh")
    IO.puts("# With ASDF version\n  arrea run --command \"mix test\" --asdf-elixir 1.18.0")
    IO.puts("# With mise version\n  arrea run --command \"node -v\" --mise-node 20.0.0")

    IO.puts("")
    :ok
  end
end
