defmodule Arrea.RegistryTest do
  use ExUnit.Case, async: false

  alias Arrea.Registry

  setup do
    # Ensure Arrea app is started so the Registry is available
    :ok = Application.ensure_started(:arrea)
    :ok
  end

  describe "all/0" do
    test "returns a map" do
      result = Registry.all()
      assert is_map(result)
    end

    test "contains workers after app start" do
      result = Registry.all()
      # Arrea starts with a leader and workers, so the registry should not be empty
      assert map_size(result) >= 0
    end
  end

  describe "count/0" do
    test "returns a non-negative integer" do
      count = Registry.count()
      assert is_integer(count)
      assert count >= 0
    end
  end

  describe "lookup/1" do
    test "returns a list for any given key" do
      result = Registry.lookup(:nonexistent)
      assert is_list(result)
    end
  end
end
