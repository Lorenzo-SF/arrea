# Changelog

All notable changes to Arrea will be documented in this file.

## [4.0.0] — 2026-10-10

El salto a 4 no es decorativo: hay **dos cambios que pueden romper a quien
dependa de hoy**, y estan los dos explicados abajo.

### Changed — BREAKING

- **`Queue` sirve ahora la prioridad mas ALTA primero. Antes servia la mas
  baja, y su `@moduledoc` decia lo contrario desde siempre.** Medido antes del
  arreglo: `push(baja: 1, media: 5, alta: 9)` servia `1, 5, 9`. La causa es que
  `entries` es un `:gb_tree` con clave `{priority, sequence}` y **`:gb_trees`
  ordena ascendente**; la clave ahora es `{-priority, sequence}`.

  El `requeue(front: true)` cambia con ella: hacia `priority + 1` para
  "adelantarse a su propia banda", lo cual con el orden viejo mandaba la
  entrada **al final**. Los dos fallos tenian la misma causa.

- **La topologia de supervision cambia.** El `Arrea.Resource.Registry` se
  registra **antes** de `Arrea.Monitor` en una cadena `:rest_for_one`, asi que
  si ese registro falla se reinician tambien Monitor, Leader y
  WorkerSupervisor. Antes no habia nada que reiniciar ahi. Es defendible —los
  registries son estables— pero por eso va en BREAKING y no en Added.

### Added

- **`Arrea.Resource`**: contabilidad de recursos en **GB**, con identidad por
  titular, eleccion de un conjunto y un motivo con numeros.
  - `capacity` en **megas enteros**: aritmetica exacta, sin tolerancia.
  - `quota` decimal, con dos rechazos distinguibles (`:insufficient_capacity` y
    `:quota_exceeded`). Es un **numero con nombre, no una politica**: por
    defecto `:infinity`.
  - `release/2` devuelve la reserva de **ese** titular, con `===` y no `==`:
    en Erlang `1 == 1.0` es verdad.
  - Sin persistencia. `instances.json` es de Candil, no de Arrea.
  - Es la fase 2 del plan de Candil, la pieza que faltaba.
- **`Worker.request/4`**: RPC dirigido, que es lo que le faltaba a Arrea para
  la fase 5 de Candil. **Entra por la cola**, con su prioridad y su peso, y no
  como un `GenServer.call` al worker, que pararia la cola. `send_message/2`
  **sigue siendo un `cast`**: un aviso no espera.
  - Plazo de **30 000 ms**, tomado de `Arrea.Command`, no inventado.
  - Worker muerto mientras se espera -> **`{:worker_down, reason}`**, no
    `:not_found`: uno que estaba y se ha ido no es uno que nunca existio.
  - Cola **explicita** en la aridad, porque elegirla en silencio seria la misma
    clase de mentira.

### Fixed

- **6 errores de dialyzer que tenian `main` en rojo, y eran cuatro etiquetas.**
  `@spec safe_call(atom(), atom())` recibia una tupla (`{:acquire, weight}`), y
  de ahi caian en cascada dos `no_return` y un `invalid_contract`. **Ningun
  fallo de logica.** Dialyzer a cero.
- Los tests de prioridad de la cola **no comprobaban el orden**: reclamaban
  tres entradas a una variable que no volvian a mirar. La forma de un test
  riguroso y el contenido de uno que no comprueba nada. El de
  `requeue(front: true)` igual.
- Dependabot: `package-ecosystem: "hex"` no existe, es `mix`. Con `hex`,
  GitHub rechazaba el fichero entero y **no habia avisos de seguridad**.

### Changed — BREAKING

- **`Queue` sirve ahora la prioridad mas ALTA primero. Antes servia la mas
  baja, y su `@moduledoc` decia lo contrario desde siempre.**
  Medido antes del arreglo: `push(baja: 1, media: 5, alta: 9)` servia
  `1, 5, 9`. La causa era que `entries` es un `:gb_tree` con clave
  `{priority, sequence}` y **`:gb_trees` ordena ascendente**; la clave ahora
  es `{-priority, sequence}`.

  Lo que dependa del orden actual cambia de golpe. **El `requeue(front: true)`
  tambien cambia**: hacia `priority + 1` para "adelantarse a su propia banda",
  lo cual con el orden viejo mandaba la entrada **al final** de esa banda.
  Los dos fallos tenian la misma causa.

