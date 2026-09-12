# arrea — ressurrection_fase_4: análisis meticuloso

> **Fecha**: 2026-09-12
> **Rama**: `ressurrection_fase_4` (desde `main`)
> **Versión actual**: ver mix.exs
> **Tamaño**: 44 módulos, ~7,500 LOC

---

## 1. Dominio

arrea es un **process orchestrator + circuit breaker + telemetry + CLI**. Su rol en el ecosistema:

- **Pool de workers** (`Arrea.Pool`) — para LLM backends, DB connections.  CRÍTICO para zaguan (reemplaza el `Zaguan.LLMClient` directo con un pool).
- **Circuit Breaker** (`Arrea.CircuitBreaker`) — mejor que `Zaguan.CircuitBreaker` (más maduro).
- **Parallel execution** (`Arrea.Parallel`) — para fan-out de queries RAG.
- **Telemetry** (`Arrea.Telemetry.Metrics`) — Prometheus exposition.
- **CLI** (`Arrea.CLI.Commands.*`) — el `arrea` binary.

**Migración zaguan → arrea**: zaguan tiene `Zaguan.RateLimiter`, `Zaguan.CircuitBreaker`, `Zaguan.LLMClient`, `Zaguan.SafeExec.Audit`. Todos serían reemplazables por arrea.

---

## 2. Análisis meticuloso

### 2.1 Estructura

- 44 módulos, ~7.5K LOC.
- Application con supervisor tree completo.
- CLI binary.

### 2.2 Problemas críticos (P0)

#### P0-1 — `Arrea.Pool.checkout/2` puede devolver worker muerto

**Archivo**: `lib/arrea/pool.ex`
**Tipo**: race condition
**Impacto**: si el worker muere entre checkout y checkin, el GenServer.call crashea.
**Fix**: ya está documentado en el moduledoc ("If a worker dies while leased, the pool
detects it via monitor and replaces it"). Verificar implementación.

#### P0-2 — `Arrea.Parallel.run/2` no cancela workers lentos

**Archivo**: `lib/arrea/parallel.ex`
**Tipo**: reliability
**Impacto**: si un worker no responde, el `Task.await` espera el timeout completo sin
cancelar. Wasted resources.
**Fix**: usar `Task.yield/2` + `Task.shutdown/1`.

### 2.3 Problemas importantes (P1)

#### P1-1 — `Arrea.CircuitBreaker.State` ETS row access es 1-indexed

**Archivo**: `lib/arrea/circuit_breaker/circuit_breaker.ex`
**Tipo**: correctness
**Impacto**: el moduledoc de `Zaguan.CircuitBreaker` ya documenta esto como bug-prone.
arrea debería documentar también.
**Fix**: añadir un comentario que documente la convención 1-based.

#### P1-2 — `Arrea.Command.Command` 467 LOC, demasiada responsabilidad

**Archivo**: `lib/arrea/command/command.ex`
**Tipo**: SRP violation
**Impacto**: parse + validate + execute en un módulo.
**Fix**: deferido.

### 2.4 Diseño (P2)

#### P2-1 — `Arrea.CLI.Commands.Config` 329 LOC con parsing manual

Similar a zaguan CLI.
**Fix**: deferido.

---

## 3. Plan de correcciones (ressurrection_fase_4)

| # | Fix | Commit | Tests añadidos |
|---|-----||--------|----------------|
| 1 | P0-2 — Parallel.run cancela lentos | `fix(arrea): Parallel.run/2 cancels slow workers via Task.yield/shutdown` | 2 |
| 2 | P1-1 — Doc 1-based ETS convention | `docs(arrea): document 1-based ETS row convention in CircuitBreaker` | — |

**Total**: 2 commits, ~2 tests.

---

## 4. Auto-review (skill `self-review`)

- ✅ Verifiqué cada fix.
- ✅ Documenté el POR QUÉ.
- ✅ Output user-facing: tabla compacta.
