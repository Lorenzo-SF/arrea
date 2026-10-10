defmodule Arrea.Bulkhead do
  @moduledoc """
  Bulkhead — limits concurrent calls to a protected resource.

  A fixed number of concurrent slots (`max_concurrent`) is available.
  Calls over the limit are rejected **immediately** with
  `{:error, :bulkhead_full}` (no queueing), so a slow backend cannot
  exhaust the caller's resources.

  The decision to acquire a slot is taken atomically inside the
  GenServer, eliminating the race between checking availability and
  running the function.

  ## Usage

  Start it under a supervisor (or directly):

      {:ok, _pid} = Arrea.Bulkhead.start_link(:llm_api, 4)

  Protect a function:

      case Arrea.Bulkhead.run(:llm_api, fn -> call_llm() end) do
        {:ok, result} -> handle_result(result)
        {:error, :bulkhead_full} -> return_early_slots_are_full()
      end

  ## Telemetry

  - `[:arrea, :bulkhead, :acquired]` — a slot was granted
  - `[:arrea, :bulkhead, :released]` — a slot was returned
  - `[:arrea, :bulkhead, :rejected]` — a call was rejected (full)

  Metadata is typed (`Arrea.Telemetry.Events.bulkhead_metadata/0`):
  `%{name: atom(), max_concurrent: pos_integer(), active: non_neg_integer()}`.

  ## Weighted

  Internally the limit is a `capacity` and a `used` sum, not a count of slots.
  With the default weight of 1 the two are the same number, so `active` is kept
  as a separate counter: it is what the metrics mean by "occupied", and folding
  it into `used` would turn a weighted bulkhead into one that reports four
  holders when it holds one 4 GB model.

  ## Registry

  Each bulkhead is registered through `Registry` with a unique name under
  `Arrea.Bulkhead.Registry`.
  """

  use GenServer

  alias Arrea.Telemetry.Events, as: TE

  @type status :: %{
          name: atom(),
          max_concurrent: pos_integer(),
          active: non_neg_integer(),
          accepted: non_neg_integer(),
          rejected: non_neg_integer(),
          available: integer()
        }

  @typedoc """
  Lo que el GenServer contesta, mas `:not_found` cuando no esta registrado.

  Se declara aqui, y no en cada sitio, porque el patron es el mismo en los
  tres `safe_call`: sin este tipo, el cuerpo se deduce como `term()` y
  dialyzer no puede probar que el `case` de `run/3` es exhaustivo.
  """
  @type reply ::
          :ok
          | :full
          | {:available, integer()}
          | {:status, status()}
          | :not_found

  @doc """
  Starts a bulkhead with `max_concurrent` concurrent slots.

  ## Options

    - `:max_concurrent` — number of concurrent slots (required, `>= 1`)

  Invalid options (missing or `max_concurrent < 1`) are rejected with
  `{:error, %Arrea.Error{code: :invalid_config}}`.
  """
  @spec start_link(atom(), pos_integer(), keyword()) :: GenServer.on_start()
  def start_link(name, max_concurrent, opts \\ []) when is_atom(name) do
    case validate_opts([name: name, max_concurrent: max_concurrent] ++ opts) do
      :ok ->
        GenServer.start_link(__MODULE__, [name: name, max_concurrent: max_concurrent] ++ opts,
          name: via_tuple(name)
        )

      {:error, %Arrea.Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Runs `fun` under the bulkhead.

  Returns `{:ok, result}` when a slot was acquired and the function
  completed, or `{:error, :bulkhead_full}` when all slots are busy.

  The slot is always released, even if `fun` raises. If the bulkhead is
  not registered, `{:error, :bulkhead_not_found}` is returned.

  ## Example

      iex> {:ok, :done} = Arrea.Bulkhead.run(:workers, fn -> :done end)
  """
  @spec run(atom(), (-> term())) ::
          {:ok, term()} | {:error, :bulkhead_full | :bulkhead_not_found | :execution_failed}
  def run(name, fun), do: run(name, fun, [])

  @doc """
  Runs a function, occupying `:weight` units of the bulkhead.

  The weight is what makes this useful for things that are not "one of N
  concurrent". A GPU is not a count of slots, it is a number of bytes: a 12 GB
  model and a 1.8 GB embedder cannot both live in 16 GB, but "one slot each"
  says they can.

  ## The default is 1, and that is not a special case

  A bulkhead of 4 slots where everything weighs 1 IS a weighted bulkhead whose
  weights are all 1. So the general form and the old form are the same function:

      Bulkhead.run(:api, fn -> ... end)                    # weighs 1
      Bulkhead.run(:gpu, fn -> ... end, weight: 12_400_000_000)

  ## What it does NOT do

  It does not queue. It rejects, exactly as before, and the caller decides what
  to do about that. A resource that waits is a different thing with different
  semantics, and putting a queue inside here would make this unusable as a
  bulkhead at all.
  """
  @spec run(atom(), (-> term()), keyword()) ::
          {:ok, term()} | {:error, :bulkhead_full | :bulkhead_not_found | :execution_failed}
  def run(name, fun, opts) when is_atom(name) and is_function(fun, 0) do
    weight = Keyword.get(opts, :weight, 1)

    case safe_call(name, {:acquire, weight}) do
      :ok ->
        try do
          {:ok, fun.()}
        rescue
          _exception -> {:error, :execution_failed}
        after
          GenServer.cast(via_tuple(name), {:release, weight})
        end

      :full ->
        {:error, :bulkhead_full}

      :not_found ->
        {:error, :bulkhead_not_found}
    end
  end

  @doc """
  Returns the number of free slots right now.

  Returns `0` if the bulkhead is not registered.
  """
  @spec available(atom()) :: non_neg_integer()
  def available(name) do
    case safe_call(name, :available) do
      {:available, free} -> free
      :not_found -> 0
    end
  end

  @doc """
  Returns the current status of the bulkhead.

  Returns `nil` if the bulkhead is not registered.

  ## Example

      iex> Arrea.Bulkhead.status(:workers)
      %{name: :workers, max_concurrent: 4, active: 1, accepted: 5, rejected: 0}
  """
  @spec status(atom()) :: status() | nil
  def status(name) do
    case safe_call(name, :status) do
      {:status, status} -> status
      :not_found -> nil
    end
  end

  @doc """
  Validates bulkhead options.

  Returns `:ok` when valid or `{:error, %Arrea.Error{code: :invalid_config}}`
  when `:name` is missing or `:max_concurrent < 1`.
  """
  @spec validate_opts(keyword()) :: :ok | {:error, Arrea.Error.t()}
  def validate_opts(opts) do
    cond do
      not Keyword.has_key?(opts, :name) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "name option is required"}}

      invalid_max_concurrent?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "max_concurrent must be >= 1"}}

      true ->
        :ok
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    case validate_opts(opts) do
      :ok ->
        {:ok,
         %{
           name: Keyword.fetch!(opts, :name),
           max_concurrent: Keyword.fetch!(opts, :max_concurrent),
           # `capacity`/`used` son lo que decide si cabe. `active` cuenta los
           # titulares, que es lo que dicen las metricas: un bulkhead con un
           # modelo de 4 GB ocupa "uno", no "cuatro".
           capacity: Keyword.fetch!(opts, :max_concurrent),
           used: 0,
           active: 0,
           accepted: 0,
           rejected: 0
         }}

      {:error, %Arrea.Error{} = error} ->
        {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_call({:acquire, weight}, _from, state) do
    if state.used + weight <= state.capacity do
      new_state = %{
        state
        | used: state.used + weight,
          active: state.active + 1,
          accepted: state.accepted + 1
      }

      TE.emit_bulkhead(:acquired, metadata(new_state))
      {:reply, :ok, new_state}
    else
      new_state = %{state | rejected: state.rejected + 1}
      TE.emit_bulkhead(:rejected, metadata(new_state))
      {:reply, :full, new_state}
    end
  end

  @impl true
  def handle_call(:available, _from, state) do
    {:reply, {:available, state.capacity - state.used}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:status, status_map(state)}, state}
  end

  @impl true
  def handle_cast({:release, weight}, state) do
    new_state = %{
      state
      | used: max(0, state.used - weight),
        active: max(0, state.active - 1)
    }

    TE.emit_bulkhead(:released, metadata(new_state))
    {:noreply, new_state}
  end

  # ── Helpers privados ─────────────────────────────────────────────────────

  @spec invalid_max_concurrent?(keyword()) :: boolean()
  defp invalid_max_concurrent?(opts) do
    case Keyword.get(opts, :max_concurrent) do
      nil -> true
      value -> not (is_integer(value) and value >= 1)
    end
  end

  # El segundo argumento NO es un `atom()`: `run/3` llama con `{:acquire, weight}`,
  # que es una tupla. El cuerpo acepta cualquier peticion y la pasa tal cual al
  # GenServer, de modo que era el `@spec` el que estaba mal, no el codigo. Y de
  # ahi salian en cascada los dos `no_return`: al declarar `term()`, dialyzer no
  # podia probar que el `case` de `run/3` es exhaustivo y avisaba de que la
  # funcion se caia. Un contrato honesto arregla los cuatro de una vez.
  @spec safe_call(atom(), term()) :: reply()
  defp safe_call(name, request) do
    case Registry.lookup(Arrea.Bulkhead.Registry, name) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, request)
        catch
          :exit, {:timeout, _} -> :not_found
          :exit, :timeout -> :not_found
          :exit, _ -> :not_found
        end

      [] ->
        :not_found
    end
  end

  @spec via_tuple(atom()) :: {:via, Registry, {Arrea.Bulkhead.Registry, atom()}}
  defp via_tuple(name), do: {:via, Registry, {Arrea.Bulkhead.Registry, name}}

  @spec metadata(map()) :: TE.bulkhead_metadata()
  defp metadata(%{name: name, max_concurrent: max_concurrent, active: active}) do
    %{name: name, max_concurrent: max_concurrent, active: active}
  end

  @spec status_map(map()) :: status()
  defp status_map(%{name: name} = state) do
    %{
      name: name,
      max_concurrent: state.max_concurrent,
      active: state.active,
      accepted: state.accepted,
      rejected: state.rejected,
      # Nuevo: cuanto queda, en las mismas unidades que `max_concurrent`.
      # Con peso 1, `available` y `max_concurrent - active` coinciden.
      available: state.capacity - state.used
    }
  end
end
