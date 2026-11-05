defmodule Arrea.Queue do
  @moduledoc """
  A named queue of work that outlives whoever is doing it.

  ## Why this exists

  `Arrea.Worker` takes its list of tasks at spawn time, runs it, and stops.
  That is right for a batch and wrong for anything longer-lived: a worker
  cannot be handed new work, and if it dies mid-batch the remaining tasks die
  with it.

  A queue separates **who has work** from **who does work**. The queue outlives
  the worker, so a worker that crashes and is restarted by its supervisor finds
  its work still waiting.

  ## What crosses the boundary, and what does not

  The payload is **opaque**. Arrea stores it, hands it back, and never looks
  inside. A consumer that pushes `%{messages: [...], model_alias: :coder}` gets
  the same service whether its payload is a shell command, an HTTP request or a
  prompt.

  Only three things are meaningful to Arrea:

  | | |
  |---|---|
  | `:priority` | an ordering. Higher runs first. Default `0` |
  | `:weight` | how much of the doer's budget it takes. Default `1` |
  | `:from` | provenance. Who put it there, for when it fails |

  Everything else is the consumer's business.

  ## The queue has the lifetime, not the worker

  A worker waiting on an empty queue is a `receive`, not a leak: it costs a few
  hundred bytes and its supervisor owns it. The thing that can be left behind is
  the **queue**, so the queue is what carries `:ttl` — how long it may sit
  empty before it removes itself.

  `worker_stop/1` is the deliberate way to stop doing work; the worker is then
  free to die, and the queue keeps whatever is still in it.
  """

  use GenServer
  require Logger

  @registry Arrea.Queue.Registry

  # ── API ─────────────────────────────────────────────────────────────────────

  @doc """
  Creates a queue, or returns the existing one.

  `:owner` is the only pid allowed to push. `:ttl` is how long the queue may sit
  empty before removing itself; `:infinity` means never.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @doc "Pushes an opaque `payload`."
  @spec push(atom(), term(), keyword()) :: :ok | {:error, term()}
  def push(queue, payload, opts \\ []) when is_atom(queue) do
    GenServer.call(via(queue), {:push, payload, opts}, :infinity)
  end

  @doc """
  Takes the highest-priority entry whose `:weight` fits in `budget`.

  Returns `{:error, :empty}` when the queue has nothing, and `{:error, :no_fit}`
  when it has work but none of it fits what the caller can take.
  """
  @spec claim(atom(), number() | :infinity) ::
          {:ok, %{payload: term(), priority: number(), weight: number(), from: term()}}
          | {:error, :empty | :no_fit | :not_found}
  def claim(queue, budget) when is_atom(queue) and (is_number(budget) or budget == :infinity) do
    GenServer.call(via(queue), {:claim, budget})
  end

  @doc """
  The best entry that fits in `budget`, WITHOUT taking it.

  A worker serving several queues peeks at all of them and takes the best
  overall, so that a `:vip` in one queue does not wait behind an ordinary entry
  in another. Peeking instead of claiming is what makes the comparison possible:
  claiming removes the entry.

  There is a window between the peek and the claim in which another worker can
  take the same entry. Losing that race is not an error — the claim returns
  `:empty` or `:no_fit` and the worker simply asks again.
  """
  @spec peek(atom(), number() | :infinity) ::
          {:ok, %{payload: term(), priority: number(), weight: number(), from: term()}}
          | {:error, :empty | :no_fit | :not_found}
  def peek(queue, budget) when is_atom(queue) and (is_number(budget) or budget == :infinity) do
    GenServer.call(via(queue), {:peek, budget})
  end

  @doc """
  Puts an entry back. For a worker that took something and could not finish it.

  With `:front` it goes ahead of everything with a lower priority — that is
  what a retry should do, not starve behind the tasks that arrived after it.
  """
  @spec requeue(atom(), map(), keyword()) :: :ok
  def requeue(queue, entry, opts \\ []) when is_atom(queue) do
    GenServer.call(via(queue), {:requeue, entry, opts})
  end

  @doc "How many entries are waiting, and the total weight."
  @spec stats(atom()) :: map() | nil
  def stats(queue), do: GenServer.call(via(queue), :stats)

  @doc "Removes the queue. Entries are lost; `drain/1` is the one that returns them."
  @spec destroy(atom()) :: :ok
  def destroy(queue), do: GenServer.stop(via(queue))

  @doc "Empties the queue, returning what was in it."
  @spec drain(atom()) :: [map()]
  def drain(queue), do: GenServer.call(via(queue), :drain)

  @spec via(atom()) :: GenServer.name()
  defp via(name), do: {:via, Registry, {@registry, name}}

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name),
      # A `:gb_tree` keyed by **{-priority, sequence}** so equal priorities
      # keep insertion order (FIFO within a priority) and the HIGHER priority
      # comes out first.
      #
      # El signo menos es lo UNICO que hace que esto sea cierto, porque
      # `:gb_trees` ordena **ascendente**: la clave mas pequena sale primero.
      # Con `{priority, sequence}` a secas, la prioridad mas baja se servia
      # primero, y el `@moduledoc` decia exactamente lo contrario. Medido
      # antes del arreglo: push(baja:1, media:5, alta:9) -> salen 1, 5, 9.
      entries: :gb_trees.empty(),
      sequence: 0,
      owner: Keyword.get(opts, :owner),
      ttl: Keyword.get(opts, :ttl, 60_000),
      empty_since: System.monotonic_time(:millisecond)
    }

    schedule_ttl(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:push, payload, opts}, {pid, _}, state) do
    cond do
      not authorised?(state, pid) ->
        {:reply, {:error, :not_owner}, state}

      true ->
        entry = %{
          payload: payload,
          priority: Keyword.get(opts, :priority, 0),
          weight: Keyword.get(opts, :weight, 1),
          from: Keyword.get(opts, :from, pid)
        }

        key = {-entry.priority, state.sequence}

        state = %{
          state
          | sequence: state.sequence + 1,
            entries: :gb_trees.enter(key, entry, state.entries)
        }

        {:reply, :ok, %{state | empty_since: nil, ttl: nil}}
    end
  end

  def handle_call({:peek, budget}, _from, state) do
    case first_fitting(state.entries, budget) do
      {_key, entry} -> {:reply, {:ok, entry}, state}
      nil -> {:reply, empty_or_no_fit(state), state}
    end
  end

  def handle_call({:claim, budget}, _from, state) do
    case first_fitting(state.entries, budget) do
      {key, entry} ->
        # Quien avisa de que esto se ha tomado es quien lo coge, que es el
        # worker. Aqui solo se quita. Un `claim` directo desde fuera del worker
        # no avisa a nadie, y eso es lo correcto: no hay quien lo ejecutara.
        {:reply, {:ok, entry}, %{state | entries: :gb_trees.delete(key, state.entries)}}

      nil ->
        # `no_fit` is NOT `empty`: there is work, just not for you. A worker
        # that confuses the two spins on a queue it can never serve.
        reply =
          if :gb_trees.is_empty(state.entries), do: {:error, :empty}, else: {:error, :no_fit}

        {:reply, reply, mark_empty(state)}
    end
  end

  def handle_call({:requeue, entry, opts}, _from, state) do
    key =
      if Keyword.get(opts, :front, false) do
        # Ahead of its own priority band, not at the head of everything: a VIP
        # that was already running does not outrank a fresh emergency.
        {-entry.priority - 1, state.sequence}
      else
        {-entry.priority, state.sequence}
      end

    state = %{
      state
      | sequence: state.sequence + 1,
        entries: :gb_trees.enter(key, entry, state.entries)
    }

    {:reply, :ok, %{state | empty_since: nil, ttl: nil}}
  end

  def handle_call(:stats, _from, state) do
    entries = :gb_trees.values(state.entries)

    {:reply,
     %{
       name: state.name,
       size: length(entries),
       weight: Enum.reduce(entries, 0, &(&1.weight + &2)),
       owner: state.owner,
       priorities: entries |> Enum.map(& &1.priority) |> Enum.uniq() |> Enum.sort()
     }, state}
  end

  def handle_call(:drain, _from, state) do
    entries = :gb_trees.values(state.entries)
    {:reply, entries, %{state | entries: :gb_trees.empty()}}
  end

  @impl true
  def handle_info(:ttl, state) do
    if :gb_trees.is_empty(state.entries) and
         System.monotonic_time(:millisecond) - state.empty_since >= state.ttl do
      Logger.debug("[Queue #{inspect(state.name)}] empty for #{state.ttl}ms, removing")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    entries = :gb_trees.values(state.entries)

    for entry <- entries do
      send(entry.from, {:arrea_queue, :dropped, state.name, entry.payload})
    end

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp empty_or_no_fit(state) do
    if :gb_trees.is_empty(state.entries), do: {:error, :empty}, else: {:error, :no_fit}
  end

  defp authorised?(%{owner: nil}, _pid), do: true
  defp authorised?(%{owner: owner}, pid), do: owner == pid

  defp first_fitting(entries, budget) do
    entries
    |> :gb_trees.to_list()
    |> Enum.find(fn {_key, entry} -> entry.weight <= budget end)
  end

  defp mark_empty(%{empty_since: nil} = state),
    do: %{state | empty_since: System.monotonic_time(:millisecond)}

  defp mark_empty(state), do: state

  defp schedule_ttl(%{ttl: :infinity}), do: :ok
  defp schedule_ttl(%{ttl: nil}), do: :ok

  defp schedule_ttl(%{ttl: ttl}) do
    Process.send_after(self(), :ttl, ttl)
    :ok
  end
end
