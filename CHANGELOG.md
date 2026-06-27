# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.6] - 2026-06-27

### Fixed
- Resolved all `mix credo --strict` warnings across the codebase:
  - **Warnings (atom creation)**: Replaced `String.to_atom/1` with `Enum.find/2`
    matching on pre-existing atoms in `Arrea.CLI.Commands.Config` (get/set config,
    default_policy, log_level). Replaced `:"#{atom}"` interpolation with
    `String.to_existing_atom/1` in `Arrea.CLI.Definition` (asdf/mise opts) and
    `Arrea.Command.execute_with_asdf/3`.
  - **Refactor (cyclomatic complexity)**: Reduced `Arrea.Parallel.do_execute_cmd/2`
    complexity from 12 to ≤9 by extracting anonymous functions `run_shell/2`,
    `yield_or_timeout/2` and fallback logic `execute_shell_with_fallback/4`
    into named private functions.
  - **Design (module aliases)**: Added `alias` declarations for `Arrea.Config`,
    `Arrea.CLI`, `Arrea.Command`, `Arrea.Parallel`, `Alaja.ANSI`, and
    `ExUnit.CaptureIO` across source and test files to avoid fully-qualified
    nested module references.
  - **Test fix**: Replaced dynamic atom creation (`:"worker_#{test_name}"`)
    with a fixed `:circuit_breaker_test` atom in `CircuitBreakerTest`.

## [0.3.5] - 2026-06-27

### Changed
- Bumped `alaja` to v0.3.8 in `mix.lock`. Now uses `pote` v0.3.0
  (which tags the Pote.Theme system). Pre-v0.3.8, `mix deps.get`
  could re-pin `pote` to v0.2.0 (which predates Pote.Theme),
  breaking `Alaja.Theme` compilation.

## [0.3.4] - 2026-06-27

## [0.3.4] - 2026-06-27

### Changed
- Bumped `alaja` to v0.3.7 in `mix.lock`. Now `Alaja.CLI.Definition.main/1`
  auto-starts the OTP application, so escripts (built with `mix gen` +
  batamanta) see the persisted `:theme_active` from `alaja.conf`.

## [0.3.3] - 2026-06-27

## [0.3.3] - 2026-06-27

### Changed
- Bumped `alaja` to v0.3.6 in `mix.lock`. Fixes cross-process theme
  persistence: every escript now sees the persisted `:theme_active`
  from `alaja.conf` without anyone calling `Alaja.Theme.activate/1`.

## [0.3.2] - 2026-06-27

## [0.3.2] - 2026-06-27

### Changed
- Bumped `alaja` to v0.3.5 in `mix.lock`. Fixes a critical bug where
  `alaja config theme set <name>` did NOT change the colour palette.
  Arrea doesn't trigger the bug itself, but downstream consumers that
  use `theme:<key>` lookups (or `Pote.parse(:success)`) now see the
  active theme's colours.

## [0.3.1] - 2026-06-26

### Changed
- Bumped `alaja` to v0.3.4 in `mix.lock`. Fixes a `print_raw/2` crash when
  the input was a `Buffer.t()` and the `:box` opt was set. Arrea's own
  tests don't trigger this, but downstream consumers using `alaja` for
  Cell-engine rendering (with box wrapping) benefit immediately.

## [0.3.0] - 2026-06-25

### Changed
- Bumped `alaja` to v0.3.3 in `mix.lock`. The Alaja CLI dispatcher no longer
  calls `System.halt/1` by default — `main/1` now returns `{:error, reason}`
  unless the consumer sets `halt_on_error: true`. This makes Arrea's
  CLI safely testable from ExUnit without the BEAM getting killed on
  error paths.
- Updated tests in `test/arrea/cli_test.exs` to capture stderr (where
  Alaja's error messages go) instead of stdout.

### Tests
- 191 tests, 1 pre-existing failure (`Arrea.CommandTest "execute/2
  successfully executes a command"`) unrelated to this change — uses
  `/bin/sh` which lacks `source` builtin. Pre-existing.

## [0.2.0] - 2026-06-24

### Added
- **`Arrea.run_sync/2`** — public façade for `Arrea.Parallel.run_sync/2`. Hides the internal `Arrea.Parallel` module (`@moduledoc false`) behind a stable name so users don't import internals.
- `Arrea.CLI.Verify.runtime_opts/1` — non-halting variant that returns `{:error, reason}` instead of `System.halt/1`.
- `Arrea.Telemetry.CommunicationMetrics` — metrics module for inter-worker communication events (sent/received/latency).
- `Arrea.Result` and `Arrea.Error` struct tests.
- `Arrea.CLI.Commands.Config` test coverage for show/get/set/help.
- `Arrea.CircuitBreaker.State` struct tests.
- `Arrea.CLI` end-to-end test exercising the self-hosted dispatch via the Alaja DSL.

### Changed
- **`Arrea.CLI.Verify` refactored**: error paths now use `{:cont, _} | {:halt, _}` reduction. Callers can opt into the non-halting `runtime_opts/1` for testable flows or use `runtime_opts!/1` for the original halt-on-error behaviour.
- **`Arrea.CLI.Definition` migrated** to the new Alaja DSL (`run {Mod, :fun}` instead of `run &fun/1`).
- **i18n**: translated remaining Spanish docstrings, moduledocs, and inline comments to English across the library for consistency.
- **Outdated README fixed**: bumped recommended version from `~> 0.1.0` to `~> 1.0.0` in `arrea run`, `arrea config`, and `arrea action` examples.
- Dep: `{:alaja, github: "Lorenzo-SF/alaja"}` — no longer requires hex publishing for development.
- `Arrea.CLI.Definition.run_handler`, `config_handler`, `action_handler` are now public (so the DSL can reference them) and tolerate missing `_args` by reading from `opts[:key]` etc.

### Removed
- `Arrea.Policies` module (283 lines, 0 references in production code, dead code).

### Changed
- **`Arrea.run_sync/2` facade cleaned up**: the previous `defdelegate ... to: Parallel` exposed that `Arrea.Parallel` is internal (`@moduledoc false`). Replaced with a thin wrapper that calls `Parallel.run_sync/2` by name and documents the public contract on the facade. Behaviour is identical; consumers keep using `Arrea.run_sync/2`.

## [1.0.0] - 2026-06-10

### Added
- Initial open source release: parallel execution, workers, leader, monitor, circuit breaker, telemetry, CLI.

[1.0.0]: https://hex.pm/packages/arrea/1.0.0

[0.2.0]: https://github.com/Lorenzo-SF/arrea/releases/tag/v0.2.0