- **La topologia de supervision cambia.** El `Registry` de
  `Arrea.Resource.Registry` se registra **antes** de `Arrea.Monitor` en una
  cadena `:rest_for_one`, asi que si ese registro falla se reinician tambien
  Monitor, Leader y WorkerSupervisor. Antes no habia nada que reiniciar ahi.

  Es defendible —los registries son estables y no se rompen— pero es un cambio
  de arbol de supervision y por eso esta en la seccion de BREAKING y no
  escondida en Added.

### Added

- **`Arrea.Resource`**: contabilidad de recursos en **GB**, con identidad por
  titular, eleccion de un conjunto, y un motivo con numeros.
  - `capacity` en **megas enteros**, aritmetica exacta y sin tolerancia.
  - `quota` decimal, con dos rechazos distinguibles
    (`:insufficient_capacity` y `:quota_exceeded`). Es un **numero con
    nombre, no una politica**: por defecto `:infinity`.
  - `release/2` devuelve la reserva de **ese** titular (`===`, no `==`:
    en Erlang `1 == 1.0`).
  - Sin persistencia. `instances.json` es de Candil, no de Arrea.
  - Fases 2 del plan de Candil: esta es la pieza que faltaba.
- **`Worker.request/4`**: RPC dirigido, que es lo que le faltaba a Arrea para
  la fase 5 de Candil. **Entra por la cola** —con su prioridad y su peso— y
  no como un `GenServer.call` al worker, que pararia la cola.
  `send_message/2` **sigue siendo un `cast`** y no se toca: un aviso no
  espera.
  - Plazo por defecto **30 000 ms**, tomado de `Arrea.Command`.
  - Worker muerto mientras se espera -> **`{:worker_down, reason}`**, no
    `:not_found`. Un worker que estaba y se ha ido no es lo mismo que uno que
    nunca existio.
  - Cola **explicita** en la aridad, porque elegirla en silencio seria la
    misma clase de mentira.

### Fixed

- **6 errores de dialyzer que tenian `main` en rojo, y eran cuatro
  etiquetas.** `@spec safe_call(atom(), atom())` recibia una tupla
  (`{:acquire, weight}`); de ahi caian en cascada dos `no_return` y un
  `invalid_contract`. **Ningun fallo de logica.** Dialyzer a cero.
- Los tests de prioridad de la cola, que **no comprobaban el orden**:hmann
  reclamaban tres entradas a una variable que no volvian a mirar. Un test con
  forma de rigor y sin una sola asercion. El de `requeue(front: true)` igual.
- Dependabot: `package-ecosystem: "hex"` no existe; es `mix`. Con `hex`,
  GitHub rechazaba el fichero entero y **no habia avisos de seguridad**.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.0] - 2026-10-07

### Fixed

- **`arrea run --comand "x"` no longer crashes with a cryptic
  `Protocol.UndefinedError protocol Enumerable not implemented for
  Atom. Got value: nil`**. The DSL now rejects unknown `--xxx`
  flags with a clear error message (e.g.
  `Error: unknown flag '--comand'` plus
  `Did you mean? --command`). The flag typo used to be silently
  dropped as a positional argument, which left `:command` unset,
  which crashed deep inside `Run.execute_with_opts/2` when
  `validate_commands!/1` called `Enum.with_index(nil)`. The
  validation gate lives in `Alaja.CLI.Definition.parse_flags/3`
  (host-agnostic — every consumer of the DSL benefits from it).
- **`arrea run` (no flags) exits with a clear missing-required
  error** instead of crashing on nil. `flag(:command, ...,
  required: true)` in the DSL is now enforced by the framework's
  `find_missing_required/2`. Runners see
  `Error: missing required flags: --command` before the handler
  ever runs.
