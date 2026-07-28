# Arrea — Document Index

> v2.2.0 — Asynchronous process orchestrator (OTP) and telemetry

| Document | Description |
|----------|-------------|
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | Complete design reference: subsystems (Core OTP, Circuit Breaker, LongRunning, Telemetry, Validation, Registry, CLI), dependencies, supervision tree |
| [`AUDIT.md`](./AUDIT.md) | Code quality audit: command injection in version-manager, circuit breaker races, telemetry ghost events, parallel 0% coverage, top 5 fixes |
| [`README.md`](../README.md) | English README — installation, usage, API overview |
| [`docs/README_ES.md`](./README_ES.md) | Spanish README |
| [`AGENTS.md`](../AGENTS.md) | AI agent instructions for working with Arrea |
| [`CHANGELOG.md`](../CHANGELOG.md) | Version history and release notes |
| [`LICENSE.md`](../LICENSE.md) | MIT License |
| [`plan_arrea.md`](./plan_arrea.md) | Historical implementation plan (registry helper, nodes CLI) |

### Ecosystem context

Arrea is the **orchestration layer** of the Lorenzo-SF ecosystem. It depends
on Alaja (CLI framework). It is consumed by Trebejo (command execution),
Candil (circuit breaker, long-running), Botica (command checks), and Delfos
(parallel execution, circuit breakers). See the
[dependency graph](../docs/ARCHITECTURE.md#6-consumed-by).
