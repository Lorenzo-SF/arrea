defmodule Arrea.Validation.ValidatorTest do
  use ExUnit.Case
  alias Arrea.Validation.Validator

  describe "validate_command/1" do
    test "accepts safe commands" do
      assert Validator.validate_command("ls -la") == {:ok, "ls -la"}
      assert Validator.validate_command("echo hello") == {:ok, "echo hello"}
      assert Validator.validate_command("mix test") == {:ok, "mix test"}

      assert Validator.validate_command("cat file.txt | grep foo") ==
               {:ok, "cat file.txt | grep foo"}
    end

    test "rejects empty or nil commands" do
      assert Validator.validate_command("") == {:error, :empty_command}
      assert Validator.validate_command(nil) == {:error, :invalid_command_type}
      assert Validator.validate_command("   ") == {:error, :empty_command}
    end

    test "rejects excessively long commands" do
      long_cmd = String.duplicate("a", 5000)
      assert Validator.validate_command(long_cmd) == {:error, :command_too_long}
    end

    test "rejects shell injection patterns" do
      assert Validator.validate_command("echo $(rm -rf /)") == {:error, :possible_injection}
      assert Validator.validate_command("ls `pwd`") == {:error, :possible_injection}
    end

    test "rejects dangerous commands" do
      assert Validator.validate_command("sudo rm -rf /") ==
               {:error, {:dangerous_command, "rm -rf"}}

      assert Validator.validate_command("rm -rf node_modules") ==
               {:error, {:dangerous_command, "rm -rf"}}

      assert Validator.validate_command("mkfs.ext4 /dev/sda") ==
               {:error, {:dangerous_command, "mkfs"}}

      assert Validator.validate_command("chmod -R 777 /var/www") ==
               {:error, {:dangerous_command, "chmod -r 777"}}

      assert Validator.validate_command("chown root:root /") ==
               {:error, {:dangerous_command, "chown "}}

      assert Validator.validate_command("dd if=/dev/zero of=/dev/sda") ==
               {:error, {:dangerous_command, "dd if="}}
    end
  end

  describe "validate_commands/1" do
    test "returns ok for a list of safe commands" do
      cmds = ["echo a", "ls", "pwd"]
      assert Validator.validate_commands(cmds) == {:ok, cmds}
    end

    test "returns all errors for invalid commands" do
      invalid = ["rm -rf /", "sudo su", "echo hello"]
      assert {:error, errors} = Validator.validate_commands(invalid)
      assert {0, {:dangerous_command, "rm -rf"}} in errors
      assert {1, {:dangerous_command, "sudo "}} in errors
      assert not Enum.any?(errors, fn {idx, _} -> idx == 2 end)
    end
  end

  describe "validate_worker_spec/1" do
    test "accepts valid worker specs" do
      spec = [
        tasks: [fn -> :ok end],
        timeout: 5000,
        max_retries: 2
      ]

      assert {:ok, _} = Validator.validate_worker_spec(spec)
    end

    test "validates nested command" do
      spec = [tasks: [fn -> :ok end, "rm -rf /"]]
      assert Validator.validate_worker_spec(spec) == {:error, :invalid_tasks}
    end

    test "validates timeout boundaries" do
      assert Validator.validate_worker_spec(tasks: [], timeout: 0) == {:error, :invalid_timeout}

      assert Validator.validate_worker_spec(tasks: [], timeout: 10_000_000) ==
               {:error, :invalid_timeout}
    end

    test "validates retry boundaries" do
      assert Validator.validate_worker_spec(tasks: [], max_retries: 50) ==
               {:ok, [tasks: [], max_retries: 50]}

      assert Validator.validate_worker_spec(tasks: [], max_retries: -1) ==
               {:error, :invalid_retry_count}

      assert Validator.validate_worker_spec(tasks: [], max_retries: 250) ==
               {:error, :invalid_retry_count}
    end
  end

  describe "validate_shell/1" do
    test "rejects unsupported shells" do
      assert Validator.validate_shell("cmd.exe") == {:error, {:disallowed_shell, "cmd.exe"}}
      assert Validator.validate_shell("powershell") == {:error, {:disallowed_shell, "powershell"}}
    end
  end
end
