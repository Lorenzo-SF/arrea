defmodule Arrea.CLI.Commands.RunTest do
  use ExUnit.Case, async: false

  alias Arrea.CLI.Commands.Run
  alias ExUnit.CaptureIO

  describe "help/0" do
    test "prints usage" do
      output = CaptureIO.capture_io(fn -> Run.help() end)
      assert output =~ "arrea run"
      assert output =~ "--command"
      assert output =~ "--parallel"
      assert output =~ "--timeout"
    end
  end
end
