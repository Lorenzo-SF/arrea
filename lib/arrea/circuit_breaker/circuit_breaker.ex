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

  @type state :: :closed | :open | :half_open

  @doc """
  Starts a circuit breaker with a unique name (required in `opts`).

  ## Options

    - `:name` — Unique breaker name (required)
    - `:id` — Alias of `:name`, accepted for convenience
    - `:threshold` — Number of consecutive failures to open the circuit (default: 5)
    - `:timeout` — Time in ms before transitioning to `:half_open` (default: 60_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name) || Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(name))
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
          # Catching all exceptions here is intentional: the breaker
          # contract is "any user-raised error counts as a failure".
          # If we narrowed this to specific exceptions, an unexpected
          # FunctionClauseError / KeyError / etc. would escape the
          # breaker and bypass failure accounting.
          _exception ->
            GenServer.cast(via_tuple(name), :failure)
            {:error, :execution_failed}
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
    {:ok,
     %State{
       threshold:
         Keyword.get(opts, :threshold, Application.get_env(:arrea, :circuit_breaker_threshold, 5)),
       timeout:
         Keyword.get(
           opts,
           :timeout,
           Application.get_env(:arrea, :circuit_breaker_timeout, 60_000)
         )
     }}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state.state, state}

  @impl true
  def handle_call(:get_full_state, _from, state), do: {:reply, state, state}

  # Atomically decide to allow or block execution.
  # When the circuit is open and the timeout has expired, transition to
  # half_open and allow one trial execution.
  @impl true
  def handle_call(:get_state_and_check, _from, state) do
    case state.state do
      :closed ->
        {:reply, {:allowed, state}, state}

      :open ->
        if should_retry_from_state?(state) do
          new_state = %{state | state: :half_open}
          {:reply, {:allowed, new_state}, new_state}
        else
          {:reply, {:blocked, :circuit_open}, state}
        end

      :half_open ->
        {:reply, {:allowed, state}, state}
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
            %{state | state: :closed, failures: 0, successes: 0}
          else
            %{state | successes: new_successes}
          end

        :closed ->
          %{state | successes: state.successes + 1}

        :open ->
          # Éxito mientras estaba abierto (llamada directa a success/1):
          # se cierra el circuito y se resetean contadores.
          %{state | state: :closed, failures: 0, successes: 0}
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
          %{state | state: :open, failures: new_failures, successes: 0, last_failure_at: now_ms}

        new_failures >= state.threshold ->
          %{state | state: :open, failures: new_failures, last_failure_at: now_ms}

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
      [{pid, _}] -> GenServer.call(pid, request)
      [] -> :not_found
    end
  end

  @spec via_tuple(atom()) :: {:via, Registry, {Arrea.CircuitBreaker.Registry, atom()}}
  defp via_tuple(name), do: {:via, Registry, {Arrea.CircuitBreaker.Registry, name}}

  # Usa tiempo monotónico para ser inmune a cambios de reloj del sistema.
  @spec should_retry_from_state?(State.t()) :: boolean()
  defp should_retry_from_state?(%State{last_failure_at: nil}), do: true

  defp should_retry_from_state?(%State{last_failure_at: last_ms, timeout: timeout}) do
    System.monotonic_time(:millisecond) - last_ms > timeout
  end
end
