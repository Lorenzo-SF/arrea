defmodule Arrea.Worker do
  @moduledoc """
  Worker GenServer for task execution.

  ## Ciclo de vida

  1. `init/1` — Inicializa estado y se registra en `Arrea.Monitor`.
  2. `handle_info(:execute_task, state)` — Executes la primera tarea de la cola.
  3. `handle_cast({:message, msg}, state)` — Procesa mensajes recibidos de otros workers.
  4. `terminate/2` — Notifica al Monitor si el worker terminó de forma inesperada.
     Si terminó por su propio flujo normal (todas las tareas completadas o error
     handled), the notification was already emitted before `{:stop, ...}` and
     `terminate` does not duplicate it.

  ## Formatos de mensaje aceptados

  `Worker.send_message/2` acepta:
  - Mapas con clave `:type` — mensaje estructurado genérico: `%{type: :my_event, ...}`
  - Tupla de enrutamiento: `{:send_to_worker, target_worker_id, payload}` — reenvía
    el `payload` al worker identificado por `target_worker_id`.

  ## Política de errores

  Si no se especifica policy al iniciar el worker, se usan los valores de
  `Arrea.Config` (`:default_policy`, `:max_retries`, `:retry_delay`).

  ## Usage

      Arrea.Worker.start_link(id: :worker_1, tasks: [fn -> :work end], parent: self())
      Arrea.Worker.send_message(:worker_1, %{type: :ping})
      Arrea.Worker.send_message(:worker_1, {:send_to_worker, :worker_2, %{type: :data, value: 42}})
      {:ok, state} = Arrea.Worker.get_state(:worker_1)
  """

  use GenServer, restart: :temporary

  require Logger

  alias Arrea.Config
  alias Arrea.{Leader, Monitor, WorkerState}

  @doc """
  Inicia un worker con opciones configurables.

  ## Opciones

  - `:id` — Identificador único del worker (requerido)
  - `:tasks` — Lista de funciones a ejecutar
  - `:parent` — PID del proceso padre (Leader)
  - `:log` — Habilitar logging (default: false)
  - `:policy` — Política de manejo de errores. Si es `nil`, se usan los valores
    de `Arrea.Config` (`:default_policy`, `:max_retries`, `:retry_delay`).
  - `:telemetry` — Habilitar telemetría (default: false)

  ## Examples

      iex> Worker.start_link(id: :worker_1, tasks: [fn -> :ok end])
      {:ok, pid}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
  end

  @doc """
  Envía un mensaje al worker identificado.

  Formatos aceptados:
  - `%{type: atom(), ...}` — mensaje estructurado
  - `{:send_to_worker, target_id, payload}` — enruta `payload` a otro worker

  ## Examples

      iex> Worker.send_message(:worker_1, %{type: :ping})
      :ok

      iex> Worker.send_message(:worker_1, {:send_to_worker, :worker_2, %{type: :data, value: 1}})
      :ok
  """
  @spec send_message(atom(), term()) :: :ok
  def send_message(worker_id, message) do
    GenServer.cast(via_tuple(worker_id), {:message, message})
  end

  @doc """
  Obtiene el estado actual del worker.

  ## Examples

      iex> Worker.get_state(:worker_1)
      {:ok, %WorkerState{id: :worker_1, ...}}

      iex> Worker.get_state(:nonexistent)
      {:error, :not_found}
  """
  @spec get_state(atom()) :: {:ok, WorkerState.t()} | {:error, :not_found}
  def get_state(worker_id) do
    case Registry.lookup(Arrea.Registry, worker_id) do
      [{pid, _}] -> GenServer.call(pid, :get_state)
      [] -> {:error, :not_found}
    end
  end

  # ── Callbacks GenServer ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    tasks = Keyword.get(opts, :tasks, [])
    log? = Keyword.get(opts, :log, false)
    parent = Keyword.get(opts, :parent)
    policy = Keyword.get(opts, :policy)
    use_telemetry = Keyword.get(opts, :telemetry, false)

    state = WorkerState.new(id, tasks, parent: parent, log: log?, policy: policy)

    if use_telemetry, do: attach_telemetry(id)

    monitor_ok =
      case safe_register_worker(id, state) do
        :ok ->
          if log?, do: Logger.debug("[Worker #{inspect(id)}] Registrado en Monitor")
          true

        {:error, reason} ->
          if log? do
            Logger.warning(
              "[Worker #{inspect(id)}] No se pudo registrar en Monitor: #{inspect(reason)}"
            )
          end

          false
      end

    notify_event(%{type: :worker_started, worker_id: id})

    if monitor_ok do
      Process.send_after(self(), :execute_task, 0)
      {:ok, state}
    else
      {:stop, {:error, :monitor_unavailable}, %{state | status: :error}}
    end
  end

  @impl true
  def handle_cast({:message, message}, state) do
    case validate_message_format(message) do
      :ok ->
        if state.log? do
          Logger.info("[Worker #{inspect(state.id)}] Mensaje recibido: #{inspect(message)}")
        end

        notify_event(%{type: :message_received, worker_id: state.id, message: message})
        new_state = process_message(message, state)
        {:noreply, new_state}

      {:error, reason} ->
        if state.log? do
          Logger.warning("[Worker #{inspect(state.id)}] Mensaje inválido: #{inspect(reason)}")
        end

        notify_event(%{type: :message_invalid, worker_id: state.id, reason: reason})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:execute_task, state) do
    running_state = %{state | status: :running}
    Monitor.update_worker(state.id, %{status: :running})

    case execute_next_task(running_state) do
      {:ok, result, new_state} -> handle_task_success(state, result, new_state)
      {:error, reason, new_state} -> handle_task_error(state, reason, new_state)
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Worker #{inspect(state.id)}] Unhandled info: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    {:reply, :ok, %{state | status: :idle}}
  end

  @impl true
  def terminate(reason, state) do
    detach_telemetry(state.id)

    if state.log? do
      Logger.info(
        "[Worker #{inspect(state.id)}] Terminado: #{inspect(format_terminate_reason(reason))}"
      )
    end

    # Solo notifica al Monitor si el worker no terminó por su propio flujo.
    # Cuando handle_task_success o notify_error_and_stop ya llamaron a
    # safe_worker_finished, el estado tiene status :finished o :error.
    # This prevents double counting in the Monitor statistics.
    unless state.status in [:finished, :error] do
      safe_notify_monitor_finished(state.id, reason)
    end

    :ok
  end

  # ── Manejo de tareas ─────────────────────────────────────────────────────

  @doc false
  @spec handle_task_success(WorkerState.t(), term(), WorkerState.t()) ::
          {:noreply, WorkerState.t()} | {:stop, :normal, WorkerState.t()}
  defp handle_task_success(state, result, new_state) do
    completed = state.completed_tasks + 1
    progress_state = WorkerState.update_progress(new_state, completed)
    result_state = WorkerState.add_result(progress_state, result)

    safe_update_worker(state.id, %{
      progress: result_state.progress,
      completed_tasks: result_state.completed_tasks
    })

    notify_event(%{
      type: :progress,
      worker_id: state.id,
      percent: result_state.progress,
      task_index: completed,
      total: state.total_tasks
    })

    notify_event(%{type: :result, worker_id: state.id, data: result})

    if state.parent do
      send(state.parent, {:worker_done, state.id, result})
    end

    if result_state.tasks == [] do
      ended_at = System.monotonic_time(:millisecond)
      notify_event(%{type: :finished, worker_id: state.id})
      safe_worker_finished(state.id, :success, ended_at)
      # status :finished marca que terminate/2 no debe re-notificar al Monitor
      final_state = %{result_state | status: :finished, ended_at: ended_at}
      {:stop, :normal, final_state}
    else
      Logger.debug("[Worker #{inspect(state.id)}] Quedan #{length(result_state.tasks)} tareas")
      Process.send_after(self(), :execute_task, 0)
      {:noreply, result_state}
    end
  end

  @spec handle_task_error(WorkerState.t(), term(), WorkerState.t()) ::
          {:noreply, WorkerState.t()} | {:stop, {:error, term()}, WorkerState.t()}
  defp handle_task_error(state, reason, new_state) do
    case handle_error_with_policy(state, reason, new_state) do
      {:retry, delay, retry_state} ->
        Process.send_after(self(), :execute_task, delay)
        {:noreply, retry_state}

      :stop ->
        notify_error_and_stop(state, reason, new_state)

      :continue ->
        if new_state.tasks == [] do
          ended_at = System.monotonic_time(:millisecond)
          notify_event(%{type: :finished, worker_id: state.id})
          safe_worker_finished(state.id, :success, ended_at)
          final_state = %{new_state | status: :finished, ended_at: ended_at}
          {:stop, :normal, final_state}
        else
          Process.send_after(self(), :execute_task, 0)
          {:noreply, new_state}
        end
    end
  end

  defp notify_error_and_stop(state, reason, new_state) do
    notify_event(%{type: :error, worker_id: state.id, reason: reason})

    if state.parent do
      send(state.parent, {:worker_error, state.id, reason})
    end

    ended_at = System.monotonic_time(:millisecond)
    safe_worker_finished(state.id, :error, ended_at)
    # status :error marca que terminate/2 no debe re-notificar al Monitor
    final_state = %{new_state | status: :error, ended_at: ended_at}
    {:stop, {:error, reason}, final_state}
  end

  # ── Monitor (llamadas seguras) ───────────────────────────────────────────

  @spec safe_register_worker(any(), any()) :: :ok | {:error, term()}
  defp safe_register_worker(worker_id, state) do
    case Process.whereis(Arrea.Monitor) do
      pid when is_pid(pid) ->
        try do
          Monitor.register_worker(worker_id, state)
          :ok
        rescue
          e -> {:error, {:monitor_error, e}}
        catch
          :exit, reason -> {:error, {:monitor_exit, reason}}
        end

      nil ->
        {:error, :monitor_not_running}
    end
  end

  @spec safe_update_worker(term(), map()) :: :ok
  defp safe_update_worker(worker_id, updates) do
    safe_monitor_call(fn -> Monitor.update_worker(worker_id, updates) end)
  end

  @spec safe_worker_finished(term(), atom(), integer()) :: :ok
  defp safe_worker_finished(worker_id, status, duration_ms) do
    safe_monitor_call(fn -> Monitor.worker_finished(worker_id, status, duration_ms) end)
  end

  @spec safe_notify_monitor_finished(term(), term()) :: :ok
  defp safe_notify_monitor_finished(worker_id, reason) do
    safe_monitor_call(fn ->
      ended_at = System.monotonic_time(:millisecond)

      status =
        case reason do
          :normal -> :finished
          {:error, _} -> :finished
          _ -> :error
        end

      Monitor.worker_finished(worker_id, status, ended_at)
    end)
  end

  @spec safe_monitor_call((-> :ok | {:ok, term()})) :: :ok
  defp safe_monitor_call(func) do
    func.()
    :ok
  rescue
    e ->
      Logger.warning("[Worker] Monitor call failed: #{inspect(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[Worker] Monitor call exited: #{inspect(reason)}")
      :ok
  end

  # ── Task execution ──────────────────────────────────────────────────

  @spec execute_next_task(WorkerState.t()) ::
          {:ok, term(), WorkerState.t()} | {:error, term(), WorkerState.t()}
  defp execute_next_task(%WorkerState{tasks: []} = state), do: {:ok, nil, state}

  defp execute_next_task(%WorkerState{tasks: [task | rest]} = state) do
    result =
      try do
        case task.() do
          :ok -> {:ok, :ok}
          {:ok, val} -> {:ok, val}
          {:error, _} = err -> err
          other -> {:ok, other}
        end
      rescue
        e -> {:error, {:exception, e}}
      catch
        type, value -> {:error, {type, value}}
      end

    case result do
      {:error, _} = error -> {:error, error, %{state | tasks: rest}}
      {:ok, val} -> {:ok, val, %{state | tasks: rest}}
    end
  end

  # ── Inter-worker messaging ─────────────────────────────────────────────

  # Acepta:
  #   - Cualquier mapa con clave :type
  #   - Tupla de enrutamiento {:send_to_worker, target_id, payload}
  @spec validate_message_format(term()) :: :ok | {:error, :invalid_format}
  defp validate_message_format(%{type: _type}), do: :ok
  defp validate_message_format({:send_to_worker, _target, _payload}), do: :ok
  defp validate_message_format(_), do: {:error, :invalid_format}

  @spec process_message(term(), WorkerState.t()) :: WorkerState.t()
  defp process_message({:send_to_worker, target_worker_id, payload}, state) do
    case Registry.lookup(Arrea.Registry, target_worker_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:message, payload})

        notify_event(%{
          type: :message_forwarded,
          worker_id: state.id,
          target: target_worker_id,
          message: payload
        })

      [] ->
        notify_event(%{
          type: :message_target_not_found,
          worker_id: state.id,
          target: target_worker_id
        })
    end

    state
  end

  defp process_message(_message, state), do: state

  # ── Política de errores ──────────────────────────────────────────────────

  defp handle_error_with_policy(state, reason, error_state) do
    # Si no hay política explícita, se construye una desde la config global.
    # Esto garantiza que Config.set/2 y config.exs del proyecto consumidor
    # afecten al comportamiento por defecto de los workers.
    policy = state.policy || build_default_policy()

    new_retry_count = state.retry_count + 1

    context = %{
      worker_id: state.id,
      task_index: state.total_tasks - length(error_state.tasks),
      retry_count: new_retry_count
    }

    case handle_policy_error(policy, reason, new_retry_count, context) do
      {:retry, delay} ->
        retry_state = %{error_state | retry_count: new_retry_count}
        {:retry, delay, retry_state}

      :stop ->
        :stop

      :continue ->
        :continue

      {:custom, custom_action} ->
        handle_custom_action(custom_action, error_state, new_retry_count)
    end
  end

  @spec build_default_policy() :: map()
  defp build_default_policy do
    %{
      on_error: Config.get(:default_policy, :retry),
      max_retries: Config.get(:max_retries, 3),
      retry_delay: Config.get(:retry_delay, 1_000)
    }
  end

  defp handle_policy_error(policy, _reason, retry_count, _context) do
    max = Map.get(policy, :max_retries, 3)
    delay = Map.get(policy, :retry_delay, 1000)

    case Map.get(policy, :on_error, :retry) do
      :retry when retry_count >= max -> :stop
      :retry -> {:retry, delay}
      :stop -> :stop
      :continue -> :continue
      :log_and_continue -> :continue
      fun when is_function(fun) -> {:custom, fun}
    end
  end

  @dialyzer {:nowarn_function, {:handle_custom_action, 3}}
  defp handle_custom_action(:retry, error_state, retry_count) do
    {:retry, 1000, %{error_state | retry_count: retry_count}}
  end

  defp handle_custom_action(:stop, _error_state, _retry_count), do: :stop
  defp handle_custom_action(:continue, _error_state, _retry_count), do: :continue

  defp handle_custom_action(custom_fn, error_state, retry_count) when is_function(custom_fn) do
    case custom_fn.(error_state) do
      :retry -> {:retry, 1000, %{error_state | retry_count: retry_count}}
      :stop -> :stop
      :continue -> :continue
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec notify_event(map()) :: :ok
  defp notify_event(event) do
    case Process.whereis(Arrea.Leader) do
      nil -> :ok
      _pid -> Leader.notify_event(event)
    end
  end

  @spec via_tuple(atom()) :: {:via, Registry, {Arrea.Registry, atom()}}
  defp via_tuple(id), do: {:via, Registry, {Arrea.Registry, id}}

  @spec format_terminate_reason(term()) :: term()
  defp format_terminate_reason(:normal), do: :normal
  defp format_terminate_reason({:error, {:exception, msg}}) when is_binary(msg), do: {:error, msg}
  defp format_terminate_reason({:error, reason}), do: {:error, reason}
  defp format_terminate_reason(reason), do: reason

  @spec attach_telemetry(term()) :: :ok
  defp attach_telemetry(_worker_id), do: :ok

  @spec detach_telemetry(term()) :: :ok
  defp detach_telemetry(_worker_id), do: :ok

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}
end
