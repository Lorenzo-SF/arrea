defmodule Arrea.LongRunningTest do
  use ExUnit.Case

  alias Arrea.LongRunning, as: LR

  # These tests spawn real OS processes via Port.open. Each uses a small,
  # harmless binary that exists on every POSIX system and exits cleanly.
  @binary "/bin/cat"

  setup_all do
    # LongRunning depends on Arrea.Registry and Arrea.WorkerSupervisor;
    # some other test files may stop the application between cases, so
    # we ensure it's running for every test in this file.
    {:ok, _} = Application.ensure_all_started(:arrea)
    :ok
  end

  describe "start_link/1" do
    test "starts and registers a long-running process" do
      {:ok, pid} = LR.start_link(id: :test_lr_1, binary: @binary, args: [])

      assert Process.alive?(pid)
      assert {:ok, _} = LR.state(:test_lr_1)

      :ok = LR.stop(:test_lr_1)
    end

    test "stop/1 closes the port and unregisters" do
      {:ok, _pid} = LR.start_link(id: :test_lr_2, binary: @binary, args: [])
      assert :ok = LR.stop(:test_lr_2)
      assert LR.state(:test_lr_2) == {:error, :not_found}
    end

    test "state/1 returns a snapshot with id, binary, running flag" do
      {:ok, _} = LR.start_link(id: :test_lr_3, binary: @binary, args: [])

      {:ok, snapshot} = LR.state(:test_lr_3)

      assert snapshot.id == :test_lr_3
      assert snapshot.binary == @binary
      assert snapshot.running == true
      assert snapshot.uptime_ms >= 0
      assert is_integer(snapshot.buffer_size)

      :ok = LR.stop(:test_lr_3)
    end
  end

  describe "health/1" do
    test "returns :ok when health probe is not configured" do
      {:ok, _} = LR.start_link(id: :test_lr_health, binary: @binary, args: [])
      assert :ok = LR.health(:test_lr_health)
      :ok = LR.stop(:test_lr_health)
    end

    test "returns :ok when probe returns truthy" do
      {:ok, _} =
        LR.start_link(
          id: :test_lr_health_ok,
          binary: @binary,
          health: fn -> true end
        )

      assert :ok = LR.health(:test_lr_health_ok)
      :ok = LR.stop(:test_lr_health_ok)
    end

    test "returns {:error, _} when probe returns falsy" do
      {:ok, _} =
        LR.start_link(
          id: :test_lr_health_bad,
          binary: @binary,
          health: fn -> false end
        )

      assert {:error, false} = LR.health(:test_lr_health_bad)
      :ok = LR.stop(:test_lr_health_bad)
    end

    test "returns :not_found for unknown id" do
      assert :not_found = LR.health(:nonexistent_id_xyz)
    end
  end

  describe "telemetry" do
    test "emits :started event with id and binary" do
      test_pid = self()

      :telemetry.attach(
        "test-started-handler",
        [:arrea, :long_running, :started],
        fn _event, _meas, meta, _config ->
          send(test_pid, {:telemetry_started, meta})
        end,
        nil
      )

      {:ok, _} = LR.start_link(id: :test_lr_telemetry, binary: @binary, args: [])

      assert_receive {:telemetry_started, meta}, 1_000
      assert meta.id == :test_lr_telemetry
      assert meta.binary == @binary

      :telemetry.detach("test-started-handler")
      :ok = LR.stop(:test_lr_telemetry)
    end
  end

  describe "exit handling" do
    test "GenServer terminates when stopped via stop/1" do
      {:ok, pid} =
        LR.start_link(
          id: :test_lr_exit,
          binary: @binary,
          args: []
        )

      ref = Process.monitor(pid)
      :ok = LR.stop(:test_lr_exit)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end
  end
end