defmodule Arrea.Supervisor do
  @moduledoc """
  Root supervisor for the Arrea engine layer.

  ## Strategy: `:rest_for_one`

  Children are ordered by dependency: each process depends on the
  previous ones, and only the dependent processes are restarted when one fails.

      1. Registry (Arrea.Registry)                — Workers
      2. Registry (Arrea.CircuitBreaker.Registry) — Circuit breakers
      3. Registry (Arrea.Bulkhead.Registry)       — Bulkheads
      4. Registry (Arrea.RateLimiter.Registry)    — Rate limiters
      5. Registry (Arrea.Pool.Registry)           — Pools
      6. Registry (Arrea.Resource.Registry)        — Resources
      7. Arrea.Monitor                            — Depende de los registries
      8. Arrea.Leader                             — Depende de Monitor y registries
      9. Arrea.WorkerSupervisor                   — Depende de Leader y registries

  Con `:rest_for_one`:
  - Si falla un **Registry** → reinicia todo (raro; los registries son muy estables)
  - Si falla `Arrea.Queue.Registry` → tambien reinicia todo, y con el las colas
    pendientes. Es el unico caso en el que se pierden entradas, y por eso esta
    ANOTADO aqui en vez de ser una sorpresa
  - Si falla **Monitor** → reinicia Monitor + Leader + WorkerSupervisor (batches activos se pierden)
  - Si falla **Leader** → reinicia solo Leader + WorkerSupervisor (Monitor y registries intactos)
  - Si falla **WorkerSupervisor** → reinicia solo WorkerSupervisor (impacto mínimo)

  Esto es significativamente mejor que `:one_for_all`, donde cualquier fallo
  (incluyendo el del WorkerSupervisor) reiniciaba todos los procesos.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Arrea.Registry},
      # Las colas se registran en el suyo, y NINGUN registro mas las referencia:
      # se crean y se destruyen solas. Por eso va el primero: un registro que
      # muere por debajo arrastraria a las colas con el.
      {Registry, keys: :unique, name: Arrea.Queue.Registry},
      {Registry, keys: :unique, name: Arrea.CircuitBreaker.Registry},
      {Registry, keys: :unique, name: Arrea.Bulkhead.Registry},
      {Registry, keys: :unique, name: Arrea.RateLimiter.Registry},
      {Registry, keys: :unique, name: Arrea.Pool.Registry},
      # Los resources se registran en el suyo. Va antes del Monitor porque el
      # Monitor los cuenta entre los procesos vivos, igual que a los demas.
      {Registry, keys: :unique, name: Arrea.Resource.Registry},
      Arrea.Monitor,
      Arrea.Leader,
      {DynamicSupervisor, name: Arrea.WorkerSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
