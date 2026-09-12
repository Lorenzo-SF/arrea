defmodule Arrea.Command.ExecuteStreamTest do
  @moduledoc """
  Tests for Arrea.Command.execute_stream/3 (iter-039).
  """
  use ExUnit.Case, async: true

  alias Arrea.Command

  test "execute_stream/3 streams stdout lines" do
    {:ok, 0} = Command.execute_stream("echo hello; echo world", fn _ -> :ok end)
  end

  test "execute_stream/3 captures output via callback" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, 0} =
      Command.execute_stream(
        "echo line1; echo line2",
        fn {:stdout, line} -> Agent.update(agent, &[line | &1]) end
      )

    lines = Agent.get(agent, &Enum.reverse/1)

    # Each line should appear at least once.
    joined = Enum.join(lines, "\n")
    assert joined =~ "line1"
    assert joined =~ "line2"

    Agent.stop(agent)
  end

  test "execute_stream/3 returns non-zero exit code" do
    {:ok, code} = Command.execute_stream("exit 7", fn _ -> :ok end)
    assert code == 7
  end

  test "execute_stream/3 propagates non-zero exit" do
    assert {:ok, 1} = Command.execute_stream("false", fn _ -> :ok end)
  end

  test "execute_stream/3 returns error for empty command" do
    assert {:error, _} = Command.execute_stream("", fn _ -> :ok end)
  end
end
