defmodule Arrea.Leader.CommandRunner do
  @moduledoc false

  alias Arrea.Command
  alias Arrea.Validation.Rules

  require Logger

  @max_command_length 65_536
  @default_shell_timeout 30_000

  @spec build_task_function(String.t() | function()) :: function()
  def build_task_function(cmd) when is_binary(cmd) do
    case validate_command(cmd) do
      :ok -> fn -> execute_shell_cmd(cmd, @default_shell_timeout) end
      {:error, reason} -> fn -> {:error, reason} end
    end
  end

  def build_task_function(fun) when is_function(fun, 0), do: fun

  def build_task_function(cmd), do: fn -> {:error, {:invalid_command, cmd}} end

  @spec execute_shell_cmd(String.t(), pos_integer()) :: map()
  def execute_shell_cmd(cmd, timeout) do
    shell = Command.resolve_shell()

    task =
      Task.async(fn ->
        System.cmd(shell, ["-c", cmd], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        %{stdout: output, exit_code: exit_code}

      nil ->
        %{stdout: "", stderr: "shell command timed out", exit_code: -1, timeout: true}

      {:exit, reason} ->
        %{stdout: "", stderr: "shell crashed: #{inspect(reason)}", exit_code: -1}
    end
  end

  @spec validate_command(String.t()) :: :ok | {:error, term()}
  def validate_command(cmd) do
    with {:ok, _} <- Rules.not_empty(cmd),
         {:ok, _} <- Rules.max_length(cmd, @max_command_length),
         {:ok, _} <- Rules.no_injection(cmd),
         {:ok, _} <- Rules.safe_command(cmd) do
      :ok
    else
      {:error, reason} -> {:error, {:validation_failed, reason}}
    end
  end

  @spec build_child_spec(term(), function(), pid(), boolean(), map()) :: map()
  def build_child_spec(worker_id, task_fn, parent, log, policy) do
    %{
      id: worker_id,
      start:
        {Arrea.Worker, :start_link,
         [
           [
             id: worker_id,
             tasks: [task_fn],
             parent: parent,
             log: log,
             policy: policy
           ]
         ]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec validate_commands(
          [String.t() | function()],
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          integer()
        ) ::
          {:ok, map()} | {:error, term()}
  def validate_commands(commands, max_allowed, workers, batch_id, started_at) do
    cmd_count = length(commands)

    cond do
      cmd_count == 0 ->
        {:error, :empty_command_list}

      cmd_count > max_allowed ->
        {:error, {:too_many_commands, cmd_count, max_allowed}}

      true ->
        {:ok,
         %{
           batch_id: batch_id,
           cmd_count: cmd_count,
           workers: workers,
           started_at: started_at
         }}
    end
  end

  @spec start_workers([String.t() | function()], keyword(), map(), map()) ::
          {non_neg_integer(), non_neg_integer(), map(), map()}
  def start_workers(commands, opts, validation, state) do
    context = %{
      batch_id: validation.batch_id,
      parent: self(),
      policy: Keyword.get(opts, :policy, %{}),
      log: Keyword.get(opts, :log, false),
      max_workers: state.max_workers,
      active_count: map_size(state.workers)
    }

    {successes, failures, workers_acc} =
      commands
      |> Enum.with_index()
      |> Enum.reduce({0, 0, %{}}, fn {cmd, idx}, {ok_count, fail_count, workers} ->
        current_active = map_size(workers) + context.active_count

        if current_active >= context.max_workers do
          Logger.warning(
            "[Leader] Global worker limit reached (#{context.max_workers}), skipping command #{idx}"
          )

          {ok_count, fail_count + 1, workers}
        else
          start_and_track_worker(cmd, idx, context, ok_count, fail_count, workers)
        end
      end)

    new_batches =
      Map.put(state.batches, validation.batch_id, %{
        commands: commands,
        workers: validation.workers,
        started_at: validation.started_at,
        total: validation.cmd_count,
        started: successes,
        failed_to_start: failures
      })

    {successes, failures, workers_acc, new_batches}
  end

  @spec build_execute_reply(non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, String.t()}
          | {:ok, String.t(), %{started: non_neg_integer(), failed: non_neg_integer()}}
          | {:error, term()}
  def build_execute_reply(successes, failures, batch_id) do
    cond do
      successes == 0 ->
        {:error, {:all_workers_failed, failures}}

      failures > 0 ->
        {:ok, batch_id, %{started: successes, failed: failures}}

      true ->
        {:ok, batch_id}
    end
  end

  @spec start_and_track_worker(
          term(),
          non_neg_integer(),
          map(),
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) ::
          {non_neg_integer(), non_neg_integer(), map()}
  defp start_and_track_worker(cmd, idx, context, ok_count, fail_count, workers) do
    %{batch_id: batch_id, parent: parent, log: log, policy: policy} = context
    task_fn = build_task_function(cmd)
    child_spec = build_child_spec({batch_id, idx}, task_fn, parent, log, policy)
    {delta_ok, delta_fail, pid} = start_worker_child(child_spec, batch_id, {batch_id, idx})
    workers = if pid, do: Map.put(workers, pid, {batch_id, idx}), else: workers
    {ok_count + delta_ok, fail_count + delta_fail, workers}
  end

  @spec start_worker_child(map(), String.t(), term()) ::
          {non_neg_integer(), non_neg_integer(), pid() | nil}
  defp start_worker_child(child_spec, batch_id, worker_id) do
    case DynamicSupervisor.start_child(Arrea.WorkerSupervisor, child_spec) do
      {:ok, pid} ->
        Process.monitor(pid)

        Arrea.Leader.notify_event(%{
          type: :worker_started,
          batch: batch_id,
          worker: worker_id,
          pid: pid
        })

        {1, 0, pid}

      {:error, reason} ->
        log_msg =
          case reason do
            :max_children -> "max children reached for #{inspect(worker_id)}"
            _ -> "failed to start worker #{inspect(worker_id)}: #{inspect(reason)}"
          end

        Logger.warning("[Leader] #{log_msg}")

        Arrea.Leader.notify_event(%{
          type: :worker_error,
          batch: batch_id,
          worker: worker_id,
          reason: reason
        })

        {0, 1, nil}
    end
  end
end
