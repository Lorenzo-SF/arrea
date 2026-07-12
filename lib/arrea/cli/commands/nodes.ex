defmodule Arrea.CLI.Commands.Nodes do
  @moduledoc """
  `arrea nodes` command – list the dynamic workers registered
  in the Arrea Registry.
  """

  alias Alaja.Components.{Header, Separator, Table}
  alias Arrea.Registry

  @doc false
  def execute(_opts) do
    workers = Registry.all()
    rows =
      workers
      |> Enum.map(fn {name, pid} -> [Atom.to_string(name), inspect(pid)] end)

    IO.puts("")
    Header.print("Registered Workers", subtitle: "#{map_size(workers)} workers", size: :small)
    IO.puts("")
    Table.print(
      headers: ["Name", "PID"],
      rows: rows,
      table_border: :rounded,
      padding: 1
    )
    IO.puts("")
  end

  @doc false
  def help do
    Header.print("Arrea Nodes", subtitle: "List dynamic workers", size: :small)
    IO.puts("")
    Separator.print("USAGE", char: "━", width: 50, color: {0, 180, 216})
    IO.puts("  arrea nodes")
    IO.puts("")
  end
end
