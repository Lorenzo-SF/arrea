## Benchmarks Arrea.Pool checkout/checkin against spawning a worker per call.
##
## Compares:
##   * `Pool.checkout/:checkin` (warm pool, size = 4)
##   * Spawn a new lightweight worker per call
##
## Both paths return `:ok` so we measure the gate, not the work.
##
## Run with: `mix run bench/pool.exs`

defmodule Arrea.Bench.BenchWorker do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
  def init(_), do: {:ok, %{}}

  def handle_call(:ping, _from, s), do: {:reply, :ok, s}
end

{:ok, pool_pid} =
  Arrea.Pool.start_link(:bench_pool, Arrea.Bench.BenchWorker,
    size: 4,
    max_overflow: 0,
    name: :bench_pool
  )

Process.sleep(50)

try do
  Benchee.run(
    %{
      "pool: checkout/checkin (warm)" => fn ->
        {:ok, pid} = Arrea.Pool.checkout(:bench_pool)
        :ok = Arrea.Pool.checkin(:bench_pool, pid)
      end,
      "spawn: start_link per call" => fn ->
        {:ok, pid} = Arrea.Bench.BenchWorker.start_link([])
        GenServer.stop(pid)
      end
    },
    time: 2,
    memory_time: 1,
    warmup: 1,
    formatters: [Benchee.Formatters.Console]
  )
after
  if Process.alive?(pool_pid), do: GenServer.stop(pool_pid, :normal, 100)
end