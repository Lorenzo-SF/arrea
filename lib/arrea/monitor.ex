defmodule Arrea.Monitor do
  @moduledoc """
  Global monitor for the `Arrea` engine.

  Responsible for:
  - Registering and updating worker state
  - Notifying worker completion
  - Managing subscriptions to engine events
  - Providing aggregate statistics for workers, tasks, and errors
  """

  use GenServer

  require Logger

  alias Arrea.Subscribers

  @doc """
  Starts the Monitor as a GenServer with name `#{__MODULE__}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Especificacion de hijo para el arbol de supervision.
  """
  @spec child_spec(keyword()) :: map()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Registra un worker en el monitor."
  @spec register_worker(any(), map()) :: :ok
  def register_worker(worker_id, state) do
    GenServer.cast(__MODULE__, {:register, worker_id, state})
  end

  @doc "Actualiza el estado de un worker."
  @spec update_worker(any(), map()) :: :ok
  def update_worker(worker_id, updates) do
    GenServer.cast(__MODULE__, {:update, worker_id, updates})
  end

  @doc "Notifica que un worker ha terminado."
  @spec worker_finished(any(), atom(), integer()) :: :ok
  def worker_finished(worker_id, status, _duration_ms) do
    GenServer.cast(__MODULE__, {:finished, worker_id, status})
  end

  @doc "Suscribe el proceso actual a eventos del Engine."
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc "Cancela la suscripcion del proceso actual."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  @doc "Obtiene el estado actual del monitor."
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
       subscribers: MapSet.new(),
       total_started: 0,
       total_finished: 0,
       total_errors: 0
     }}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    new_subscribers = Subscribers.subscribe(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    new_subscribers = Subscribers.unsubscribe(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
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

    new_subscribers =
      Subscribers.broadcast(new_state.subscribers, {:worker_registered, worker_id})

    {:noreply, %{new_state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_cast({:update, worker_id, updates}, state) do
    new_workers = Map.update(state.workers, worker_id, updates, &Map.merge(&1, updates))

    new_subscribers =
      Subscribers.broadcast(state.subscribers, {:worker_updated, worker_id, updates})

    {:noreply, %{state | workers: new_workers, subscribers: new_subscribers}}
  end

  @impl true
  def handle_cast({:finished, worker_id, status}, state) do
    new_workers =
      Map.update(state.workers, worker_id, %{status: status}, &Map.put(&1, :status, status))

    new_finished =
      if status == :finished, do: state.total_finished + 1, else: state.total_finished

    new_errors = if status == :error, do: state.total_errors + 1, else: state.total_errors

    new_state = %{
      state
      | workers: new_workers,
        total_finished: new_finished,
        total_errors: new_errors
    }

    new_subscribers =
      Subscribers.broadcast(new_state.subscribers, {:worker_finished, worker_id, status})

    {:noreply, %{new_state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = Subscribers.handle_down(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Monitor] Unhandled info: #{inspect(msg)}")
    {:noreply, state}
  end
end
