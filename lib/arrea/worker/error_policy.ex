defmodule Arrea.Worker.ErrorPolicy do
  @moduledoc """
  Error handling policy for `Arrea.Worker`.

  Splits out the error-policy logic from `Arrea.Worker` so
  the worker GenServer remains focused on state transitions.

  Not part of the public API — used only by `Arrea.Worker`.
  """

  alias Arrea.Config

  @spec handle_error_with_policy(map(), term(), map()) ::
          {:retry, pos_integer(), map()} | :stop | :continue
  def handle_error_with_policy(state, reason, error_state) do
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

  @spec handle_custom_action((map() -> :retry | :stop | :continue), map(), non_neg_integer()) ::
          {:retry, pos_integer(), map()} | :stop | :continue
  defp handle_custom_action(custom_fn, error_state, retry_count) do
    case custom_fn.(error_state) do
      :retry -> {:retry, 1000, %{error_state | retry_count: retry_count}}
      :stop -> :stop
      :continue -> :continue
    end
  end
end
