defmodule Arrea.MixProject do
  use Mix.Project

  def project do
    [
      app: :arrea,
      version: "3.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Arrea",
      description: "Asynchronous process orchestrator (OTP) and telemetry",
      source_url: "https://github.com/Lorenzo-SF/arrea",
      homepage_url: "https://github.com/Lorenzo-SF/arrea",
      package: [
        name: :arrea,
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/Lorenzo-SF/arrea"},
        maintainers: ["Lorenzo Sánchez"]
      ],
      docs: docs(),
      batamanta: batamanta(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      escript: [main_module: Arrea.CLI.Escript]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      # Arrea starts its supervision tree automatically when included
      # as a dependency. Callers do not need to call Arrea.Supervisor.start_link/1
      # manually.
      mod: {Arrea.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/Lorenzo-SF/arrea",
      homepage_url: "https://github.com/Lorenzo-SF/arrea",
      source_ref: "3.1.0",
      extras: ["README.md", "docs/README_ES.md", "LICENSE.md"],
      groups_for_modules: [
        "Core API": [Arrea, Arrea.Config, Arrea.Error, Arrea.Result],
        "OTP Core": [
          Arrea.Leader,
          Arrea.Leader.CommandRunner,
          Arrea.Worker,
          Arrea.WorkerState,
          Arrea.Worker.ErrorPolicy,
          Arrea.Worker.Registry,
          Arrea.Worker.ResultHandler,
          Arrea.Worker.Scheduler,
          Arrea.Supervisor,
          Arrea.Monitor,
          Arrea.Parallel,
          Arrea.LongRunning,
          Arrea.Registry
        ],
        "Fault Tolerance": [
          Arrea.CircuitBreaker,
          Arrea.CircuitBreaker.State,
          Arrea.Bulkhead,
          Arrea.RateLimiter,
          Arrea.Pool,
          Arrea.Pool.Worker
        ],
        "Commands & Validation": [
          Arrea.Command,
          Arrea.Policies,
          Arrea.Validation.Validator,
          Arrea.Validation.JsonSchema,
          Arrea.Validation.Rules
        ],
        Telemetry: [
          Arrea.Telemetry,
          Arrea.Telemetry.Events,
          Arrea.Telemetry.Metrics,
          Arrea.Telemetry.CommunicationMetrics,
          Arrea.Telemetry.DebugHandler
        ],
        CLI: [Arrea.CLI, Arrea.CLI.Definition, Arrea.CLI.Verify],
        "CLI Commands": [
          Arrea.CLI.Commands.Action,
          Arrea.CLI.Commands.Config,
          Arrea.CLI.Commands.Nodes,
          Arrea.CLI.Commands.Run,
          Arrea.CLI.Commands.Run.Execution,
          Arrea.CLI.Commands.Run.Format
        ],
        Utilities: [Arrea.Subscribers, Arrea.Logging.Behaviour, Arrea.Application]
      ]
    ]
  end

  defp batamanta do
    [
      format: :escript,
      execution_mode: :cli,
      compression: 19,
      binary_name: "Arrea",
      # BEAM-keeps-alive. The wrapper dispatches to a warm Erlang VM over a
      # Unix-domain socket instead of booting one per invocation. The socket
      # is namespaced by (app, version, target), so this daemon is Arrea's
      # own — it is not shared with the other packaged CLIs.
      #   ARREA_BEAM_ALIVE=<ms>  override the TTL for one shell (max 86_400_000)
      #   ARREA_BEAM_ALIVE=0     force the legacy cold-start path
      daemon: [
        enabled: true,
        var: "ARREA_BEAM_ALIVE",
        default_ms: 300_000,
        request_timeout_ms: 60_000
      ]
    ]
  end

  defp deps do
    [
      {:alaja, "~> 3.2"},
      {:apero, "~> 4.0", optional: true},
      {:batamanta, "~> 3.1", optional: true, runtime: false},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:benchee, "~> 1.3", only: :dev}
    ]
  end

  defp aliases do
    [
      gen: ["clean_build", "deps.get", "compile", "batamanta"],
      clean_build: &clean_build/1,
      qa: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "cmd sh -c 'MIX_ENV=test mix test --cover'",
        "dialyzer"
      ],
      bench: [
        "run bench/bulkhead.exs",
        "run bench/rate_limiter.exs",
        "run bench/pool.exs"
      ]
    ]
  end

  defp clean_build(_args) do
    File.rm_rf("_build")
    File.rm_rf("deps")
    File.rm_rf("mix.lock")
    Mix.shell().info("✅  Clean slate.")
  end
end
