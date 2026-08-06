defmodule Arrea.RateLimiter do
  @moduledoc """
  Rate limiter — supervised wrapper around `Apero.RateLimit`.

  The token/leaky bucket logic lives in `Apero.RateLimit` (the base
  primitive, shared with the `apero` kit). This module wraps it as a
  supervised GenServer that serializes checks per limiter and emits
  typed telemetry events, without duplicating bucket logic.

  ## Usage

  Start it under a supervisor:

      {:ok, _pid} =
        Arrea.RateLimiter.start_link(:llm_api,
          capacity: 10,
          refill_per_second: 2.0
        )

  Consume tokens:

      case Arrea.RateLimiter.check(:llm_api, 3) do
        :ok -> call_llm()
        {:error, :rate_limited} -> backoff()
      end

  `Apero.RateLimit` must be a dependency of the consuming project
  (it is optional for Arrea itself).

  ## Telemetry

  - `[:arrea, :rate_limiter, :allowed]` — tokens were consumed
  - `[:arrea, :rate_limiter, :denied]` — request denied (bucket empty)

  Metadata is typed (`Arrea.Telemetry.Events.rate_limiter_metadata/0`):
  `%{name: atom(), capacity: pos_integer(), n: pos_integer()}`.

  ## Registry

  Each limiter is registered through `Registry` with a unique name under
  `Arrea.RateLimiter.Registry`.
  """

  use GenServer

  alias Apero.RateLimit

  alias Arrea.Telemetry.Events, as: TE

  @doc """
  Starts a rate limiter wrapping an `Apero.RateLimit` bucket.

  ## Options

    - `:name` — bucket name (required, unique)
    - `:capacity` — max tokens (token bucket) or max in-flight work
      (leaky bucket), default: 10
    - `:refill_per_second` — tokens added per second, default: 1.0
    - `:bucket` — `:token` (default) or `:leaky`

  Invalid options (`capacity < 1`, negative refill, unknown bucket) are
  rejected with `{:error, %Arrea.Error{code: :invalid_config}}`.
  """
  @spec start_link(atom(), keyword()) :: GenServer.on_start()
  def start_link(name, opts \\ []) when is_atom(name) do
    case validate_opts([name: name] ++ opts) do
      :ok -> GenServer.start_link(__MODULE__, [name: name] ++ opts, name: via_tuple(name))
      {:error, %Arrea.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Checks whether `n` tokens can be consumed, consuming them.

  Returns `:ok` when allowed or `{:error, :rate_limited}` otherwise.
  Emits `[:arrea, :rate_limiter, :allowed]` / `[:arrea, :rate_limiter, :denied]`.

  If `Apero.RateLimit` is not loaded, returns `{:error, :apero_unavailable}`.

  ## Example

      iex> Arrea.RateLimiter.check(:api, 1)
      :ok
  """
  @spec check(atom(), pos_integer()) :: :ok | {:error, :rate_limited | :apero_unavailable}
  def check(name, n \\ 1) when is_atom(name) and is_integer(n) and n > 0 do
    case safe_call(name, {:check, n}) do
      :not_found -> {:error, :limiter_not_found}
      result -> result
    end
  end

  @doc """
  Returns `true` if `n` tokens can be consumed, consuming them.

  ## Example

      iex> Arrea.RateLimiter.allow?(:api, 1)
      true
  """
  @spec allow?(atom(), pos_integer()) :: boolean()
  def allow?(name, n \\ 1) when is_atom(name) and is_integer(n) and n > 0 do
    case safe_call(name, {:allow?, n}) do
      :not_found -> false
      result -> result
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    with :ok <- validate_opts(opts),
         :ok <- ensure_apero() do
      name = Keyword.fetch!(opts, :name)

      config = [
        name: name,
        capacity: Keyword.get(opts, :capacity, 10),
        refill_per_second: Keyword.get(opts, :refill_per_second, 1.0),
        bucket: Keyword.get(opts, :bucket, :token)
      ]

      case RateLimit.new(config) do
        %RateLimit{} = limiter ->
          {:ok,
           %{
             name: name,
             capacity: limiter.capacity,
             refill_per_second: limiter.refill_per_second,
             bucket: limiter.bucket
           }}
      end
    else
      {:error, %Arrea.Error{} = error} -> {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_call({:check, n}, _from, state) do
    result = do_check(state, n)

    if result == :ok do
      TE.emit_rate_limiter(:allowed, metadata(state, n))
    else
      case result do
        {:error, :rate_limited} -> TE.emit_rate_limiter(:denied, metadata(state, n))
        {:error, _reason} -> :ok
      end
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:allow?, n}, _from, state) do
    case do_check(state, n) do
      :ok ->
        TE.emit_rate_limiter(:allowed, metadata(state, n))
        {:reply, true, state}

      {:error, :rate_limited} ->
        TE.emit_rate_limiter(:denied, metadata(state, n))
        {:reply, false, state}

      {:error, _reason} ->
        {:reply, false, state}
    end
  end

  # ── Helpers privados ─────────────────────────────────────────────────────

  # The bucket primitive lives in apero (optional dependency). Make sure
  # the apero application (its Registry and Supervisor) is running before
  # delegating.
  @spec ensure_apero() :: :ok | {:error, Arrea.Error.t()}
  defp ensure_apero do
    if Code.ensure_loaded?(RateLimit) do
      case Application.ensure_all_started(:apero) do
        {:ok, _apps} -> :ok
        {:error, reason} -> {:error, %Arrea.Error{code: :apero_unavailable, message: inspect(reason)}}
      end
    else
      {:error, %Arrea.Error{code: :apero_unavailable, message: "Apero.RateLimit is not available"}}
    end
  end

  @spec validate_opts(keyword()) :: :ok | {:error, Arrea.Error.t()}
  defp validate_opts(opts) do
    cond do
      not Keyword.has_key?(opts, :name) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "name option is required"}}

      invalid_capacity?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "capacity must be >= 1"}}

      invalid_refill?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "refill_per_second must be >= 0"}}

      invalid_bucket?(opts) ->
        {:error,
         %Arrea.Error{code: :invalid_config, message: "bucket must be :token or :leaky"}}

      true ->
        :ok
    end
  end

  @spec invalid_capacity?(keyword()) :: boolean()
  defp invalid_capacity?(opts) do
    case Keyword.get(opts, :capacity) do
      nil -> false
      value -> not (is_integer(value) and value >= 1)
    end
  end

  @spec invalid_refill?(keyword()) :: boolean()
  defp invalid_refill?(opts) do
    case Keyword.get(opts, :refill_per_second) do
      nil -> false
      value -> not (is_number(value) and value >= 0)
    end
  end

  @spec invalid_bucket?(keyword()) :: boolean()
  defp invalid_bucket?(opts) do
    case Keyword.get(opts, :bucket) do
      nil -> false
      value -> value not in [:token, :leaky]
    end
  end

  @spec do_check(map(), pos_integer()) :: :ok | {:error, :rate_limited | :apero_unavailable}
  defp do_check(state, n) do
    if Code.ensure_loaded?(RateLimit) do
      RateLimit.check(state.name, n)
    else
      {:error, :apero_unavailable}
    end
  end

  @spec safe_call(atom(), term()) :: term() | :not_found
  defp safe_call(name, request) do
    case Registry.lookup(Arrea.RateLimiter.Registry, name) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, request)
        catch
          :exit, {:timeout, _} -> :not_found
          :exit, :timeout -> :not_found
          :exit, _ -> :not_found
        end

      [] ->
        :not_found
    end
  end

  @spec via_tuple(atom()) :: {:via, Registry, {Arrea.RateLimiter.Registry, atom()}}
  defp via_tuple(name), do: {:via, Registry, {Arrea.RateLimiter.Registry, name}}

  @spec metadata(map(), pos_integer()) :: TE.rate_limiter_metadata()
  defp metadata(%{name: name, capacity: capacity}, n) do
    %{name: name, capacity: capacity, n: n}
  end
end
