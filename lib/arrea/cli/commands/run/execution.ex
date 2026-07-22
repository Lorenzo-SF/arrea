defmodule Arrea.CLI.Commands.Run.Execution do
  @moduledoc false

  alias Arrea.CLI.Commands.Run.Format
  alias Arrea.Error
  alias Arrea.Parallel
  alias Arrea.Result
  alias Alaja.Printer
  alias Alaja.Structures.ChunkText

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @doc false
  def execute(opts, exec_opts) do
    commands = Map.get(opts, :command, [])
    parallel = opts[:parallel] || 4
    timeout = opts[:timeout] || 30_000
    quiet = opts[:quiet] || false

    ensure_engine_started!()
    Format.maybe_print_header(opts, commands)

    results = execute_commands(commands, parallel, timeout, quiet, exec_opts)
    Format.maybe_print_results(results, quiet)
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
        {:ok, %Result{data: data}} ->
          duration = System.monotonic_time() - start
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)

          %{
            command: cmd,
            exit_code: Format.extract_exit_code(data),
            stdout: Format.extract_stdout(data),
            duration_ms: duration_ms
          }

        {:error, %Error{message: msg}} ->
          duration = System.monotonic_time() - start
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)
          %{command: cmd, exit_code: -1, stdout: "Error: #{msg}", duration_ms: duration_ms}
      end

    if quiet do
      if result.stdout != "", do: IO.puts(result.stdout)
    else
      label = Format.truncate_command(cmd, 20)

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
        entry = Format.build_result_entry(Enum.at(commands, idx), result)
        Format.maybe_echo_output(entry)
        entry
      end)
    else
      execute_parallel_animated(commands, workers, timeout, total, exec_opts)
    end
  end

  defp execute_parallel_animated(commands, _workers, timeout, total, exec_opts) do
    Enum.each(Enum.with_index(commands), fn {cmd, idx} ->
      label = Format.truncate_command(cmd, 20)
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
      Format.render_progress(commands, states, anim_frame)
      animate_loop(commands, tasks, task_structs, states, pending, anim_frame + 1)
    end
  end

  defp process_completed_tasks(tasks, completed, states, pending) do
    Enum.zip(tasks, completed)
    |> Enum.reduce({states, pending}, &process_single_task/2)
  end

  defp process_single_task({{idx, cmd, _task}, {_t, task_result}}, {states_acc, pending_acc}) do
    if MapSet.member?(pending_acc, idx) do
      entry = Format.build_entry_from_result(cmd, task_result, idx)

      if entry do
        {Map.put(states_acc, idx, entry), MapSet.delete(pending_acc, idx)}
      else
        {states_acc, pending_acc}
      end
    else
      {states_acc, pending_acc}
    end
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
end
