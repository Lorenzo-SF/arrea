defmodule Arrea.CommandTest do
  use ExUnit.Case

  alias Arrea.Command

  setup_all do
    File.write!("#{System.get_env("HOME")}/.profile", "")
    on_exit(fn -> File.rm("#{System.get_env("HOME")}/.profile") end)
  end

  describe "execute/2" do
    test "successfully executes a command" do
      assert {:ok, result} = Command.execute("echo 'hello'", shell: "sh")

      cleaned =
        result.stdout
        |> String.split("\n")
        |> Enum.reject(&(String.contains?(&1, ".profile") or String.contains?(&1, "No existe")))
        |> Enum.join("\n")

      assert String.trim(cleaned) == "hello"
      assert result.exit_code == 0
      assert result.duration_ms >= 0
    end

    test "handles execution error gracefully" do
      # Using invalid command should return a validation error or shell error
      result = Command.execute("some_command_that_does_not_exist_at_all 2>/dev/null")
      # Bash will return exit_code 127
      assert {:ok, res} = result
      assert res.exit_code == 127
    end

    test "applies timeout properly" do
      # Note: Exact timeout testing with shell can be brittle,
      # but timeout: 0 should always trigger timeout
      assert {:error, :timeout} = Command.execute("sleep 0.1", timeout: 0)
    end

    test "accepts environment properties and passes them to shell" do
      assert {:ok, result} =
               Command.execute("echo $ZAGUAN_TEST_VAR", env: %{"ZAGUAN_TEST_VAR" => "foo"})

      assert String.trim(result.stdout) == "foo"
    end
  end

  describe "execute_with_asdf/4" do
    test "prepends ASDF variables" do
      assert {:ok, result} =
               Command.execute_with_asdf("echo $ASDF_ELIXIR_VERSION", :elixir, "1.18.0")

      assert String.trim(result.stdout) == "1.18.0"
    end
  end

  describe "parse_result/1" do
    test "parses 0 as :ok" do
      assert {:ok, _} = Command.parse_result(%{exit_code: 0, stdout: "", duration_ms: 10})
    end

    test "parses non-zero as error" do
      assert {:error, {:exit_code, 1}} =
               Command.parse_result(%{exit_code: 1, stdout: "", duration_ms: 10})
    end
  end
end
