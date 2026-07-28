# Arrea — Architectural Reference

> Asynchronous process orchestrator (OTP) and telemetry — v2.2.0

---

## 1. What is Arrea

Arrea is the **agent orchestration and fault tolerance** library of the
Lorenzo-SF ecosystem. It provides parallel execution (Leader + Worker pool),
circuit breakers for resilience, long-running OS process management (via
`Port`), telemetry/metrics, command validation, and a CLI for managing
execution.

Arrea replaces raw `Task.async_stream` and ad-hoc retry logic with a
structured OTP-based approach: supervised worker pool, circuit breakers,
telemetry events, and a consistent API.

---

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    Arrea (Facade)                             │
│  lib/arrea.ex — execute/2, run/2, run_sync/2, stats/0       │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                     ┌──────────┐                             │
│                     │  Leader  │  (GenServer)                │
│                     │          │                             │
│                     │coordinate│                             │
│                     │distribute│                             │
│                     │broadcast │                             │
│                     └────┬─────┘                             │
│                          │                                    │
│               ┌──────────┴──────────┐                        │
│               │                     │                         │
│        ┌──────▼──────┐      ┌──────▼──────┐                  │
│        │WorkerSuperv │      │   Monitor   │  (GenServer)     │
│        │(DynamicSup) │      │             │                   │
│        │             │      │  lifecycle  │                   │
│        │ spawn/stop  │      │  stats      │                   │
│        │ per worker  │      │  aggregate  │                   │
│        └──────┬──────┘      └─────────────┘                  │
│               │                                                │
│        ┌──────▼──────┐      ┌─────────────┐                  │
│        │   Worker    │      │CircuitBreak │                  │
│        │ (GenServer) │      │  (per name) │                  │
│        │             │      │             │                   │
│        │ task queue  │      │ closed/open │                  │
│        │ progress    │      │ half_open   │                  │
│        │ retry/stop  │      │ monotonic   │                  │
│        └─────────────┘      └─────────────┘                  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │                 LongRunning                           │    │
│  │  Supervisor-backed Port wrapper                      │    │
│  │  health checks, telemetry, auto-cleanup              │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │              Telemetry                                │    │
│  │  Events (worker/task/exec/validation/cb/longrunning) │    │
│  │  Metrics (ETS-stored, idempotent setup)              │    │
│  │  DebugHandler (attach/detach for dev)                │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │              Validation                               │    │
│  │  Rules: dangerous commands, allowed shells           │    │
│  │  Validator: compose rules, validate commands/specs   │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │              CLI (via Alaja.CLI.Definition)           │    │
│  │  run  config  action  nodes  verify                  │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. Subsystems

### 3.1 Core OTP

| Module | Type | Role |
|--------|------|------|
| `Arrea.Leader` | GenServer | Coordinates parallel execution. Manages workers, distributes tasks, periodic batch cleanup. Emits `{:leader_event, event}` to subscribers. |
| `Arrea.Worker` | GenServer | Task execution lifecycle: init → execute queue → handle messages → terminate. Tracks progress, supports retry/stop/continue policies. |
| `Arrea.WorkerState` | Struct | State: id, tasks, status, progress, results, policy, retry_count, elapsed_time |
| `Arrea.Monitor` | GenServer | Global registry of workers. Lifecycle tracking, aggregate stats (active/completed/failed/total). |
| `Arrea.Parallel` | Internal | Parallel engine used by facade. `execute/2` (single via Task.async), `run/2` (batch via Leader), `run_sync/2` (ordered results). |
| `Arrea.Supervisor` | Supervisor | `:rest_for_one` strategy. Children: Registry → CircuitBreaker.Registry → Monitor → Leader → WorkerSupervisor |

### 3.2 Fault Tolerance

| Module | Type | Role |
|--------|------|------|
| `Arrea.CircuitBreaker` | GenServer | Three states: `:closed`, `:open`, `:half_open`. Atomic state decision. Configurable threshold + recovery timeout. Monotonic time. |
| `Arrea.CircuitBreaker.State` | Struct | Fields: state, failures, successes, threshold, timeout, last_failure_at |

### 3.3 LongRunning
- Supervisor-backed wrapper around `Port.open/2` for long-running OS processes
- Supports: `start_link` with id, binary, args, health check
- Registers in `Arrea.Registry`, emits telemetry events
- Auto-cleanup via `DynamicSupervisor`

### 3.4 Telemetry
- **Events**: Worker (lifecycle), Task (start/stop), Execution, Communication,
  Validation, LongRunning, Action, CircuitBreaker
- **Metrics**: Execution time/success/failure, resource usage, circuit breaker
  state, UI renders — stored in ETS (`:arrea_metrics`)
