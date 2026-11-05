# Arrea — Document Index

> v3.0.0 — Fault-tolerance primitives (Circuit Breaker, Bulkhead, RateLimiter, Pool) + orchestration layer (OTP) + telemetry

| Document | Description |
|----------|-------------|
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | Complete design reference: subsystems (Core OTP, Circuit Breaker, Bulkhead, RateLimiter, Pool, LongRunning, Telemetry, Validation, Registry, CLI), dependencies, supervision tree |
| [`AUDIT.md`](./AUDIT.md) | Code quality audit (legacy) |
| [`README.md`](../README.md) | English README — installation, usage, API overview |
| [`docs/README_ES.md`](./README_ES.md) | Spanish README |
| [`AGENTS.md`](../AGENTS.md) | AI agent instructions for working with Arrea |
| [`CHANGELOG.md`](../CHANGELOG.md) | Version history and release notes |
| [`LICENSE.md`](../LICENSE.md) | MIT License |
| [`guides/choosing_primitives.md`](../guides/choosing_primitives.md) | Decision tree: when to use CircuitBreaker vs Bulkhead vs RateLimiter vs Pool, composition rules, anti-patterns |

### Ecosystem context

Arrea is the **orchestration layer** of the Lorenzo-SF ecosystem. It depends
on Alaja (CLI framework). It is consumed by Trebejo (command execution),
Candil (circuit breaker, long-running), Botica (command checks), and Delfos
(parallel execution, circuit breakers). See the
[dependency graph](../docs/ARCHITECTURE.md#6-consumed-by).
