defmodule Arrea.CLI.Commands.NodesTest do
  use ExUnit.Case

  alias Arrea.CLI.Commands.Nodes

  test "module exists and has execute/1" do
    Code.ensure_loaded(Nodes)
    assert function_exported?(Nodes, :execute, 1)
    assert Nodes.execute([]) == :ok
  end
end