- **DebugHandler**: Attach/detach to all `[:arrea, ...]` events, logs in readable format

### 3.5 Validation
- **Rules**: Dangerous command patterns (`rm -rf`, `sudo`, `dd if=`, `mkfs`,
  `shutdown`, etc.), allowed shells — configurable
- **Validator**: `validate_command/1`, `validate_worker_spec/1` — compose rules
- **JSON Schema**: Validates `arrea action` JSON input structure

### 3.6 Registry
- Wraps Elixir's `Registry` (named `Arrea.Registry`)
- `all/0` → `%{name => pid}`, `count/0`, `lookup/1`
- Used by `arrea nodes` CLI command

### 3.7 Command Execution
- `Arrea.Command.execute/2`: Synchronous shell execution with:
  - Shell resolution: Config → `$SHELL` → login shell → fallback `"sh"`
  - asdf/mise version manager integration
  - Real timeout enforcement (not `:timer.sleep`)
  - Structured result parsing

---

## 4. Public API

| Function | Description |
|----------|-------------|
| `execute/2` | Execute single command or function. Opts: `:timeout`, `:retry`, `:shell`, `:validate` |
| `run/2` | Run multiple commands/functions in parallel. Returns batch_id |
| `run_sync/2` | Run in parallel, wait for all, return results in input order. Supports `:workers`, `:timeout`, `:ordered` |
| `max_workers/0` | Returns configured max workers (default 100) |
| `stats/0` | Worker lifecycle statistics (active, completed, failed, total) |
| `subscribe/0` | Subscribe caller to Leader events |
| `unsubscribe/0` | Unsubscribe from Leader events |

---

## 5. Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| **Alaja** | path: ../alaja | CLI framework (DSL, components, printer) |
| Jason | ~> 1.4 | JSON decoding for action files |
| telemetry | ~> 1.3 | Core telemetry events |
| telemetry_metrics | ~> 1.1 | Metrics definitions |
| telemetry_poller | ~> 1.3 | Periodic measurements |

Arrea depends on **Alaja** (for its CLI) and standard telemetry libraries.
It has no dependency on Apero or Trebejo — command execution uses Port,
not shell wrappers.

---

## 6. Consumed by

| Project | What it uses |
|---------|--------------|
| **Trebejo** | `Arrea.Command.execute/2` for all shell operations, `Arrea.WorkerSupervisor` for file watching |
| **Candil** | `Arrea.CircuitBreaker` for fault tolerance, `Arrea.LongRunning` for llama-server process management, Registry, Monitor, WorkerSupervisor |
| **Botica** | `Arrea.Command` for command existence checks |
| **Delfos** | `Arrea.run_sync` for parallel summarization/retrieval, `Arrea.CircuitBreaker` for LLM resilience, `Arrea.LongRunning` for embed server auto-start, `Arrea.Subscribers` for MCP index broadcasts |

---

## 7. Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **GenServer-based Leader** | Central coordinator avoids race conditions in parallel dispatch. Subscribers get events for real-time UI updates. |
| **DynamicSupervisor per Worker** | Workers are ephemeral and independently supervised. Failure isolation: one worker crash doesn't affect others. |
| **`:rest_for_one` supervision** | If Leader fails, all workers restart from clean state. CircuitBreaker registry survives Leader restarts. |
| **Circuit breaker per name** | Independent failure domains. LLM calls have their own breaker vs database calls. |
| **Telemetry as first-class** | Every operation emits events. Consumers (Delfos, Alaja) render progress bars from telemetry without coupling. |
| **LongRunning via Port, not System.cmd** | Port gives real stdout/stderr streaming, timeout with `:kill`, and process lifecycle without shell overhead. |
| **Validation in arrea itself** | Dangerous command filtering lives in the execution engine, not in each consumer. Single point of security. |

---

## 8. Supervision Tree

```
Arrea.Supervisor (:rest_for_one)
  ├── Arrea.Registry (Elixir.Registry)
  ├── Arrea.CircuitBreaker.Registry (Elixir.Registry)
  ├── Arrea.Monitor (GenServer)
  ├── Arrea.Leader (GenServer)
  └── Arrea.WorkerSupervisor (DynamicSupervisor)
        └── Arrea.Worker (GenServer, one per task batch)
```

Auto-starts via `Arrea.Application` when included as a dependency.

---

## 9. Current State (v2.2.0 — Jul 2026)

- 22 source modules across 7 subsystems
- 22 test files
- Full CLI: `arrea run`, `arrea config`, `arrea action`, `arrea nodes`, `arrea verify`
- Circuit breaker, long-running, telemetry all operational
- Used by every downstream Lorenzo-SF project
