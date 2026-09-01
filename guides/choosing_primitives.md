# Choosing a Fault-Tolerance Primitive in Arrea 3.0

> Arrea 3.0 ships four cooperating primitives. This guide explains what each
> one does, what problem it solves, and when to reach for it.

Arrea is built on a small idea: **the same fault can break your system in
several different ways, and each one needs a different lever.** Picking the
wrong lever wastes CPU, hides bugs, or makes your system less reliable than
no protection at all.

## The four primitives

| Primitive        | Solves                                     | State       | Cost per call |
|------------------|--------------------------------------------|-------------|---------------|
| `CircuitBreaker` | Cascading failures from a flaky dependency | per-name    | 1 GenServer call (or 0 if registered) |
| `Bulkhead`       | Resource exhaustion under concurrent load  | per-name    | 1 GenServer call |
| `RateLimiter`    | Sustained overload / fairness between tenants | per-name | 1 GenServer call |
| `Pool`           | Cold-start latency for reusable workers    | per-name    | 1 GenServer call (only on miss) |

All four live under the same `Arrea.Supervisor`. They share the
`Arrea.Telemetry` namespace so a single handler can observe all of them.

---

## Decision tree

```
Your service calls a flaky dependency and you keep seeing cascades.
  └─ Use CircuitBreaker.

You have a fixed-size downstream (DB pool, third-party quota) and your
workers can overwhelm it when load spikes.
  └─ Use Bulkhead.

You have an API with a hard quota (X requests/sec) and you must stay below
it even when your own callers burst.
  └─ Use RateLimiter.

You spin up expensive workers (Python subprocess, GPU process, SSH
connection) and you want to avoid paying cold-start cost on every request.
  └─ Use Pool.
```

If two answers feel right, **compose them**. Arrea is designed for stacking:

```elixir
defmodule SafeCaller do
  def call(url) do
    Arrea.Pool.with_worker(:http_pool, fn worker ->
      Arrea.CircuitBreaker.call(:remote_api, fn ->
        Arrea.Bulkhead.run(:http_bulkhead, fn ->
          Arrea.RateLimiter.check(:public_api, 1) and
            HTTPClient.get(worker, url)
        end)
      end)
    end)
  end
end
```

This pattern is **fail-fast outside, fair-share inside, isolated between
tenants, and cheap on the happy path** (Pool only pays on a miss).

---

## CircuitBreaker — the upstream health guard

**Symptom**: A downstream service has started failing. Every retry from
your service adds latency; every retry from every other service adds more.
The queue behind the dependency fills up. Threads are exhausted. Your
service is now broken, not the dependency.

**What CircuitBreaker does**:
1. Tracks failures per `:name`.
2. After N failures in a row (`threshold`), **opens** the circuit.
3. While open, every call fails fast with `{:blocked, :circuit_open}`.
4. After a timeout, the next call becomes a **probe** (half-open).
5. If the probe succeeds, the circuit closes. If it fails, it opens again
   for a fresh window.

**Key property — single-flight probe (AR-4)**: while half-open, only ONE
concurrent caller runs the probe. Every other caller in the same probe
window is blocked instantly, instead of all N callers racing to hit the
flaky dependency simultaneously.

**Don't use it for**:
- Rate limiting (use `RateLimiter`).
- Bounding concurrency (use `Bulkhead`).

```elixir
case Arrea.CircuitBreaker.call(:stripe, fn -> Stripe.charge(token, 100) end) do
  {:ok, result}             -> result
  {:error, {:blocked, _}}   -> {:error, :stripe_unavailable}
  {:error, {:raised, exc}}  -> {:error, exc}
end
```

---

## Bulkhead — the concurrency governor

**Symptom**: A downstream has a fixed capacity (e.g. a Postgres connection
pool, a gRPC server with N streams, an LLM provider with a request limit).
Your service has many concurrent callers. When load spikes, every caller
queues up behind the limit, holding threads, sockets, and memory. Total
collapse.

**What Bulkhead does**:
1. Caps the number of concurrent operations under a given name.
2. Acquired slots are counted atomically in a GenServer.
3. If the cap is reached, the next `run/2` returns `{:error, :bulkhead_full}`
   **immediately** — no queue, no waiting.
4. Emits `[:arrea, :bulkhead, :acquired | :released | :rejected]` so you
   can observe saturation in production.

