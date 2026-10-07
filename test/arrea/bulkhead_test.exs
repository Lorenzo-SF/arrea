defmodule Arrea.BulkheadTest do
  use ExUnit.Case

  alias Arrea.Bulkhead

  @max_concurrent 2

  setup do
    test_id = :bulkhead_test

    _ = start_supervised({Registry, keys: :unique, name: Arrea.Bulkhead.Registry})

    case Registry.lookup(Arrea.Bulkhead.Registry, test_id) do
      [{existing_pid, _}] ->
        Process.exit(existing_pid, :kill)
        :timer.sleep(10)

      [] ->
        :ok
    end

    {:ok, pid} = Bulkhead.start_link(test_id, @max_concurrent)
    %{pid: pid, test_id: test_id}
  end

  test "runs a function when a slot is available", %{test_id: test_id} do
    assert {:ok, :done} = Bulkhead.run(test_id, fn -> :done end)
    assert Bulkhead.available(test_id) == @max_concurrent
  end

  test "rejects the call above max_concurrent (no queueing)", %{test_id: test_id} do
    parent = self()
    started = :bulkhead_slot_taken

    tasks =
      for i <- 1..@max_concurrent do
        Task.async(fn ->
          Bulkhead.run(test_id, fn ->
            send(parent, {started, i})

            receive do
              {:release_slot, ^i} -> :finished
            after
              2_000 -> :timed_out
            end
          end)
        end)
      end

    for i <- 1..@max_concurrent do
      assert_receive {^started, ^i}, 1_000
    end

    assert Bulkhead.available(test_id) == 0
    assert Bulkhead.run(test_id, fn -> :third end) == {:error, :bulkhead_full}

    for {task, i} <- Enum.with_index(tasks, 1) do
      send(task.pid, {:release_slot, i})
      assert Task.await(task, 1_000) == {:ok, :finished}
    end

    assert Bulkhead.available(test_id) == @max_concurrent
  end

  test "releases the slot even when the function raises", %{test_id: test_id} do
    assert {:error, :execution_failed} = Bulkhead.run(test_id, fn -> raise "boom" end)
    assert Bulkhead.available(test_id) == @max_concurrent
  end

  test "returns :bulkhead_not_found for an unknown bulkhead" do
    assert Bulkhead.run(:unknown_bulkhead, fn -> :nope end) == {:error, :bulkhead_not_found}
    assert Bulkhead.available(:unknown_bulkhead) == 0
    assert Bulkhead.status(:unknown_bulkhead) == nil
  end

  test "status reflects counters", %{test_id: test_id} do
    Bulkhead.run(test_id, fn -> :ok end)
    Bulkhead.run(test_id, fn -> :ok end)
    Bulkhead.run(test_id, fn -> :ok end)
    Bulkhead.run(test_id, fn -> :ok end)

    assert %{name: ^test_id, max_concurrent: 2, active: 0, accepted: 4, rejected: 0} =
             Bulkhead.status(test_id)
  end

  test "emits :rejected telemetry event with typed metadata" do
    test_id = :bulkhead_rejected
    {:ok, _} = Bulkhead.start_link(test_id, 1)
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "bulkhead-test-handler",
      [:arrea, :bulkhead, :rejected],
      fn _event, _measurements, metadata, ^ref -> send(parent, {:rejected, metadata}) end,
      ref
    )

    on_exit(fn -> :telemetry.detach("bulkhead-test-handler") end)

    task =
      Task.async(fn ->
        Bulkhead.run(test_id, fn ->
          send(parent, :held)

          receive do
            :go -> :done
          end
        end)
      end)

    assert_receive :held, 1_000
    assert {:error, :bulkhead_full} = Bulkhead.run(test_id, fn -> :nope end)

    assert_receive {:rejected, %{name: ^test_id, max_concurrent: 1, active: 1}}, 1_000

    send(task.pid, :go)
    Task.await(task, 1_000)
  end

  test "start_link rejects invalid max_concurrent with typed error" do
    assert {:error, %Arrea.Error{code: :invalid_config, message: msg}} =
             Bulkhead.start_link(:bad_bulkhead, 0)

    assert msg =~ "max_concurrent"

    assert {:error, %Arrea.Error{code: :invalid_config}} =
             Bulkhead.start_link(:bad_bulkhead, -3)
  end

  # ── Peso ────────────────────────────────────────────────────────────────────
  #
  # Un bulkhead de 4 donde todo pesa 1 ES un bulkhead ponderado con pesos de 1.
  # Por eso los tests de arriba NO se tocan: si .run/2 sigue funcionando sin
  # opciones, la generalizacion es compatible hacia atras.
  #
  # Y `run/3` es una reserva CON ALCANCE: ocupa mientras corre la funcion y
  # suelta al terminar. Por eso casi todos miran desde DENTRO. Un test que
  # mira despues ve siempre el bulkhead libre, que es exactamente lo que
  # hacia el primero que escribi.
  describe "peso" do
    setup do
      _ = start_supervised({Registry, keys: :unique, name: Arrea.Bulkhead.Registry})
      :ok
    end

    defp bulk(name), do: Bulkhead.start_link(name, 4)

    test "el peso por defecto de 1 se comporta como antes" do
      {:ok, _} = bulk(:w_default)
      parent = self()

      assert {:ok, 3} =
               Bulkhead.run(:w_default, fn ->
                 send(parent, {:inside, Bulkhead.available(:w_default)})
                 3
               end)

      assert_receive {:inside, 3}
    end

    test "durante la llamada el peso esta ocupado" do
      {:ok, _} = bulk(:w_used)
      parent = self()

      assert {:ok, :done} =
               Bulkhead.run(
                 :w_used,
                 fn ->
                   send(parent, {:inside, Bulkhead.available(:w_used)})
                   :done
                 end,
                 weight: 3
               )

      # 4 - 3 = 1 libre mientras el modelo esta cargado.
      assert_receive {:inside, 1}
      # Y al terminar, todo libre otra vez.
      assert Bulkhead.available(:w_used) == 4
    end

    test "lo que no cabe se rechaza, y lo que cabe despues tambien" do
      {:ok, _} = bulk(:w_full)
      assert {:error, :bulkhead_full} = Bulkhead.run(:w_full, fn -> :nunca end, weight: 5)

      # Rechazar no gasta nada.
      assert Bulkhead.available(:w_full) == 4
      assert {:ok, :ok} = Bulkhead.run(:w_full, fn -> :ok end, weight: 4)
    end

    test "active es un contador y available son unidades" do
      {:ok, _} = bulk(:w_metrics)
      parent = self()

      Bulkhead.run(
        :w_metrics,
        fn ->
          send(parent, {:inside, Bulkhead.status(:w_metrics)})
        end,
        weight: 3
      )

      assert_receive {:inside, status}
      # Un modelo de "3" es UN titular, no tres.
      assert status.active == 1
      assert status.available == 1
      assert status.max_concurrent == 4
    end

    test "dos pesados a la vez llenan el bulkhead" do
      {:ok, _} = bulk(:w_two)
      parent = self()

      t1 =
        Task.async(fn ->
          Bulkhead.run(
            :w_two,
            fn ->
              send(parent, :uno)
              Process.sleep(150)
              :ok
            end,
            weight: 2
          )
        end)

      receive do: (:uno -> :ok)

      t2 =
        Task.async(fn ->
          Bulkhead.run(
            :w_two,
            fn ->
              send(parent, :dos)
              Process.sleep(150)
              :ok
            end,
            weight: 2
          )
        end)

      receive do: (:dos -> :ok)

      # 2 + 2 = 4 ocupados. Sin await: t2 SIGUE ocupando.
      assert Bulkhead.run(:w_two, fn -> :nunca end, weight: 1) == {:error, :bulkhead_full}

      Task.await(t1)
      Task.await(t2)
      assert Bulkhead.available(:w_two) == 4
    end
  end
end
