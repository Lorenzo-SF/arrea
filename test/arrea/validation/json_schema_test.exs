defmodule Arrea.Validation.JsonSchemaTest do
  use ExUnit.Case

  alias Arrea.Validation.JsonSchema

  describe "validate/1" do
    test "accepts valid action with command field" do
      assert :ok = JsonSchema.validate(%{"command" => "show", "args" => ["success", "Hello"]})
    end

    test "accepts valid action with action field" do
      assert :ok = JsonSchema.validate(%{"action" => "show", "args" => ["success", "Hello"]})
    end

    test "accepts action without args" do
      assert :ok = JsonSchema.validate(%{"command" => "show"})
    end

    test "rejects missing command field" do
      assert {:error, msg} = JsonSchema.validate(%{})
      assert msg =~ "Missing"
    end

    test "rejects non-string command" do
      assert {:error, msg} = JsonSchema.validate(%{"command" => 123})
      assert msg =~ "string"
    end

    test "rejects non-object input" do
      assert {:error, msg} = JsonSchema.validate("not a map")
      assert msg =~ "object"
    end

    test "rejects non-list args" do
      assert {:error, msg} = JsonSchema.validate(%{"command" => "show", "args" => "not a list"})
      assert msg =~ "list of strings"
    end

    test "rejects args with non-string elements" do
      assert {:error, msg} =
               JsonSchema.validate(%{"command" => "show", "args" => ["valid", 123]})

      assert msg =~ "strings"
    end
  end
end
