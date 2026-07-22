defmodule Arrea.Monitor do
  @moduledoc """
  Global monitor for the `Arrea` engine.

  Responsible for:
  - Registering and updating worker state
  - Notifying worker completion
  - Providing aggregate statistics for workers, tasks, and errors

  The Monitor is an internal component that accumulates statistics. External
  subscribers live on `Arrea.Leader`; the Monitor no longer maintains a
  subscriber set of its own.
  """

  use GenServer

  require Logger

  @doc """
  Starts the Monitor as a GenServer with name `#{__MODULE__}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Child specification for the supervision tree.
  """
  @spec child_spec(keyword()) :: map()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 500
    }
  end

  @doc "Registers a worker in the monitor."
  @spec register_worker(any(), map()) :: :ok
  def register_worker(worker_id, state) do
    GenServer.cast(__MODULE__, {:register, worker_id, state})
  end

  @doc "Updates a worker's state."
  @spec update_worker(any(), map()) :: :ok
  def update_worker(worker_id, updates) do
    GenServer.cast(__MODULE__, {:update, worker_id, updates})
  end

  @doc "Notifies the monitor that a worker has finished."
  @spec worker_finished(any(), atom(), integer()) :: :ok
  def worker_finished(worker_id, status, _duration_ms) do
    GenServer.cast(__MODULE__, {:finished, worker_id, status})
  end

  @doc "Returns the current state of the monitor."
  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Returns summarised Engine statistics."
  @spec get_stats() :: {:ok, map()}
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       workers: %{},
       total_started: 0,
       total_finished: 0,
       total_errors: 0
     }}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call(:get_stats, _from, state) do
    active =
      state.workers
      |> Map.values()
      |> Enum.count(fn w -> Map.get(w, :status) not in [:finished, :error] end)

    stats = %{
      total_workers: state.total_started,
      active_workers: active,
      completed_tasks: state.total_finished,
      failed_tasks: state.total_errors
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_cast({:register, worker_id, worker_state}, state) do
    new_workers = Map.put(state.workers, worker_id, Map.put(worker_state, :status, :started))
    new_state = %{state | workers: new_workers, total_started: state.total_started + 1}

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update, worker_id, updates}, state) do
    new_workers = Map.update(state.workers, worker_id, updates, &Map.merge(&1, updates))
    {:noreply, %{state | workers: new_workers}}
  end

  @impl true
  def handle_cast({:finished, worker_id, status}, state) do
    # Terminal status: drop the worker from `state.workers` to avoid
    # unbounded growth. The counters below keep the totals accurate for
    # observability, and `get_worker/2` will return :not_found which is
    # correct semantically (the worker is no longer being tracked).
    new_workers = Map.delete(state.workers, worker_id)

    new_finished =
      if status == :finished, do: state.total_finished + 1, else: state.total_finished

    new_errors = if status == :error, do: state.total_errors + 1, else: state.total_errors

    {:noreply,
     %{state | workers: new_workers, total_finished: new_finished, total_errors: new_errors}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Monitor] Unhandled info: #{inspect(msg)}")
    {:noreply, state}
  end
end
