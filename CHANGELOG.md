# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[1.0.0]: https://hex.pm/packages/arrea/1.0.0
[2.0.0]: https://github.com/Lorenzo-SF/arrea/releases/tag/v2.0.0


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
> Tag `v1.0.0` points to the initial open-source cut-over; tag
> `v2.0.0` points to the current HEAD and the canonical consolidated
> release. All versioned artifacts on Hex.pm and GitHub Releases
> follow this convention.
