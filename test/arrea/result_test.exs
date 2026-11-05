defmodule Arrea.ResultTest do
  use ExUnit.Case, async: true

  alias Arrea.Result

  describe "struct" do
    test "default fields" do
      result = %Result{}
      assert result.success == nil
      assert result.data == nil
      assert result.failures == nil
    end

    test "builds a success result" do
      result = %Result{success: true, data: "file.txt", failures: []}
      assert result.success == true
      assert result.data == "file.txt"
      assert result.failures == []
    end
  end
end
