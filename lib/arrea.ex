defmodule Arrea do
  @moduledoc """
  Main facade of the `Arrea` orchestrator.

  Responsible for:
  - Parallel execution of tasks and commands
  - Worker management via `Arrea.Leader`
  - Fault tolerance with `Arrea.CircuitBreaker`
  - Status reporting via `Arrea.Monitor`

  ## Architecture

      ┌─────────────────────────────────────────────────────────┐
      │                      Arrea                              │
      │                    (Facade)                             │
      └─────────────────────────┬───────────────────────────────┘
                               │
      ┌────────────────────────▼───────────────────────────────┐
      │              Arrea.Leader (GenServer)                   │
      │         Coordinates execution, manages workers           │
      │         Emits {:leader_event, event} events           │
      └─────────────────────────┬───────────────────────────────┘
                               │
      ┌────────────────────────▼───────────────────────────────┐
      │       Arrea.WorkerSupervisor (DynamicSupervisor)       │
      │              Ephemeral workers                          │
      └─────────────────────────┬───────────────────────────────┘
                               │
      ┌────────────────────────▼───────────────────────────────┐
      │              Arrea.Worker (GenServer)                  │
      │              Executes individual tasks                │
      └─────────────────────────────────────────────────────────┘

      Arrea.Monitor — Worker lifecycle statistics
      Arrea.CircuitBreaker — Fault tolerance

  The supervision tree starts automatically when including Arrea as a
  dependencia. No es necesario arrancar `Arrea.Supervisor` manualmente.

  ## Quick start

      # Simple execution
      {:ok, result} = Arrea.execute(fn -> :ok end)

      # Parallel execution
      {:ok, results} = Arrea.run([fn -> 1 end, fn -> 2 end], workers: 4)

      # Subscribing to Leader events
      :ok = Arrea.subscribe()

      receive do
        {:leader_event, %{type: :worker_started} = event} ->
          IO.inspect(event)
        {:leader_event, %{type: :finished} = event} ->
          IO.inspect(event)
      end

      :ok = Arrea.unsubscribe()
  """

  alias Arrea.Config, as: Config
  alias Arrea.{Leader, Monitor, Parallel}

  @type execution_option ::
          {:workers, non_neg_integer()}
          | {:timeout, non_neg_integer()}
          | {:retry, boolean()}

  @doc """
  Devuelve el número máximo de workers configurados.

  ## Ejemplo

      iex> Arrea.max_workers()
      100
  """
  @spec max_workers() :: non_neg_integer()
  def max_workers, do: Config.get(:max_workers, 100)

  @doc """
  Executes un comando único de forma síncrona.

  ## Parámetros

    * `cmd` — A binary (shell command) or a zero-arity function
    * `opts` — Opciones adicionales:
      - `:timeout` — Timeout en ms (por defecto `30_000`). Timeout real: cancela la ejecución.
      - `:retry` — Si se debe reintentar en caso de fallo
      - `:shell` — Shell a usar (máxima prioridad sobre config y entorno)

  ## Returns

    * `{:ok, Arrea.Result.t()}` — Éxito con resultado
    * `{:error, Arrea.Error.t()}` — Error con código y mensaje

  ## Examples

      iex> Arrea.execute("echo hello")
      {:ok, %Arrea.Result{success: true, data: %{stdout: "hello\\n", ...}, failures: []}}

      iex> Arrea.execute(fn -> :work end)
      {:ok, %Arrea.Result{success: true, data: :work, failures: []}}
  """
  @spec execute(binary() | (-> term()), [execution_option()]) ::
          {:ok, Arrea.Result.t()} | {:error, Arrea.Error.t()}
  def execute(cmd, opts \\ []) when is_binary(cmd) or is_function(cmd, 0) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:arrea, :engine, :execute, :start],
      %{},
      %{command: safe_command_label(cmd)}
    )

    result = Parallel.execute(cmd, opts)

    duration_ms =
      System.convert_time_unit(
        System.monotonic_time() - start_time,
        :native,
        :millisecond
      )

    case result do
      {:ok, r} ->
        :telemetry.execute(
          [:arrea, :engine, :execute, :stop],
          %{duration: duration_ms},
          %{command: safe_command_label(cmd), success: true}
        )

        {:ok, %Arrea.Result{success: true, data: r, failures: []}}

      {:error, reason} ->
        :telemetry.execute(
          [:arrea, :engine, :execute, :error],
          %{duration: duration_ms},
          %{command: safe_command_label(cmd), reason: inspect(reason)}
        )

        {:error, %Arrea.Error{code: :engine_failure, message: inspect(reason)}}
    end
  catch
    :exit, reason ->
      {:error, %Arrea.Error{code: :process_exited, message: inspect(reason)}}
  end

  @doc """
  Executes múltiples comandos en paralelo.

  ## Parámetros

    * `commands` — Lista de binaries o funciones
    * `opts` — Opciones:
      - `:workers` — Número máximo de workers paralelos (por defecto `max_workers()`)
      - `:timeout` — Timeout total en ms

  ## Returns

    * `{:ok, Arrea.Result.t()}` — Con `batch_id` para correlacionar eventos
    * `{:error, Arrea.Error.t()}` — Si todos fallaron o no hay workers disponibles

  ## Ejemplo

      iex> {:ok, result} = Arrea.run([fn -> 1 end, fn -> 2 end, fn -> 3 end], workers: 2)
      iex> result.data.batch_id
      "batch_..."
  """
  @spec run([binary() | (-> term())], [execution_option()]) ::
          {:ok, Arrea.Result.t()} | {:error, Arrea.Error.t()}
  def run(commands, opts \\ []) when is_list(commands) do
    workers = Keyword.get(opts, :workers, max_workers())

    :telemetry.execute(
      [:arrea, :engine, :run, :start],
      %{},
      %{count: length(commands), workers: workers}
    )

    case Parallel.run(commands, opts) do
      {:ok, batch_id} ->
        :telemetry.execute(
          [:arrea, :engine, :run, :stop],
          %{},
          %{batch_id: batch_id}
        )

        {:ok,
         %Arrea.Result{
           success: true,
           data: %{batch_id: batch_id, pending: length(commands)},
           failures: []
         }}

      {:ok, batch_id, info} ->
        :telemetry.execute(
          [:arrea, :engine, :run, :stop],
          %{},
          %{batch_id: batch_id, partial: true}
        )

        {:ok,
         %Arrea.Result{
           success: true,
           data: Map.merge(%{batch_id: batch_id, pending: Map.get(info, :started, 0)}, info),
           failures: []
         }}

      {:error, reason} ->
        {:error, %Arrea.Error{code: :parallel_failure, message: inspect(reason)}}
    end
  end

  @doc """
  Suscribe el proceso actual a los eventos semánticos del Leader.

  Los mensajes recibidos tienen la forma `{:leader_event, event}` donde
  `event` es un mapa con al menos la clave `:type`.

  Tipos de evento habituales:
  - `%{type: :worker_started, worker_id: id}`
  - `%{type: :progress, worker_id: id, percent: float, ...}`
  - `%{type: :finished, worker_id: id}`
  - `%{type: :error, worker_id: id, reason: term}`
  - `%{type: :result, worker_id: id, data: term}`

  Para desuscribirse, llamar a `unsubscribe/0`.

  ## Ejemplo

      :ok = Arrea.subscribe()

      receive do
        {:leader_event, %{type: :finished, worker_id: id}} ->
          IO.puts("Worker \#{id} terminó")
      end
  """
  @spec subscribe() :: :ok
  def subscribe do
    Leader.subscribe()
  end

  @doc """
  Cancels the subscription of the current process to Leader events.

  ## Ejemplo

      :ok = Arrea.unsubscribe()
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Leader.unsubscribe()
  end

  @doc """
  Returns the current statistics of the Engine.

  The statistics are provided by `Arrea.Monitor`, which tracks the lifecycle
  de todos los workers arrancados bajo el Leader.

  ## Ejemplo

      iex> {:ok, stats} = Arrea.stats()
      iex> Map.keys(stats)
      [:active_workers, :completed_tasks, :failed_tasks, :total_workers]
  """
  @spec stats() :: {:ok, map()} | {:error, :monitor_unavailable}
  def stats do
    Monitor.get_stats()
  end

  # ── Helpers privados ──────────────────────────────────────────────────────

  @spec safe_command_label(binary() | function()) :: String.t()
  defp safe_command_label(cmd) when is_binary(cmd), do: String.slice(cmd, 0, 100)

  defp safe_command_label(fun) when is_function(fun),
    do: "function/#{:erlang.fun_info(fun)[:arity]}"
end
