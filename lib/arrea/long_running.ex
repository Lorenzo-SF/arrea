defmodule Arrea.LongRunning do
  @moduledoc """
  Supervisor-backed wrapper around `Port.open/2` for long-running OS processes.

  Use this when you need to spawn a binary that stays alive for the
  lifetime of the VM (or a long batch) and want:

  - Registration in `Arrea.Registry` for `lookup`/`health`/`stop`
  - Telemetry events on lifecycle (`[:arrea, :long_running, ...]`)
  - Automatic cleanup via `DynamicSupervisor` (`Arrea.WorkerSupervisor`)
  - Crash propagation back to the caller

  Designed for processes like `llama-server` (LLM inference), Postgres
  sidecars, message brokers, dev databases — anything that you'd
  otherwise spawn with raw `Port.open` and reinvent the supervision
  boilerplate for.

  ## Usage

      {:ok, pid} = Arrea.LongRunning.start_link(
        id: :llama_for_llama3,
        binary: "/usr/local/bin/llama-server",
        args: ["--model", "llama-3.gguf", "--port", "8080"],
        health: fn pid -> GenServer.call(pid, :health) end
      )

      :ok = Arrea.LongRunning.stop(:llama_for_llama3)

  ## Telemetry

  Emits:

    * `[:arrea, :long_running, :started]` — `id`, `binary`, `pid`
    * `[:arrea, :long_running, :stopped]` — `id`, `exit_code`
    * `[:arrea, :long_running, :data]` — `id`, `data` (stdout/stderr)
    * `[:arrea, :long_running, :crashed]` — `id`, `reason`

  ## Health checks

  Pass a `:health` option (zero-arity function) when starting. It runs
  after the `:started` event so callers can do a readiness probe (e.g.
  HTTP GET against the spawned process). `health/1` returns:

    * `:ok` — health probe returned truthy
    * `{:error, reason}` — probe returned falsy or raised
    * `:not_found` — no process registered with that id
  """

  use GenServer, restart: :transient

  require Logger

  @type id :: term()
  @type opt ::
          {:id, id()}
          | {:binary, Path.t()}
          | {:args, [String.t()]}
          | {:env, [{String.t(), String.t()}]}
          | {:cd, String.t()}
          | {:health, (-> any())}
          | {:name, GenServer.name()}

  @doc """
  Starts a long-running process synchronously (linked to the caller).

  See moduledoc for options.
  """
  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, nil)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Starts a long-running process under `Arrea.WorkerSupervisor`.

  Returns `{:ok, pid}` (like `DynamicSupervisor.start_child/2`).
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts) do
    id = Keyword.fetch!(opts, :id)
    child_spec = {__MODULE__, opts}

    DynamicSupervisor.start_child(Arrea.WorkerSupervisor, child_spec)
    |> case do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
    |> tap(fn _ -> :ok = register(id) end)
  end

  @doc """
  Stops a long-running process by id (graceful: closes the port).
  """
  @spec stop(id()) :: :ok | {:error, :not_found}
  def stop(id) do
    case Registry.lookup(Arrea.Registry, id) do
      [{pid, _}] ->
        GenServer.stop(pid, :normal, 5_000)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Runs the configured health probe for the given id.
  """
  @spec health(id()) :: :ok | {:error, term()} | :not_found
  def health(id) do
    case Registry.lookup(Arrea.Registry, id) do
      [{pid, _}] ->
        try do
          health_fn = :persistent_term.get({__MODULE__, pid, :health}, nil)

          if is_function(health_fn, 0) do
            case health_fn.() do
              truthy when truthy in [true, :ok] -> :ok
              falsy -> {:error, falsy}
            end
          else
            :ok
          end
        rescue
          e -> {:error, Exception.message(e)}
        end

      [] ->
        :not_found
    end
  end

  @doc """
  Writes `data` to the process stdin. Useful for inter-process protocols.

  Only works if the underlying port was opened with `:binary` (which is
  the default in `start_link/1`).
  """
  @spec write(id(), iodata()) :: :ok | {:error, term()}
  def write(id, data) do
    case Registry.lookup(Arrea.Registry, id) do
      [{pid, _}] ->
        GenServer.call(pid, {:write, data})

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a snapshot of the current state for the given id.
  """
  @spec state(id()) :: {:ok, map()} | {:error, :not_found}
  def state(id) do
    case Registry.lookup(Arrea.Registry, id) do
      [{pid, _}] ->
        {:ok, GenServer.call(pid, :state)}

      [] ->
        {:error, :not_found}
    end
  end

  # ── Callbacks ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    binary = Keyword.fetch!(opts, :binary)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])
    cd = Keyword.get(opts, :cd, ".")
    health_fn = Keyword.get(opts, :health)

    port =
      Port.open(
        {:spawn_executable, binary},
        [:binary, :exit_status, :stderr_to_stdout, args: args, env: env, cd: cd]
      )

    true = Process.link(port)

    state = %{
      id: id,
      binary: binary,
      args: args,
      port: port,
      buffer: "",
      started_at: System.monotonic_time(:millisecond)
    }

    :ok = register(id)

    if is_function(health_fn, 0) do
      :persistent_term.put({__MODULE__, self(), :health}, health_fn)
    end

    :telemetry.execute(
      [:arrea, :long_running, :started],
      %{},
      %{id: id, binary: binary, pid: self()}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    case state.port do
      nil ->
        {:reply, {:error, :not_running}, state}

      port when is_port(port) ->
        Port.command(port, data)
        {:reply, :ok, state}
    end
  end

  def handle_call(:state, _from, state) do
    snapshot = %{
      id: state.id,
      binary: state.binary,
      args: state.args,
      running: state.port != nil,
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at,
      buffer_size: byte_size(state.buffer)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    :telemetry.execute(
      [:arrea, :long_running, :data],
      %{bytes: byte_size(data)},
      %{id: state.id, data: data}
    )

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    :telemetry.execute(
      [:arrea, :long_running, :stopped],
      %{},
      %{id: state.id, exit_code: code}
    )

    {:stop, {:exit_status, code}, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    :telemetry.execute(
      [:arrea, :long_running, :crashed],
      %{},
      %{id: state.id, reason: reason}
    )

    {:stop, reason, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[Arrea.LongRunning #{state.id}] Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, self(), :health})
    unregister(state.id)
    :ok
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, state}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp register(id) do
    case Registry.register(Arrea.Registry, id, %{}) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp unregister(id) do
    Registry.unregister(Arrea.Registry, id)
    :ok
  end
end
