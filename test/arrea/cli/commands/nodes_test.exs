defmodule Arrea.CLI.Commands.NodesTest do
  use ExUnit.Case

  alias Arrea.CLI.Commands.Nodes

  test "module exists and has execute/1" do
    assert Nodes.execute([]) == :ok
  end
end
