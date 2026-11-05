defmodule Arrea.WorkerServesQueuesTest do
  use ExUnit.Case, async: false

  alias Arrea.Queue
  alias Arrea.Worker

  setup do
    _ = start_supervised({Registry, keys: :unique, name: Arrea.Queue.Registry})
    _ = start_supervised({Registry, keys: :unique, name: Arrea.Bulkhead.Registry})

    if Process.whereis(Arrea.Monitor) == nil do
      start_supervised!(Arrea.Monitor)
    end

    :ok
  end

  defp queue(name, opts \\ []), do: Queue.start_link([name: name] ++ opts)

  defp serve(id, queues, opts \\ []) do
    {:ok, pid} = Worker.start_link([id: id, queues: queues, poll_interval: 10] ++ opts)
    pid
  end

  describe "un worker que sirve colas" do
    test "toma lo que se empuja y avisa a quien lo empujo" do
      queue(:wq1)
      parent = self()
      serve(:worker_a, [:wq1])

      Queue.push(:wq1, :trabajo, from: parent)
      assert_receive {:arrea_queue, :claimed, :wq1, %{payload: :trabajo}}, 2_000
    end

    test "lo que no entra en el presupuesto no lo saca de la cola" do
      queue(:wq2)
      parent = self()

      # Presupuesto 5, y lo que hay pesa 10.
      serve(:worker_b, [:wq2], budget: 5)
      Queue.push(:wq2, :pesado, weight: 10, from: parent)

      refute_receive {:arrea_queue, :claimed, :wq2, _}, 200

      # Y sigue ahi para otro con hueco.
      assert Queue.stats(:wq2).size == 1
    end

    test "de varias colas, elige la de mayor prioridad que le quepa" do
      queue(:wq3a)
      queue(:wq3b)
      parent = self()

      serve(:worker_c, [:wq3a, :wq3b], budget: 10)

      Queue.push(:wq3a, :baja, priority: 1, weight: 5, from: parent)
      Queue.push(:wq3b, :alta, priority: 9, weight: 5, from: parent)

      assert_receive {:arrea_queue, :claimed, :wq3b, %{payload: :alta}}, 2_000
    end

    test "una cola ligera no queda bloqueada detras de una pesada de otra" do
      # Este es el motivo de recorrer en ORDEN y parar en la primera que vale,
      # en vez de mirar la maxima prioridad global: si solo mirase la global, la
      # ligera de wq4a esperaria a la pesada de wq4b que no cabe.
      queue(:wq4a)
      queue(:wq4b)
      parent = self()

      serve(:worker_d, [:wq4a, :wq4b], budget: 5)

      Queue.push(:wq4b, :no_cabe, priority: 9, weight: 9, from: parent)
      Queue.push(:wq4a, :cabe, priority: 1, weight: 5, from: parent)

      assert_receive {:arrea_queue, :claimed, :wq4a, %{payload: :cabe}}, 2_000
    end

    test "un worker parado NO se lleva el trabajo" do
      # La razon de ser de la cola. El trabajo esta en la cola, no en el
      # worker, asi que quien el que muere no pierde nada.
      queue(:wq5)
      parent = self()
      pid = serve(:worker_e, [:wq5])

      Queue.push(:wq5, :pendiente, from: parent)
      # Le da tiempo a tomar el primero y se para.
      assert_receive {:arrea_queue, :claimed, :wq5, %{payload: :pendiente}}, 2_000

      Queue.push(:wq5, :segundo, from: parent)
      :ok = Worker.stop(:worker_e)

      # El segundo sigue ahi. El worker se fue; la cola no.
      assert Queue.stats(:wq5).size == 1
      assert {:ok, e} = Queue.claim(:wq5, 100)
      assert e.payload == :segundo
      _ = pid
    end

    test "el worker espera en vez de morirse cuando no hay nada" do
      queue(:wq6)
      serve(:worker_f, [:wq6])

      # Varios ciclos de poll: si el worker se parase al quedarse sin trabajo,
      # tras un par de vueltas habria desaparecido del registro.
      Process.sleep(400)

      assert [{pid, _}] = Registry.lookup(Arrea.Registry, :worker_f)
      assert Process.alive?(pid)

      # Y ademas sigue EN SUS DIAS: empujarle algo despues funciona.
      parent = self()
      Queue.push(:wq6, :tarde, from: parent)
      assert_receive {:arrea_queue, :claimed, :wq6, %{payload: :tarde}}, 2_000
    end
  end
end
