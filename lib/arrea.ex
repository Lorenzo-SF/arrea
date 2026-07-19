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
  dependency. There is no need to start `Arrea.Supervisor` manually.

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
  alias Arrea.Telemetry.Events, as: TE
  alias Arrea.Validation.Validator

  @type execution_option ::
          {:workers, non_neg_integer()}
          | {:timeout, non_neg_integer()}
          | {:retry, boolean()}
          | {:validate, boolean()}

  @doc """
  Returns the maximum number of workers configured.

  ## Example

      iex> Arrea.max_workers()
      100
  """
  @spec max_workers() :: non_neg_integer()
  def max_workers, do: Config.get(:max_workers, 100)

  @doc """
  Executes a single command synchronously.

  ## Parameters

    * `cmd` — A binary (shell command) or a zero-arity function
    * `opts` — Additional options:
      - `:timeout` — Timeout in ms (default `30_000`). Real timeout: cancels execution.
      - `:retry` — Whether to retry on failure
      - `:shell` — Shell to use (highest priority over config and environment)
      - `:validate` — Run safety validation before executing (default `false`).
        Set to `true` to reject dangerous commands (`:rm -rf`, `:sudo `, etc.)
        before they run. Disabled by default to preserve prior behaviour;
        trusted internal callers (e.g. Apero's info commands) can keep the
        default and pay no per-call cost.

  ## Returns

    * `{:ok, Arrea.Result.t()}` — Success with result
    * `{:error, Arrea.Error.t()}` — Error with code and message

  ## Examples

      iex> Arrea.execute("echo hello")
      {:ok, %Arrea.Result{success: true, data: %{stdout: "hello\\n", ...}, failures: []}}

      iex> Arrea.execute(fn -> :work end)
      {:ok, %Arrea.Result{success: true, data: :work, failures: []}}

      iex> Arrea.execute("rm -rf /tmp", validate: true)
      {:error, %Arrea.Error{code: :validation_failed, message: "{:dangerous_command, \\"rm -rf\\"}"}}
  """
  @spec execute(binary() | (-> term()), [execution_option()]) ::
          {:ok, Arrea.Result.t()} | {:error, Arrea.Error.t()}
  def execute(cmd, opts \\ []) when is_binary(cmd) or is_function(cmd, 0) do
    with :ok <- maybe_validate_cmd(cmd, opts) do
      do_execute(cmd, opts)
    end
  end

  defp do_execute(cmd, opts) do
    start_time = System.monotonic_time()

    TE.emit_engine(:execute, :start, %{}, %{command: safe_command_label(cmd)})

    result = Parallel.execute(cmd, opts)

    duration_ms =
      System.convert_time_unit(
        System.monotonic_time() - start_time,
        :native,
        :millisecond
      )

    case result do
      {:ok, r} ->
        TE.emit_engine(:execute, :stop, %{duration: duration_ms}, %{
          command: safe_command_label(cmd),
          success: true
        })

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

  # Runs `Validator.validate_command/1` for binary commands when the caller
  # passed `:validate, true`. Default `false` to preserve the historical
  # behaviour of `Arrea.execute/2` (only batch `Arrea.run/2` validated).
  # Functions and the default path skip validation entirely.
  @spec maybe_validate_cmd(binary() | (-> term()), keyword()) ::
          :ok | {:error, Arrea.Error.t()}
  defp maybe_validate_cmd(cmd, opts) when is_binary(cmd) do
    if Keyword.get(opts, :validate, true) do
      case Validator.validate_command(cmd) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error,
           %Arrea.Error{
             code: :validation_failed,
             message: inspect(reason)
           }}
      end
    else
      :ok
    end
  end

  defp maybe_validate_cmd(_fun, _opts), do: :ok

  @doc """
  Executes multiple commands in parallel.

  ## Parameters

    * `commands` — List of binaries or functions
    * `opts` — Options:
      - `:workers` — Maximum number of parallel workers (default `max_workers()`)
      - `:timeout` — Total timeout in ms

  ## Returns

    * `{:ok, Arrea.Result.t()}` — With `batch_id` to correlate events
    * `{:error, Arrea.Error.t()}` — If all failed or no workers are available

  ## Example

      iex> {:ok, result} = Arrea.run([fn -> 1 end, fn -> 2 end, fn -> 3 end], workers: 2)
      iex> result.data.batch_id
      "batch_..."
  """
  @spec run([binary() | (-> term())], [execution_option()]) ::
          {:ok, Arrea.Result.t()} | {:error, Arrea.Error.t()}
  def run(commands, opts \\ []) when is_list(commands) do
    workers = Keyword.get(opts, :workers, max_workers())

    TE.emit_engine(:run, :start, %{}, %{count: length(commands), workers: workers})

    case Parallel.run(commands, opts) do
      {:ok, batch_id} ->
        TE.emit_engine(:run, :stop, %{}, %{batch_id: batch_id})

        {:ok,
         %Arrea.Result{
           success: true,
           data: %{batch_id: batch_id, pending: length(commands)},
           failures: []
         }}

      {:ok, batch_id, info} ->
        TE.emit_engine(:run, :stop, %{}, %{batch_id: batch_id, partial: true})

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
  Subscribes the current process to the Leader's semantic events.

  Received messages have the shape `{:leader_event, event}` where
  `event` is a map with at least the `:type` key.

  Common event types:
  - `%{type: :worker_started, worker_id: id}`
  - `%{type: :progress, worker_id: id, percent: float, ...}`
  - `%{type: :finished, worker_id: id}`
  - `%{type: :error, worker_id: id, reason: term}`
  - `%{type: :result, worker_id: id, data: term}`

  To unsubscribe, call `unsubscribe/0`.

  ## Example

      :ok = Arrea.subscribe()

      receive do
        {:leader_event, %{type: :finished, worker_id: id}} ->
          IO.puts("Worker \#{id} finished")
      end
  """
  @spec subscribe() :: :ok
  def subscribe do
    Leader.subscribe()
  end

  @doc """
  Cancels the subscription of the current process to Leader events.

  ## Example

      :ok = Arrea.unsubscribe()
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Leader.unsubscribe()
  end

  @doc """
  Returns the current statistics of the Engine.

  The statistics are provided by `Arrea.Monitor`, which tracks the lifecycle
  of all workers started under the Leader.

  ## Example

      iex> {:ok, stats} = Arrea.stats()
      iex> Map.keys(stats)
      [:active_workers, :completed_tasks, :failed_tasks, :total_workers]
  """
  @spec stats() :: {:ok, map()} | {:error, :monitor_unavailable}
  def stats do
    Monitor.get_stats()
  end

  @doc """
  Runs a list of commands or functions in parallel and waits for all to complete.

  Thin facade over the internal parallel engine so consumers do not need to
  reach into `Arrea.Parallel` (which is marked `@moduledoc false`).

  ## Options

    * `:workers` — Number of parallel workers (default: 4)
    * `:timeout` — Default timeout per command in ms (default: 30_000)
    * `:ordered` — Return results in input order (default: true)

  ## Example

      iex> Arrea.run_sync([fn -> 1 end, fn -> 2 end])
      [{:ok, %{result: 1, exit_code: 0}}, {:ok, %{result: 2, exit_code: 0}}]
  """
  @spec run_sync([binary() | (-> term())], keyword()) :: [map()]
  def run_sync(commands, opts \\ []) when is_list(commands) do
    Parallel.run_sync(commands, opts)
  end

  # ── Helpers privados ──────────────────────────────────────────────────────

  @spec safe_command_label(binary() | function()) :: String.t()
  defp safe_command_label(cmd) when is_binary(cmd), do: String.slice(cmd, 0, 500)

  defp safe_command_label(fun) when is_function(fun),
    do: "function/#{:erlang.fun_info(fun)[:arity]}"
end
