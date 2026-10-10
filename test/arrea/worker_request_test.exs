defmodule Arrea.WorkerRequestTest do
  @moduledoc """
  `Worker.request/4` — la peticion que SI tiene respuesta.

  `send_message/2` avisa y sigue, a proposito. Aqui lo que se prueba es la
  otra mitad: la pregunta y su respuesta.

  Cada test dice **que no puede ocurrir**, no solo que responde. Un
  `assert {:ok, x}` que pasaria igual con un `GenServer.call` no demuestra
  nada de este diseno; lo que lo demuestra es que la peticion:

  - se ejecuta DENTRO del worker, con su presupuesto y su prioridad;
  - no se queda esperando a que el que pregunto recoja la respuesta;
  - no se cuela por delante de la cola ni por detrás del presupuesto;
  - y distingue "no hay worker" de "el worker se ha ido mientras esperaba".
  """

  use ExUnit.Case, async: false

  alias Arrea.Queue
  alias Arrea.Worker

  setup do
    _ = start_supervised({Registry, keys: :unique, name: Arrea.Queue.Registry})
    _ = start_supervised({Registry, keys: :unique, name: Arrea.Bulkhead.Registry})

    if Process.whereis(Arrea.Registry) == nil do
      start_supervised!({Registry, keys: :unique, name: Arrea.Registry})
    end

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

  # `assert_receive` se salta lo que no coincide, asi que no vale para comprobar
  # un ORDEN: si `:normal` llegase antes que `:peticion`, el `assert_receive
  # :peticion` pasaria igual y la comprobacion no diria nada. Esto recoge las
  # etiquetas EN ORDEN y no las ordena despues.
  defp recoge_etiquetas(0, acc), do: Enum.reverse(acc)

  defp recoge_etiquetas(quedan, acc) do
    receive do
      {:orden, etiqueta} -> recoge_etiquetas(quedan - 1, [etiqueta | acc])
    after
      2_000 ->
        flunk("solo llegaron #{length(acc)} de las etiquetas que esperaba: #{inspect(acc)}")
    end
  end

  describe "la pregunta y su respuesta" do
    test "responde con lo que produjo el payload" do
      queue(:rq1)
      serve(:worker_rq1, [:rq1])

      assert {:ok, :hola} = Worker.request(:worker_rq1, :rq1, fn -> :hola end)
    end

    test "el payload se ejecuta DENTRO del worker, no en el que pregunta" do
      # Si esto pasara, la peticion seria un `Task` con el nombre de otra cosa:
      # el trabajo se haria fuera del presupuesto del worker, y el worker solo
      # miraria. El presupuesto y la prioridad de la cola son de este.
      queue(:rq2)
      pid = serve(:worker_rq2, [:rq2])
      parent = self()

      assert {:ok, :hecho} =
               Worker.request(:worker_rq2, :rq2, fn ->
                 send(parent, {:ejecutado_en, self()})
                 :hecho
               end)

      assert_receive {:ejecutado_en, ^pid}
    end

    test "el que espera puede marcharse y el worker NO se queda esperándole" do
      # Lo que NO puede pasar: que el worker se quede bloqueado hasta que el
      # que pregunto pase a por la respuesta. Si el worker esperase un acuse,
      # el trabajo normal de debajo se quedaria sin despachar para siempre.
      queue(:rq3)
      serve(:worker_rq3, [:rq3], budget: 10)

      parent = self()

      # Esta peticion no la recoge nadie: se pasa de plazo.
      assert {:error, :timeout} =
               Worker.request(
                 :worker_rq3,
                 :rq3,
                 fn ->
                   Process.sleep(150)
                   :nadie_me_viene_a_buscar
                 end,
                 timeout: 20
               )

      # Y el worker, sin embargo, sigue sirviendo lo que venga despues.
      Queue.push(:rq3, fn -> send(parent, :trabajo_normal) end, from: parent)
      assert_receive :trabajo_normal, 2_000
    end

    test "la respuesta caduca con su peticion: una respuesta vieja no contesta a la siguiente" do
      # Cada peticion tiene su `ref`, como el de `GenServer.call`. Sin eso, la
      # respuesta de la primera se colaria como si fuera la segunda y el que
      # pregunta receberia un numero que no pidio.
      queue(:rq4)
      serve(:worker_rq4, [:rq4], budget: 10)
      parent = self()

      # La primera se pasa de plazo, y su respuesta LLEGA tarde: a mitad de la
      # espera de la segunda, que es justo cuando podria colarse.
      assert {:error, :timeout} =
               Worker.request(
                 :worker_rq4,
                 :rq4,
                 fn ->
                   Process.sleep(120)
                   :respuesta_tardia
                 end,
                 timeout: 20
               )

      assert {:ok, :la_que_mola} =
               Worker.request(
                 :worker_rq4,
                 :rq4,
                 fn ->
                   Process.sleep(120)
                   :la_que_mola
                 end,
                 timeout: 2_000
               )

      # Y la tardia no se ha comido la segunda. Si se hubiera colado, el
      # `assert_receive` de abajo seria de la respuesta vieja.
      assert_receive {:arrea_worker_reply, _ref, {:ok, :respuesta_tardia}}, 300
      assert parent == self()
    end

    test "la peticion se consume: no deja la entrada parada en la cola" do
      # "No puede ocurrir": una peticion respondida que se queda en la cola
      # hasta que otro worker la coja y la ejecute otra vez.
      queue(:rq5)
      serve(:worker_rq5, [:rq5])

      assert {:ok, :una_vez} = Worker.request(:worker_rq5, :rq5, fn -> :una_vez end)
      assert Queue.stats(:rq5).size == 0
    end

    test "lo que Arrea no puede ejecutar lo dice en el momento, no al vencer el plazo" do
      # El payload de una cola es opaco; por convencion es una funcion de
      # aridad cero. Si no lo es, el que espera tiene derecho a saberlo ya, y
      # no a seguir esperando el plazo entero para recibir un silencio.
      queue(:rq6)
      serve(:worker_rq6, [:rq6])

      t0 = System.monotonic_time(:millisecond)

      assert {:error, :not_executable} =
               Worker.request(:worker_rq6, :rq6, %{type: :mensaje}, timeout: 5_000)

      assert System.monotonic_time(:millisecond) - t0 < 1_000
    end

    test "un payload que revienta responde al que espera, y el worker sobrevive" do
      # El fallo es del payload de quien pregunta, no del worker: quien espera
      # tiene que enterarse, y el worker tiene que seguir sirviendo.
      queue(:rq7)
      serve(:worker_rq7, [:rq7])
      parent = self()

      assert {:error, {:exception, %RuntimeError{message: "boom"}}} =
               Worker.request(:worker_rq7, :rq7, fn -> raise "boom" end, timeout: 1_000)

      Queue.push(:rq7, fn -> send(parent, :sigo_vivo) end, from: parent)
      assert_receive :sigo_vivo, 2_000
    end

    test "el worker no recuerda las peticiones que le han hecho" do
      # La frontera. Una peticion no deja estado: ni persistencia, ni historial,
      # ni una ultima respuesta cacheada. Si el worker guardara algo, eso
      # creeria sin limite con el numero de peticiones.
      queue(:rq8)
      serve(:worker_rq8, [:rq8])

      {:ok, antes} = Worker.get_state(:worker_rq8)
      assert {:ok, :x} = Worker.request(:worker_rq8, :rq8, fn -> :x end)
      {:ok, despues} = Worker.get_state(:worker_rq8)

      assert Map.keys(antes) == Map.keys(despues)
    end
  end

  describe "la peticion entra por la cola, con su prioridad y su peso" do
    test "una peticion mas prioritaria se sirve antes que una entrada normal" do
      # Si la peticion tuviera un camino aparte, se saltaria la prioridad — o la
      # perderia. Aqui compite de frente, y gana por lo que dice la cola.
      #
      # Se mide sobre DOS colas, que es donde el worker elige de verdad (elige la
      # de mayor prioridad entre las que le valen). Dentro de una sola cola, el
      # orden depende de `Arrea.Queue`, y eso es otro asunto: ver la seccion de
      # hallazgos del entregable.
      queue(:rq9a)
      queue(:rq9b)
      serve(:worker_rq9, [:rq9a, :rq9b], budget: 10)
      parent = self()

      # Se ocupa al worker con algo que tarda. Sin esperar a que este ENCOLADO
      # antes de empujar las otras dos, el worker (libre) se llevaria la de mayor
      # prioridad y la prueba no mediria lo que dice medir.
      Queue.push(:rq9a, fn -> send(parent, {:orden, :ocupando}) end, from: parent)
      assert_receive {:orden, :ocupando}, 2_000

      # Mientras esta ocupado, se encolan las dos: la normal primero, la
      # peticion despues pero con mas prioridad.
      Queue.push(:rq9a, fn -> send(parent, {:orden, :normal}) end, priority: 0, from: parent)
      Queue.push(:rq9b, fn -> send(parent, {:orden, :peticion}) end, priority: 9, from: parent)

      assert recoge_etiquetas(2, []) == [:peticion, :normal]
    end

    test "una peticion que no cabe en el presupuesto NO la serve" do
      # El presupuesto es lo que impide tomar una entrada que no cabe. Una
      # peticion que no cabe no es una peticion "urgente": es trabajo que este
      # worker no puede hacer, y el que espera se entera al vencer su plazo.
      queue(:rq10)
      serve(:worker_rq10, [:rq10], budget: 5)
      parent = self()

      assert {:error, :timeout} =
               Worker.request(
                 :worker_rq10,
                 :rq10,
                 fn -> send(parent, :nunca) end,
                 weight: 10,
                 timeout: 150
               )

      refute_receive :nunca, 100
      # Y sigue ahi para quien si tenga hueco. No se ha perdido.
      assert Queue.stats(:rq10).size == 1
    end
  end

  describe "lo que la respuesta no puede ser" do
    test "un worker que nunca existio: se dice al instante, sin esperar el plazo" do
      # El precondicional, sin esto el test pasaria igual: si el worker existiera
      # o la respuesta volviera, el `assert` de abajo seria el mismo.
      assert Registry.lookup(Arrea.Registry, :NUNCA_EXISTIO) == []
      queue(:rq11)

      t0 = System.monotonic_time(:millisecond)

      assert Worker.request(:NUNCA_EXISTIO, :rq11, fn -> :nada end, timeout: 5_000) ==
               {:error, :worker_not_found}

      assert System.monotonic_time(:millisecond) - t0 < 1_000
    end

    test "un worker que se va mientras espera no es lo mismo que uno que nunca existio" do
      # Este es el motivo de `:worker_down` y no `:worker_not_found`: uno no
      # estaba, el otro estaba y se ha ido con la peticion dentro. Aplanar los
      # dos es decir "tu pregunta no se ha perdido" cuando si se ha perdido.
      queue(:rq12)
      pid = serve(:worker_rq12, [:rq12])

      # El worker esta enlazado a este test (lo arranca `start_link`), asi que
      # hay que tragarse su salida o el test se cae con el.
      Process.flag(:trap_exit, true)
      parent = self()

      quien_pregunta =
        spawn(fn ->
          send(
            parent,
            {:respuesta,
             Worker.request(:worker_rq12, :rq12, fn -> Process.sleep(5_000) end, timeout: 5_000)}
          )
        end)

      # Se muere con la peticion en las manos. A proposito `kill` y no
      # `GenServer.stop/1`: un worker ejecutando un payload esta DENTRO de un
      # callback, y ahi un `stop` educado no se le cuela hasta que el payload
      # acaba. Eso tambien es un hallazgo, no un detalle del test.
      Process.sleep(50)
      Process.exit(pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}, 1_000

      assert_receive {:respuesta, respuesta}, 2_000
      assert {:error, {:worker_down, _}} = respuesta
      refute match?({:error, :worker_not_found}, respuesta)
      refute match?({:error, :timeout}, respuesta)
      refute Process.alive?(quien_pregunta)
    end

    test "una cola que no existe se dice, no se responde con un silencio" do
      queue(:rq13)
      serve(:worker_rq13, [:rq13])

      assert Worker.request(:worker_rq13, :no_esta_esta_cola, fn -> :nada end, timeout: 500) ==
               {:error, :queue_not_found}
    end
  end
end
