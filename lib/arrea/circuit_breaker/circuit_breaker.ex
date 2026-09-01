defmodule Arrea.CircuitBreaker do
  @moduledoc """
  Circuit Breaker for system protection.

  Implements the Circuit Breaker pattern with three states:

  - `:closed` — Normal operation; calls are executed directly.
  - `:open` — Calls are blocked immediately after exceeding the
    consecutive failures threshold.
  - `:half_open` — Probe state after the recovery timeout. A single
    call is allowed to verify whether the system has recovered.

  ## Atomic decision

  The decision to allow or block execution is taken atomically inside
  the GenServer (`get_state_and_check`), eliminating the race condition
  between reading the state and executing the function.

  ## Closing from half_open

  In `:half_open` state, `max(1, threshold / 2)` **consecutive** successes
  are required to close the circuit, mitigating the risk of premature
  closure under concurrent calls.

  A failure in `:half_open` resets the accumulated success counter on
  the way back to `:open`, guaranteeing that the next recovery attempt
  starts from zero.

  ## Timeout measurement

  `System.monotonic_time/1` is used to compute the interval since the
  last failure, immune to system clock adjustments (NTP, manual changes, etc.).

  ## Registry

  Each breaker is registered through `Registry` with a unique name under
  `Arrea.CircuitBreaker.Registry`.
  """

  use GenServer
  alias Arrea.CircuitBreaker.State
  alias Arrea.Telemetry.Events, as: TE

  require Logger

  @type state :: :closed | :open | :half_open

  @doc """
  Validates circuit breaker options.

  Returns `:ok` when the options are valid or
  `{:error, %Arrea.Error{}}` with a `:invalid_config` code describing the
  first problem found.

  ## Validation rules

    - `:name` or `:id` must be present
    - `:threshold` must be `>= 1`
    - `:timeout` must be `> 0`

  ## Example

      iex> Arrea.CircuitBreaker.validate_opts(name: :db, threshold: 3)
      :ok

      iex> Arrea.CircuitBreaker.validate_opts(name: :db, threshold: -1)
      {:error, %Arrea.Error{code: :invalid_config}}
  """
  @spec validate_opts(keyword()) :: :ok | {:error, Arrea.Error.t()}
  def validate_opts(opts) do
    cond do
      not (Keyword.has_key?(opts, :name) or Keyword.has_key?(opts, :id)) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "name (or id) option is required"}}

      invalid_threshold?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "threshold must be >= 1"}}

      invalid_timeout?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "timeout must be > 0"}}

      true ->
        :ok
    end
  end

  @doc """
  Starts a circuit breaker with a unique name (required in `opts`).

  ## Options

    - `:name` — Unique breaker name (required)
    - `:id` — Alias of `:name`, accepted for convenience
    - `:threshold` — Number of consecutive failures to open the circuit (default: 5)
    - `:timeout` — Time in ms before transitioning to `:half_open` (default: 60_000)

  Invalid options (missing name, `threshold < 1`, `timeout <= 0`) are
  rejected with `{:error, %Arrea.Error{code: :invalid_config}}` instead
  of silently accepted.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case validate_opts(opts) do
      :ok ->
        name = Keyword.get(opts, :name) || Keyword.fetch!(opts, :id)
        GenServer.start_link(__MODULE__, opts, name: via_tuple(name))

      {:error, %Arrea.Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Executes a function protected by the circuit breaker.

  - If the circuit is **closed** or **half_open**: the function is executed.
  - If the circuit is **open** and the timeout has not elapsed: returns
    `{:error, :circuit_open}` without executing anything.
  - If the breaker is not registered: the function is executed directly
    (behaviour equivalent to a closed circuit).

  ## Examples

      iex> CircuitBreaker.call(:my_breaker, fn -> :ok end)
      {:ok, :ok}

      iex> CircuitBreaker.call(:my_breaker, fn -> raise "boom" end)
      {:error, :execution_failed}
  """
  @spec call(atom(), (-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def call(name, fun, _opts \\ []) when is_function(fun, 0) do
    case safe_call(name, :get_state_and_check) do
      {:allowed, _state} ->
        try do
          result = fun.()
          GenServer.cast(via_tuple(name), :success)
          {:ok, result}
        rescue
          _exception ->
            GenServer.cast(via_tuple(name), :failure)
            {:error, :execution_failed}
        catch
          kind, reason ->
            GenServer.cast(via_tuple(name), :failure)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:blocked, reason} ->
        {:error, reason}

      :not_found ->
        {:ok, fun.()}
    end
  end

  @doc """
  Returns the current state of the circuit breaker (`:closed`, `:open`, `:half_open`).

  Returns `:closed` if the breaker is not registered.
  """
  @spec get_state(atom()) :: state()
  def get_state(name) do
    case Registry.lookup(Arrea.CircuitBreaker.Registry, name) do
      [{pid, _}] -> GenServer.call(pid, :get_state)
      [] -> :closed
    end
  end

  @doc """
  Notifies the circuit breaker of a successful execution.
  """
  @spec success(atom()) :: :ok
  def success(name), do: GenServer.cast(via_tuple(name), :success)

  @doc """
  Notifies the circuit breaker of an execution failure.
  """
  @spec failure(atom()) :: :ok
  def failure(name), do: GenServer.cast(via_tuple(name), :failure)

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    case validate_opts(opts) do
      :ok ->
        {:ok,
         %State{
           name: Keyword.get(opts, :name) || Keyword.fetch!(opts, :id),
           threshold:
             Keyword.get(
               opts,
               :threshold,
               Application.get_env(:arrea, :circuit_breaker_threshold, 5)
             ),
           timeout:
             Keyword.get(
               opts,
               :timeout,
               Application.get_env(:arrea, :circuit_breaker_timeout, 60_000)
             )
         }}

      {:error, %Arrea.Error{} = error} ->
        {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state.state, state}

  @impl true
  def handle_call(:get_full_state, _from, state), do: {:reply, state, state}

  # Atomically decide to allow or block execution.
  # When the circuit is open and the timeout has expired, transition to
  # half_open and allow one trial execution.
  #
  # Single-flight probe: in :half_open only the first caller is allowed to
  # probe (probe_in_progress is set). Every concurrent caller that arrives
  # while a probe is running gets :circuit_open, so the retry storm is
  # replaced by a single probe whose outcome is recorded by the casts
  # :success/:failure that reset the flag.
  @impl true
  def handle_call(:get_state_and_check, _from, state) do
    case state.state do
      :closed ->
        {:reply, {:allowed, state}, state}

      :open ->
        if should_retry_from_state?(state) do
          new_state = %{state | state: :half_open}
          emit(:half_open, new_state)
          {:reply, {:allowed, new_state}, new_state}
        else
          {:reply, {:blocked, :circuit_open}, state}
        end

      :half_open ->
        if state.probe_in_progress do
          {:reply, {:blocked, :circuit_open}, state}
        else
          {:reply, {:allowed, state}, %{state | probe_in_progress: true}}
        end
    end
  end

  # En half_open se requieren `threshold / 2` éxitos consecutivos para cerrar,
  # mitigando el riesgo de cierre prematuro ante múltiples llamadas concurrentes.
  @impl true
  def handle_cast(:success, state) do
    new_state =
      case state.state do
        :half_open ->
          new_successes = state.successes + 1
          required = max(1, div(state.threshold, 2))

          if new_successes >= required do
            new = %{state | state: :closed, failures: 0, successes: 0, probe_in_progress: false}
            emit(:closed, new)
            new
          else
            %{state | successes: new_successes, probe_in_progress: false}
          end

        :closed ->
          %{state | successes: state.successes + 1}

        :open ->
          new = %{state | state: :closed, failures: 0, successes: 0, probe_in_progress: false}
          emit(:closed, new)
          new
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:failure, state) do
    new_failures = state.failures + 1
    now_ms = System.monotonic_time(:millisecond)

    new_state =
      cond do
        # En half_open cualquier fallo vuelve a abrir.
        # Se resetean también los éxitos acumulados para que el próximo
        # attempt starts from zero.
        state.state == :half_open ->
          new = %{
            state
            | state: :open,
              failures: new_failures,
              successes: 0,
              last_failure_at: now_ms,
              probe_in_progress: false
          }

          emit(:open, new)
          new

        new_failures >= state.threshold ->
          new = %{state | state: :open, failures: new_failures, last_failure_at: now_ms}
          emit(:open, new)
          emit(:trip, new)
          new

        true ->
          %{state | failures: new_failures}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:to_half_open, %{state: :open} = state) do
    {:noreply, %{state | state: :half_open}}
  end

  def handle_cast(:to_half_open, state), do: {:noreply, state}

  # ── Helpers privados ─────────────────────────────────────────────────────

  @spec safe_call(atom(), atom()) :: {:allowed, State.t()} | {:blocked, atom()} | :not_found
  defp safe_call(name, request) do
    case Registry.lookup(Arrea.CircuitBreaker.Registry, name) do
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

  @spec via_tuple(atom()) :: {:via, Registry, {Arrea.CircuitBreaker.Registry, atom()}}
  defp via_tuple(name), do: {:via, Registry, {Arrea.CircuitBreaker.Registry, name}}

  @spec emit(atom(), State.t()) :: :ok
  defp emit(event, %State{} = state) do
    TE.emit_circuit_breaker(event, %{
      name: state.name,
      failures: state.failures,
      threshold: state.threshold,
      successes: state.successes,
      state: state.state
    })
  end

  @spec invalid_threshold?(keyword()) :: boolean()
  defp invalid_threshold?(opts) do
    case Keyword.get(opts, :threshold) do
      nil -> false
      value -> not (is_integer(value) and value >= 1)
    end
  end

  @spec invalid_timeout?(keyword()) :: boolean()
  defp invalid_timeout?(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> false
      value -> not (is_integer(value) and value > 0)
    end
  end

  # Usa tiempo monotónico para ser inmune a cambios de reloj del sistema.
  @spec should_retry_from_state?(State.t()) :: boolean()
  defp should_retry_from_state?(%State{last_failure_at: nil}), do: true

  defp should_retry_from_state?(%State{last_failure_at: last_ms, timeout: timeout}) do
    System.monotonic_time(:millisecond) - last_ms > timeout
  end
end
