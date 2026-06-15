defmodule Arrea.Telemetry.DebugHandlerTest do
  use ExUnit.Case

  alias Arrea.Telemetry.DebugHandler

  describe "attach/0" do
    test "attaches debug handler returns :ok" do
      assert DebugHandler.attach() == :ok
      DebugHandler.detach()
    end
  end

  describe "detach/0" do
    test "detaches debug handler returns :ok" do
      DebugHandler.attach()
      assert DebugHandler.detach() == :ok
    end

    test "detach succeeds even when not attached" do
      assert DebugHandler.detach() == :ok
    end
  end

  describe "handle_event/4" do
    test "handles event and returns :ok" do
      assert DebugHandler.handle_event([:arrea, :test], %{}, %{}, nil) == :ok
    end

    test "handles event with measurements and metadata" do
      measurements = %{duration: 100, memory: 1024}
      metadata = %{worker_id: :test_worker, status: :completed}

      assert DebugHandler.handle_event(
               [:arrea, :worker, :completed],
               measurements,
               metadata,
               nil
             ) == :ok
    end

    test "handles nested event names" do
      assert DebugHandler.handle_event([:arrea, :ui, :render, :slow], %{}, %{}, nil) == :ok
    end
  end

  describe "format_event_name (private)" do
    test "formats event name with dots" do
      # Testing through handle_event which uses format_event_name internally
      # The format is "arrea.worker.completed"
      event_name = [:arrea, :worker, :completed]
      measurements = %{}
      metadata = %{}
      # Should not raise and return :ok
      assert DebugHandler.handle_event(event_name, measurements, metadata, nil) == :ok
    end
  end
end
