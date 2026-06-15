defmodule Arrea.WorkerState do
  @moduledoc """
  Structure for a worker's state.

  ## Fields

  - `:id` - Unique worker identifier
  - `:tasks` - List of pending tasks (0-arity functions)
  - `:status` - Current state (:idle, :running, :finished, :error)
  - `:started_at` - Start timestamp in monotonic milliseconds
  - `:ended_at` - End timestamp (only for :finished or :error)
  - `:parent` - PID of the parent process (Leader or supervisor)
  - `:log?` - Enable logging
  - `:progress` - Current progress (0-100)
  - `:total_tasks` - Total number of tasks
  - `:completed_tasks` - Number of completed tasks
  - `:results` - List of completed task results
  - `:policy` - Error/warning policy
  - `:retry_count` - Retry counter
  - `:warnings` - List of accumulated warnings

  ## Usage

      state = WorkerState.new(:worker_1, [fn -> :work end], parent: self(), log: true)
      state = WorkerState.update_progress(state, 5)
      state = WorkerState.add_result(state, {:ok, :result})
      elapsed = WorkerState.elapsed_time(state)

  """

  @type t :: %__MODULE__{
          id: atom() | String.t(),
          tasks: [function()],
          status: :idle | :running | :finished | :error,
          started_at: integer() | nil,
          ended_at: integer() | nil,
          parent: pid() | nil,
          log?: boolean(),
          progress: float(),
          total_tasks: non_neg_integer(),
          completed_tasks: non_neg_integer(),
          results: [term()],
          policy: map() | nil,
          retry_count: non_neg_integer(),
          warnings: [term()]
        }

  defstruct id: nil,
            tasks: [],
            status: :idle,
            started_at: nil,
            ended_at: nil,
            parent: nil,
            log?: false,
            progress: 0,
            total_tasks: 0,
            completed_tasks: 0,
            results: [],
            policy: nil,
            retry_count: 0,
            warnings: []

  @doc """
  Creates a new worker state.

  ## Parameters

  - `id` - Unique identifier
  - `tasks` - List of functions to execute
  - `opts` - Additional options

  ## Options

  - `:parent` - PID of the parent process
  - `:log` - Enable logging (default: false)
  - `:policy` - Error/warning policy (default: nil)

  ## Examples

      iex> WorkerState.new(:worker_1, [fn -> :ok end])
      %WorkerState{id: :worker_1, tasks: [...], status: :idle, ...}

      iex> WorkerState.new(:worker_1, [fn -> :ok end], parent: self(), log: true)
      %WorkerState{id: :worker_1, parent: #PID<...>, log?: true, ...}

  """
  @dialyzer {:nowarn_function, {:new, 3}}
  @spec new(
          id :: term(),
          tasks :: [(-> term())],
          opts :: keyword()
        ) :: t()
  def new(id, tasks, opts \\ []) do
    %__MODULE__{
      id: id,
      tasks: tasks,
      total_tasks: length(tasks),
      status: :idle,
      started_at: System.monotonic_time(:millisecond),
      parent: Keyword.get(opts, :parent),
      log?: Keyword.get(opts, :log, false),
      policy: Keyword.get(opts, :policy),
      progress: 0,
      completed_tasks: 0,
      results: [],
      retry_count: 0,
      warnings: []
    }
  end

  @doc """
  Calculates the elapsed time since the worker started.

  If the worker has finished (:finished or :error), returns the final time.
  If the worker is running, returns the time up to now.

  ## Examples

      iex> state = WorkerState.new(:w1, [])
      iex> elapsed = WorkerState.elapsed_time(state)
      iex> is_integer(elapsed)
      true

  """
  @spec elapsed_time(t()) :: integer()
  def elapsed_time(%__MODULE__{started_at: started, ended_at: ended})
      when is_integer(started) and is_integer(ended) do
    ended - started
  end

  def elapsed_time(%__MODULE__{started_at: started}) when is_integer(started) do
    System.monotonic_time(:millisecond) - started
  end

  def elapsed_time(_), do: 0

  @doc """
  Updates the worker progress.

  ## Examples

      iex> state = WorkerState.new(:w1, [fn -> :ok end, fn -> :ok end])
      iex> state = WorkerState.update_progress(state, 1)
      iex> state.progress
      50.0

  """
  @spec update_progress(t(), non_neg_integer()) :: t()
  def update_progress(%__MODULE__{} = state, completed) do
    progress =
      if state.total_tasks > 0 do
        completed / state.total_tasks * 100
      else
        0
      end

    %{state | completed_tasks: completed, progress: progress}
  end

  @doc """
  Adds a result to the results list.

  ## Examples

      iex> state = WorkerState.new(:w1, [])
      iex> state = WorkerState.add_result(state, {:ok, :value})
      iex> state.results
      [{:ok, :value}]

  """
  @spec add_result(t(), term()) :: t()
  def add_result(%__MODULE__{} = state, result) do
    %{state | results: [result | state.results]}
  end
end