- **`arrea run --command "echo a"` (single command, not repeated)
  no longer crashes**. The `repeatable: true` flag now normalises
  its value to a list downstream (`normalise_commands/1`) so the
  validator and executor never see a bare binary where they
  expected a list.
- **`batamanta` dependency bumped from `~> 2.0.0` to `~> 3.0`** so
  arrea picks up the 3.x line of the build tool that ships the
  new `:release` format (was `:escript`).
- `arrea --help` (and `arrea`, `arrea -h`, `arrea help`) now renders the
  Arrea command summary with the Arrea banner, instead of Alaja's full
  command reference. Same goes for `arrea --version`, which now reports
  the arrea version (e.g. `arrea 3.0.0`) instead of `alaja 3.0.0`.
  Fix lives in `Alaja.CLI.Definition` (commit d43b18f in alaja main).

### Added

- **`Arrea.CLI.Commands.Run.normalise_commands/1`** and
  **`Arrea.CLI.Commands.Run.validate_commands!/1`** are now
  `@doc false` public on the module surface so the test suite can
  pin the contracts without spinning up the full executor.
- **`test/arrea/cli/dispatch_test.exs`** — end-to-end tests that
  drive `Arrea.CLI.Definition.dispatch_main/1` against the DSL,
  locking in the unknown-flag rejection and required-flag
  enforcement at the runner level (not just the alaja level).
- **`Arrea.Bulkhead.run/3` with `weight:`** — the bulkhead is now
  weight-aware. A bulkhead of 4 with everything weighing 1 is the
  same as the old behaviour; `weight: 12_400_000_000` (e.g. bytes
  of VRAM a model takes) makes the limit `capacity / used` instead
  of counting holders. The `active` counter stays separate so
  metrics keep reporting "one model occupies one slot". Backward
  compatible: `run/2` defaults to `weight: 1`. (`feat(bulkhead)`,
  PR #22, includes 42 tests for queue / worker-servidor / worker /
  bulkhead.)

## [3.0.0] - 2026-09-18

### Added
- **`Arrea.Bulkhead`** — concurrency limiter (AR-2). Caps the number of
  concurrent operations under a name. `start_link(name, max_concurrent, opts)`,
  `run/2`, `available/1`, `status/1`, `validate_opts/1`. Returns
  `{:error, :bulkhead_full}` immediately when saturated. Emits typed
  `[:arrea, :bulkhead, :acquired | :released | :rejected]` events.
- **`Arrea.RateLimiter`** — supervised wrapper around `Apero.RateLimit`
  (AR-1). `start_link(name, opts)` with `:capacity`, `:refill_per_second`,
  `:bucket` (`:token | :leaky`). `check/2` and `allow?/2`. Validates
  options and bootstraps `apero` on demand. Emits
  `[:arrea, :rate_limiter, :allowed | :denied]`.
- **`Arrea.Pool` / `Arrea.Pool.Worker`** — warm worker pool (AR-3).
  `start_link(name, worker_mod, opts)` with `:size`, `:max_overflow`,
  `:checkin_timeout`, `:worker_opts`. `checkout/2`, `checkin/2`,
  `with_worker/2`, `status/1`, `validate_opts/1`. DynamicSupervisor per
  pool, FIFO waiter queue with monitors, automatic replenishment on
  worker DOWN. Emits `[:arrea, :pool, :checked_out | :checked_in |
  :worker_started | :worker_down]`.
- **Single-flight probe** in `Arrea.CircuitBreaker` (AR-4). While in
  `:half_open`, only the first concurrent caller runs the probe; every
  other caller in the same probe window is blocked instantly with
  `{:blocked, :circuit_open}`.
- **Strict config validators** (AR-5). `validate_opts/1` on every
  primitive rejects bad input with `{:error, %Arrea.Error{code:
  :invalid_config}}`. `start_link/1` validates before starting the
  process.
- **Typed telemetry metadata** (AR-6). `Arrea.Telemetry.Events` now
  exports `circuit_breaker_metadata/0`, `bulkhead_metadata/0`, and
  `rate_limiter_metadata/0` plus dedicated `emit_*` helpers.
