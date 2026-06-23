# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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

## [1.0.0] - 2026-06-10

### Added
- Initial open source release: parallel execution, workers, leader, monitor, circuit breaker, telemetry, CLI.

[1.0.0]: https://hex.pm/packages/arrea/1.0.0
