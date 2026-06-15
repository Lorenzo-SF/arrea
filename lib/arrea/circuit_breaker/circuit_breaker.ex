defmodule Arrea.CircuitBreaker do
  @moduledoc """
  Circuit Breaker para protección del sistema.

  Implementa el patrón Circuit Breaker con tres estados:

  - `:closed` — Operación normal; las llamadas se ejecutan directamente.
  - `:open` — Las llamadas se bloquean inmediatamente tras exceder el umbral
    de fallos consecutivos.
  - `:half_open` — Estado de prueba tras el timeout de recuperación. Se permite
    una llamada para verificar si el sistema se ha recuperado.

  ## Decisión atómica

  La decisión de permitir o bloquear la ejecución se toma de forma atómica
  dentro del GenServer (`get_state_and_check`), eliminando la race condition
  entre leer el estado y ejecutar la función.

  ## Cierre desde half_open

  En estado `:half_open` se requieren `max(1, threshold / 2)` éxitos
  **consecutivos** para cerrar el circuito, mitigando el riesgo de cierre
  prematuro ante llamadas concurrentes.

  Un fallo en `:half_open` resetea el contador de éxitos acumulados al
  volver a `:open`, garantizando que el próximo intento de recuperación
  parta desde cero.

  ## Tiempo de timeout

  Se usa `System.monotonic_time/1` para calcular el intervalo desde el último
  fallo, inmune a ajustes de reloj del sistema (NTP, cambios manuales, etc.).

  ## Registro

  Cada breaker se registra via `Registry` con nombre único bajo
  `Arrea.CircuitBreaker.Registry`.
  """

  use GenServer
  alias Arrea.CircuitBreaker.State

  @type state :: :closed | :open | :half_open

  @doc """
  Inicia un circuit breaker con nombre único (requerido en `opts`).

  ## Opciones

    - `:name` — Nombre único del breaker (requerido)
    - `:id` — Alias de `:name` aceptado por conveniencia
    - `:threshold` — Número de fallos consecutivos para abrir el circuito (default: 5)
    - `:timeout` — Tiempo en ms antes de pasar a `:half_open` (default: 60_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name) || Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(name))
  end

  @doc """
  Ejecuta una función protegida por el circuit breaker.

  - Si el circuito está **cerrado** o en **half_open**: ejecuta la función.
  - Si el circuito está **abierto** y el timeout no ha expirado: retorna
    `{:error, :circuit_open}` sin ejecutar nada.
  - Si el breaker no está registrado: ejecuta la función directamente
    (comportamiento equivalente a circuito cerrado).

  ## Ejemplos

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
          _e ->
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
  Obtiene el estado actual del circuit breaker (`:closed`, `:open`, `:half_open`).

  Retorna `:closed` si el breaker no está registrado.
  """
  @spec get_state(atom()) :: state()
  def get_state(name) do
    case Registry.lookup(Arrea.CircuitBreaker.Registry, name) do
      [{pid, _}] -> GenServer.call(pid, :get_state)
      [] -> :closed
    end
  end

  @doc """
  Notifica una ejecución exitosa al circuit breaker.
  """
  @spec success(atom()) :: :ok
  def success(name), do: GenServer.cast(via_tuple(name), :success)

  @doc """
  Notifica un fallo de ejecución al circuit breaker.
  """
  @spec failure(atom()) :: :ok
  def failure(name), do: GenServer.cast(via_tuple(name), :failure)

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %State{
       threshold: Keyword.get(opts, :threshold, 5),
       timeout: Keyword.get(opts, :timeout, 60_000)
     }}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state.state, state}

  @impl true
  def handle_call(:get_full_state, _from, state), do: {:reply, state, state}

  # Toma la decisión de permitir o bloquear de forma atómica.
  # Si el circuito está abierto y el timeout expiró, transiciona a half_open
  # y permite un intento de ejecución.
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
        # intento de recuperación parta desde cero.
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