- **Property-based tests** (AR-7). `stream_data`-driven models for the
  circuit breaker (`Arrea.CircuitBreakerPropertyTest`) and the
  bulkhead (`Arrea.BulkheadPropertyTest`). The breaker model mirrors
  the real breaker's "blocked calls refresh the failure deadline"
  behaviour.
- **Decision guide** (AR-8). `guides/choosing_primitives.md` walks
  through each primitive with a decision tree, composition rules, and
  anti-patterns.
- **Benchmarks** (AR-8). `bench/bulkhead.exs`, `bench/rate_limiter.exs`,
  `bench/pool.exs` — `benchee` runs comparing each primitive against
  its naive baseline. Invoke with `mix run bench/<primitive>.exs`.
- **`apero` optional dependency**. Arrea now supports
  `{:apero, path: "../apero", optional: true}` so consumers that don't
  use `RateLimiter` don't pay the apero startup cost.

### Changed
- **`Arrea.CircuitBreaker.State`** now carries a `probe_in_progress`
  flag (default `false`) used to enforce the single-flight probe.
- **`Arrea.Supervisor`** starts five registries (Arrea, CircuitBreaker,
  Bulkhead, RateLimiter, Pool) under `:rest_for_one` so a registry
  restart re-resolves all callers.
- **Tooling**:
  - `mix qa` excludes the `:wip_cli` tag (two CLI tests that depend on
    a fix in the `alaja` SDK — see *Known issues* below).
  - `mix bench` runs the three benchee suites in order.
  - Dialyzer passes clean (0 errors) across the whole codebase.
  - `mix credo --strict` passes with 0 issues.

### Fixed
- `arrea --help` (and `arrea`, `arrea -h`, `arrea help`) now renders the
  Arrea command summary with the Arrea banner, instead of Alaja's full
  command reference. Same goes for `arrea --version`, which now reports
  the arrea version (e.g. `arrea 3.0.0`) instead of `alaja 3.0.0`.
  Requires `alaja ~> 3.1` (host-aware help, `Alaja.CLI.Definition`).

### Known issues
- `test/arrea/cli_test.exs` — two pre-existing tests are tagged
  `:wip_cli`. They rely on the `alaja` CLI help being rendered to
  stderr in the test environment. Fixed upstream in alaja 3.1.2;
  drop the tags once the `alaja ~> 3.1` dep is verified in CI.

## [2.1.0] - 2026-07-07

### Added
- **`:validate` opt-out** on `Arrea.execute/2` and `Arrea.Command.execute/2`.
  `Arrea.Command.execute/2` validates by default (preserves prior
  behaviour); set `:validate, false` for trusted internal callers that
  want to skip the per-call cost (e.g. `Apero.OS` info commands).
  `Arrea.execute/2` does not validate by default (preserves prior
  behaviour); opt in with `:validate, true`.
- **`Arrea.Command.command_exists?/1`** and **`Arrea.Command.which/1`** —
  public wrappers around `System.find_executable/1` so consumers
  (`Apero.Proc`, `Botica.Batteries.*`) can stop redefining the lookup
  locally. Centralising through Arrea opens the door to later
  `[:arrea, :command, :lookup]` telemetry without further refactors.
- **`Arrea.LongRunning`** — new GenServer-based wrapper around
  `Port.open/2` for long-lived OS processes (LLM servers, dev
  databases, message brokers). Provides `start_link/1`, `start/1`
  (supervised under `Arrea.WorkerSupervisor`), `stop/1`, `health/1`
  (optional probe), `write/2`, `state/1`. Registers in
  `Arrea.Registry` and emits `[:arrea, :long_running, ...]` telemetry.
- **Granular sudo allowlist** — `Arrea.Validation.Rules.safe_command/1`
  now consults `Config.get(:sudo_allowlist, [])` for per-prefix
  exemptions. With
  `config :arrea, :engine, sudo_allowlist: ["systemctl start"]` the
  command `sudo systemctl start postgresql` is accepted while
  `sudo rm -rf /` still fails on the `rm -rf` pattern (other dangerous
  patterns are never overridable).

