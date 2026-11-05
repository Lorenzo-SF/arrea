defmodule Arrea.Pool do
  @moduledoc """
  Supervised pool of typed workers — an OTP-native `:poolboy`.

  `Arrea.Pool` manages a fixed number of `Arrea.Pool.Worker` processes
  (plus optional overflow). Consumers `checkout/2` a worker, use it, and
  `checkin/2` it back; `with_worker/2` does both automatically.

  Useful for LLM backends (candil), database connections, or any
  expensive-to-start resource.

  ## Lifecycle

  - On start, `size` workers are spawned under a per-pool
    `DynamicSupervisor` (`:temporary` children — the pool owns restarts).
  - `checkout/2` hands out an idle worker, or spawns an overflow worker
    while `total < size + max_overflow`, or waits for a slot up to the
    caller's timeout (default 5s) and returns `{:error, :timeout}`.
  - If a worker dies while leased, the pool detects it via monitor and
    replaces it, keeping the pool at `size`.
  - `:checkin_timeout` is the recommended maximum lease duration; pools
    used by slow backends should raise it (documented contract, not
    enforced).

  ## Usage

      defmodule MyWorker do
        use GenServer
        @behaviour Arrea.Pool.Worker
        @impl true
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
      end

      {:ok, _pid} = Arrea.Pool.start_link(:my_pool, MyWorker, size: 4, max_overflow: 2)

      Arrea.Pool.with_worker(:my_pool, fn worker ->
        GenServer.call(worker, :work)
      end)

  ## Registry

  Each pool is registered through `Registry` with a unique name under
  `Arrea.Pool.Registry`.
  """

  use GenServer

  alias Arrea.Pool.Worker

  @type status :: %{
          name: atom(),
          worker_mod: module(),
          size: pos_integer(),
          max_overflow: non_neg_integer(),
          total: non_neg_integer(),
          leased: non_neg_integer(),
          idle: non_neg_integer(),
          waiting: non_neg_integer()
        }

  @doc """
  Starts a pool of `worker_mod` workers under `name`.

  ## Options

    - `:size` — number of workers to keep alive (default: 4, `>= 1`)
    - `:max_overflow` — extra workers allowed beyond `:size` when busy
      (default: 2, `>= 0`)
    - `:checkin_timeout` — recommended max lease duration in ms
      (default: 30_000, `> 0`)
    - `:worker_opts` — options passed to `worker_mod.start_link/1`
      (default: `[]`)

  Invalid options are rejected with
  `{:error, %Arrea.Error{code: :invalid_config}}`.
  """
  @spec start_link(atom(), module(), keyword()) :: GenServer.on_start()
  def start_link(name, worker_mod, opts \\ []) when is_atom(name) and is_atom(worker_mod) do
    case validate_opts([name: name, worker_mod: worker_mod] ++ opts) do
      :ok ->
        GenServer.start_link(__MODULE__, [name: name, worker_mod: worker_mod] ++ opts,
          name: via_tuple(name)
        )

      {:error, %Arrea.Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Checks out an idle worker.

  Returns `{:ok, pid}` within `timeout` ms, or
  `{:error, :timeout}` when no worker becomes available in time.

  ## Example

      iex> {:ok, worker} = Arrea.Pool.checkout(:my_pool)
      iex> Arrea.Pool.checkin(:my_pool, worker)
      :ok
  """
  @spec checkout(atom(), timeout()) :: {:ok, pid()} | {:error, :timeout | :pool_not_found}
  def checkout(pool, timeout \\ 5000) do
    case safe_call(pool, :checkout, timeout) do
      {:ok, pid} -> {:ok, pid}
      :timeout -> {:error, :timeout}
      :not_found -> {:error, :pool_not_found}
    end
  end

  @doc """
  Returns a worker to the pool.

  Idempotent for unknown pools; a dead worker is discarded.
  """
  @spec checkin(atom(), pid()) :: :ok
  def checkin(pool, worker) when is_pid(worker) do
    safe_call(pool, {:checkin, worker}, 5000)
    :ok
  end

  @doc """
  Checks out a worker, runs `fun.(worker)`, and always checks it back in.

  Returns the result of `fun`, or `{:error, :timeout}` / `{:error, :pool_not_found}`
  when no worker was available.

  ## Example

      iex> Arrea.Pool.with_worker(:my_pool, fn worker ->
      ...>   GenServer.call(worker, :work)
      ...> end)
      :done
  """
  @spec with_worker(atom(), (pid() -> term())) :: term()
  def with_worker(pool, fun) when is_function(fun, 1) do
    case checkout(pool) do
      {:ok, worker} ->
        try do
          fun.(worker)
        after
          checkin(pool, worker)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current status of the pool.

  Returns `nil` if the pool is not registered.

  ## Example

      iex> Arrea.Pool.status(:my_pool)
      %{name: :my_pool, worker_mod: MyWorker, size: 4, max_overflow: 2,
        total: 4, leased: 1, idle: 3, waiting: 0}
  """
  @spec status(atom()) :: status() | nil
  def status(pool) do
    case safe_call(pool, :status, 5000) do
      {:status, status} -> status
      :not_found -> nil
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    case validate_opts(opts) do
      :ok ->
        name = Keyword.fetch!(opts, :name)
        size = Keyword.get(opts, :size, 4)

        {:ok, sup} =
          DynamicSupervisor.start_link(
            strategy: :one_for_one,
            name: via_sup_tuple(name)
          )

        state = %{
          name: name,
          worker_mod: Keyword.fetch!(opts, :worker_mod),
          size: size,
          max_overflow: Keyword.get(opts, :max_overflow, 2),
          checkin_timeout: Keyword.get(opts, :checkin_timeout, 30_000),
          worker_opts: Keyword.get(opts, :worker_opts, []),
          sup: sup,
          available: :queue.new(),
          leased: 0,
          leased_pids: %{},
          total: 0,
          waiters: :queue.new()
        }

        {:ok, spawn_initial(state)}

      {:error, %Arrea.Error{} = error} ->
        {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_call(:checkout, from, state) do
    case take_worker(state) do
      {:ok, pid, new_state} ->
        {:reply, {:ok, pid}, new_state}

      :none ->
        start_or_wait(from, state)
    end
  end

  @impl true
  def handle_call({:checkin, pid}, _from, state) do
    {:reply, :ok, do_checkin(pid, state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:status, status_map(state)}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.leased_pids, pid) do
      {nil, _} ->
        state = remove_waiter(state, ref)
        {:noreply, state}

      {_ref, leased_pids} ->
        state = %{
          state
          | leased: max(0, state.leased - 1),
            leased_pids: leased_pids,
            total: max(0, state.total - 1)
        }

        {:noreply, replenish(state)}
    end
  end

  # ── Helpers privados ─────────────────────────────────────────────────────

  @spec validate_opts(keyword()) :: :ok | {:error, Arrea.Error.t()}
  defp validate_opts(opts) do
    cond do
      not Keyword.has_key?(opts, :name) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "name option is required"}}

      not Keyword.has_key?(opts, :worker_mod) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "worker_mod option is required"}}

      is_nil(Keyword.get(opts, :worker_mod)) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "worker_mod option is required"}}

      invalid_size?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "size must be >= 1"}}

      invalid_overflow?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "max_overflow must be >= 0"}}

      invalid_checkin_timeout?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "checkin_timeout must be > 0"}}

      true ->
        :ok
    end
  end

  @spec invalid_size?(keyword()) :: boolean()
  defp invalid_size?(opts) do
    case Keyword.get(opts, :size) do
      nil -> false
      value -> not (is_integer(value) and value >= 1)
    end
  end

  @spec invalid_overflow?(keyword()) :: boolean()
  defp invalid_overflow?(opts) do
    case Keyword.get(opts, :max_overflow) do
      nil -> false
      value -> not (is_integer(value) and value >= 0)
    end
  end

  @spec invalid_checkin_timeout?(keyword()) :: boolean()
  defp invalid_checkin_timeout?(opts) do
    case Keyword.get(opts, :checkin_timeout) do
      nil -> false
      value -> not (is_integer(value) and value > 0)
    end
  end

  @spec spawn_initial(map()) :: map()
  defp spawn_initial(state) do
    Enum.reduce(1..state.size, state, fn _, acc ->
      case start_worker(acc) do
        {:ok, pid, new_state} -> %{new_state | available: :queue.in(pid, new_state.available)}
        {:error, _} -> acc
      end
    end)
  end

  @spec start_worker(map()) :: {:ok, pid(), map()} | {:error, term()}
  defp start_worker(state) do
    child_spec = Worker.child_spec(state.worker_mod, state.worker_opts)

    case DynamicSupervisor.start_child(state.sup, child_spec) do
      {:ok, pid} -> {:ok, pid, %{state | total: state.total + 1}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec take_worker(map()) :: {:ok, pid(), map()} | :none
  defp take_worker(state) do
    case :queue.out(state.available) do
      {{:value, pid}, rest} ->
        if Process.alive?(pid) do
          {:ok, pid, lease(pid, %{state | available: rest})}
        else
          # Dead idle worker: discard and keep looking / replenish.
          state = %{state | available: rest, total: max(0, state.total - 1)}
          take_worker(replenish(state))
        end

      {:empty, _} ->
        :none
    end
  end

  @spec lease(pid(), map()) :: map()
  defp lease(pid, state) do
    ref = Process.monitor(pid)
    %{state | leased: state.leased + 1, leased_pids: Map.put(state.leased_pids, pid, ref)}
  end

  @spec do_checkin(pid(), map()) :: map()
  defp do_checkin(pid, state) do
    state = unlease(pid, state)

    if Process.alive?(pid) do
      case :queue.out(state.waiters) do
        {{:value, {from, ref}}, rest} ->
          Process.demonitor(ref, [:flush])
          GenServer.reply(from, {:ok, pid})
          %{state | waiters: rest}

        {:empty, _} ->
          %{state | available: :queue.in(pid, state.available)}
      end
    else
      replenish(%{state | total: max(0, state.total - 1)})
    end
  end

  @spec unlease(pid(), map()) :: map()
  defp unlease(pid, state) do
    case Map.pop(state.leased_pids, pid) do
      {nil, _} ->
        state

      {ref, leased_pids} ->
        Process.demonitor(ref, [:flush])
        %{state | leased: max(0, state.leased - 1), leased_pids: leased_pids}
    end
  end

  @spec replenish(map()) :: map()
  defp replenish(state) do
    if state.total < state.size do
      case start_worker(state) do
        {:ok, pid, new_state} -> enqueue_worker(pid, new_state)
        {:error, _} -> state
      end
    else
      state
    end
  end

  @spec enqueue_worker(pid(), map()) :: map()
  defp enqueue_worker(pid, state) do
    case :queue.out(state.waiters) do
      {{:value, {from, ref}}, rest} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, {:ok, pid})
        %{state | waiters: rest}

      {:empty, _} ->
        %{state | available: :queue.in(pid, state.available)}
    end
  end

  @spec start_or_wait(GenServer.from(), map()) ::
          {:reply, term(), map()} | {:noreply, map()}
  defp start_or_wait(from, state) do
    if state.total < state.size + state.max_overflow do
      case start_worker(state) do
        {:ok, pid, new_state} ->
          {:reply, {:ok, pid}, lease(pid, new_state)}

        {:error, _reason} ->
          {:reply, {:error, :start_failed}, state}
      end
    else
      {pid, _tag} = from
      ref = Process.monitor(pid)
      {:noreply, %{state | waiters: :queue.in({from, ref}, state.waiters)}}
    end
  end

  @spec remove_waiter(map(), reference()) :: map()
  defp remove_waiter(state, ref) do
    waiters =
      :queue.filter(fn {_from, waiter_ref} -> waiter_ref != ref end, state.waiters)

    %{state | waiters: waiters}
  end

  @spec status_map(map()) :: status()
  defp status_map(state) do
    %{
      name: state.name,
      worker_mod: state.worker_mod,
      size: state.size,
      max_overflow: state.max_overflow,
      total: state.total,
      leased: state.leased,
      idle: :queue.len(state.available),
      waiting: :queue.len(state.waiters)
    }
  end

  @spec safe_call(atom(), term(), timeout()) :: term() | :not_found | :timeout
  defp safe_call(name, request, timeout) do
    case Registry.lookup(Arrea.Pool.Registry, name) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, request, timeout)
        catch
          :exit, {:timeout, _} -> :timeout
          :exit, :timeout -> :timeout
          :exit, _ -> :not_found
        end

      [] ->
        :not_found
    end
  end

  @spec via_tuple(atom()) :: {:via, Registry, {Arrea.Pool.Registry, atom()}}
  defp via_tuple(name), do: {:via, Registry, {Arrea.Pool.Registry, name}}

  @spec via_sup_tuple(atom()) ::
          {:via, Registry, {Arrea.Pool.Registry, {atom(), :workers}}}
  defp via_sup_tuple(name),
    do: {:via, Registry, {Arrea.Pool.Registry, {name, :workers}}}
end
