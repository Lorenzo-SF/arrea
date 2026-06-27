defmodule Arrea.CLI.Commands.Run do
  @moduledoc """
  `arrea run` — Execute shell commands using the Arrea engine.
  """

  alias Alaja.CLI.Parser
  alias Alaja.Components.{Header, Separator, Table}
  alias Alaja.Printer
  alias Alaja.Structures.ChunkText
  alias Arrea.Parallel
  alias Arrea.Validation.Validator

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @doc false
  @spec execute_with_opts(map(), keyword()) :: :ok | no_return()
  def execute_with_opts(opts, exec_opts) do
    execute(opts, exec_opts)
  end

  defp execute(opts, exec_opts) do
    commands = Map.get(opts, :command, [])
    validate_commands!(commands)

    parallel = opts[:parallel] || 4
    timeout = opts[:timeout] || 30_000
    quiet = opts[:quiet] || false

    ensure_engine_started!()
    maybe_print_header(opts, commands)
    exec_opts = merge_shell_opt(opts, exec_opts)

    results = execute_commands(commands, parallel, timeout, quiet, exec_opts)
    maybe_print_results(results, quiet)
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

  defp maybe_print_header(opts, commands) do
    quiet = opts[:quiet] || false

    if not quiet do
      header_text = opts[:header] || "Arrea Run"
      subtitle_text = opts[:subtitle] || "#{length(commands)} command(s)"
      header_color = parse_color(Map.get(opts, :header_color))
      subtitle_color = parse_color(Map.get(opts, :subtitle_color))

      Header.print(header_text,
        subtitle: subtitle_text,
        size: :small,
        color: header_color,
        subtitle_color: subtitle_color
      )

      IO.puts("")
    end
  end

  defp merge_shell_opt(opts, exec_opts) do
    case opts[:shell] do
      nil -> exec_opts
      shell -> Keyword.put(exec_opts, :shell, shell)
    end
  end

  defp maybe_print_results(results, quiet) do
    if not quiet, do: print_results(results)
  end

  defp ensure_engine_started! do
    case Process.whereis(Arrea.Leader) do
      nil ->
        {:ok, _} = Arrea.Supervisor.start_link([])
        :ok

      _pid ->
        :ok
    end
  end

  defp execute_commands(commands, parallel, timeout, quiet, exec_opts) do
    if length(commands) == 1 do
      execute_single(commands, timeout, quiet, exec_opts)
    else
      execute_parallel(commands, parallel, timeout, quiet, exec_opts)
    end
  end

  defp execute_single(commands, timeout, quiet, exec_opts) do
    cmd = hd(commands)
    start = System.monotonic_time()

    opts = Keyword.put(exec_opts, :timeout, timeout)

    result =
      case Arrea.execute(cmd, opts) do
        {:ok, %Arrea.Result{data: data}} ->
          duration = System.monotonic_time() - start
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)

          %{
            command: cmd,
            exit_code: extract_exit_code(data),
            stdout: extract_stdout(data),
            duration_ms: duration_ms
          }

        {:error, %Arrea.Error{message: msg}} ->
          duration = System.monotonic_time() - start
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)
          %{command: cmd, exit_code: -1, stdout: "Error: #{msg}", duration_ms: duration_ms}
      end

    if quiet do
      if result.stdout != "", do: IO.puts(result.stdout)
    else
      label = truncate_command(cmd, 20)

      if result.exit_code == 0 do
        Printer.print([
          ChunkText.new("  "),
          ChunkText.new("✓", color: {72, 187, 120}),
          ChunkText.new(" #{label} (#{result.duration_ms}ms)")
        ])
      else
        Printer.print([
          ChunkText.new("  "),
          ChunkText.new("✗", color: {245, 101, 101}, effects: [:bold]),
          ChunkText.new(" #{label} (exit #{result.exit_code}, #{result.duration_ms}ms)")
        ])
      end
    end

    [result]
  end

  defp execute_parallel(commands, workers, timeout, quiet, exec_opts) do
    total = length(commands)

    if quiet do
      sync_opts = Keyword.merge(exec_opts, workers: workers, timeout: timeout)

      Parallel.run_sync(commands, sync_opts)
      |> Enum.with_index()
      |> Enum.map(fn {result, idx} ->
        entry = build_result_entry(Enum.at(commands, idx), result)
        maybe_echo_output(entry)
        entry
      end)
    else
      execute_parallel_animated(commands, workers, timeout, total, exec_opts)
    end
  end

  defp maybe_echo_output(%{stdout: stdout}) when stdout != "", do: IO.puts(stdout)
  defp maybe_echo_output(_entry), do: :ok

  defp execute_parallel_animated(commands, _workers, timeout, total, exec_opts) do
    Enum.each(Enum.with_index(commands), fn {cmd, idx} ->
      label = truncate_command(cmd, 20)
      spinner = Enum.at(@spinner_frames, rem(idx, length(@spinner_frames)))

      Printer.print([
        ChunkText.new("  "),
        ChunkText.new(spinner, color: {0, 180, 216}),
        ChunkText.new(" Running \"#{label}...\"")
      ])
    end)

    opts = Keyword.put(exec_opts, :timeout, timeout)

    tasks =
      commands
      |> Enum.with_index()
      |> Enum.map(fn {cmd, idx} ->
        task =
          Task.async(fn ->
            start = System.monotonic_time(:millisecond)
            result = Arrea.execute(cmd, opts)
            duration = System.monotonic_time(:millisecond) - start
            {idx, result, duration}
          end)

        {idx, cmd, task}
      end)

    task_structs = Enum.map(tasks, fn {_, _, t} -> t end)

    animate_loop(commands, tasks, task_structs, %{}, MapSet.new(0..(total - 1)), 0)
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_, entry} -> entry end)
  end

  defp animate_loop(commands, tasks, task_structs, states, pending, anim_frame) do
    if MapSet.size(pending) == 0 do
      states
    else
      completed = Task.yield_many(task_structs, 100)
      {states, pending} = process_completed_tasks(tasks, completed, states, pending)
      render_progress(commands, states, anim_frame)
      animate_loop(commands, tasks, task_structs, states, pending, anim_frame + 1)
    end
  end

  defp process_completed_tasks(tasks, completed, states, pending) do
    Enum.zip(tasks, completed)
    |> Enum.reduce({states, pending}, &process_single_task/2)
  end

  defp process_single_task({{idx, cmd, _task}, {_t, task_result}}, {states_acc, pending_acc}) do
    if MapSet.member?(pending_acc, idx) do
      entry = build_entry_from_result(cmd, task_result, idx)

      if entry do
        {Map.put(states_acc, idx, entry), MapSet.delete(pending_acc, idx)}
      else
        {states_acc, pending_acc}
      end
    else
      {states_acc, pending_acc}
    end
  end

  defp build_entry_from_result(cmd, task_result, idx) do
    case task_result do
      {:ok, {^idx, {:ok, %Arrea.Result{data: data}}, duration}} ->
        %{
          command: cmd,
          exit_code: extract_exit_code(data),
          stdout: extract_stdout(data),
          duration_ms: duration
        }

      {:ok, {^idx, {:error, %Arrea.Error{message: msg}}, duration}} ->
        %{command: cmd, exit_code: -1, stdout: "Error: #{msg}", duration_ms: duration}

      _ ->
        nil
    end
  end

  defp render_progress(commands, states, anim_frame) do
    IO.write("\e[#{length(commands)}A")

    Enum.each(0..(length(commands) - 1), fn idx ->
      IO.write("\e[K")
      render_progress_row(commands, states, anim_frame, idx)
    end)
  end

  defp render_progress_row(commands, states, anim_frame, idx) do
    case Map.get(states, idx) do
      nil ->
        label = truncate_command(Enum.at(commands, idx), 20)
        spinner = Enum.at(@spinner_frames, rem(anim_frame + idx, length(@spinner_frames)))

        Printer.print([
          ChunkText.new("  "),
          ChunkText.new(spinner, color: {0, 180, 216}),
          ChunkText.new(" Running \"#{label}...\"")
        ])

      %{exit_code: 0, duration_ms: ms} = entry ->
        label = truncate_command(entry.command, 20)

        Printer.print([
          ChunkText.new("  "),
          ChunkText.new("✓", color: {72, 187, 120}),
          ChunkText.new(" #{label} (#{ms}ms)")
        ])

      entry ->
        label = truncate_command(entry.command, 20)
        code = entry[:exit_code] || -1
        ms = entry[:duration_ms] || 0

        Printer.print([
          ChunkText.new("  "),
          ChunkText.new("✗", color: {245, 101, 101}, effects: [:bold]),
          ChunkText.new(" #{label} (exit #{code}, #{ms}ms)")
        ])
    end
  end

  defp truncate_command(cmd, max_len) do
    if String.length(cmd) > max_len do
      String.slice(cmd, 0, max_len) <> "..."
    else
      cmd
    end
  end

  defp build_result_entry(
         cmd,
         {:ok, %{stdout: stdout, exit_code: exit_code, duration_ms: duration_ms}}
       ) do
    %{
      command: cmd,
      exit_code: exit_code,
      stdout: String.trim(stdout || ""),
      duration_ms: duration_ms || 0
    }
  end

  defp build_result_entry(cmd, {:ok, %{exit_code: exit_code} = data}) do
    %{
      command: cmd,
      exit_code: exit_code,
      stdout: inspect(Map.drop(data, [:exit_code])),
      duration_ms: 0
    }
  end

  defp build_result_entry(cmd, {:error, %{error: error, exit_code: code}}) do
    %{command: cmd, exit_code: code || -1, stdout: "Error: #{inspect(error)}", duration_ms: 0}
  end

  defp build_result_entry(cmd, {:error, reason}) do
    %{command: cmd, exit_code: -1, stdout: "Error: #{inspect(reason)}", duration_ms: 0}
  end

  defp build_result_entry(cmd, %{stdout: stdout, exit_code: exit_code}) do
    %{command: cmd, exit_code: exit_code, stdout: String.trim(stdout || ""), duration_ms: 0}
  end

  defp extract_exit_code(%{exit_code: code}), do: code
  defp extract_exit_code(%{}), do: 0
  defp extract_exit_code(_), do: 0

  defp extract_stdout(%{stdout: s}), do: String.trim(s || "")
  defp extract_stdout(%{result: r}), do: inspect(r)
  defp extract_stdout(_), do: ""

  defp print_results(results) do
    successes = Enum.count(results, &(&1.exit_code == 0))
    failures = Enum.count(results, &(&1.exit_code != 0))
    total = length(results)

    IO.puts("")
    Separator.print("RESULTS", char: "━", width: 50, color: {0, 180, 216})

    Printer.print([
      ChunkText.new(" "),
      ChunkText.new("✓", color: {72, 187, 120}),
      ChunkText.new(" Success\t#{successes}"),
      ChunkText.new("   ✗", color: {245, 101, 101}),
      ChunkText.new(" Failed\t#{failures}"),
      ChunkText.new("   Total\t#{total}")
    ])

    IO.puts("")
  end

  defp parse_color(nil), do: nil

  defp parse_color("theme:" <> name) do
    # Map theme names to colors (fallback). Adjust as needed.
    case String.downcase(name) do
      "ternary" -> {255, 165, 0}
      "quaternary" -> {128, 0, 128}
      _ -> nil
    end
  end

  defp parse_color(s) do
    case Parser.parse_color(s) do
      {:ok, c} -> c
      _ -> nil
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
