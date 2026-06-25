defmodule Arrea.MixProject do
  use Mix.Project

  def project do
    [
      app: :arrea,
      version: "0.3.0",
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
      escript: [main_module: Arrea.CLI]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      # Arrea arranca su árbol de supervisión automáticamente al incluirse
      # como dependencia. No es necesario llamar a Arrea.Supervisor.start_link/1
      # manualmente en el proyecto consumidor.
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
      extras: ["README.md", "README_ES.md", "LICENSE.md"],
      groups_for_modules: [
        "Core API": [Arrea, Arrea.Config, Arrea.Error, Arrea.Result],
        "OTP Core": [
          Arrea.Leader,
          Arrea.Worker,
          Arrea.WorkerState,
          Arrea.Supervisor,
          Arrea.Monitor,
          Arrea.Parallel
        ],
        "Fault Tolerance": [Arrea.CircuitBreaker, Arrea.CircuitBreaker.State],
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
          Arrea.Telemetry.DebugHandler
        ],
        CLI: [Arrea.CLI, Arrea.CLI.Definition],
        "CLI Commands": [
          Arrea.CLI.Commands.Action,
          Arrea.CLI.Commands.Config,
          Arrea.CLI.Commands.Run
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
      binary_name: "Arrea"
    ]
  end

  defp deps do
    [
      {:alaja, github: "Lorenzo-SF/alaja"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:batamanta, "~> 1.5.1", optional: true, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:benchee, "~> 1.3", only: :dev}
    ]
  end

  defp aliases do
    [
      gen: ["deps.get", "compile", "batamanta", "install"],
      install: fn _ ->
        dest_dir = Path.expand("~/bin")
        File.mkdir_p!(dest_dir)
        config = Mix.Project.config()
        app_name = Atom.to_string(config[:app])

        source_path = Path.expand("arrea")
        dest_path = Path.join(dest_dir, app_name)

        if File.exists?(source_path) do
          case File.cp(source_path, dest_path) do
            :ok ->
              File.chmod!(dest_path, 0o755)
              Mix.shell().info("✅  arrea instalado en #{dest_path}")

            {:error, reason} ->
              Mix.shell().error("❌ [ERROR] No se pudo copiar arrea: #{inspect(reason)}")
          end
        else
          Mix.shell().error("❌ [ERROR] No se encontró el binario: #{source_path}")
          Mix.shell().info("   ¿Ejecutaste 'mix batamanta' primero?")
        end
      end,
      qa: [
        "format",
        "compile",
        "dialyzer",
        "cmd sh -c 'MIX_ENV=test mix test --cover'",
        "cmd sh -c 'alaja json \"$(mix credo --strict --format=json)\"'"
      ]
    ]
  end
end
