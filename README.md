# Arrea

Async process orchestrator and telemetry for Elixir.

Arrea is an OTP-based library that provides parallel process execution, worker management, circuit breaker protection, command validation, and built-in telemetry for monitoring your Elixir applications.

## Quick Start

Add Arrea to your `mix.exs`:

```elixir
def deps do
  [
    {:arrea, github: "Lorenzo-SF/arrea"}
  ]
end
```

Arrea starts its supervision tree automatically when added as a dependency. No manual setup required.

### Execute a single command

```elixir
# Shell command
{:ok, result} = Arrea.execute("echo hello")

# Or a function
{:ok, result} = Arrea.execute(fn -> :work end)
```

### Run commands in parallel

```elixir
{:ok, result} = Arrea.run(
  [
    fn -> Process.sleep(100); 1 end,
    fn -> Process.sleep(100); 2 end,
    fn -> Process.sleep(100); 3 end
  ],
  workers: 2
)
```

### Subscribe to events

```elixir
:ok = Arrea.subscribe()

receive do
  {:leader_event, %{type: :finished, worker_id: id}} ->
    IO.puts("Worker #{id} finished")
  {:leader_event, event} ->
    IO.inspect(event, label: "Event")
end

:ok = Arrea.unsubscribe()
```

### Get stats

```elixir
{:ok, stats} = Arrea.stats()
# => %{
#      total_workers: 10,
#      active_workers: 3,
#      completed_tasks: 42,
#      failed_tasks: 2
#    }
```

## Features

- **Parallel execution** — Run commands and functions concurrently with configurable worker pools via `Arrea.run/2`
- **Synchronous execution** — Execute single commands with `Arrea.execute/2`, including shell integration with real timeout cancellation
- **Circuit breaker** — Protect external calls with automatic open/close/half-open state transitions to prevent cascading failures
- **Command validation** — Built-in validation rules blocking dangerous commands (`rm -rf`, `sudo`, `mkfs`, fork bombs, injection patterns)
- **Telemetry** — Rich event system with worker lifecycle, task progress, system metrics, and circuit breaker state tracking
- **Error policies** — Configurable error handling: retry, stop, continue, or custom handlers with retry counts and delays
- **Worker monitoring** — Subscribe to real-time events: worker start, completion, failure, and progress updates
- **Batch execution** — Submit command batches with worker limits and per-worker timeouts
- **ASDF/mise integration** — Runtime version management via `asdf` or `mise` with support for `--asdf-<runtime>` CLI flags and `mise exec` wrapping
- **Custom shell** — Configurable shell per-command (`--shell`), via config (`Arrea.Config.set(:shell, ...)`), or auto-detected from `$SHELL` with automatic config file sourcing
- **Structured results** — `Arrea.Result` and `Arrea.Error` structs for consistent return types

## CLI

