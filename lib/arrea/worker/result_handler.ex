defmodule Arrea.Worker.ResultHandler do
  @moduledoc """
  Task result handling for `Arrea.Worker`.

  Splits out the success/error handling logic from `Arrea.Worker` so
  the worker GenServer remains focused on state transitions.

  Not part of the public API — used only by `Arrea.Worker`.

  All functions take the `state` map and return a tuple describing the
  next state machine action (`{:noreply, state}`, `{:stop, reason, state}`).
  """

  @doc """
  Handles a successful task result.

  Updates progress, emits telemetry, and returns either `{:noreply, state}`
  (more tasks remaining) or `{:stop, :normal, state}` (all tasks done).
  """
  @spec handle_task_success(map(), term(), map()) ::
          {:noreply, map()} | {:stop, :normal, map()}
  def handle_task_success(state, result, new_state) do
    completed = state.completed_tasks + 1
    progress_state = update_progress(new_state, completed)
    result_state = add_result(progress_state, result)

    update_worker_safely(state.id, %{
      progress: result_state.progress,
      completed_tasks: result_state.completed_tasks
    })

    emit_progress(state.id, result_state, completed)
    emit_result(state.id, result)

    if state.parent do
      send(state.parent, {:worker_done, state.id, result})
    end

    if result_state.tasks == [] do
      finalize_success(result_state, state)
    else
      schedule_next(result_state)
    end
  end

  @doc """
  Handles a task error according to the worker's retry policy.

  Returns:
    * `{:noreply, state}` — retrying or continuing
    * `{:stop, {:error, term()}, state}` — fatal error
  """
  @spec handle_task_error(map(), term(), map()) ::
          {:noreply, map()} | {:stop, {:error, term()}, map()}
  def handle_task_error(state, reason, new_state) do
    case Arrea.Worker.Scheduler.handle_error_with_policy(state, reason, new_state) do
      {:retry, delay, retry_state} ->
        Process.send_after(self(), :execute_task, delay)
        {:noreply, retry_state}

      :stop ->
        emit_error_and_stop(state, reason, new_state)

      :continue ->
        if new_state.tasks == [] do
          finalize_continue(new_state)
        else
          schedule_next(new_state)
        end
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────

  # Standalone defaults — replace with WorkerState.* when integrated.
  defp update_progress(state, _completed), do: state
  defp add_result(state, _result), do: state

  defp update_worker_safely(_id, _updates), do: :ok
  defp emit_progress(_id, state, completed), do: {state.id, state.progress, completed}
  defp emit_result(_id, result), do: result

  defp finalize_success(result_state, original_state) do
    ended_at = System.monotonic_time(:millisecond)

    emit_telemetry(:completed, original_state.id, ended_at - original_state.started_at)
    notify_event(%{type: :finished, worker_id: original_state.id})
    worker_finished_safely(original_state.id, :success, ended_at)

    final_state = %{result_state | status: :finished, ended_at: ended_at}
    {:stop, :normal, final_state}
  end

  defp finalize_continue(new_state) do
    ended_at = System.monotonic_time(:millisecond)
    notify_event(%{type: :finished, worker_id: new_state.id})
    worker_finished_safely(new_state.id, :success, ended_at)

    final_state = %{new_state | status: :finished, ended_at: ended_at}
    {:stop, :normal, final_state}
  end

  defp schedule_next(state) do
    Process.send_after(self(), :execute_task, 0)
    {:noreply, state}
  end

  defp emit_error_and_stop(state, reason, new_state) do
    emit_telemetry(:error, state.id, reason)
    notify_event(%{type: :error, worker_id: state.id, reason: reason})

    if state.parent do
      send(state.parent, {:worker_error, state.id, reason})
    end

    worker_finished_safely(state.id, {:error, reason}, System.monotonic_time(:millisecond))
    final_state = %{new_state | status: :finished, ended_at: System.monotonic_time(:millisecond)}
    {:stop, {:error, reason}, final_state}
  end

  defp emit_telemetry(event, worker_id, metadata) do
    Arrea.Telemetry.emit_worker(event, %{}, %{worker_id: worker_id} |> Map.put(:metadata, metadata))
    :ok
  end

  defp notify_event(_event), do: :ok
  defp worker_finished_safely(_id, _status, _ended_at), do: :ok
end