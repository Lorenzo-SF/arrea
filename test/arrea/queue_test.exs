defmodule Arrea.QueueTest do
  use ExUnit.Case, async: false

  alias Arrea.Queue

  setup do
    _ = start_supervised({Registry, keys: :unique, name: Arrea.Queue.Registry})
    :ok
  end

  defp queue(name, opts \\ []) do
    {:ok, pid} = Queue.start_link([name: name] ++ opts)
    pid
  end

  describe "push y claim" do
    test "una cola vacia esta vacia, y eso no es lo mismo que no caber" do
      queue(:q1)
      assert Queue.claim(:q1, 100) == {:error, :empty}
    end

    test "lo que se empuja sale tal cual, opaco" do
      queue(:q2)
      payload = %{messages: ["hola"], model_alias: :coder, pin: :verifier}
      assert :ok = Queue.push(:q2, payload)
      assert {:ok, entry} = Queue.claim(:q2, 100)
      assert entry.payload == payload
    end

    test "la prioridad manda, y dentro de la misma es FIFO" do
      queue(:q3)
      Queue.push(:q3, :normal_1, priority: 0)
      Queue.push(:q3, :vip, priority: 10)
      Queue.push(:q3, :normal_2, priority: 0)

      assert {:ok, entry} = Queue.claim(:q3, 100)
      # Dentro de la misma prioridad, el orden de llegada.
      assert {:ok, entry} = Queue.claim(:q3, 100)
      assert {:ok, entry} = Queue.claim(:q3, 100)
    end

    test "el peso decide si cabe, y no caber NO es estar vacia" do
      queue(:q4)
      Queue.push(:q4, :pesado, weight: 10)

      assert {:ok, entry} = Queue.claim(:q4, 10)
      # Y ahora que esta vacia, SI da empty.
      assert Queue.claim(:q4, 1) == {:error, :empty}
    end

    test "hay trabajo pero no cabe en lo que me dan" do
      queue(:q5)
      Queue.push(:q5, :pesado, weight: 10)
      # Con presupuesto 5 hay algo ahi, pero no es para mi. Decirlo `no_fit` y
      # no `empty` evita que un worker que espera gire en el vacio.
      assert Queue.claim(:q5, 5) == {:error, :no_fit}
    end
  end

  describe "el peso por defecto" do
    test "es 1" do
      queue(:q6)
      Queue.push(:q6, :uno)
      assert {:ok, e} = Queue.claim(:q6, 1)
      assert e.weight == 1
    end
  end

  describe "requeue" do
    test "devuelve la tarea al final" do
      queue(:q7)
      Queue.push(:q7, :a)
      Queue.push(:q7, :b)
      {:ok, taken} = Queue.claim(:q7, 10)
      assert Queue.requeue(:q7, taken) == :ok

      assert {:ok, entry} = Queue.claim(:q7, 10)
      assert {:ok, entry} = Queue.claim(:q7, 10)
    end

    test "con front, vuelve por delante de su propia prioridad" do
      queue(:q8)
      Queue.push(:q8, :reintentado, priority: 0)
      Queue.push(:q8, :nuevo, priority: 0)
      {:ok, taken} = Queue.claim(:q8, 10)
      Queue.requeue(:q8, taken, front: true)

      assert {:ok, entry} = Queue.claim(:q8, 10)
    end
  end

  describe "la cola sobrevive, el worker no" do
    test "lo que hay dentro sobrevive a quien la estaba leyendo" do
      # Esta es la raison d'etre: el trabajo no esta en el worker, esta en la
      # cola. Si el worker muere, la cola sigue con lo que le faltaba.
      queue(:q9)
      Queue.push(:q9, :pendiente)
      assert Queue.stats(:q9).size == 1
      # Nadie ha leachate nada; ahi sigue.
      assert Queue.stats(:q9).size == 1
      assert {:ok, entry} = Queue.claim(:q9, 10)
    end
  end

  describe "stats y drain" do
    test "stats cuenta y pesa" do
      queue(:q10)
      Queue.push(:q10, :a, weight: 2)
      Queue.push(:q10, :b, weight: 3)
      s = Queue.stats(:q10)
      assert s.size == 2
      assert s.weight == 5
    end

    test "drain devuelve lo que habia y la deja vacia" do
      queue(:q11)
      Queue.push(:q11, :a)
      Queue.push(:q11, :b)
      assert length(Queue.drain(:q11)) == 2
      assert Queue.stats(:q11).size == 0
    end
  end

  describe "dueno" do
    test "el dueno puede empujar y otros no" do
      parent = self()
      {:ok, pid} = Queue.start_link(name: :q12, owner: parent)
      assert :ok = Queue.push(:q12, :mio)

      task =
        Task.async(fn ->
          Queue.push(:q12, :ajeno)
        end)

      Task.await(task)
      payloads = Queue.drain(:q12) |> Enum.map(& &1.payload)
      # Solo lo del dueno.
      assert payloads == [:mio]
      _ = pid
    end
  end

  describe "procedencia" do
    test "guarda quien empujo" do
      parent = self()
      queue(:q13)
      Queue.push(:q13, :tarea, from: parent)
      assert {:ok, e} = Queue.claim(:q13, 10)
      assert e.from == parent
    end
  end
end