**Why "bulkhead"?** Like a ship's bulkhead: one compartment flooding
doesn't sink the whole vessel. `Bulkhead.run(:db, ...)` flooding does not
drown your `:cache` or `:llm` calls.

**Don't use it for**:
- Throttling rate over time (use `RateLimiter`).
- A circuit breaker for upstream health (use `CircuitBreaker`).

```elixir
case Arrea.Bulkhead.run(:db, fn -> Repo.insert!(record) end) do
  {:ok, record}                -> record
  {:error, :bulkhead_full}     -> {:error, :backpressure}
  {:error, {:execution, exc}}  -> {:error, exc}
end
```

---

## RateLimiter — the fairness enforcer

**Symptom**: You have a quota (100 req/s to a public API, 1000 GPU-seconds
per minute per tenant, etc.). When your own callers burst, you blow past
the quota and start getting HTTP 429s or billing penalties.

**What RateLimiter does**:
1. Wraps an `Apero.RateLimit` bucket (token or leaky).
2. Token bucket: refills at `refill_per_second`, holds `capacity` tokens.
3. Leaky bucket: drains at `refill_per_second`, holds `capacity` work units.
4. `check/2` is atomic per limiter (single GenServer, serialized).
5. Emits `[:arrea, :rate_limiter, :allowed | :denied]`.

**Don't use it for**:
- Bounding concurrency (use `Bulkhead`).
- Replacing a circuit breaker (use `CircuitBreaker`).

```elixir
case Arrea.RateLimiter.check(:openai, 1) do
  :ok                  -> call_openai(prompt)
  {:error, :rate_limited} -> fallback()
end
```

---

## Pool — the warm-start accelerator

**Symptom**: Your workers are expensive to start (Python subprocess, GPU
context, SSH tunnel, compiled WASM module). Spinning one up per request
adds 200ms–2s of latency and eats resources.

**What Pool does**:
1. Keeps up to `size` workers warm under a DynamicSupervisor.
2. `checkout/1` returns an idle worker or starts a new one (up to
   `size + max_overflow`).
3. Past the overflow, callers **wait** (FIFO queue, monitored) instead
   of failing.
4. `checkin/2` returns the worker to the pool, unless the queue has a
   waiter — in which case the worker goes straight to the waiter with
   no idle window.

**Don't use it for**:
- Limiting concurrent work (use `Bulkhead`).
- Replacing a circuit breaker (use `CircuitBreaker`).

```elixir
{:ok, worker} = Arrea.Pool.checkout(:ssh_pool)
result = SSHClient.exec(worker, cmd)
Arrea.Pool.checkin(:ssh_pool, worker)
```

Or, more idiomatically:

```elixir
Arrea.Pool.with_worker(:ssh_pool, fn worker -> SSHClient.exec(worker, cmd) end)
```

---

## Composition rules

1. **Order matters, but only slightly.** The cheapest gates go outermost.
   Pool miss → CircuitBreaker → Bulkhead → RateLimiter → call. Most of
   the time Pool hits and you pay one GenServer call. Other gates are
   paid only on the unhappy path.

2. **Never put `CircuitBreaker` inside a `Pool.with_worker` checkin path.**
   A blocked probe should not leak a worker. Use the breaker at the
   outermost layer and the pool immediately inside.

3. **Telemetry handlers are cheap; ship one handler per primitive in
   production.** The event namespacing lets you route each primitive's
   events to a different dashboard without filtering at the handler level.

4. **Each primitive has its own `:name`.** Names are atoms. Don't share
   a name across primitive types (`:db` for both a Pool and a Bulkhead is
   asking for confusion in telemetry and operator dashboards).

5. **Validation is strict (AR-5).** `start_link/1` for every primitive
   returns `{:error, %Arrea.Error{code: :invalid_config}}` instead of
   starting a broken process. A broken Bulkhead silently letting
   everything through is worse than no Bulkhead at all.

---

## When NOT to use Arrea

Arrea is a fault-tolerance library, not an observability one. It does not
emit traces, does not aggregate metrics to a remote backend, and does not
do retries with backoff (that's a future primitive — AR-N in FASE-3+).
If you need any of those, wrap Arrea's primitives in your own caller
function and add retries/traces there.

Arrea is also not a generic concurrency limiter. If your system needs
real backpressure (slow down producers, not fail them), you want
`GenStage` or `Broadway`. Arrea's Bulkhead is **fail-fast**, not
**back-pressure**.