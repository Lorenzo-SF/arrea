defmodule Arrea.CLI.VerifyTest do
  use ExUnit.Case, async: false

  alias Arrea.CLI.Verify

  describe "runtime_opts/1 (no-halt variant)" do
    test "accepts empty options" do
      assert Verify.runtime_opts(%{}) == :ok
    end

    test "ignores non-runtime options" do
      assert Verify.runtime_opts(%{some_option: "value"}) == :ok
    end

    test "returns :ok when no asdf/mise keys present" do
      assert Verify.runtime_opts(%{command: "ls"}) == :ok
    end
  end

  describe "runtime_opts!/1 (backwards-compatible)" do
    test "function exists with correct arity" do
      assert function_exported?(Verify, :runtime_opts!, 1)
    end

    test "accepts empty options" do
      assert Verify.runtime_opts!(%{}) == :ok
    end
  end
end