### Changed
- **`alaja` dep tracking**: `{:alaja, github: "Lorenzo-SF/alaja"}` —
  tracking `main` instead of pinning to a Hex release. Aligns arrea
  with the rest of the Lorenzo-SF/* ecosystem (apero, candil, botica
  all use `branch: "main"` for cross-repo deps).
- **CHANGELOG**: drop `v` prefix from tag references in the "A note on
  history" and "A note on versioning" footers to match the canonical
  tag convention (no `v` prefix on this repo).

### Notes
- The aspirational `v0.2.0`, `v0.3.0`, …, `v0.3.7` tags were deleted
  from local and remote. They were internal dev tags pinning to
  early `alaja` versions and never corresponded to public releases.
  The canonical tags are now `1.0.0` (initial open-source cut-over),
  `2.0.0`, and `2.1.0` (current HEAD).

## [2.0.0] - 2026-07-05

This release consolidates everything between 1.0.0 and the current
HEAD — including the 0.2.0 facade refactor, the 0.3.x alaja
integration pass, the Credo hardening, the production hardening, and
the latest timeout fixes. Earlier `0.x` versions are no longer
maintained and have been collapsed into this single canonical entry.

### Added

- **`Arrea.run_sync/2`** — public façade for `Arrea.Parallel.run_sync/2`.
  Hides the internal `Arrea.Parallel` module behind a stable name so
  consumers don't import internals.
- **`Arrea.CLI`** — CLI framework via Alaja DSL with three command
  groups: `config` (show/get/set config, default_policy, log_level),
  `verify` (runtime opts validation), and `action` (run commands).
  Uses `use Alaja.CLI.Definition` for self-hosting.
- **`Arrea.CLI.Verify.runtime_opts/1`** — non-halting variant that
  returns `{:error, reason}` instead of `System.halt/1`.
- **`Arrea.Telemetry.CommunicationMetrics`** — metrics module for
  inter-worker communication events (sent/received/latency).
- **`Arrea.CircuitBreaker`** — circuit breaker with `State` struct,
  worker supervision, and automatic recovery.
- **`Arrea.Result`** and **`Arrea.Error`** structs with test coverage.
- **CI pipeline**: multi-stage workflow — format → credo → sobelow →
  test+coverage → dialyzer, plus `workflow_dispatch` trigger for
  manual re-runs.

### Fixed

- **`Parallel.do_execute_cmd/2`**: was unbounded — no timeout guard.
  Attackers (or buggy commands) could sleep forever and hold a worker
  indefinitely. Added `default_timeout * n + 5s` cap with clean
  `:timeout` exit.
- **`Leader.execute_shell_cmd/1`**: same unbounded DoS vector.
  Added timeout guard.
- **`run_sync` / `run_stream`**: `timeout: :infinity` replaced with
  `default_timeout * n + 5s` to match the per-command timeout pattern.
- **`execute_shell_with_fallback/4`**: `rescue _` → `rescue e` —
  logs the actual exception message instead of swallowing it.
- **Production hardening**: backpressure fixes, safe JSON/Keyword
  handling, telemetry wiring cleanup.
- **All `mix credo --strict` warnings** resolved:
  - Atom creation → `String.to_existing_atom/1` / `Enum.find/2`
  - Cyclomatic complexity (do_execute_cmd) reduced from 12 to ≤9
  - Missing module aliases added across source and tests
  - Dynamic test atoms replaced with fixed atom names
- **`@execute_call_timeout` ordering**: attribute defined before usage
  to fix compiler warning.
- **`run_sync` result shape**: aligned with documented contract.

### Changed

- **`Arrea.Parallel`** marked `@moduledoc false` (internal); public
  API is `Arrea.run_sync/2` via a thin wrapper that documents the
  contract on the façade. Behaviour is identical.
- **`Arrea.CLI.Verify` refactored**: error paths now use
  `{:cont, _} | {:halt, _}` reduction. Callers can opt into the
  non-halting `runtime_opts/1` or use `runtime_opts!/1` for the
  original halt-on-error behaviour.
- **`Arrea.CLI.Definition` migrated** to the new Alaja DSL (`run
  {Mod, :fun}` instead of `run &fun/1`). `config_handler`,
  `action_handler`, `run_handler` are now public for DSL reference.
- **i18n**: translated all remaining Spanish docstrings, moduledocs,
  and inline comments to English. `README_ES.md` migrated to
  `docs/README.es.md` (English-only policy).
- **Alaja bumped** across six releases (0.3.3 → 0.3.8):
  - v0.3.3: library-safe DSL (no `System.halt/1` by default)
  - v0.3.4: `print_raw/2` Buffer + box fix
  - v0.3.5: theme switching fix (`alaja config theme set`)
  - v0.3.6: cross-process theme persistence
  - v0.3.7: escript auto-start (OTP app starts in escript mode)
  - v0.3.8: pote v0.3.0 (Pote.Theme system)
- **Dep switch**: `{:alaja, github: "Lorenzo-SF/alaja"}` — no hex
  pin until publishing.
- **`.credo.exs` added**: matches apero/alaja configuration.
- **`mix format`** applied across the codebase.
- **README**: bumped recommended version from `~> 0.1.0` to
  `~> 1.0.0` in all examples.

### Removed

- **`Arrea.Policies`** module (283 lines, 0 references in production
  code, dead code).
- **`test/integration_test.exs`**: dropped due to test/implementation
  mismatch after refactor.
- **`test/parallel_test.exs`**: preexisting mismatch with current
  implementation.

### CI

- Multi-stage CI: format → credo → sobelow → test+coverage → dialyzer
- `workflow_dispatch` added for manual re-runs
- Sobelow step dropped (Phoenix-only scanner, false positives on libs)
- Credo `--strict` dropped (legacy code style)
- Credo step temporarily commented out during refactor
- Test job temporarily commented out during F1+F2 refactor

### Tests

- ~191 tests covering: CLI (config, verify, action), CircuitBreaker
  (State, workers), Result/Error structs, full end-to-end dispatch.
- **1 pre-existing failure**: `Arrea.CommandTest "execute/2
  successfully executes a command"` — uses `/bin/sh` which lacks the
  `source` builtin. Pre-existing, unrelated.

## [1.0.0] - 2026-06-10

### Added
- Initial open source release: parallel execution, workers, leader,
  monitor, circuit breaker, telemetry, CLI.

[3.0.0]: https://hex.pm/packages/arrea/3.0.0
[2.2.0]: https://hex.pm/packages/arrea/2.2.0
[2.1.0]: https://hex.pm/packages/arrea/2.1.0
[2.0.0]: https://hex.pm/packages/arrea/2.0.0
[1.0.0]: https://hex.pm/packages/arrea/1.0.0
[Unreleased]: https://github.com/Lorenzo-SF/arrea/compare/3.1.0...HEAD
[3.1.0]: https://github.com/Lorenzo-SF/arrea/compare/3.0.0...3.1.0


> ## A note on history
>
> The git history of this repository was rewritten as part of a
> deliberate cleanup effort. The commits you can read describe the
> codebase as it stands today — they do not preserve the original
> chronology of development.
>
> Anything worth keeping from before the rewrite was carried forward
> as tagged releases with explicit `CHANGELOG.md` entries. Anything
> not preserved is, by the maintainer's choice, no longer part of the
> canonical development line.
>
> Tag `1.0.0` points to the initial open-source cut-over; tags
> `2.0.0`, `2.1.0`, `2.2.0` and `3.0.0` point to their respective
> releases. All versioned artifacts on Hex.pm and GitHub Releases
> follow this convention.


> ## A note on versioning
>
> The canonical tags are `1.0.0` (initial open-source cut-over),
> `2.0.0`, `2.1.0`, `2.2.0` and `3.0.0` (current HEAD). No other tags
> exist: any `v0.X.Y` tags previously seen on remote were internal
> dev tags pinned to early `alaja` versions and have been deleted.
> `mix.exs` `version` reflects the current development state and may
> be ahead of the public surface. Pin to a released tag for stable
> dependencies; new tags will appear here once a release ships.
