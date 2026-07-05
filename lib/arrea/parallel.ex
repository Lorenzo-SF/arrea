defmodule Arrea.Parallel do
  @moduledoc false

  alias Arrea.Command
  alias Arrea.Leader

  @doc """
  Executes a single command synchronously.

  ## Options
    - `:timeout` — Timeout in milliseconds (default: 30_000)
    - `:shell` — Shell to use (default: resolved automatically)
    - `:shell_config` — Path to shell config file
    - `:asdf_elixir`, `:asdf_erlang`, etc. — Versions via ASDF (environment variable)
    - `:mise_node`, `:mise_elixir`, etc. — Versions via `mise exec`

  ## Examples

      iex> Arrea.Parallel.execute("echo hello")
      {:ok, %{stdout: "hello\\n", stderr: "", exit_code: 0}}
  """
  @spec execute(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(cmd, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    exec_opts = Keyword.drop(opts, [:timeout])

    task =
      Task.async(fn ->
        do_execute(cmd, exec_opts)
      end)

    Task.await(task, timeout)
  end

  @doc """
  Executes multiple commands in parallel via Leader.

  ## Options
    - `:workers` — Number of parallel workers (default: 4)
    - `:timeout` — Timeout in milliseconds (default: 30_000)

  ## Examples

      iex> Arrea.Parallel.run(["echo a", "echo b", "echo c"], workers: 2)
      {:ok, batch_id}
  """
  @spec run([binary() | function()], keyword()) ::
          {:ok, binary()}
          | {:ok, binary(), map()}
          | {:error, term()}
  def run(commands, opts \\ []) do
    workers = Keyword.get(opts, :workers, 4)

    case Process.whereis(Arrea.Leader) do
      nil ->
        {:error, :leader_not_available}

      _pid ->
        Leader.execute(commands, workers: workers, timeout: Keyword.get(opts, :timeout, 30_000))
    end
  end

  @doc """
  Executes multiple commands and waits for all results synchronously.

  Uses `Task.async_stream/3` with `max_concurrency` for real sliding window:
  a new task starts as soon as one finishes, without waiting for the whole chunk.

  Supports per-task timeout via tuple-input:
  - `{command, timeout_ms}` — per-task timeout
  - `{:tag, command}` — tag the task (tag appears in the result)
  - `{:tag, command, timeout_ms}` — tag + per-task timeout

  Results are returned in the same order as input commands.
  When a tag is provided, the result is wrapped as `{:tagged, tag, result}`
  so callers can identify tasks without relying on position.

  ## Options
    - `:workers` — Number of parallel workers (default: 4)
    - `:timeout` — Default timeout per command in ms (default: 30_000)
    - `:ordered` — Return results in input order (default: true)

  ## Examples

      iex> Arrea.Parallel.run_sync([fn -> 1 end, fn -> 2 end])
      [{:ok, %{result: 1, exit_code: 0}}, {:ok, %{result: 2, exit_code: 0}}]

      iex> Arrea.Parallel.run_sync([{:vector, fn -> 1 end}, {:bm25, fn -> 2 end}])
      [{:tagged, :vector, {:ok, %{result: 1, exit_code: 0}}},
       {:tagged, :bm25, {:ok, %{result: 2, exit_code: 0}}}]
  """
  @spec run_sync([binary() | function() | tuple()], keyword()) :: [map()]
  def run_sync(commands, opts \\ []) do
    workers = Keyword.get(opts, :workers, 4)
    default_timeout = Keyword.get(opts, :timeout, 30_000)
    ordered = Keyword.get(opts, :ordered, true)
    exec_opts = Keyword.drop(opts, [:workers, :timeout, :ordered])
    n = length(commands)

    # Outer timeout = max per-task × tasks + 5s buffer so a single hung
    # worker doesn't freeze the whole stream forever.
    stream_timeout = default_timeout * max(n, 1) + 5_000

    commands
    |> Enum.with_index()
    |> Task.async_stream(
      fn {cmd_entry, idx} ->
        {cmd, tag, timeout} = normalize_command(cmd_entry, idx, default_timeout)

        # Inner Task per command so we can enforce per-task timeout.
        task = Task.async(fn -> do_execute(cmd, exec_opts) end)

        result =
          case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
            {:ok, result} -> result
            nil -> {:error, %{error: :timeout, exit_code: -1}}
            {:exit, reason} -> {:error, %{error: reason, exit_code: -1}}
          end

        {idx, tag, result}
      end,
      timeout: stream_timeout,
      max_concurrency: workers,
      ordered: ordered
    )
    |> Enum.map(fn
      {:ok, {idx, tag, result}} -> build_result(idx, tag, result)
      {:exit, reason} -> {:error, %{error: reason, exit_code: -1}}
      {:error, reason} -> {:error, %{error: reason, exit_code: -1}}
    end)
  end

  @doc false
  def normalize_command(cmd_entry, idx, default_timeout) when is_tuple(cmd_entry) do
    case cmd_entry do
      {tag, cmd, timeout} when is_atom(tag) and is_integer(timeout) ->
        {cmd, tag, timeout}

      {cmd, timeout} when is_integer(timeout) ->
        {cmd, idx, timeout}

      {tag, cmd} when is_atom(tag) ->
        {cmd, tag, default_timeout}

      _ ->
        {cmd_entry, idx, default_timeout}
    end
  end

  def normalize_command(cmd_entry, idx, default_timeout) do
    {cmd_entry, idx, default_timeout}
  end

  defp build_result(idx, tag, result) when is_atom(tag) and tag != idx do
    {:tagged, tag, result}
  end

  defp build_result(_idx, _tag, result) do
    result
  end

  @spec do_execute(binary() | function(), keyword()) :: {:ok, map()} | {:error, map()}
  defp do_execute(cmd, opts)

  defp do_execute(cmd, opts) when is_binary(cmd) do
    {:ok, do_execute_cmd(cmd, opts)}
  end

  defp do_execute(fun, _opts) when is_function(fun, 0) do
    result = fun.()
    {:ok, %{result: result, exit_code: 0}}
  rescue
    e ->
      {:error, %{error: e, exit_code: 1}}
  end

  @doc """
  Executes multiple commands in parallel returning a stream of individual
  results as they complete, including the duration of each.

  Each stream element is `{index, {:ok, result} | {:error, reason}}`.

  ## Options
    - `:workers` — Number of parallel workers (default: 4)
    - `:timeout` — Timeout per command in milliseconds (default: 30_000)
  """
  @spec run_stream([binary() | function()], keyword()) :: Enumerable.t()
  def run_stream(commands, opts \\ []) do
    workers = Keyword.get(opts, :workers, 4)
    timeout = Keyword.get(opts, :timeout, 30_000)
    exec_opts = Keyword.drop(opts, [:workers, :timeout])
    stream_timeout = timeout * max(length(commands), 1) + 5_000

    commands
    |> Enum.with_index()
    |> Task.async_stream(
      fn {cmd, idx} ->
        task = Task.async(fn -> do_execute(cmd, exec_opts) end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> {idx, result}
          nil -> {idx, {:error, :timeout}}
          {:exit, reason} -> {idx, {:error, reason}}
        end
      end,
      timeout: stream_timeout,
      max_concurrency: workers,
      ordered: false
    )
    |> Stream.map(fn
      {:ok, {idx, {:ok, _} = result}} ->
        {idx, result}

      {:ok, {idx, {:error, _} = err}} ->
        {idx, err}

      {:exit, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end)
  end

  @doc """
  Executes multiple commands in parallel returning a list of `{idx, cmd, task}`
  where each `task` is a `Task` that can be monitored with `Task.yield_many/2`.

  Each task manages its own timeout internally.

  ## Options
    - `:workers` — Number of parallel workers (default: 4)
    - `:timeout` — Timeout per command in milliseconds (default: 30_000)
  """
  @spec run_tasks([binary()], keyword()) :: [{non_neg_integer(), String.t(), Task.t()}]
  def run_tasks(commands, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    exec_opts = Keyword.drop(opts, [:timeout])

    commands
    |> Enum.with_index()
    |> Enum.map(fn {cmd, idx} ->
      task =
        Task.async(fn ->
          inner = start_execution_task(idx, cmd, exec_opts)
          wait_for_task_result(inner, idx, timeout)
        end)

      {idx, cmd, task}
    end)
  end

  defp start_execution_task(idx, cmd, exec_opts) do
    Task.async(fn ->
      start = System.monotonic_time(:millisecond)
      result = do_execute(cmd, exec_opts)
      duration = System.monotonic_time(:millisecond) - start
      {idx, result, duration}
    end)
  end

  defp wait_for_task_result(inner, idx, timeout) do
    case Task.yield(inner, timeout) || Task.shutdown(inner, :brutal_kill) do
      {:ok, value} -> value
      nil -> {idx, {:error, :timeout}, timeout}
      {:exit, reason} -> {idx, {:error, reason}, 0}
    end
  end

  @spec do_execute_cmd(String.t(), keyword()) :: map()
  defp do_execute_cmd(cmd, opts) when is_binary(cmd) do
    shell = Command.resolve_shell(opts)
    full_cmd = Command.build_full_command(cmd, opts)
    timeout = Keyword.get(opts, :timeout, 30_000)
    start = System.monotonic_time(:millisecond)

    case yield_or_timeout(run_shell(shell, full_cmd), timeout) do
      {:ok, {output, exit_code}} ->
        build_shell_success(output, exit_code, start)

      {:error, :timeout} ->
        build_shell_timeout(start)

      {:exit, reason} ->
        execute_shell_with_fallback(full_cmd, timeout, start, reason)
    end
  end

  defp run_shell(shell, full_cmd) do
    Task.async(fn ->
      System.cmd(shell, ["-c", full_cmd], stderr_to_stdout: true)
    end)
  end

  defp yield_or_timeout(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> {:ok, value}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:exit, reason}
    end
  end

  defp build_shell_success(output, exit_code, start) do
    duration = System.monotonic_time(:millisecond) - start
    %{stdout: output, stderr: "", exit_code: exit_code, duration_ms: duration}
  end

  defp build_shell_timeout(start) do
    duration = System.monotonic_time(:millisecond) - start

    %{
      stdout: "",
      stderr: "shell command timed out",
      exit_code: -1,
      duration_ms: duration,
      timeout: true
    }
  end

  defp execute_shell_with_fallback(full_cmd, timeout, start, reason) do
    fallback = System.get_env("SHELL") || "sh"

    case yield_or_timeout(run_shell(fallback, full_cmd), timeout) do
      {:ok, {output, exit_code}} ->
        duration = System.monotonic_time(:millisecond) - start
        %{stdout: output, stderr: "", exit_code: exit_code, duration_ms: duration}

      _ ->
        duration = System.monotonic_time(:millisecond) - start

        %{
          stdout: "",
          stderr: "fallback shell failed: #{inspect(reason)}",
          exit_code: -1,
          duration_ms: duration
        }
    end
  rescue
    e ->
      duration = System.monotonic_time(:millisecond) - start

      %{
        stdout: "",
        stderr: "shell crashed: #{Exception.message(e)}",
        exit_code: -1,
        duration_ms: duration
      }
  end
end
