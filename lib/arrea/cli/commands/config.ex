# credo:disable-for-this-file Credo.Check.Readability.StringSigils
defmodule Arrea.CLI.Commands.Config do
  @moduledoc """
  `arrea config` — Manage Arrea engine configuration.

  Allows reading and writing engine configuration at runtime.
  Changes persist only for the current VM session.
  """

  alias Alaja.ANSI
  alias Alaja.Components.{Header, Separator, Table}
  alias Arrea.Config
  alias Arrea.Validation.Rules

  @config_keys [
    :max_workers,
    :max_commands_per_batch,
    :default_policy,
    :max_retries,
    :retry_delay,
    :restart_limit,
    :circuit_breaker_threshold,
    :circuit_breaker_timeout,
    :asdf_enabled,
    :telemetry_enabled,
    :log_level,
    :shell
  ]

  @valid_policies [:retry, :stop, :continue]
  @valid_log_levels [:debug, :info, :warn, :error]
  @valid_bool_values ~w(true false yes no 1 0)

  @doc """
  Shows the current engine configuration.
  """
  @spec show_config() :: :ok

  def show_config do
    IO.puts("")
    IO.puts("  #{ANSI.fg(0, 180, 216)}Arrea Engine Configuration#{ANSI.reset()}\n")

    rows =
      Enum.map(@config_keys, fn key ->
        formatted_key = to_string(key) |> String.replace("_", " ")
        value = Config.get(key)
        [formatted_key, inspect(value)]
      end)

    Table.print(
      headers: ["Key", "Value"],
      rows: rows,
      table_border: :rounded,
      padding: 1
    )

    IO.puts("")
  end

  @doc """
  Gets a configuration value by key.
  """
  @spec get_config(String.t()) :: :ok
  def get_config(key_str) do
    case Enum.find(@config_keys, &(to_string(&1) == key_str)) do
      nil ->
        IO.puts(:stderr, "Unknown config key: #{key_str}")
        IO.puts("Available: #{Enum.join(@config_keys, ", ")}")

      key ->
        value = Config.get(key)
        IO.puts("  #{key_str}: #{inspect(value)}")
    end
  end

  @doc """
  Sets a configuration value.
  """
  @spec set_config(String.t(), String.t()) :: :ok
  def set_config(key_str, value_str) do
    case Enum.find(@config_keys, &(to_string(&1) == key_str)) do
      nil ->
        IO.puts(:stderr, "Unknown config key: #{key_str}")
        IO.puts("Available: #{Enum.join(@config_keys, ", ")}")

      key ->
        do_set_config(key, value_str)
    end
  end

  defp do_set_config(:max_workers, v) do
    case Integer.parse(v) do
      {n, _} when n >= 1 ->
        Config.set(:max_workers, n)
        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} max_workers set to #{n}")

      _ ->
        IO.puts(:stderr, "Invalid max_workers: #{v} (must be >= 1)")
    end
  end

  defp do_set_config(:max_commands_per_batch, v) do
    case Integer.parse(v) do
      {n, _} when n >= 1 ->
        Config.set(:max_commands_per_batch, n)

        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} max_commands_per_batch set to #{n}")

      _ ->
        IO.puts(:stderr, "Invalid max_commands_per_batch: #{v} (must be >= 1)")
    end
  end

  defp do_set_config(:default_policy, v) do
    case Enum.find(@valid_policies, &(to_string(&1) == v)) do
      nil ->
        IO.puts(
          :stderr,
          "Invalid default_policy: #{v} (valid: #{Enum.join(@valid_policies, ", ")})"
        )

      val ->
        Config.set(:default_policy, val)

        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} default_policy set to #{val}")
    end
  end

  defp do_set_config(:max_retries, v) do
    case Integer.parse(v) do
      {n, _} when n >= 0 ->
        Config.set(:max_retries, n)
        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} max_retries set to #{n}")

      _ ->
        IO.puts(:stderr, "Invalid max_retries: #{v} (must be >= 0)")
    end
  end

  defp do_set_config(:retry_delay, v) do
    case Integer.parse(v) do
      {n, _} when n >= 0 ->
        Config.set(:retry_delay, n)

        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} retry_delay set to #{n}ms")

      _ ->
        IO.puts(:stderr, "Invalid retry_delay: #{v} (must be >= 0)")
    end
  end

  defp do_set_config(:restart_limit, v) do
    case Integer.parse(v) do
      {n, _} when n >= 0 ->
        Config.set(:restart_limit, n)

        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} restart_limit set to #{n}")

      _ ->
        IO.puts(:stderr, "Invalid restart_limit: #{v} (must be >= 0)")
    end
  end

  defp do_set_config(:circuit_breaker_threshold, v) do
    case Integer.parse(v) do
      {n, _} when n >= 1 ->
        Config.set(:circuit_breaker_threshold, n)

        IO.puts(
          "  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} circuit_breaker_threshold set to #{n}"
        )

      _ ->
        IO.puts(:stderr, "Invalid circuit_breaker_threshold: #{v} (must be >= 1)")
    end
  end

  defp do_set_config(:circuit_breaker_timeout, v) do
    case Integer.parse(v) do
      {n, _} when n >= 1000 ->
        Config.set(:circuit_breaker_timeout, n)

        IO.puts(
          "  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} circuit_breaker_timeout set to #{n}ms"
        )

      _ ->
        IO.puts(:stderr, "Invalid circuit_breaker_timeout: #{v} (must be >= 1000)")
    end
  end

  defp do_set_config(:asdf_enabled, v) do
    case parse_bool(v) do
      {:ok, bool} ->
        Config.set(:asdf_enabled, bool)

        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} asdf_enabled set to #{bool}")

      :error ->
        IO.puts(
          :stderr,
          "Invalid asdf_enabled: #{v} (valid: #{Enum.join(@valid_bool_values, ", ")})"
        )
    end
  end

  defp do_set_config(:telemetry_enabled, v) do
    case parse_bool(v) do
      {:ok, bool} ->
        Config.set(:telemetry_enabled, bool)

        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} telemetry_enabled set to #{bool}")

      :error ->
        IO.puts(
          :stderr,
          "Invalid telemetry_enabled: #{v} (valid: #{Enum.join(@valid_bool_values, ", ")})"
        )
    end
  end

  defp do_set_config(:log_level, v) do
    case Enum.find(@valid_log_levels, &(to_string(&1) == v)) do
      nil ->
        IO.puts(
          :stderr,
          "Invalid log_level: #{v} (valid: #{Enum.join(@valid_log_levels, ", ")})"
        )

      val ->
        Config.set(:log_level, val)
        IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} log_level set to #{val}")
    end
  end

  defp do_set_config(:shell, v) do
    shell_name = Path.basename(v)
    allowed = Rules.allowed_shells()

    if shell_name in allowed do
      Config.set(:shell, v)
      IO.puts("  #{ANSI.fg(72, 187, 120)}✓#{ANSI.reset()} shell set to #{v}")
    else
      IO.puts(:stderr, "Invalid shell: #{v} (valid: #{Enum.join(allowed, ", ")})")
    end
  end

  defp parse_bool("true"), do: {:ok, true}
  defp parse_bool("false"), do: {:ok, false}
  defp parse_bool("yes"), do: {:ok, true}
  defp parse_bool("no"), do: {:ok, false}
  defp parse_bool("1"), do: {:ok, true}
  defp parse_bool("0"), do: {:ok, false}
  defp parse_bool(_), do: :error

  # ─── Help ─────────────────────────────────────────────────────────────────

  @doc """
  Prints help for the `arrea config` command.
  """
  @spec help() :: :ok
  def help do
    Header.print("Arrea Config",
      subtitle: "Manage Arrea engine configuration",
      size: :small
    )

    IO.puts("")

    Separator.print("DESCRIPTION", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  View and modify Arrea engine configuration at runtime.")
    IO.puts("  Changes affect the current VM session only.")
    IO.puts("")

    Separator.print("USAGE", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  arrea config --show")
    IO.puts("  arrea config get <key>")
    IO.puts("  arrea config set <key> <value>")
    IO.puts("")

    Separator.print("ACTIONS", char: "━", width: 50, color: {0, 180, 216})

    Table.print(
      headers: ["Action", "Description"],
      rows: [
        ["--show", "Print current engine configuration"],
        ["get KEY", "Get a configuration value"],
        ["set KEY VALUE", "Set a configuration value"]
      ],
      table_border: :none,
      padding: 1
    )

    IO.puts("")

    Separator.print("CONFIGURABLE KEYS", char: "━", width: 50, color: {0, 180, 216})

    Table.print(
      headers: ["Key", "Type", "Default", "Description"],
      rows: [
        ["max_workers", "integer", "100", "Maximum parallel workers"],
        ["max_commands_per_batch", "integer", "500", "Max commands per batch"],
        ["default_policy", "atom", "retry", "Error policy: retry, stop, continue"],
        ["max_retries", "integer", "3", "Max retry attempts"],
        ["retry_delay", "integer", "1000", "Delay between retries (ms)"],
        ["restart_limit", "integer", "3", "Worker restart limit"],
        ["circuit_breaker_threshold", "integer", "5", "Failures before circuit opens"],
        ["circuit_breaker_timeout", "integer", "60000", "Time before half-open (ms)"],
        ["asdf_enabled", "boolean", "true", "Enable ASDF version management"],
        ["telemetry_enabled", "boolean", "true", "Enable telemetry"],
        ["log_level", "atom", "info", "Log verbosity: debug, info, warn, error"],
        ["shell", "string", "user shell", "Default shell (e.g. /bin/bash, /bin/zsh)"]
      ],
      table_border: :none,
      padding: 1
    )

    IO.puts("")

    Separator.print("EXAMPLES", char: "━", width: 50, color: {0, 180, 216})

    IO.puts(
      "# Show all config\n  arrea config --show\n\n# Get a value\n  arrea config get max_workers\n\n# Set integer\n  arrea config set max_workers 200\n\n# Set atom\n  arrea config set default_policy stop\n\n# Set boolean\n  arrea config set asdf_enabled true\n\n# Set log level\n  arrea config set log_level debug\n\n# Set circuit breaker\n  arrea config set circuit_breaker_threshold 10\n  arrea config set circuit_breaker_timeout 30000"
    )

    IO.puts("")
    :ok
  end
end
