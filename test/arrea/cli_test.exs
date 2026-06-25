defmodule Arrea.CLITest do
  use ExUnit.Case, async: false

  alias Arrea.CLI.Definition

  describe "Arrea.CLI module" do
    test "main/1 delegates to Arrea.CLI.Definition.main/1" do
      output = ExUnit.CaptureIO.capture_io(:stderr, fn -> Arrea.CLI.main([]) end)
      assert output =~ "run"
    end
  end

  describe "self hosted CLI Definition" do
    test "__commands__/0 returns run, config, action" do
      commands = Definition.__commands__()
      names = Enum.map(commands, & &1.name)

      assert "run" in names
      assert "config" in names
      assert "action" in names
    end

    test "run command has the expected flags" do
      [run] = Enum.filter(Definition.__commands__(), &(&1.name == "run"))
      flag_names = Enum.map(run.flags, & &1.name)

      assert :command in flag_names
      assert :parallel in flag_names
      assert :timeout in flag_names
      assert :quiet in flag_names
      assert :shell in flag_names
    end

    test "config command has --show flag" do
      [config] = Enum.filter(Definition.__commands__(), &(&1.name == "config"))
      flag_names = Enum.map(config.flags, & &1.name)
      assert :show in flag_names
    end

    test "action command has --file, --data, --stdin flags" do
      [action] = Enum.filter(Definition.__commands__(), &(&1.name == "action"))
      flag_names = Enum.map(action.flags, & &1.name)

      assert :file in flag_names
      assert :data in flag_names
      assert :stdin in flag_names
    end

    test "main/1 routes config --help" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Definition.main(["config", "--help"])
        end)

      assert output =~ "config"
    end

    test "main/1 routes action --help" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Definition.main(["action", "--help"])
        end)

      assert output =~ "action"
    end

    test "main/1 with no command shows help" do
      output = ExUnit.CaptureIO.capture_io(:stderr, fn -> Definition.main([]) end)
      assert output =~ "run"
    end
  end
end
