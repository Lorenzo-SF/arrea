# arrea — audit completitud (iter-039)

> **Fecha**: 2026-09-12
> **Tamaño**: 7,542 LOC, ~30 módulos
> **Tests**: 30 archivos
> **Meta**: arrea 100% terminado

---

## Estado actual

| Área | LOC | Estado |
|------|-----|--------|
| `arrea.ex` (facade) | 329 | ✅ |
| `command/command.ex` | 467 | ✅ (sin streaming) |
| `pool.ex` | 461 | ✅ |
| `worker.ex` | 456 | ✅ |
| `circuit_breaker/` | 389 | ✅ (iter-028 fix) |
| `parallel.ex` | 366 | ✅ (iter-028 Task.yield/shutdown) |
| `leader.ex` | 300 | ✅ |
| `telemetry/metrics.ex` | 284 | ✅ |
| `cli/commands/config.ex` | 329 | ✅ |

30 tests files.

## Gap identificado (iter-039)

### P1 — `Arrea.Command.execute_stream/2` no existe
**Archivo**: `lib/arrea/command/command.ex`
**Tipo**: feature gap
**Impacto**: arrea no expone un API de streaming de stdout/stderr para
comandos largos (build, test runs).  Los consumidores tienen que usar
trebejo o System.cmd directamente.

### Plan iter-039

1. P1: `Arrea.Command.execute_stream/2` — streaming con callback.
2. Tests: 4 nuevos (success, error, timeout, exit_code propagation).
3. Doc.
