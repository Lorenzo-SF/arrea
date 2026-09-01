defmodule Arrea.Telemetry.Events do
  @moduledoc """
  Centralized definition of all telemetry events in `Arrea`.

  ## Event Categories

  ### Workers (Engine)
  - `[:arrea, :worker, :started]` — Worker started
  - `[:arrea, :worker, :completed]` — Worker completed
  - `[:arrea, :worker, :error]` — Worker error
  - `[:arrea, :worker, :message]` — Worker received message

  ### Tasks
  - `[:arrea, :task, :started]` — Task started
  - `[:arrea, :task, :completed]` — Task completed
  - `[:arrea, :task, :error]` — Task error

  ### Execution
  - `[:arrea, :execution, :started]` — Execution started
  - `[:arrea, :execution, :completed]` — Execution completed
  - `[:arrea, :execution, :failed]` — Execution failed

  ### Communication
  - `[:arrea, :communication, :message_sent]` — Message sent
  - `[:arrea, :communication, :message_received]` — Message received
  - `[:arrea, :communication, :error]` — Communication error
  - `[:arrea, :communication, :retry]` — Communication retry

  ### Validation
  - `[:arrea, :validation, :passed]` — Validation passed
  - `[:arrea, :validation, :failed]` — Validation failed

  ### UI
  - `[:arrea, :ui, :render]` — Component render
  - `[:arrea, :ui, :keypress]` — Key press
  - `[:arrea, :ui, :focus_change]` — Focus change

  ### System
  - `[:arrea, :system, :started]` — System started
  - `[:arrea, :system, :stopped]` — System stopped

  ### Circuit Breaker
  - `[:arrea, :circuit_breaker, :closed]` — Circuit closed (normal op)
  - `[:arrea, :circuit_breaker, :open]` — Circuit opened
  - `[:arrea, :circuit_breaker, :trip]` — Circuit tripped
  - `[:arrea, :circuit_breaker, :half_open]` — Circuit entered probe state

  ### Bulkhead
  - `[:arrea, :bulkhead, :acquired]` — A slot was acquired
  - `[:arrea, :bulkhead, :released]` — A slot was released
  - `[:arrea, :bulkhead, :rejected]` — A call was rejected (full)

  ### RateLimiter
  - `[:arrea, :rate_limiter, :allowed]` — Tokens were consumed
  - `[:arrea, :rate_limiter, :denied]` — Request denied (bucket empty)
  """

  @typedoc """
  Metadata for `[:arrea, :circuit_breaker, *]` events.

  All fields are guaranteed present and correctly typed, so handlers
  can pattern match without defensive `Map.get/3` calls.
  """
  @type circuit_breaker_metadata :: %{
          name: atom(),
          failures: non_neg_integer(),
          threshold: pos_integer(),
          successes: non_neg_integer(),
          state: :closed | :open | :half_open
        }

  @typedoc "Metadata for `[:arrea, :bulkhead, *]` events."
  @type bulkhead_metadata :: %{
          name: atom(),
          max_concurrent: pos_integer(),
          active: non_neg_integer()
        }

  @typedoc "Metadata for `[:arrea, :rate_limiter, *]` events."
  @type rate_limiter_metadata :: %{
          name: atom(),
          capacity: pos_integer(),
          n: pos_integer()
        }

  # Worker events
  def worker_started, do: [:arrea, :worker, :started]
  def worker_completed, do: [:arrea, :worker, :completed]
  def worker_error, do: [:arrea, :worker, :error]
  def worker_message, do: [:arrea, :worker, :message]

  # Task events
  def task_started, do: [:arrea, :task, :started]
  def task_completed, do: [:arrea, :task, :completed]
  def task_error, do: [:arrea, :task, :error]

  # Communication events
  def communication_message_sent, do: [:arrea, :communication, :message_sent]
  def communication_message_received, do: [:arrea, :communication, :message_received]
  def communication_error, do: [:arrea, :communication, :error]
  def communication_retry, do: [:arrea, :communication, :retry]

  # Validation events
  def validation_passed, do: [:arrea, :validation, :passed]
  def validation_failed, do: [:arrea, :validation, :failed]

  # Execution events
  def execution_started, do: [:arrea, :execution, :started]
  def execution_completed, do: [:arrea, :execution, :completed]
  def execution_failed, do: [:arrea, :execution, :failed]

  # UI events
  def ui_render, do: [:arrea, :ui, :render]
  def ui_keypress, do: [:arrea, :ui, :keypress]
  def ui_focus_change, do: [:arrea, :ui, :focus_change]

  # System events
  def system_started, do: [:arrea, :system, :started]
  def system_stopped, do: [:arrea, :system, :stopped]

  @doc """
  Emits a worker event.
  """
  @spec emit_worker(atom(), map(), map()) :: :ok
  def emit_worker(type, measurements \\ %{}, metadata \\ %{}) do
    event = [:arrea, :worker, type]
    :telemetry.execute(event, measurements, metadata)
    :ok
  end

  @doc """
  Emits a communication event.
  """
  @spec emit_communication(atom(), map(), map()) :: :ok
  def emit_communication(type, measurements \\ %{}, metadata \\ %{}) do
    event = [:arrea, :communication, type]
    :telemetry.execute(event, measurements, metadata)
    :ok
  end

  @doc """
  Emits a validation event.
  """
  @spec emit_validation(atom(), map(), map()) :: :ok
  def emit_validation(type, measurements \\ %{}, metadata \\ %{}) do
    event = [:arrea, :validation, type]
    :telemetry.execute(event, measurements, metadata)
    :ok
  end

  @doc """
  Emits a UI event.
  """
  @spec emit_ui(atom(), map(), map()) :: :ok
  def emit_ui(type, measurements \\ %{}, metadata \\ %{}) do
    event = [:arrea, :ui, type]
    :telemetry.execute(event, measurements, metadata)
    :ok
  end

  @doc """
  Emits an engine event.
  Events follow the pattern `[:arrea, :engine, sub_category, type]`.
  """
  @spec emit_engine(atom(), atom(), map(), map()) :: :ok
  def emit_engine(sub_category, type, measurements \\ %{}, metadata \\ %{}) do
    event = [:arrea, :engine, sub_category, type]
    :telemetry.execute(event, measurements, metadata)
    :ok
  end

  @doc """
  Emits a long_running engine event.
  Events follow the pattern `[:arrea, :long_running, type]`.
  """
  @spec emit_long_running(atom(), map(), map()) :: :ok
  def emit_long_running(type, measurements \\ %{}, metadata \\ %{}) do
    event = [:arrea, :long_running, type]
    :telemetry.execute(event, measurements, metadata)
    :ok
  end

  @doc """
  Emits a circuit breaker event with typed metadata.

  ## Example

      iex> Arrea.Telemetry.Events.emit_circuit_breaker(:open, %{
      ...>   name: :my_breaker,
      ...>   failures: 5,
      ...>   threshold: 5,
      ...>   successes: 0,
      ...>   state: :open
      ...> })
      :ok
  """
  @spec emit_circuit_breaker(atom(), circuit_breaker_metadata()) :: :ok
  def emit_circuit_breaker(event, metadata) do
    :telemetry.execute([:arrea, :circuit_breaker, event], %{}, metadata)
    :ok
  end

  @doc """
  Emits a bulkhead event with typed metadata.

  ## Example

      iex> Arrea.Telemetry.Events.emit_bulkhead(:rejected, %{
      ...>   name: :db_pool,
      ...>   max_concurrent: 4,
      ...>   active: 4
      ...> })
      :ok
  """
  @spec emit_bulkhead(atom(), bulkhead_metadata()) :: :ok
  def emit_bulkhead(event, metadata) do
    :telemetry.execute([:arrea, :bulkhead, event], %{}, metadata)
    :ok
  end

  @doc """
  Emits a rate limiter event with typed metadata.

  ## Example

      iex> Arrea.Telemetry.Events.emit_rate_limiter(:denied, %{
      ...>   name: :llm_api,
      ...>   capacity: 10,
      ...>   n: 1
      ...> })
      :ok
  """
  @spec emit_rate_limiter(atom(), rate_limiter_metadata()) :: :ok
  def emit_rate_limiter(event, metadata) do
    :telemetry.execute([:arrea, :rate_limiter, event], %{}, metadata)
    :ok
  end
end
