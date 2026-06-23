defmodule Arrea.Leader do
  @moduledoc """
  Leader GenServer that coordinates parallel execution.

  The Leader manages worker processes, coordinates task distribution,
  and emits events to subscribers. Workers are started via
  `Arrea.WorkerSupervisor` (DynamicSupervisor) to keep them within
  the OTP supervision tree.

  The Leader also performs periodic cleanup of old batches (every 60s)
  to prevent memory leaks.
  """

  use GenServer

  alias Arrea.Subscribers
  alias Arrea.Validation.Rules

  require Logger

  defstruct subscribers: MapSet.new(),
            batches: %{},
            workers: %{},
            max_workers: 100,
            stats: %{started: 0, finished: 0, failed: 0}

  @type t :: %__MODULE__{
          subscribers: MapSet.t(),
          batches: map(),
          workers: map(),
          max_workers: non_neg_integer(),
          stats: map()
        }

  @max_command_length 65_536

  # Per-shell-command timeout (ms). System.cmd blocks until the shell
  # exits, so a runaway command (sleep, cat /dev/zero, network call)
  # would otherwise hang the worker forever.
  @default_shell_timeout 30_000

  @doc """
  Starts the Leader as a GenServer with name `#{__MODULE__}`.

  ## Options

    - `:max_workers` — Maximum number of workers (default: 100)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes the caller PID to Leader events.

  The process will receive `{:leader_event, event}` messages.
  """
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, :subscribe)
  end

  @doc """
  Unsubscribes the caller PID.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, :unsubscribe)
  end

  @doc """
  Executes a list of commands or functions in parallel.

  Returns `{:ok, batch_id}` when all workers start successfully.
  Returns `{:ok, batch_id, %{started: n, failed: m}}` when some workers fail to start.
  Returns `{:error, {:all_workers_failed, n}}` when all workers fail.
  Returns `{:error, {:too_many_commands, count, max}}` when the list exceeds the limit.

  Subscribe to Leader events to track progress. Each element in `commands`
  can be a shell command binary or a zero-arity function.

  ## Options

    - `:workers` — Maximum parallel workers (default: 4)
    - `:timeout` — Timeout per worker in ms (default: 30_000)
    - `:log` — Enable worker logging (default: false)
    - `:policy` — Policy map for error handling
    - `:max_workers` — Maximum commands per batch (default: 100)
  """
  @spec execute([String.t() | function()], keyword()) ::
          {:ok, String.t()}
          | {:ok, String.t(), %{started: non_neg_integer(), failed: non_neg_integer()}}
          | {:error, term()}
  def execute(commands, opts \\ []) do
    GenServer.call(__MODULE__, {:execute, commands, opts})
  end

  @doc """
  Broadcasts an event to all subscribers.
  """
  @spec notify_event(map()) :: :ok
  def notify_event(event) do
    GenServer.cast(__MODULE__, {:notify_event, event})
  end

  @doc """
  Returns the current internal state of the Leader.
  """
  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{max_workers: Keyword.get(opts, :max_workers, 100)}
    {:ok, state, {:continue, :schedule_cleanup}}
  end

  @impl true
  def handle_continue(:schedule_cleanup, state) do
    Process.send_after(self(), :cleanup_batches, 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_call(:subscribe, {pid, _ref}, state) do
    new_subscribers = Subscribers.subscribe(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call(:unsubscribe, {pid, _ref}, state) do
    new_subscribers = Subscribers.unsubscribe(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:execute, commands, opts}, _from, state) do
    max_allowed = Keyword.get(opts, :max_workers, state.max_workers)
    workers = Keyword.get(opts, :workers, 4)

    case validate_commands(commands, max_allowed, workers) do
      {:error, _} = error ->
        {:reply, error, state}

      {:ok, validation} ->
        {successes, failures, workers_acc, new_batches} =
          start_workers(commands, opts, validation, state)

        reply = build_execute_reply(successes, failures, validation.batch_id)
        new_state = %{state | batches: new_batches, workers: workers_acc}
        {:reply, reply, new_state}
    end
  end

  defp validate_commands(commands, max_allowed, workers) do
    cmd_count = length(commands)

    cond do
      cmd_count == 0 ->
        {:error, :empty_command_list}

      cmd_count > max_allowed ->
        {:error, {:too_many_commands, cmd_count, max_allowed}}

      true ->
        {:ok,
         %{
           batch_id: generate_batch_id(),
           cmd_count: cmd_count,
           workers: workers,
           started_at: now()
         }}
    end
  end

  defp start_workers(commands, opts, validation, state) do
    context = %{
      batch_id: validation.batch_id,
      parent: self(),
      policy: Keyword.get(opts, :policy, %{}),
      log: Keyword.get(opts, :log, false)
    }

    {successes, failures, workers_acc} =
      commands
      |> Enum.with_index()
      |> Enum.reduce({0, 0, %{}}, fn {cmd, idx}, {ok_count, fail_count, workers} ->
        start_and_track_worker(cmd, idx, context, ok_count, fail_count, workers)
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

  defp build_execute_reply(successes, failures, batch_id) do
    cond do
      successes == 0 ->
        {:error, {:all_workers_failed, failures}}

      failures > 0 ->
        {:ok, batch_id, %{started: successes, failed: failures}}

      true ->
        {:ok, batch_id}
    end
  end

  defp start_and_track_worker(cmd, idx, context, ok_count, fail_count, workers) do
    %{batch_id: batch_id, parent: parent, log: log, policy: policy} = context
    task_fn = build_task_function(cmd)
    child_spec = build_child_spec({batch_id, idx}, task_fn, parent, log, policy)
    {delta_ok, delta_fail, pid} = start_worker_child(child_spec, batch_id, {batch_id, idx})
    workers = if pid, do: Map.put(workers, pid, {batch_id, idx}), else: workers
    {ok_count + delta_ok, fail_count + delta_fail, workers}
  end

  @impl true
  def handle_cast({:notify_event, event}, state) do
    new_subscribers = Subscribers.broadcast(state.subscribers, {:leader_event, event})

    new_stats =
      case event[:type] do
        :worker_started -> update_stat(state.stats, :started, 1)
        :worker_finished -> update_stat(state.stats, :finished, 1)
        :worker_error -> update_stat(state.stats, :failed, 1)
        _ -> state.stats
      end

    {:noreply, %{state | subscribers: new_subscribers, stats: new_stats}}
  end

  @impl true
  def handle_info({:worker_finished, worker_id}, state) do
    notify_event(%{type: :worker_finished, worker: worker_id})
    {:noreply, state}
  end

  @impl true
  def handle_info({:worker_failed, worker_id, reason}, state) do
    notify_event(%{type: :worker_error, worker: worker_id, reason: reason})
    {:noreply, state}
  end

  @impl true
  def handle_info({:worker_done, worker_id, result}, state) do
    notify_event(%{type: :worker_done, worker: worker_id, result: result})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    new_subscribers = Subscribers.handle_down(state.subscribers, pid)
    new_state = %{state | subscribers: new_subscribers}

    if Map.has_key?(state.workers, pid) do
      notify_event(%{type: :worker_crashed, pid: pid, reason: reason})
      {:noreply, %{new_state | workers: Map.delete(new_state.workers, pid)}}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:cleanup_batches, state) do
    now = now()
    max_age = 300_000

    new_batches =
      Map.filter(state.batches, fn {_id, batch} ->
        now - Map.get(batch, :started_at, 0) < max_age
      end)

    Process.send_after(self(), :cleanup_batches, 60_000)
    {:noreply, %{state | batches: new_batches}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Leader] Unhandled info: #{inspect(msg)}")
    {:noreply, state}
  end

  @spec build_task_function(String.t() | function()) :: function()
  defp build_task_function(cmd) when is_binary(cmd) do
    case validate_command(cmd) do
      :ok -> fn -> execute_shell_cmd(cmd, @default_shell_timeout) end
      {:error, reason} -> fn -> {:error, reason} end
    end
  end

  defp build_task_function(fun) when is_function(fun, 0), do: fun

  defp build_task_function(cmd), do: fn -> {:error, {:invalid_command, cmd}} end

  @spec execute_shell_cmd(String.t(), pos_integer()) :: map()
  defp execute_shell_cmd(cmd, timeout) do
    shell = Arrea.Command.resolve_shell()
    task = Task.async(fn ->
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
  defp validate_command(cmd) do
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
  defp build_child_spec(worker_id, task_fn, parent, log, policy) do
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

  @spec start_worker_child(map(), String.t(), term()) ::
          {non_neg_integer(), non_neg_integer(), pid() | nil}
  defp start_worker_child(child_spec, batch_id, worker_id) do
    case DynamicSupervisor.start_child(Arrea.WorkerSupervisor, child_spec) do
      {:ok, pid} ->
        Process.monitor(pid)

        notify_event(%{
          type: :worker_started,
          batch: batch_id,
          worker: worker_id,
          pid: pid
        })

        {1, 0, pid}

      {:error, reason} ->
        Logger.warning(
          "[Leader] Failed to start worker #{inspect(worker_id)}: #{inspect(reason)}"
        )

        notify_event(%{
          type: :worker_error,
          batch: batch_id,
          worker: worker_id,
          reason: reason
        })

        {0, 1, nil}
    end
  end

  @spec update_stat(map(), atom(), integer()) :: map()
  defp update_stat(stats, key, delta) do
    Map.update(stats, key, delta, &(&1 + delta))
  end

  @spec generate_batch_id() :: String.t()
  defp generate_batch_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @spec now() :: integer()
  defp now, do: :erlang.system_time(:millisecond)

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end
end
