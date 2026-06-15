defmodule Arrea.Supervisor do
  @moduledoc """
  Supervisor raíz para la capa Engine de Arrea.

  ## Estrategia: `:rest_for_one`

  Los hijos se ordenan por dependencia: cada proceso depende de los anteriores,
  y solo los procesos dependientes se reinician cuando uno falla.

      1. Registry (Arrea.Registry)              — Workers
      2. Registry (Arrea.CircuitBreaker.Registry) — Circuit breakers
      3. Arrea.Monitor                           — Depende de los registries
      4. Arrea.Leader                            — Depende de Monitor y registries
      5. Arrea.WorkerSupervisor                  — Depende de Leader y registries

  Con `:rest_for_one`:
  - Si falla un **Registry** → reinicia todo (raro; los registries son muy estables)
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
      {Registry, keys: :unique, name: Arrea.CircuitBreaker.Registry},
      Arrea.Monitor,
      Arrea.Leader,
      {DynamicSupervisor, name: Arrea.WorkerSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
