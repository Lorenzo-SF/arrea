defmodule Arrea.CLI.Commands.ConfigTest do
  use ExUnit.Case, async: false

  alias Arrea.CLI.Commands.Config, as: ConfigCmd
  alias Arrea.Config

  setup do
    # Snapshot the application env so tests can restore it
    keys = [
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

    originals = for k <- keys, into: %{}, do: {k, Application.get_env(:arrea, k)}

    on_exit(fn ->
      for {k, v} <- originals do
        if v == nil,
          do: Application.delete_env(:arrea, k),
          else: Application.put_env(:arrea, k, v)
      end
    end)

    :ok
  end

  describe "show_config/0" do
    test "prints a table with all keys" do
      output = ExUnit.CaptureIO.capture_io(fn -> ConfigCmd.show_config() end)
      assert output =~ "max workers"
      assert output =~ "max commands per batch"
    end

    test "shows current values" do
      Config.set(:max_workers, 42)
      output = ExUnit.CaptureIO.capture_io(fn -> ConfigCmd.show_config() end)
      assert output =~ "42"
    end
  end

  describe "get_config/1" do
    test "prints known key" do
      Config.set(:max_workers, 50)
      output = ExUnit.CaptureIO.capture_io(fn -> ConfigCmd.get_config("max_workers") end)
      assert output =~ "max_workers"
      assert output =~ "50"
    end

    test "rejects unknown key" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ConfigCmd.get_config("nonsense_key")
        end)

      assert stderr =~ "Unknown config key"

      # The "Available" list goes to stdout; capture it separately.
      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          ConfigCmd.get_config("another_unknown")
        end)

      assert stdout =~ "max_workers"
    end
  end

  describe "set_config/2" do
    test "sets known integer key" do
      output = ExUnit.CaptureIO.capture_io(fn -> ConfigCmd.set_config("max_workers", "10") end)
      assert output =~ "max_workers set to 10"
      assert Config.get(:max_workers) == 10
    end

    test "sets known atom key" do
      output =
        ExUnit.CaptureIO.capture_io(fn -> ConfigCmd.set_config("default_policy", "retry") end)

      assert output =~ "default_policy set to retry"
      assert Config.get(:default_policy) == :retry
    end

    test "rejects invalid integer" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ConfigCmd.set_config("max_workers", "not_a_number")
        end)

      assert output =~ "Invalid max_workers"
    end

    test "rejects invalid atom" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ConfigCmd.set_config("default_policy", "invalid_policy")
        end)

      assert output =~ "Invalid default_policy"
    end

    test "rejects unknown key" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ConfigCmd.set_config("nonexistent_key", "value")
        end)

      assert output =~ "Unknown config key"
    end

    test "sets log_level" do
      output = ExUnit.CaptureIO.capture_io(fn -> ConfigCmd.set_config("log_level", "debug") end)
      assert output =~ "log_level set to debug"
      assert Config.get(:log_level) == :debug
    end

    test "rejects invalid log_level" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ConfigCmd.set_config("log_level", "trace")
        end)

      assert output =~ "Invalid log_level"
    end
  end

  describe "help/0" do
    test "prints help text" do
      output = ExUnit.CaptureIO.capture_io(fn -> ConfigCmd.help() end)
      assert output =~ "arrea config"
    end
  end
end
