defmodule Arrea.Pool.Worker do
  @moduledoc """
  Behaviour for typed workers managed by `Arrea.Pool`.

  A worker is any OTP process that can be started with
  `start_link/1` and receives the pool's `:worker_opts` as argument.
  GenServers already implement the shape via `use GenServer`, so a
  behaviour callback is usually enough:

      defmodule MyWorker do
        use GenServer
        @behaviour Arrea.Pool.Worker

        @impl true
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
      end

  Workers are started as `:temporary` children of a per-pool
  `DynamicSupervisor`: they are **not** restarted automatically. The
  pool owns the lifecycle and replaces a dead worker on the next
  checkout, so the pool size stays accurate under crashes.
  """

  @doc "Starts the worker process with the pool-provided options."
  @callback start_link(term()) :: GenServer.on_start()

  @doc "Builds a child spec starting `worker_mod` with `opts`."
  @spec child_spec(module(), term()) :: Supervisor.child_spec()
  def child_spec(worker_mod, opts) do
    %{
      id: {worker_mod, make_ref()},
      start: {worker_mod, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end
end