Arrea includes a command-line interface built with [Alaja](https://github.com/lorenzo-sf/alaja):

```bash
# Build the escript
mix escript.build

# Run locally
./arrea run --command "echo hello"

# Install to ~/bin
mix install
```

### `arrea run`

Execute shell commands in parallel with progress tracking.

```bash
# Single command
arrea run --command "echo hello"

# Multiple commands (parallel)
arrea run --command "echo a" --command "echo b"

# With worker limit
arrea run --command "sleep 1" --command "sleep 2" --parallel 2

# Custom timeout (ms)
arrea run --command "sleep 10" --timeout 5000

# Quiet mode (suppress progress)
arrea run --command "echo done" --quiet

# Custom shell
arrea run --command "echo $0" --shell zsh

# With ASDF version
arrea run --command "mix test" --asdf-elixir 1.18.0

# With mise version
arrea run --command "node -v" --mise-node 20.0.0
```

### `arrea config`

Manage Arrea engine configuration at runtime.

```bash
# Show all config
arrea config --show

# Get a value
arrea config get max_workers

# Set a value
arrea config set max_workers 200
arrea config set default_policy stop
arrea config set asdf_enabled true
arrea config set log_level debug
```

### `arrea action`

Execute Arrea commands from JSON input (stdin, file, or inline).

```bash
# From stdin
echo '{"command":"run","args":["--command","echo hello"]}' | arrea action

# From file
arrea action --file ./pipeline.json

# Inline JSON
arrea action --data '{"command":"run","args":["--command","echo hi","--quiet"]}'

# Batch actions
arrea action --data '{
  "actions": [
    {"command": "run", "args": ["--command", "echo first"], "order": 0},
    {"command": "run", "args": ["--command", "echo second", "--quiet"], "order": 1}
  ]
}'
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Arrea (Facade)                    │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│              Arrea.Leader (GenServer)                │
│     Coordinates execution, manages workers,          │
│     broadcasts {:leader_event, event} to subscribers │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│       Arrea.WorkerSupervisor (DynamicSupervisor)     │
│              Spawns ephemeral workers                │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│            Arrea.Worker (GenServer)                  │
│     Executes individual tasks, handles policies,     │
│     reports progress via Leader                      │
└─────────────────────────────────────────────────────┘

  Arrea.Monitor (GenServer)   — Tracks worker lifecycle, provides stats
  Arrea.CircuitBreaker        — Fault tolerance for external dependencies
```

All processes run under `Arrea.Supervisor` with `:rest_for_one` strategy, using two Registries (`Arrea.Registry` for workers, `Arrea.CircuitBreaker.Registry` for circuit breakers). With `:rest_for_one`, only the processes that depend on a failed process are restarted, minimizing disruption to active batches.

## API

### `Arrea.execute/2`

Execute a single command (binary shell command or zero-arity function).

```elixir
@spec execute(binary() | (-> term()), keyword()) ::
        {:ok, Arrea.Result.t()} | {:error, Arrea.Error.t()}
```

Options:

- `:timeout` — Timeout in ms (default: `30_000`). **Real timeout**: cancels execution if exceeded.
- `:retry` — Whether to retry on failure
- `:shell` — Shell to use — highest priority, overrides config and `$SHELL`
- `:shell_config` — Path to shell config file to source (auto-detected by default)
- `:asdf_<runtime>` — Pin runtime version via asdf/mise (e.g. `asdf_elixir: "1.18.0"`)
- `:mise_<runtime>` — Use `mise exec` wrapping (e.g. `mise_node: "20.0.0"`)

### `Arrea.run/2`

Execute multiple commands in parallel.

```elixir
@spec run([binary() | (-> term())], keyword()) ::
        {:ok, Arrea.Result.t()} | {:error, Arrea.Error.t()}
```

Options:

- `:workers` — Max parallel workers (default: `max_workers()`)
- `:timeout` — Total timeout in ms

### `Arrea.subscribe/0` / `Arrea.unsubscribe/0`

Subscribe (or unsubscribe) the calling process to Leader events.

Messages received are `{:leader_event, event}` where `event` is a map with at least a `:type` key:

| Type               | Extra keys                               |
| ------------------ | ---------------------------------------- |
| `:worker_started`  | `worker_id`                              |
| `:progress`        | `worker_id`, `percent`, `task_index`, `total` |
| `:finished`        | `worker_id`                              |
| `:error`           | `worker_id`, `reason`                    |
| `:result`          | `worker_id`, `data`                      |

```elixir
@spec subscribe() :: :ok
@spec unsubscribe() :: :ok
```

### `Arrea.stats/0`

Get current engine statistics (provided by `Arrea.Monitor`).

```elixir
@spec stats() :: {:ok, map()} | {:error, :monitor_unavailable}
```

### `Arrea.max_workers/0`

Get the configured max workers.

```elixir
@spec max_workers() :: non_neg_integer()
```

## Configuration

### Priority (lowest to highest)

For use **as a library**:

1. `@default` in `Arrea.Config` — compile-time baseline
2. `config :arrea, :engine, [...]` in the consuming project's `config.exs` — overrides defaults
3. `Arrea.Config.set/2` at runtime — overrides static config for the current session
4. Opts passed directly to functions — highest priority, per-call

For use **as a CLI binary**:

1. `@default` baseline
2. Application env (from `config.exs` if applicable)
3. `arrea config set KEY VALUE` — session-level, persists while the binary process is running
4. CLI args — highest priority, per-invocation only

### `config.exs` example

Accepts both keyword list and map:

```elixir
config :arrea, :engine,
  max_workers: 100,
  max_commands_per_batch: 500,
  default_policy: :retry,
  max_retries: 3,
  retry_delay: 1_000,
  restart_limit: 3,
  circuit_breaker_threshold: 5,
  circuit_breaker_timeout: 60_000,
  validation_rules: [:no_rm_rf, :no_sudo, :no_dd, :no_mkfs, :no_fork_bomb],
  telemetry_enabled: true,
  log_level: :info
```

| Key                         | Type    | Default  | Description                                     |
| --------------------------- | ------- | -------- | ----------------------------------------------- |
| `max_workers`               | integer | `100`    | Maximum parallel workers                        |
| `max_commands_per_batch`    | integer | `500`    | Max commands per batch                          |
| `default_policy`            | atom    | `:retry` | Default error policy for workers                |
| `max_retries`               | integer | `3`      | Max retry attempts                              |
| `retry_delay`               | integer | `1_000`  | Delay between retries (ms)                      |
| `restart_limit`             | integer | `3`      | Worker restart limit                            |
| `circuit_breaker_threshold` | integer | `5`      | Failures before circuit opens                   |
| `circuit_breaker_timeout`   | integer | `60_000` | Time before half-open attempt (ms)             |
| `validation_rules`          | list    | see below | Blocked command patterns                     |
| `asdf_enabled`              | boolean | `true`   | Enable ASDF version management                 |
| `telemetry_enabled`         | boolean | `true`   | Enable telemetry                               |
| `log_level`                 | atom    | `:info`  | Log verbosity                                  |
| `shell`                     | string  | `nil`    | Default shell (e.g. `"/bin/zsh"`)             |

**Validation rules** (default):
- `:no_rm_rf` — blocks `rm -rf`
- `:no_sudo` — blocks `sudo`
- `:no_dd` — blocks `dd`
- `:no_mkfs` — blocks `mkfs`
- `:no_fork_bomb` — blocks fork bombs

### Runtime config

```elixir
Arrea.Config.get(:max_workers)      # => 100
Arrea.Config.set(:max_workers, 50)  # persists for the current VM session
Arrea.Config.all()                  # => full effective config map
```

## Telemetry Events

Arrea emits the following `:telemetry` events:

### Worker events

| Event                           | Measurements | Metadata              |
| ------------------------------- | ------------ | --------------------- |
| `[:arrea, :worker, :started]`   | —            | `worker_id`           |
| `[:arrea, :worker, :completed]` | `duration`   | `worker_id`           |
| `[:arrea, :worker, :error]`     | —            | `worker_id`, `reason` |
| `[:arrea, :worker, :message]`   | —            | `worker_id`           |

### Task events

| Event                         | Measurements | Metadata              |
| ----------------------------- | ------------ | --------------------- |
| `[:arrea, :task, :started]`   | —            | —                     |
| `[:arrea, :task, :completed]` | `duration`   | —                     |
| `[:arrea, :task, :error]`     | —            | `worker_id`, `reason` |

### Engine events

| Event                                 | Measurements | Metadata             |
| ------------------------------------- | ------------ | -------------------- |
| `[:arrea, :engine, :execute, :start]` | —            | `command`            |
| `[:arrea, :engine, :execute, :stop]`  | `duration`   | `command`, `success` |
| `[:arrea, :engine, :execute, :error]` | `duration`   | `command`, `reason`  |
| `[:arrea, :engine, :run, :start]`     | —            | `count`, `workers`   |
| `[:arrea, :engine, :run, :stop]`      | —            | `batch_id`           |

### Circuit breaker events

| Event                                 | Measurements | Metadata                      |
| ------------------------------------- | ------------ | ----------------------------- |
| `[:arrea, :circuit_breaker, :open]`   | —            | `breaker_id`                  |
| `[:arrea, :circuit_breaker, :closed]` | —            | `breaker_id`                  |
| `[:arrea, :circuit_breaker, :trip]`   | —            | `breaker_id`, `failure_count` |

### Communication events

| Event                                         | Measurements | Metadata |
| --------------------------------------------- | ------------ | -------- |
| `[:arrea, :communication, :message_sent]`     | —            | —        |
| `[:arrea, :communication, :message_received]` | —            | —        |
| `[:arrea, :communication, :error]`            | —            | —        |
| `[:arrea, :communication, :retry]`            | —            | —        |

### UI events (CLI / alaja components)

| Event                     | Measurements | Metadata  |
| ------------------------- | ------------ | --------- |
| `[:arrea, :ui, :render]`  | —            | —         |
| `[:arrea, :ui, :keypress]`| —            | —         |
| `[:arrea, :ui, :focus_change]` | —       | —         |

### Validation / Execution / System events

| Event                              | Measurements | Metadata |
| ---------------------------------- | ------------ | -------- |
| `[:arrea, :validation, :passed]`   | —            | —        |
| `[:arrea, :validation, :failed]`   | —            | —        |
| `[:arrea, :execution, :started]`   | —            | —        |
| `[:arrea, :execution, :completed]` | —            | —        |
| `[:arrea, :execution, :failed]`    | —            | —        |
| `[:arrea, :system, :started]`      | —            | —        |
| `[:arrea, :system, :stopped]`      | —            | —        |

### Attaching a custom handler

```elixir
:telemetry.attach(
  "my-handler",
  [:arrea, :worker, :completed],
  fn _event, measurements, metadata, _config ->
    IO.puts("Worker #{metadata.worker_id} finished in #{measurements.duration}ms")
  end,
  nil
)
```

### Built-in metrics and debug

```elixir
# Setup built-in ETS metrics (worker/task/circuit breaker counters)
Arrea.Telemetry.setup()

# Get current metrics snapshot
Arrea.Telemetry.get_current()

# Attach debug handler for development
Arrea.Telemetry.attach()

# Measure a function with telemetry
Arrea.Telemetry.measure(fn -> do_work() end, metadata: %{tag: "batch-1"})
```

## Policies

Arrea provides configurable error policies for workers:

```elixir
# Default policy (retry 3 times with 1s delay)
policy = Arrea.Policies.default()

# Strict policy (stop on first error)
policy = Arrea.Policies.strict()

# Tolerant policy (retry up to 10 times with 2s delay)
policy = Arrea.Policies.tolerant(max_retries: 10, retry_delay: 2000)

# Custom handler
policy = Arrea.Policies.custom(fn error, retry_count, context ->
  if retry_count < 5, do: :retry, else: :stop
end)
```

Workers without an explicit policy fall back to `Arrea.Config.get(:default_policy)`, which defaults to `:retry`.

Policy maps support the following fields:

| Field         | Type                                                | Default  | Description                |
| ------------- | --------------------------------------------------- | -------- | -------------------------- |
| `on_error`    | `:retry \| :stop \| :continue \| function`          | `:retry` | Action on task error       |
| `on_warning`  | `:log \| :notify \| :continue \| :promote_to_error` | `:log`   | Action on warning          |
| `on_timeout`  | `:retry \| :stop \| :continue`                      | `:retry` | Action on timeout          |
| `max_retries` | integer                                             | `3`      | Maximum retry attempts     |
| `retry_delay` | integer                                             | `1000`   | Delay between retries (ms) |
| `timeout`     | integer                                             | `30000`  | Per-task timeout (ms)      |

## Command Validation

Arrea validates all shell commands before execution, blocking dangerous patterns:

```elixir
iex> Arrea.Validation.Validator.validate_command("echo hello")
{:ok, "echo hello"}

iex> Arrea.Validation.Validator.validate_command("rm -rf /")
{:error, {:dangerous_command, "rm -rf"}}

iex> Arrea.Validation.Validator.validate_command("$(whoami)")
{:error, :possible_injection}
```

## Inter-worker Messaging

Workers can send messages to each other:

```elixir
# Structured message
Arrea.Worker.send_message(:worker_1, %{type: :ping})

# Route a message to another worker
Arrea.Worker.send_message(:worker_1, {:send_to_worker, :worker_2, %{type: :data, value: 42}})
```

## Dependencies

- **alaja** — Internal UI/CLI utility library (powers the Arrea CLI)
- **jason** — JSON encoding/decoding
- **telemetry** — Event emission and handling
- **telemetry_metrics** — Metric definitions
- **telemetry_poller** — Periodic metric collection

## Installation

Add `arrea` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:arrea, github: "Lorenzo-SF/arrea"}
  ]
end
```

Then run:

```bash
mix deps.get
```

---

## Project history

This library was developed as part of a larger internal toolkit and extracted
to open source in mid-2026. The single commit visible on `main` represents the
OSS cut-over point — all the features shipped in `1.0.0` were built and tested
before being made public. Subsequent releases (`1.0.1`, `1.1.0`, ...) will be
tagged normally, providing a clean public history going forward.

A Spanish version of this README is available at [`README_ES.md`](./README_ES.md).

## Recent changes

### v0.3.0 (2026-06-25)
- Bumped `alaja` to v0.3.3 in `mix.lock`. The Alaja CLI dispatcher no longer
  calls `System.halt/1` by default — `main/1` now returns `{:error, reason}`
  unless the consumer sets `halt_on_error: true`. This makes Arrea's
  CLI safely testable from ExUnit.
- Updated tests in `test/arrea/cli_test.exs` to capture stderr instead
  of stdout (where Alaja's error messages go).

### v0.2.0 (2026-06-24)
- First release adopting the `Alaja.CLI.Definition` DSL. The previous
  hand-rolled argument dispatcher is gone.

## License

MIT License. See the [source repository](https://github.com/lorenzo-sf/arrea) for details.
