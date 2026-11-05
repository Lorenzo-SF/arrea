defmodule Arrea.CLI.Commands.Run.Format do
  @moduledoc false

  alias Alaja.CLI.Parser
  alias Alaja.Components.{Header, Separator}
  alias Alaja.Printer
  alias Alaja.Structures.ChunkText

  alias Arrea.Error
  alias Arrea.Result

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @doc false
  def maybe_print_header(opts, commands) do
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

  @doc false
  def maybe_print_results(results, quiet) do
    if not quiet, do: print_results(results)
  end

  @doc false
  def maybe_echo_output(%{stdout: stdout}) when stdout != "", do: IO.puts(stdout)
  def maybe_echo_output(_entry), do: :ok

  @doc false
  def render_progress(commands, states, anim_frame) do
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

  @doc false
  def truncate_command(cmd, max_len) do
    if String.length(cmd) > max_len do
      String.slice(cmd, 0, max_len) <> "..."
    else
      cmd
    end
  end

  @doc false
  def build_result_entry(
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

  def build_result_entry(cmd, {:ok, %{exit_code: exit_code} = data}) do
    %{
      command: cmd,
      exit_code: exit_code,
      stdout: inspect(Map.drop(data, [:exit_code])),
      duration_ms: 0
    }
  end

  def build_result_entry(cmd, {:error, %{error: error, exit_code: code}}) do
    %{command: cmd, exit_code: code || -1, stdout: "Error: #{inspect(error)}", duration_ms: 0}
  end

  def build_result_entry(cmd, {:error, reason}) do
    %{command: cmd, exit_code: -1, stdout: "Error: #{inspect(reason)}", duration_ms: 0}
  end

  def build_result_entry(cmd, %{stdout: stdout, exit_code: exit_code}) do
    %{command: cmd, exit_code: exit_code, stdout: String.trim(stdout || ""), duration_ms: 0}
  end

  @doc false
  def build_entry_from_result(cmd, task_result, idx) do
    case task_result do
      {:ok, {^idx, {:ok, %Result{data: data}}, duration}} ->
        %{
          command: cmd,
          exit_code: extract_exit_code(data),
          stdout: extract_stdout(data),
          duration_ms: duration
        }

      {:ok, {^idx, {:error, %Error{message: msg}}, duration}} ->
        %{command: cmd, exit_code: -1, stdout: "Error: #{msg}", duration_ms: duration}

      _ ->
        nil
    end
  end

  @doc false
  def extract_exit_code(%{exit_code: code}), do: code
  def extract_exit_code(%{}), do: 0
  def extract_exit_code(_), do: 0

  @doc false
  def extract_stdout(%{stdout: s}), do: String.trim(s || "")
  def extract_stdout(%{result: r}), do: inspect(r)
  def extract_stdout(_), do: ""

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
end
