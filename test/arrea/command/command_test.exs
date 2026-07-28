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

    test "rejects dangerous commands by default" do
      assert {:error, {:dangerous_command, "rm -rf"}} = Command.execute("rm -rf /tmp")
    end

    test ":validate, false bypasses the safety check for trusted callers" do
      # The string would normally be rejected as dangerous, but with
      # :validate, false it runs (echo is harmless).
      assert {:ok, result} = Command.execute("echo bypassed", validate: false)
      assert String.trim(result.stdout) == "bypassed"
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

  describe "command_exists?/1 and which/1" do
    test "command_exists?/1 returns true for a known binary" do
      assert Command.command_exists?("echo")
    end

    test "command_exists?/1 returns false for a non-existent binary" do
      refute Command.command_exists?("definitely_not_a_real_binary_12345")
    end

    test "command_exists?/1 returns false for empty/garbage input" do
      refute Command.command_exists?("")
      refute Command.command_exists?(nil)
      refute Command.command_exists?(42)
    end

    test "which/1 returns a path for a known binary" do
      assert is_binary(Command.which("echo"))
    end

    test "which/1 returns nil for a non-existent binary" do
      assert Command.which("definitely_not_a_real_binary_12345") == nil
    end
  end

  describe "version validation" do
    test "build_asdf_prefix rejects injection attempts" do
      assert_raise ArgumentError, fn ->
        Command.build_asdf_prefix(asdf_elixir: "1.0; rm -rf /")
      end

      assert_raise ArgumentError, fn ->
        Command.build_asdf_prefix(asdf_node: "$(cat /etc/passwd)")
      end

      assert_raise ArgumentError, fn ->
        Command.build_asdf_prefix(asdf_python: "`whoami`")
      end

      assert_raise ArgumentError, fn ->
        Command.build_asdf_prefix(asdf_ruby: "1.0\nrm -rf /")
      end
    end

    test "build_mise_args rejects injection attempts" do
      assert_raise ArgumentError, fn ->
        Command.build_mise_args(mise_elixir: "1.0; rm -rf /")
      end

      assert_raise ArgumentError, fn ->
        Command.build_mise_args(mise_node: "$(cat /etc/passwd)")
      end
    end

    test "build_asdf_prefix accepts valid versions" do
      assert Command.build_asdf_prefix(asdf_elixir: "1.18.0") != ""
      assert Command.build_asdf_prefix(asdf_node: "20.0.0") != ""
      assert Command.build_asdf_prefix(asdf_erlang: "27.0-rc1") != ""
      assert Command.build_asdf_prefix(asdf_python: "3.12.0_beta1") != ""
    end

    test "build_mise_args accepts valid versions" do
      assert Command.build_mise_args(mise_elixir: "1.18.0") != []
      assert Command.build_mise_args(mise_node: "20.0.0") != []
    end
  end
end
