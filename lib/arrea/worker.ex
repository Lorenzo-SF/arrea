defmodule Arrea.Worker do
  @moduledoc """
  Worker GenServer for task execution.

  ## Lifecycle

  1. `init/1` — Initializes state and registers in `Arrea.Monitor`.
  2. `handle_info(:execute_task, state)` — Executes the first task in the queue.
  3. `handle_cast({:message, msg}, state)` — Processes messages received from other workers.
  4. `terminate/2` — Notifies the Monitor if the worker ended unexpectedly.
     If it ended through its own normal flow (all tasks completed or error
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

  alias Arrea.{Leader, Monitor, WorkerState}
  alias Arrea.Telemetry.Events, as: TE
  alias Arrea.Telemetry.Metrics, as: TelemetryMetrics
  alias Arrea.Worker.ErrorPolicy
  alias Arrea.Queue

  def start_link(opts) do
    case Keyword.fetch(opts, :id) do
      {:ok, id} ->
        opts =
          case Keyword.fetch(opts, :queues) do
            {:ok, _} -> Keyword.put(opts, :mode, :queues)
            :error -> Keyword.put(opts, :mode, :tasks)
          end

        GenServer.start_link(__MODULE__, opts, name: via_tuple(id))

      :error ->
        {:error, "missing required option :id"}
    end
  end

  @doc """
  Stops a worker. Its queues keep whatever is still in them.
  """
  @spec stop(atom()) :: :ok | {:error, :not_found}
  def stop(id) do
    case GenServer.whereis(via_tuple(id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid, :normal)
    end
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

      iex> Worker.send_message(:no_existe, %{type: :ping})
      {:error, :worker_not_found}
  """
  # Antes esto decia `@spec send_message(atom(), term()) :: :ok` y devolvia
  # `:ok` SIEMPRE. `GenServer.cast/2` devuelve `:ok` pase lo que pase, y el
  # `via_tuple` es un `{:via, Registry, {Arrea.Registry, id}}`: si el worker no
  # existe, el via no resuelve y el cast es un no-op silencioso.
  #
  # Medido, no supuesto:
  #
  #     iex> Worker.send_message(:worker_1, %{type: :ping})
  #     :ok
  #
  #     iex> Worker.send_message(:NUNCA_EXISTIO, %{type: :ping})
  #     :ok
  #
  # Un sistema de mensajes que dice que entrego lo que no entrego es peor que
  # no tener mensajes: quien llama cree que el otro agente lo sabe, y no hay
  # forma de saber que no. Y el `@spec` decia `:ok`, asi que dialyzer
  # confirmaba la mentira. No era un contrato optimista: era un contrato
  # equivocado escrito justo donde dialyzer lo lee.
  #
  # Lo que SIGUE sin haber: acuse de recibo. `:ok` aqui significa "el cast se
  # encolo en un worker vivo", no "el worker lo proceso". Una llamada con
  # respuesta es otra operacion, y por eso no se ha convertido esta en un
  # `call`: el que manda un aviso no deberia bloquear esperando un acuse que
  # nadie pidio.
  @spec send_message(atom(), term()) :: :ok | {:error, :worker_not_found}
  def send_message(worker_id, message) do
    case Registry.lookup(Arrea.Registry, worker_id) do
      [] -> {:error, :worker_not_found}
      [{pid, _}] -> GenServer.cast(pid, {:message, message})
    end
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

    # Modo colas: sin lista propia. El presupuesto es lo que me permite tomar
    # una tarea y lo que impide tomar una que no cabe.
    state =
      if Keyword.get(opts, :mode, :tasks) == :queues do
        Process.send_after(self(), :poll, Keyword.get(opts, :poll_interval, 50))

        %{
          state
          | mode: :queues,
            queues: List.wrap(Keyword.fetch!(opts, :queues)),
            budget: Keyword.get(opts, :budget, :infinity),
            poll_interval: Keyword.get(opts, :poll_interval, 50)
        }
      else
        state
      end

    if use_telemetry, do: attach_telemetry(id)

    monitor_ok =
      case safe_register_worker(id, state) do
        :ok ->
          if log?, do: Logger.debug("[Worker #{inspect(id)}] Registered in Monitor")
          true

        {:error, reason} ->
          if log? do
            Logger.warning(
              "[Worker #{inspect(id)}] Failed to register in Monitor: #{inspect(reason)}"
            )
          end

          false
      end

    TE.emit_worker(:started, %{}, %{worker_id: id, tasks_count: length(tasks)})
    notify_event(%{type: :worker_started, worker_id: id})

    if monitor_ok do
      # Solo el modo lista arranca con una tarea pendiente. El modo colas ya se
      # ha suscrito a su propio `:poll` mas arriba, y mandarle tambien un
      # `:execute_task` lo mete por `handle_task_completed` con la lista vacia,
      # que lo para. Por eso el estado que se mira es `mode`, no `tasks`.
      if state.mode != :queues, do: Process.send_after(self(), :execute_task, 0)
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

  # ── el take por presupuesto ─────────────────────────────────────────────────

  # De todas las colas que sirvo, la entrada de mayor prioridad que quepa en lo
  # que me queda. Recorrerlas EN ORDEN y parar en la primera que tiene algo que
  # me vale, en vez de mirar "la maxima prioridad global", es lo que permite
  # que una cola de prioridad baja pero ligera no quede bloqueada para siempre
  # detras de una pesada de otra cola.
  # Una entrada de cola trae un payload opaco. Por convencion es una funcion
  # de aridad cero, como las tareas de siempre; si no lo es, se cuenta como
  # fallo de esa entrada y se sigue. Arrea NO mira dentro del payload mas alla
  # de intentar ejecutarlo.
  defp execute_queue_entry(%{payload: payload, from: from} = entry, state) do
    case payload do
      fun when is_function(fun, 0) ->
        try do
          fun.()
        rescue
          e ->
            Logger.warning(
              "[Worker #{inspect(state.id)}] La entrada de #{inspect(from)} fallo: #{inspect(e)}"
            )
        end

      other ->
        Logger.warning("[Worker #{inspect(state.id)}] Payload no ejecutable: #{inspect(other)}")
    end

    Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, %{state | status: :idle}}
  end

  # De todas las colas que sirvo, la entrada de MAYOR PRIORIDAD que quepa en
  # lo que me queda. Se comparan todas antes de coger ninguna, porque si se
  # cogiera en orden de lista una tarea normal de la primera cola se llevaria
  # por delante de un `:vip` de la ultima, y entonces la prioridad no significaria
  # nada entre colas.
  defp take_from_queues(state) do
    available = budget_left(state)

    state.queues
    |> Enum.reduce(nil, fn queue, best ->
      case Queue.peek(queue, available) do
        {:ok, entry} ->
          case best do
            nil ->
              {queue, entry}

            {_queue, _entry} = candidate ->
              if entry.priority > elem(candidate, 1).priority, do: {queue, entry}, else: candidate
          end

        {:error, _} ->
          best
      end
    end)
    |> case do
      {queue, entry} ->
        # Peek no quita. Puede que otro worker se haya adelantado.
        case Queue.claim(queue, available) do
          {:ok, claimed} ->
            TE.emit_worker(:busy, %{}, %{worker_id: state.id})
            send(claimed.from, {:arrea_queue, :claimed, queue, claimed})
            {:ok, claimed}

          {:error, _} ->
            :nothing
        end

      nil ->
        :nothing
    end
  end

  # Una entrada de cola trae un payload opaco. Por convencion es una funcion
  # de aridad cero, como las tareas de siempre; si no lo es, se cuenta como
  # fallo de esa entrada y se sigue. Arrea NO mira dentro del payload mas alla
  # de intentar ejecutarlo.
  defp execute_queue_entry(%{payload: payload, from: from} = entry, state) do
    case payload do
      fun when is_function(fun, 0) ->
        try do
          fun.()
        rescue
          e ->
            Logger.warning(
              "[Worker #{inspect(state.id)}] La entrada de #{inspect(from)} fallo: #{inspect(e)}"
            )
        end

      other ->
        Logger.warning("[Worker #{inspect(state.id)}] Payload no ejecutable: #{inspect(other)}")
    end

    Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, %{state | status: :idle}}
  end

  defp take_from_queues(state) do
    available = budget_left(state)

    Enum.reduce_while(state.queues, :nothing, fn queue, _acc ->
      case Queue.claim(queue, available) do
        {:ok, entry} ->
          TE.emit_worker(:busy, %{}, %{worker_id: state.id})

          if state.log? do
            Logger.debug(
              "[Worker #{inspect(state.id)}] Took from #{inspect(queue)}, weight #{entry.weight}"
            )
          end

          {:halt, {:ok, entry}}

        {:error, reason} when reason in [:empty, :not_found] ->
          {:cont, :nothing}

        # Hay trabajo pero no cabe en lo que me queda: la siguiente cola puede
        # que si. Un `no_fit` NO es un `empty` y no corta la busqueda.
        {:error, :no_fit} ->
          {:cont, :nothing}
      end
    end)
  end

  defp budget_left(%{budget: :infinity}), do: :infinity
  defp budget_left(%{budget: budget}) when is_number(budget), do: budget

  @impl true
  def handle_info(:poll, %{queues: _} = state) do
    case take_from_queues(state) do
      {:ok, entry} ->
        # Trabajo tomado. Se devuelve el control a la cola del worker: lo
        # EJECUTA, avisa a su padre, y cuando termine vuelve a preguntar. Un
        # worker de colas no tiene lista propia, asi que no hay `tasks` que
        # Consumir ni un `:execute_task` que disparar.
        execute_queue_entry(entry, state)

      :nothing ->
        Process.send_after(self(), :poll, state.poll_interval)
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
        "[Worker #{inspect(state.id)}] Terminated: #{inspect(format_terminate_reason(reason))}"
      )
    end

    # Only notify the Monitor if the worker did not finish through its own flow.
    # When handle_task_success or notify_error_and_stop already called
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

    if result_state.tasks == [] and result_state.mode != :queues do
      ended_at = System.monotonic_time(:millisecond)

      TE.emit_worker(:completed, %{}, %{
        worker_id: state.id,
        duration_ms: ended_at - state.started_at
      })

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
    TE.emit_worker(:error, %{}, %{worker_id: state.id, reason: reason})
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
    Arrea.Worker.Registry.safe_register_worker(worker_id, state)
  end

  @spec safe_update_worker(term(), map()) :: :ok
  defp safe_update_worker(worker_id, updates) do
    Arrea.Worker.Registry.safe_update_worker(worker_id, updates)
  end

  @spec safe_worker_finished(term(), atom(), integer()) :: :ok
  defp safe_worker_finished(worker_id, status, duration_ms) do
    Arrea.Worker.Registry.safe_worker_finished(worker_id, status, duration_ms)
  end

  @spec safe_notify_monitor_finished(term(), term()) :: :ok
  defp safe_notify_monitor_finished(worker_id, reason) do
    Arrea.Worker.Registry.safe_notify_monitor_finished(worker_id, reason)
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
    ErrorPolicy.handle_error_with_policy(state, reason, error_state)
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
  defp attach_telemetry(worker_id) do
    :telemetry.attach(
      {__MODULE__, worker_id, :started},
      [:arrea, :worker, :started],
      &TelemetryMetrics.handle_worker_started/4,
      %{}
    )

    :telemetry.attach(
      {__MODULE__, worker_id, :completed},
      [:arrea, :worker, :completed],
      &TelemetryMetrics.handle_worker_completed/4,
      %{}
    )

    :telemetry.attach(
      {__MODULE__, worker_id, :error},
      [:arrea, :worker, :error],
      &TelemetryMetrics.handle_worker_error/4,
      %{}
    )

    :ok
  end

  @spec detach_telemetry(term()) :: :ok
  defp detach_telemetry(worker_id) do
    :telemetry.detach({__MODULE__, worker_id, :started})
    :telemetry.detach({__MODULE__, worker_id, :completed})
    :telemetry.detach({__MODULE__, worker_id, :error})
    :ok
  end

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}
end
