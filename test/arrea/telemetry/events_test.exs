defmodule Arrea.Telemetry.EventsTest do
  use ExUnit.Case

  alias Arrea.Telemetry.Events

  describe "worker events" do
    test "worker_started returns correct telemetry event" do
      assert Events.worker_started() == [:arrea, :worker, :started]
    end

    test "worker_completed returns correct telemetry event" do
      assert Events.worker_completed() == [:arrea, :worker, :completed]
    end

    test "worker_error returns correct telemetry event" do
      assert Events.worker_error() == [:arrea, :worker, :error]
    end

    test "worker_message returns correct telemetry event" do
      assert Events.worker_message() == [:arrea, :worker, :message]
    end
  end

  describe "task events" do
    test "task_started returns correct telemetry event" do
      assert Events.task_started() == [:arrea, :task, :started]
    end

    test "task_completed returns correct telemetry event" do
      assert Events.task_completed() == [:arrea, :task, :completed]
    end

    test "task_error returns correct telemetry event" do
      assert Events.task_error() == [:arrea, :task, :error]
    end
  end

  describe "communication events" do
    test "communication_message_sent returns correct telemetry event" do
      assert Events.communication_message_sent() == [:arrea, :communication, :message_sent]
    end

    test "communication_message_received returns correct telemetry event" do
      assert Events.communication_message_received() == [
               :arrea,
               :communication,
               :message_received
             ]
    end

    test "communication_error returns correct telemetry event" do
      assert Events.communication_error() == [:arrea, :communication, :error]
    end

    test "communication_retry returns correct telemetry event" do
      assert Events.communication_retry() == [:arrea, :communication, :retry]
    end
  end

  describe "validation events" do
    test "validation_passed returns correct telemetry event" do
      assert Events.validation_passed() == [:arrea, :validation, :passed]
    end

    test "validation_failed returns correct telemetry event" do
      assert Events.validation_failed() == [:arrea, :validation, :failed]
    end
  end

  describe "execution events" do
    test "execution_started returns correct telemetry event" do
      assert Events.execution_started() == [:arrea, :execution, :started]
    end

    test "execution_completed returns correct telemetry event" do
      assert Events.execution_completed() == [:arrea, :execution, :completed]
    end

    test "execution_failed returns correct telemetry event" do
      assert Events.execution_failed() == [:arrea, :execution, :failed]
    end
  end

  describe "ui events" do
    test "ui_render returns correct telemetry event" do
      assert Events.ui_render() == [:arrea, :ui, :render]
    end

    test "ui_keypress returns correct telemetry event" do
      assert Events.ui_keypress() == [:arrea, :ui, :keypress]
    end

    test "ui_focus_change returns correct telemetry event" do
      assert Events.ui_focus_change() == [:arrea, :ui, :focus_change]
    end
  end

  describe "system events" do
    test "system_started returns correct telemetry event" do
      assert Events.system_started() == [:arrea, :system, :started]
    end

    test "system_stopped returns correct telemetry event" do
      assert Events.system_stopped() == [:arrea, :system, :stopped]
    end
  end

  describe "emit functions" do
    test "emit_worker returns :ok" do
      assert Events.emit_worker(:completed, %{duration: 100}, %{worker_id: :test}) == :ok
    end

    test "emit_communication returns :ok" do
      assert Events.emit_communication(:sent, %{bytes: 1024}, %{dest: :node}) == :ok
    end

    test "emit_validation returns :ok" do
      assert Events.emit_validation(:passed, %{}, %{rule: :unique}) == :ok
    end

    test "emit_ui returns :ok" do
      assert Events.emit_ui(:render, %{ms: 5}, %{component: :status_bar}) == :ok
    end
  end
end
