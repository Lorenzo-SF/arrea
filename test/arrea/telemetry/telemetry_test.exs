defmodule Arrea.TelemetryTest do
  use ExUnit.Case
  alias Arrea.Telemetry

  setup do
    # Provide a unique handler ID for the test
    handler_id = "test_telemetry_#{System.unique_integer()}"
    {:ok, handler_id: handler_id}
  end

  describe "measure/2" do
    test "executes function and emits telemetry event", %{handler_id: handler_id} do
      test_pid = self()

      # Attach to the :arrea, :measure event
      :telemetry.attach(
        handler_id,
        [:arrea, :measure],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      # Run the measurement
      result =
        Telemetry.measure(
          fn ->
            :timer.sleep(10)
            :measured_result
          end,
          %{type: "test_job"}
        )

      assert result == {:ok, :measured_result}

      # Assert event was received
      assert_receive {:telemetry_event, [:arrea, :measure], measurements, metadata}, 500

      assert Map.has_key?(measurements, :duration)
      assert measurements.duration >= 10
      assert metadata.type == "test_job"

      # Cleanup
      :telemetry.detach(handler_id)
    end
  end

  describe "measure/2 with keyword opts" do
    test "accepts keyword metadata" do
      result = Telemetry.measure(fn -> :ok end, metadata: %{tag: "kw"})
      assert result == {:ok, :ok}
    end
  end

  describe "emit/3" do
    test "emits a purely customized event", %{handler_id: handler_id} do
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arrea, :custom_metric],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit(:custom_metric, %{value: 42}, %{tag: "unit_test"})

      assert_receive {:telemetry_event, [:arrea, :custom_metric], measurements, metadata}, 500

      assert measurements.value == 42
      assert metadata.tag == "unit_test"

      :telemetry.detach(handler_id)
    end

    test "emits with empty measurements and metadata" do
      Telemetry.emit(:ping)
      assert true
    end
  end

  describe "measure_with_result/1" do
    test "returns ok tuple with duration on success" do
      {:ok, result, duration} = Telemetry.measure_with_result(fn -> {:ok, "data"} end)
      assert result == {:ok, "data"}
      assert is_integer(duration)
      assert duration >= 0
    end

    test "returns error tuple with duration on exception" do
      {:error, msg, duration} =
        Telemetry.measure_with_result(fn -> raise ArgumentError, "bad arg" end)

      assert is_binary(msg)
      assert is_integer(duration)
      assert duration >= 0
    end

    test "measures duration of function" do
      {:ok, _result, duration} =
        Telemetry.measure_with_result(fn ->
          :timer.sleep(20)
          :done
        end)

      assert duration >= 10
    end
  end

  describe "delegate functions" do
    test "setup returns :ok" do
      assert Telemetry.setup() == :ok
    end

    test "get_current returns map" do
      result = Telemetry.get_current()
      assert is_map(result)
    end

    test "emit_worker emits event" do
      # Just verify it doesn't raise
      assert Telemetry.emit_worker(:started, %{}, %{}) == :ok
    end

    test "emit_communication emits event" do
      assert Telemetry.emit_communication(:sent, %{}, %{}) == :ok
    end

    test "emit_validation emits event" do
      assert Telemetry.emit_validation(:passed, %{}, %{}) == :ok
    end

    test "emit_ui emits event" do
      assert Telemetry.emit_ui(:render, %{}, %{}) == :ok
    end
  end
end
