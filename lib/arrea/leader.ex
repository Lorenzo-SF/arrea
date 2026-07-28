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

  alias Arrea.Leader.CommandRunner
  alias Arrea.Subscribers

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

  # Bound the synchronous GenServer.call timeout for execute/2 so a
  # stuck Leader cannot block a caller forever.
  @execute_call_timeout 60_000

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
    GenServer.call(__MODULE__, {:execute, commands, opts}, @execute_call_timeout)
  end

  @doc """
  Fire-and-forget variant of `execute/2`. Returns `:ok` immediately
  after enqueueing the batch. Progress is observable through the
  existing event subscription (subscribe to Leader events).

  Use this from a GenServer mailbox loop or any context where blocking
  on the Leader's call reply is undesirable. The Leader still processes
  the batch; the reply path is simply skipped.
  """
  @spec execute_async([String.t() | function()], keyword()) :: :ok
  def execute_async(commands, opts \\ []) do
    parent = self()

    GenServer.cast(
      __MODULE__,
      {:execute_async, commands, opts, parent}
    )

    :ok
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

    case CommandRunner.validate_commands(
           commands,
           max_allowed,
           workers,
           generate_batch_id(),
           now()
         ) do
      {:error, _} = error ->
        {:reply, error, state}

      {:ok, validation} ->
        {successes, failures, workers_acc, new_batches} =
          CommandRunner.start_workers(commands, opts, validation, state)

        reply = CommandRunner.build_execute_reply(successes, failures, validation.batch_id)
        new_state = %{state | batches: new_batches, workers: workers_acc}
        {:reply, reply, new_state}
    end
  end

  @impl true
  def handle_cast({:execute_async, commands, opts, parent}, state) do
    max_allowed = Keyword.get(opts, :max_workers, state.max_workers)
    workers = Keyword.get(opts, :workers, 4)

    new_state =
      case CommandRunner.validate_commands(
             commands,
             max_allowed,
             workers,
             generate_batch_id(),
             now()
           ) do
        {:error, reason} ->
          send(parent, {:arrea_execute_result, nil, {:error, reason}})
          state

        {:ok, validation} ->
          {successes, failures, workers_acc, new_batches} =
            CommandRunner.start_workers(commands, opts, validation, state)

          reply = CommandRunner.build_execute_reply(successes, failures, validation.batch_id)
          send(parent, {:arrea_execute_result, validation.batch_id, reply})

          %{state | batches: new_batches, workers: workers_acc}
      end

    {:noreply, new_state}
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
