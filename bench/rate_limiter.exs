## Benchmarks Arrea.RateLimiter.check/2 against a no-op baseline.
##
## Compares:
##   * `RateLimiter.check(:bench_rl, 1)` (token bucket, capacity large)
##   * `:ok` literal
##
## Capacity is set high (10_000) so we never hit denial and the benchmark
## measures the per-call overhead of the gate itself.
##
## Run with: `mix run bench/rate_limiter.exs`

{:ok, pid} =
  Arrea.RateLimiter.start_link(
    :bench_rl,
    name: :bench_rl,
    capacity: 10_000,
    refill_per_second: 10_000.0
  )

Process.sleep(50)

try do
  Benchee.run(
    %{
      "rate_limiter: check/2" => fn ->
        Arrea.RateLimiter.check(:bench_rl, 1)
      end,
      "noop: literal :ok" => fn ->
        :ok
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