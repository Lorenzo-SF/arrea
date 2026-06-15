defmodule Arrea.ErrorTest do
  use ExUnit.Case, async: true

  alias Arrea.Error

  describe "struct" do
    test "has a code and message" do
      error = %Error{code: :timeout, message: "took too long"}
      assert error.code == :timeout
      assert error.message == "took too long"
    end

    test "defaults to nil fields" do
      error = %Error{}
      assert error.code == nil
      assert error.message == nil
    end
  end
end
