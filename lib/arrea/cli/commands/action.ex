defmodule Arrea.CLI.Commands.Action do
  @moduledoc """
  `arrea action` — Execute Arrea commands from JSON input.

  Accepts JSON from stdin, a file, or inline data and dispatches commands
  to `Arrea.CLI.main/1`. Supports single actions and batch operations.
  """

  alias Alaja.Components.{Header, Separator, Table}

  @doc false
  @spec execute_with_opts(map()) :: :ok | no_return()
  def execute_with_opts(opts) do
    case get_json(opts) do
      {:ok, json_str} ->
        case Jason.decode(json_str) do
          {:ok, data} ->
            process_data(data)

          {:error, error} ->
            IO.puts(:stderr, "Error: invalid JSON: #{error}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  # ─── JSON source resolution ───────────────────────────────────────────────

  defp get_json(opts) do
    cond do
      opts[:stdin] ->
        read_stdin()

      opts[:file] ->
        read_file(opts[:file])

      opts[:data] ->
        {:ok, opts[:data]}

      true ->
        read_stdin()
    end
  end

  defp read_stdin do
    case IO.binread(:stdio, :eof) do
      :eof -> {:error, "No data received from stdin"}
      data when is_binary(data) and data == "" -> {:error, "No data received from stdin"}
      data -> {:ok, String.trim(data)}
    end
  end

  defp read_file(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Cannot read '#{path}': #{reason}"}
      end
    else
      {:error, "File not found: '#{path}'"}
    end
  end

  # ─── Data processing ──────────────────────────────────────────────────────

  defp process_data(%{"actions" => actions} = data) do
    verbose = Map.get(data, "verbose", false)
    quiet = Map.get(data, "quiet", false)

    actions
    |> Enum.sort_by(&Map.get(&1, "order", 0))
    |> Enum.each(fn action ->
      execute_action(action, verbose, quiet)
    end)

    :ok
  end

  defp process_data(data) when is_map(data) do
    verbose = Map.get(data, "verbose", false)
    quiet = Map.get(data, "quiet", false)
    execute_action(data, verbose, quiet)
  end

  defp process_data(_data) do
    IO.puts(:stderr, "Error: expected a JSON object or object with 'actions' array")
    System.halt(1)
  end

  defp execute_action(action, verbose, quiet) do
    cmd = Map.get(action, "command") || Map.get(action, "action")
    args = Map.get(action, "args") || Map.get(action, "params") || []

    if is_nil(cmd) do
      IO.puts(:stderr, "  Error: missing 'command' field")
    else
      full_args = build_args(cmd, args, verbose, quiet)
      Arrea.CLI.main(full_args)
    end
  end

  defp build_args(cmd, args, verbose, quiet) do
    cmd_parts =
      if String.contains?(cmd, " ") do
        String.split(cmd)
      else
        [cmd]
      end

    string_args = Enum.map(args, &to_string/1)
    extra = cmd_parts ++ string_args

    extra =
      if verbose do
        extra ++ ["--verbose"]
      else
        extra
      end

    if quiet, do: extra ++ ["--quiet"], else: extra
  end

  # ─── Help ─────────────────────────────────────────────────────────────────

  @doc false
  @spec help() :: :ok
  def help do
    Header.print("Arrea Action",
      subtitle: "Execute Arrea commands from JSON input",
      size: :small
    )

    IO.puts("")

    Separator.print("DESCRIPTION", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  Execute Arrea commands from JSON input. Accepts JSON from stdin,")
    IO.puts("  a file, or inline data. Supports single actions and batch")
    IO.puts("  operations with ordered execution.")
    IO.puts("")

    Separator.print("USAGE", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  echo '<json>' | arrea action")
    IO.puts("  arrea action --file <path>")
    IO.puts("  arrea action --data <json>")
    IO.puts("  arrea action --stdin")
    IO.puts("")

    Separator.print("OPTIONS", char: "━", width: 50, color: {0, 180, 216})

    Table.print(
      headers: ["Option", "Alias", "Type", "Description"],
      rows: [
        ["--file PATH", "-f", "string", "Read JSON from a file"],
        ["--data JSON", "-d", "string", "Inline JSON string"],
        ["--stdin", "-s", "boolean", "Force reading from stdin"]
      ],
      table_border: :none,
      padding: 1
    )

    IO.puts("")

    Separator.print("SOURCE PRIORITY", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  --stdin > --file > --data > (implicit stdin)")
    IO.puts("")

    Separator.print("JSON SCHEMA", char: "━", width: 50, color: {0, 180, 216})

    IO.puts("  Single action:")

    IO.puts(
      "  #{String.replace(~s({\n    "command": "run",\n    "args": ["--command", "echo hello"]\n  }), "  ", "")}"
    )

    IO.puts("")

    IO.puts("  Batch actions:")

    IO.puts(
      "  #{String.replace(~s({\n    "verbose": true,\n    "quiet": false,\n    "actions": [\n      {"command": "run", "args": ["--command", "echo step 1"], "order": 0},\n      {"command": "run", "args": ["--command", "echo step 2", "--quiet"], "order": 1}\n    ]\n  }), "  ", "")}"
    )

    IO.puts("")

    Separator.print("FIELD ALIASES", char: "━", width: 50, color: {0, 180, 216})

    Table.print(
      headers: ["Field", "Alias", "Description"],
      rows: [
        ["command", "action", "Command to execute (run, config, ...)"],
        ["args", "params", "Arguments for the command"],
        ["order", "", "Execution order (batch mode)"]
      ],
      table_border: :none,
      padding: 1
    )

    IO.puts("")

    Separator.print("EXAMPLES", char: "━", width: 50, color: {0, 180, 216})

    IO.puts(~S"""
    # Pipe JSON to action
      echo '#{"command":"run","args":["--command","echo hello"]}' | arrea action

    # From a file
      arrea action --file ./pipeline.json

    # Inline JSON data
      arrea action --data '#{"command":"run","args":["--command","echo done","--quiet"]}'

    # Using field aliases
      arrea action --data '#{"action":"config","params":["get","max_workers"]}'

    # Batch actions with ordering
      arrea action --data '#{"actions":[{"command":"run","args":["--command","echo first"],"order":0},{"command":"run","args":["--command","echo second"],"order":1}]}'

    # With verbose flag
      arrea action --data '#{"command":"run","args":["--command","echo hi"],"verbose":true}'

    # Force stdin mode
      arrea action --stdin < commands.json
    """)

    IO.puts("")
    :ok
  end
end
