## Benchmarks Arrea.Bulkhead against a no-op baseline.
##
## Compares:
##   * `bulkhead.run/2` (cap = 50, fast happy path)
##   * bare anonymous function
##
## Each iteration runs a trivial `:ok` returner. The point is to measure
## the overhead of the Bulkhead gate itself, not the work inside.
##
## Run with: `mix run bench/bulkhead.exs`

{:ok, pid} =
  Arrea.Bulkhead.start_link(:bench_bulkhead, 50, name: :bench_bulkhead)

Process.sleep(50)

try do
  Benchee.run(
    %{
      "bulkhead: run(:ok)" => fn ->
        Arrea.Bulkhead.run(:bench_bulkhead, fn -> :ok end)
      end,
      "noop: bare fn" => fn ->
        (fn -> :ok end).()
      end
    },
    time: 2,
    memory_time: 1,
    warmup: 1,
    formatters: [Benchee.Formatters.Console]
  )
after
  if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
end