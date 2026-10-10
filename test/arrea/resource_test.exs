defmodule Arrea.ResourceTest do
  # Tests de `Arrea.Resource`.
  #
  # La forma de este fichero NO es "responde bien": cada test dice que algo NO
  # puede ocurrir. Un criterio que solo comprueba que la funcion contesta pasa
  # con una lista vacia de titulares, y una lista vacia es exactamente el
  # knapsack roto.
  use ExUnit.Case

  alias Arrea.Resource
  alias Code.Typespec

  # 10 GB, en megas enteros: el eje DURO es entero a proposito.
  @capacity 10_240

  setup do
    test_id = unique_name()

    _ = start_supervised({Registry, keys: :unique, name: Arrea.Resource.Registry})

    {:ok, pid} = Resource.start_link(test_id, @capacity)
    %{pid: pid, test_id: test_id}
  end

  # Nombres de compilacion, no de runtime: `Credo.Check.Warning.UnsafeToAtom`
  # tiene razon, y una suite que fabrica un atomo por test es una fuga de la
  # tabla de atomos. El pool se recorre desde un punto de partida distinto en
  # cada proceso y se para en el primer hueco del Registry, de modo que dos
  # tests concurrentes nunca se pisan ni aunque les toque el mismo inicio.
  @pool for n <- 1..256, do: :"resource_test_#{n}"

  defp unique_name do
    inicio = :erlang.phash2({self(), System.unique_integer([:positive])}, length(@pool))

    @pool
    |> Enum.drop(inicio)
    |> Kernel.++(Enum.take(@pool, inicio))
    |> Enum.find_value(fn nombre ->
      if Registry.lookup(Arrea.Resource.Registry, nombre) == [], do: nombre
    end)
  end

  # ── 1 · El eje duro: megas enteros ────────────────────────────────────────

  describe "capacidad fisica" do
    test "caben por megas y el rechazo lleva numeros, no un atomo", %{test_id: test_id} do
      # 6144 de 10240. No es "una ranura de dos": son megas.
      assert {:ok, receipt} = Resource.acquire(test_id, :modelo_a, 6_144, 0.0)
      assert receipt.holder == :modelo_a
      assert receipt.capacity == 6_144
      assert is_integer(receipt.acquired_at)

      # Un segundo modelo de 6144 NO cabe en los 4096 que quedan.
      refute match?({:ok, _}, Resource.acquire(test_id, :modelo_b, 6_144, 0.0))

      assert {:error,
              {:insufficient_capacity, %{requested: 6_144, available: 4_096, capacity: @capacity}}} =
               Resource.acquire(test_id, :modelo_c, 6_144, 0.0)
    end

    test "el eje duro es entero: no admite fracciones y la cuenta es exacta", %{pid: pid} do
      name = unique_name()
      {:ok, _} = Resource.start_link(name, 13)

      # Un peso FRACCIONAL en megas no es un importe: los megas son enteros. Es
      # lo que hace que este eje no necesite epsilon —`0.1 + 0.2` no aparece en
      # la capacidad porque en la capacidad no hay decimales— y lo que impide
      # que `1.4` se cuele por la puerta de atras de `:unknown_cost`.
      assert {:error, :invalid_weight} = Resource.acquire(name, :embedder, 1.4, 0.0)

      # Y con megas enteros, 1 + 12 = 13 entra JUSTO. La cuenta es exacta: ni
      # epsilon ni margen, porque 13 == 13.
      assert {:ok, _} = Resource.acquire(name, :embedder, 1, 0.0)
      assert Resource.available(name) == 12

      assert {:error, {:insufficient_capacity, %{requested: 13, available: 12, capacity: 13}}} =
               Resource.acquire(name, :grande, 13, 0.0)

      # En la cuota, en cambio, los decimales son lo NORMAL, porque es una
      # politica, y las politicas reparten en fracciones.
      assert {:ok, _} = Resource.acquire(name, :cuota_alta, 1, 0.25)
      assert %{quota_used: 0.25} = Resource.status(name)

      assert Process.alive?(pid)
    end

    test "rechazar no gasta: la misma carga entra justo despues", %{test_id: test_id} do
      {:ok, _} = Resource.acquire(test_id, :ocupa, 8_192, 0.0)
      assert Resource.available(test_id) == 2_048

      refute match?({:ok, _}, Resource.acquire(test_id, :grande, 5_000, 0.0))

      # Lo que se rechazo no ha reservado nada.
      assert Resource.available(test_id) == 2_048
      assert %{used: 8_192, holders: [{:ocupa, 8_192, 0.0}]} = Resource.status(test_id)

      # Lo que cabe, entra; y lo que no cabe despues, sigue sin caber.
      assert {:ok, _} = Resource.acquire(test_id, :mediano, 2_048, 0.0)
      assert Resource.available(test_id) == 0
      refute match?({:ok, _}, Resource.acquire(test_id, :grande, 1, 0.0))
    end
  end

  # ── 2 · El eje blando: la cuota ───────────────────────────────────────────

  describe "cuota de politica" do
    test "entra por cuota lo que no cabe por megas, y al reves", %{test_id: test_id} do
      n = unique_name()
      {:ok, _} = Resource.start_link(n, @capacity, quota: 1.0)

      # Entra por CAPACIDAD: 1024 megas de 10240, y cuota de sobra.
      assert {:ok, _} = Resource.acquire(n, :chico, 1_024, 0.1)
      # Entra por CUOTA: 2048 megas (caben de sobra) y cuota ajustada.
      assert {:ok, _} = Resource.acquire(n, :mediano, 2_048, 0.4)
      assert Resource.quota_available(n) == 0.5

      # Y se rechaza por CUOTA, no por megas: hay 7168 megas libres.
      assert Resource.available(n) == 7_168

      assert {:error, {:quota_exceeded, %{requested: 0.6, available: 0.5, quota: 1.0}}} =
               Resource.acquire(n, :vampiro, 2_048, 0.6)
    end

    test "el limite es el limite: justo entra y una unidad mas no", %{test_id: test_id} do
      n = unique_name()
      # Capacidad de sobra para que los dos ejes se puedan castigar por separado:
      # si no, el rechazo de megas tapa al de cuota y no se prueba el segundo.
      {:ok, _} = Resource.start_link(n, 2_000, quota: 1.0)

      # Justo en los DOS ejes entra: 1000 de 2000 megas y 1.0 de 1.0 de cuota.
      assert {:ok, _} = Resource.acquire(n, :justo, 1_000, 1.0)

      # Y una unidad de mas en megas se rechaza POR CAPACIDAD, y solo por eso.
      # Este es el test que caza a un modulo que admite un 5% de mas.
      assert {:error,
              {:insufficient_capacity, %{requested: 1_001, available: 1_000, capacity: 2_000}}} =
               Resource.acquire(n, :un_mega_de_mas, 1_001, 0.0)

      # Y una centesima de mas de cuota se rechaza POR CUOTA, con megas de sobra.
      assert {:error, {:quota_exceeded, %{requested: 0.01, available: 0.0, quota: 1.0}}} =
               Resource.acquire(n, :una_centesima_de_mas, 1, 0.01)

      # Y nada de esto ha gastado nada de mas.
      assert %{used: 1_000, quota_used: 1.0, accepted: 1, rejected: 2} = Resource.status(n)
    end

    test "un rechazo por cuota no dice que no hay megas", %{test_id: test_id} do
      n = unique_name()
      {:ok, _} = Resource.start_link(n, @capacity, quota: 0.5)

      assert {:error, {:quota_exceeded, motivo}} = Resource.acquire(n, :modelo, 100, 0.9)

      # Los tres numeros son del eje BLANDO. Si `available` fuera el de megas,
      # este motivo no distinguiria un rechazo de cuota de uno de capacidad.
      assert motivo.requested == 0.9
      assert motivo.available == 0.5
      assert motivo.quota == 0.5
      refute Map.has_key?(motivo, :capacity)

      # Y los megas siguen libres, que es información distinta de la misma.
      assert Resource.available(n) == @capacity
    end

    test "un rechazo por capacidad no dice que se acabo la cuota", %{test_id: test_id} do
      n = unique_name()
      {:ok, _} = Resource.start_link(n, 100, quota: 10.0)

      assert {:error, {:insufficient_capacity, motivo}} = Resource.acquire(n, :modelo, 200, 1.0)

      assert motivo.requested == 200
      assert motivo.available == 100
      assert motivo.capacity == 100
      refute Map.has_key?(motivo, :quota)

      # La cuota sigue entera, que es OTRO hecho.
      assert Resource.quota_available(n) == 10.0
    end

    test "por defecto la cuota es :infinity y no rechaza nunca", %{test_id: test_id} do
      assert Resource.quota_available(test_id) == :infinity
      assert %{quota: :infinity, quota_available: :infinity} = Resource.status(test_id)

      # 9.0 de cuota en un resource que no tiene cuota: no es un problema.
      assert {:ok, _} = Resource.acquire(test_id, :modelo, 1_024, 9.0)
      assert {:ok, _} = Resource.acquire(test_id, :otro, 1_024, 90.0)
      assert Resource.quota_available(test_id) == :infinity
      assert Resource.available(test_id) == @capacity - 2_048
    end

    test "una cuota que cabe por poco no se rechaza, y lo publicado se puede comparar", %{
      test_id: test_id
    } do
      # 0.1 + 0.2 vale 0.30000000000000004 en IEEE-754. Sin tolerancia, esta
      # cuota no cabria en 0.3 y el modulo rechazaria algo que entra de sobra.
      name = unique_name()
      {:ok, _} = Resource.start_link(name, @capacity, quota: 0.3)
      assert {:ok, _} = Resource.acquire(name, :uno, 1, 0.1)

      # Y lo que sale de aqui no es ruido de coma flotante: un router tiene que
      # poder comparar lo que lee con lo que el mismo pide.
      assert Resource.quota_available(name) == 0.2

      assert {:ok, receipt} = Resource.acquire(name, :dos, 1, 0.2)
      assert receipt.quota == 0.2
      assert Resource.quota_available(name) == 0.0
      assert %{quota_used: 0.3, quota_available: 0.0} = Resource.status(name)
    end
  end

  # ── 3 · Un coste que no se declara NO es un coste de cero ─────────────────

  describe "importes no declarados" do
    test "falta un eje entero: no se admite, y no gasta", %{test_id: test_id} do
      assert {:error, :unknown_cost} = Resource.acquire(test_id, :sin_megas, nil, 0.1)
      assert {:error, :unknown_cost} = Resource.acquire(test_id, :sin_cuota, 1_024, nil)

      # Lo importante: no ha ocupado ni un mega ni una unidad de cuota.
      assert Resource.available(test_id) == @capacity
      assert Resource.quota_available(test_id) == :infinity
      assert %{used: 0, quota_used: 0.0, holders: []} = Resource.status(test_id)
    end

    test "un importe que no es numerico tampoco es un importe", %{test_id: test_id} do
      assert {:error, :unknown_cost} = Resource.acquire(test_id, :a, :muchisimo, 0.1)
      assert {:error, :unknown_cost} = Resource.acquire(test_id, :b, 1_024, "mucha")
      assert %{used: 0, holders: []} = Resource.status(test_id)
    end

    test "un importe <= 0 o fraccional en megas no es un importe", %{test_id: test_id} do
      # Sin esto, `:unknown_cost` se esquiva por la puerta de atras pasando 0.
      assert {:error, :invalid_weight} = Resource.acquire(test_id, :cero, 0, 0.1)
      assert {:error, :invalid_weight} = Resource.acquire(test_id, :negativo, -1, 0.1)
      assert {:error, :invalid_weight} = Resource.acquire(test_id, :fraccion, 1.4, 0.1)

      # En la cuota, en cambio, 0 es una afirmacion de politica legitima.
      assert {:ok, _} = Resource.acquire(test_id, :gratis, 1_024, 0)
      assert {:error, :invalid_weight} = Resource.acquire(test_id, :cuota_neg, 1_024, -0.5)

      assert %{used: 1_024, quota_used: 0.0, holders: [{:gratis, 1_024, 0}]} =
               Resource.status(test_id)

      # Y un importe entero de cuota se devuelve entero, sin pasar por el
      # redondeo decimal: lo que dio el que llama, tal cual.
      assert {:ok, %{capacity: 1_024, quota: 0}} = Resource.release(test_id, :gratis)
    end
  end

  # ── 4 · Identidad: devolver lo devuelto ─────────────────────────────────────

  describe "identidad" do
    test "release devuelve lo reservado a ESE titular y a ningun otro", %{test_id: test_id} do
      {:ok, _} = Resource.acquire(test_id, :a, 4_096, 0.25)
      {:ok, _} = Resource.acquire(test_id, :b, 4_096, 0.25)

      assert %{used: 8_192, holders: holders} = Resource.status(test_id)
      assert Enum.sort(holders) == Enum.sort([{:a, 4_096, 0.25}, {:b, 4_096, 0.25}])

      # Y devuelve LOS DOS IMPORTES, no solo el peso.
      assert {:ok, %{capacity: 4_096, quota: 0.25}} = Resource.release(test_id, :a)

      # `release(:a)` NO puede decrementar lo de `:b`. Un contador por peso
      # ("used - 4096") pasa este test si solo se mira `used`; por eso se mira
      # la lista de titulares, que es lo que un contador no puede responder.
      assert %{used: 4_096, holders: [{:b, 4_096, 0.25}]} = Resource.status(test_id)
      assert Resource.available(test_id) == 6_144
    end

    test "soltar dos veces el mismo titular no libera el de otro", %{test_id: test_id} do
      {:ok, _} = Resource.acquire(test_id, :a, 3_072, 0.1)
      {:ok, _} = Resource.acquire(test_id, :b, 3_072, 0.2)

      assert {:ok, %{capacity: 3_072, quota: 0.1}} = Resource.release(test_id, :a)
      # El segundo release de `:a` ya no puede tocar nada: `:a` no esta, y lo
      # que devuelve son ceros, que es lo que de verdad ha vuelto a la cuenta.
      assert {:ok, %{capacity: 0, quota: 0.0}} = Resource.release(test_id, :a)
      assert {:ok, %{capacity: 0, quota: 0.0}} = Resource.release(test_id, :nunca_fue_titular)

      assert %{used: 3_072, quota_used: 0.2, holders: [{:b, 3_072, 0.2}]} =
               Resource.status(test_id)
    end

    test "el mismo titular con dos reservas las devuelve una a una", %{test_id: test_id} do
      # El escenario de todos los dias: el mismo modelo cargado dos veces. Cada
      # `release` devuelve UNA reserva, y la segunda sigue puesta hasta que la
      # devuelves. Antes la busqueda encontraba las dos, devolvia la primera y
      # quitaba las dos: 4 GB perdidos en silencio, con `holders: []`.
      assert {:ok, _} = Resource.acquire(test_id, :llama7b, 4_000, 1.0)
      assert {:ok, _} = Resource.acquire(test_id, :llama7b, 4_000, 1.0)

      assert %{
               used: 8_000,
               quota_used: 2.0,
               holders: [{:llama7b, 4_000, 1.0}, {:llama7b, 4_000, 1.0}]
             } =
               Resource.status(test_id)

      assert {:ok, %{capacity: 4_000, quota: 1.0}} = Resource.release(test_id, :llama7b)

      assert %{used: 4_000, quota_used: 1.0, holders: [{:llama7b, 4_000, 1.0}]} =
               Resource.status(test_id)

      # Y la segunda tambien vuelve a la cuenta, sin dejar rastro.
      assert {:ok, %{capacity: 4_000, quota: 1.0}} = Resource.release(test_id, :llama7b)
      assert %{used: 0, quota_used: 0.0, holders: []} = Resource.status(test_id)
      assert Resource.available(test_id) == @capacity
    end

    test "soltar a un titular que NO esta el primero no pierde a los demas" do
      # Este es el test que faltaba y que casi se lleva por delante una version
      # anterior: con tres titulares, soltar al DEL MEDIO. Si la busqueda solo
      # encuentra al primero de la lista, esto devuelve cero; si al quitar esa
      # reserva tira tambien las de delante, disappears `a` sin que nadie la
      # toque. Los dos fallos son silenciosos y los dos son la misma fuga.
      n = unique_name()
      {:ok, _} = Resource.start_link(n, 16_384, quota: 8.0)

      for {titular, mb, cuota} <- [{:a, 1_024, 0.1}, {:b, 4_096, 0.5}, {:c, 8_192, 1.5}] do
        assert {:ok, _} = Resource.acquire(n, titular, mb, cuota)
      end

      assert %{used: 13_312, holders: [{:a, 1_024, 0.1}, {:b, 4_096, 0.5}, {:c, 8_192, 1.5}]} =
               Resource.status(n)

      # Al del medio: se devuelve la suya, y los otros dos siguen puestos.
      assert {:ok, %{capacity: 4_096, quota: 0.5}} = Resource.release(n, :b)

      assert %{used: 9_216, quota_used: 1.6, holders: [{:a, 1_024, 0.1}, {:c, 8_192, 1.5}]} =
               Resource.status(n)

      # Y al ultimo, con una lista que ya no empieza por el.
      assert {:ok, %{capacity: 8_192, quota: 1.5}} = Resource.release(n, :c)
      assert %{used: 1_024, holders: [{:a, 1_024, 0.1}]} = Resource.status(n)

      assert {:ok, %{capacity: 1_024, quota: 0.1}} = Resource.release(n, :a)
      assert %{used: 0, quota_used: 0.0, holders: []} = Resource.status(n)
      assert Resource.available(n) == 16_384
    end

    test "el mismo titular con reservas DISTINTAS devuelve la que le toca" do
      # Resource aparte porque 4 GB + 8 GB no caben en el de la fixture, y el
      # punto de este test es justamente que las dos reservas coexisten.
      n = unique_name()
      {:ok, _} = Resource.start_link(n, 16_384, quota: 8.0)

      assert {:ok, _} = Resource.acquire(n, :mixto, 4_096, 0.5)
      assert {:ok, _} = Resource.acquire(n, :mixto, 8_192, 2.0)

      assert %{
               used: 12_288,
               quota_used: 2.5,
               holders: [{:mixto, 4_096, 0.5}, {:mixto, 8_192, 2.0}]
             } =
               Resource.status(n)

      # Una reserva devuelta, UNA: la primera. Y lo que devuelve es lo que
      # pesaba ESA, no la suma de las dos.
      assert {:ok, %{capacity: 4_096, quota: 0.5}} = Resource.release(n, :mixto)
      assert %{used: 8_192, quota_used: 2.0, holders: [{:mixto, 8_192, 2.0}]} = Resource.status(n)

      assert {:ok, %{capacity: 8_192, quota: 2.0}} = Resource.release(n, :mixto)
      assert %{used: 0, quota_used: 0.0, holders: []} = Resource.status(n)
      assert Resource.available(n) == 16_384
    end

    test "ocho reservas del mismo titular se devuelven de una en una", %{test_id: test_id} do
      for _ <- 1..8, do: {:ok, _} = Resource.acquire(test_id, :pesado, 1_024, 0.125)
      assert %{used: 8_192, holders: holders} = Resource.status(test_id)
      assert length(holders) == 8

      for _ <- 1..8 do
        assert {:ok, %{capacity: 1_024, quota: 0.125}} = Resource.release(test_id, :pesado)
      end

      # Ni una se queda por el camino, que es el fallo que esto caza.
      assert %{used: 0, quota_used: 0.0, holders: []} = Resource.status(test_id)
      assert Resource.available(test_id) == @capacity
    end

    test "la identidad es estricta: 1 no es el titular 1.0", %{test_id: test_id} do
      {:ok, _} = Resource.acquire(test_id, 1, 1_024, 0.1)
      {:ok, _} = Resource.acquire(test_id, :otro, 3_072, 0.2)

      # En Erlang `1 == 1.0` es VERDAD. Con `==` este release se llevaria la
      # reserva del titular `1`, que no ha pedido nada: es el eje del
      # contrato (devolver lo que se devolvio, no lo que se parece a ello).
      assert {:ok, %{capacity: 0, quota: 0.0}} = Resource.release(test_id, 1.0)

      assert %{used: 4_096, quota_used: 0.3, holders: [{1, 1_024, 0.1}, {:otro, 3_072, 0.2}]} =
               Resource.status(test_id)

      # Y el titular de verdad sigue pudiendo devolver lo suyo, y solo lo suyo.
      assert {:ok, %{capacity: 1_024, quota: 0.1}} = Resource.release(test_id, 1)

      assert %{used: 3_072, quota_used: 0.2, holders: [{:otro, 3_072, 0.2}]} =
               Resource.status(test_id)
    end
  end

  # ── 5 · Nombres desconocidos ──────────────────────────────────────────────

  test "un nombre desconocido contesta, no revienta" do
    # Nunca un `exit`: quien pregunta por una GPU que no existe tiene que poder
    # seguir preguntando.
    assert {:error, :resource_not_found} = Resource.acquire(:gpu_que_no_existe, :modelo, 1, 0.1)
    assert Resource.available(:gpu_que_no_existe) == 0
    assert Resource.quota_available(:gpu_que_no_existe) == :infinity
    assert Resource.status(:gpu_que_no_existe) == nil
    assert {:error, :resource_not_found} = Resource.release(:gpu_que_no_existe, :modelo)
  end

  # ── 6 · El motivo lleva los números ────────────────────────────────────────

  test "el motivo dice cuanto se pidio, cuanto habia y cuanto cabe", %{test_id: test_id} do
    {:ok, _} = Resource.acquire(test_id, :uno, 7_168, 0.0)

    assert {:error, reason} = Resource.acquire(test_id, :otro, 4_096, 0.0)

    assert {:insufficient_capacity, %{requested: r, available: a, capacity: c}} = reason

    # Un `{:error, :no_room}` falla aqui, y tiene que fallar: los numeros son
    # lo que le dicen al router QUE no cabe y CUANTO le falta.
    assert r == 4_096
    assert a == 3_072
    assert c == @capacity
    # Y la cuenta tiene que cuadrar: lo que se pide es mas de lo que hay.
    # `available` ES lo que hay; `c - available` es lo OCUPADO (7_168), y
    # 4_096 > 7_168 es falso, asi que esa formula no podia ser la correcta.
    assert r > a
  end

  # ── 7 · El motivo no es el del bulkhead ────────────────────────────────────

  test "el motivo no puede ser el de `Bulkhead`, ni cambiar segun por donde se llame", %{
    test_id: test_id
  } do
    {:ok, _} = Resource.acquire(test_id, :uno, 9_216, 0.0)

    # Mismo hecho, dos veces. Si la respuesta dependiera del camino, estas dos
    # lineas compararian dos hechos distintos.
    primera = Resource.acquire(test_id, :a, 2_048, 0.0)
    segunda = Resource.acquire(test_id, :b, 2_048, 0.0)
    assert primera == segunda

    refute match?({:error, :bulkhead_full}, primera)
    refute match?({:error, :bulkhead_full}, segunda)
    assert {:error, {:insufficient_capacity, _}} = primera
  end

  # ── 8 · El `@type` no mezcla las razones ──────────────────────────────────

  describe "el @type de la razon" do
    test "declara sus propias razones y no la del bulkhead" do
      atoms = rejection_atoms()

      # El @type es la puerta: si `:bulkhead_full` vuelve a colarse, Arrea
      # vuelve a tener dos verdades sobre por que se rechazo algo.
      refute :bulkhead_full in atoms
      assert :insufficient_capacity in atoms
      assert :quota_exceeded in atoms
      assert :unknown_cost in atoms
      assert :invalid_weight in atoms
      assert :resource_not_found in atoms
    end

    test "ninguna razon es una de las que ya escribe el router" do
      atoms = rejection_atoms()

      # Son las dos que el motor de decisiones de Candil ya tiene escritas. Si
      # Arrea las reutiliza, la verdad de por que se rechazo una peticion vuelve
      # a estar en dos sitios, que es el defecto que esto viene a evitar.
      refute :no_models_for_consumer in atoms
      refute :model_not_in_candidates in atoms
    end
  end

  defp rejection_atoms do
    {:ok, types} = Typespec.fetch_types(Resource)
    # `fetch_types/1` devuelve `{kind, {name, definition, args}}`, NO
    # `{type, name, args}`: el filtro de cuatro elementos de la version
    # anterior no encajaba con nada y reventaba con FunctionClauseError antes
    # de comprobar un solo atomo.
    type = Enum.find(types, fn {_kind, {name, _definition, _args}} -> name == :rejection end)
    assert type, "Arrea.Resource tiene que declarar un @type rejection"

    # Y `type_to_quoted/1` quiere el `{name, definition, args}` de dentro, y
    # devuelve el AST ENTERO del type (`{:"::", meta, [name, body]}`), no un
    # `{ast, meta}` de dos: por eso `{quoted, _}` reventaba con MatchError.
    quoted = Typespec.type_to_quoted(elem(type, 1))
    collect_atoms(quoted)
  end

  # `:beam_lib.chunks/2` solo acepta charlists: con un binario devuelve
  # `{:not_a_beam_file, ruta}` aunque el fichero sea un BEAM perfectlyo. Y
  # bajo `mix test --cover`, `:cover.compile_beam_directory/1` deja el modulo
  # en memoria y `:code.which/1` devuelve el atomo `:cover_compiled` en vez de
  # una ruta. El beam de verdad sigue en el `ebin` de la app con la misma tabla
  # de `imports`: lo que se comprueba no cambia, solo de donde se lee.
  defp module_beam(module) do
    path = :code.which(module)

    if is_list(path) and File.exists?(path), do: path, else: beam_in_ebin(module)
  end

  defp beam_in_ebin(module) do
    :arrea
    |> :code.lib_dir(:ebin)
    |> List.to_string()
    |> Path.join("Elixir.#{inspect(module)}.beam")
    |> String.to_charlist()
  end

  defp collect_atoms(ast) do
    case ast do
      atom when is_atom(atom) -> [atom]
      tuple when is_tuple(tuple) -> tuple |> Tuple.to_list() |> Enum.flat_map(&collect_atoms/1)
      list when is_list(list) -> Enum.flat_map(list, &collect_atoms/1)
      _other -> []
    end
  end

  # ── 9 · No persiste ───────────────────────────────────────────────────────

  test "la verdad no esta en disco: al parar y volver, no queda nada", %{
    test_id: test_id,
    pid: pid
  } do
    dir = Path.join(System.tmp_dir!(), "arrea_resource_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # Este `dir` se le da a la APLICACION, que es quien decide donde vive su
    # directorio de datos. Antes se listaba un directorio que no se le
    # llegaba a nadie: el refute de abajo no podia fallar, porque el modulo
    # no tenia forma de escribir ahi ni de escribir en ninguna parte.
    Application.put_env(:arrea, :data_dir, dir)
    on_exit(fn -> Application.delete_env(:arrea, :data_dir) end)

    {:ok, _} = Resource.acquire(test_id, :modelo, 6_144, 0.5)
    assert %{used: 6_144} = Resource.status(test_id)

    assert {:ok, %{capacity: 6_144, quota: 0.5}} = Resource.release(test_id, :modelo)
    {:ok, _} = Resource.acquire(test_id, :otro, 3_072, 0.25)

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    # Ningun fichero: la cuenta vive en memoria y se pierde a proposito. Es lo
    # que hace imposible que dos repos tengan dos verdades sobre la misma GPU.
    assert File.ls!(dir) == []

    # Y no solo que este test no lo ve: que el modulo no PUEDE. Sin funciones
    # de fichero en la tabla de imports, no hay forma de que escriba.
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(module_beam(Resource), [:imports])

    refute Enum.any?(imports, fn {module, _function, _arity} ->
             module in [File, :file, :erl_prim_file]
           end),
           "Arrea.Resource importa funciones de fichero: no es cierto que no pueda persistir"

    {:ok, _} = Resource.start_link(test_id, @capacity)

    assert %{used: 0, quota_used: 0.0, holders: [], accepted: 0, rejected: 0} =
             Resource.status(test_id)

    assert Resource.available(test_id) == @capacity
  end

  # ── 10 · No lee la GPU ────────────────────────────────────────────────────

  test "una capacidad de 0 rechaza con numeros y no se cuelga", %{pid: pid} do
    vacio = unique_name()
    {:ok, vacio_pid} = Resource.start_link(vacio, 0)

    # `free_mb: 0` no es "no lo se". El modulo tiene que poder decir "no cabe
    # y aqui hay 0" en vez de adivinar el motivo.
    assert {:error, {:insufficient_capacity, %{requested: 512, available: 0, capacity: 0}}} =
             Resource.acquire(vacio, :modelo, 512, 0.1)

    refute match?({:error, :unknown_cost}, Resource.acquire(vacio, :modelo, 512, 0.1))
    assert Process.alive?(vacio_pid)
    assert Process.alive?(pid)
  end

  test "el modulo no importa nada de Candil ni llama a la GPU" do
    # Estructural, no de prosa: se lee la tabla de imports del BEAM. Si
    # Resource empieza a preguntar a otro repositorio por la VRAM, esto se
    # rompe solo, y un `refute fuente =~ "Candil"` no lo detectaria porque el
    # moduledoc tiene que poder nombrar la frontera.
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(module_beam(Resource), [:imports])

    # El chunk `imports` son TRIPLAS `{modulo, funcion, aridad}`. La forma de
    # cuatro elementos `{:import, m, f, a}` no Encaja con ninguna: el bucle
    # recorria CERO entradas y el refute de abajo no se ejecutaba jamas.
    # Las dos aserciones siguientes son las que hacen que eso no pueda volver.
    assert imports != [], "el BEAM de Arrea.Resource deberia traer tabla de imports"

    assert Enum.any?(imports, &match?({Arrea.Telemetry.Events, :emit_resource, 2}, &1)),
           "la forma de las entradas de `imports` ha cambiado: mira como son antes de fiarte"

    for {module, _function, _arity} <- imports do
      refute String.starts_with?(inspect(module), "Candil"),
             "Arrea.Resource importa #{inspect(module)}: la frontera con Candil esta cruzada"
    end

    fuente = Resource.__info__(:compile) |> Keyword.fetch!(:source) |> File.read!()

    refute fuente =~ "instances.json"
    refute fuente =~ "nvidia-smi"
    refute fuente =~ "File."
  end

  # ── 11 · El titular es opaco ──────────────────────────────────────────────

  test "el titular se guarda entero y se devuelve entero", %{test_id: test_id} do
    titular = %{lo_que_sea: :quiera, nested: %{a: [1, 2, %{b: :c}]}}

    assert {:ok, %{holder: ^titular, capacity: 2_560, quota: 0.125}} =
             Resource.acquire(test_id, titular, 2_560, 0.125)

    assert %{holders: [{^titular, 2_560, 0.125}]} = Resource.status(test_id)

    assert {:ok, %{capacity: 2_560, quota: 0.125}} = Resource.release(test_id, titular)
    assert %{used: 0, holders: []} = Resource.status(test_id)
  end

  # ── 12 · Telemetría tipada ─────────────────────────────────────────────────

  describe "telemetria" do
    setup do
      ref = make_ref()
      parent = self()

      for {suffix, sufijo} <- [{"acquired", :acquired}, {"rejected", :rejected}] do
        :telemetry.attach(
          "resource-#{suffix}-#{inspect(ref)}",
          [:arrea, :resource, sufijo],
          fn _event, _measurements, metadata, ^ref -> send(parent, {sufijo, metadata}) end,
          ref
        )
      end

      on_exit(fn ->
        :telemetry.detach("resource-acquired-#{inspect(ref)}")
        :telemetry.detach("resource-rejected-#{inspect(ref)}")
      end)

      :ok
    end

    test "adquirir emite :acquired con los dos ejes", %{test_id: test_id} do
      assert {:ok, _} = Resource.acquire(test_id, :modelo, 3_072, 0.25)

      assert_receive {:acquired,
                      %{
                        name: ^test_id,
                        capacity: 10_240,
                        used: 3_072,
                        quota_used: 0.25,
                        holders: 1
                      }},
                     1_000
    end

    test "rechazar NO emite :acquired", %{test_id: test_id} do
      {:ok, _} = Resource.acquire(test_id, :modelo, 9_216, 0.0)
      refute match?({:ok, _}, Resource.acquire(test_id, :otro, 2_048, 0.0))

      assert_receive {:rejected, %{name: ^test_id, used: 9_216, holders: 1}}, 1_000
      # La compra de 9_216 emite `:acquired` DE VERDAD, asi que su mensaje esta
      # en el buzon: sin consumirlo antes, este `refute` solo mediria eso.
      assert_received {:acquired, %{used: 9_216}}
      refute_received {:acquired, _}
    end
  end

  # ── 13 · Contadores, ambito de la reserva y validacion ────────────────────

  test "la reserva NO se suelta sola, y los contadores cuentan entradas y salidas", %{
    test_id: test_id
  } do
    assert %{accepted: 0, rejected: 0} = Resource.status(test_id)

    {:ok, _} = Resource.acquire(test_id, :a, 1_024, 0.1)
    refute match?({:ok, _}, Resource.acquire(test_id, :b, 20_000, 0.1))

    # La reserva se queda puesta. La de `Bulkhead` se suelta al acabar la
    # funcion, y eso es lo contrario de un modelo cargado en memoria.
    assert %{used: 1_024} = Resource.status(test_id)
    Process.sleep(20)
    assert %{used: 1_024} = Resource.status(test_id)

    assert {:ok, %{capacity: 1_024, quota: 0.1}} = Resource.release(test_id, :a)
    assert %{used: 0, accepted: 1, rejected: 1} = Resource.status(test_id)
  end

  test "status, available y quota_available cuentan lo mismo", %{test_id: test_id} do
    assert %{capacity: @capacity, used: 0, available: @capacity, quota_used: 0.0} =
             Resource.status(test_id)

    assert Resource.available(test_id) == @capacity
    assert Resource.quota_available(test_id) == :infinity

    {:ok, _} = Resource.acquire(test_id, :a, 2_048, 0.1)

    assert %{used: 2_048, available: 8_192} = Resource.status(test_id)
    assert Resource.available(test_id) == 8_192
  end

  test "start_link y validate_opts rechazan capacidades que no son cantidades" do
    assert Resource.validate_opts(name: :gpu, capacity: 16_384) == :ok
    # 0 es una capacidad legitima: significa "ahora no cabe nada", que no es
    # lo mismo que "no lo se".
    assert Resource.validate_opts(name: :gpu, capacity: 0) == :ok
    assert Resource.validate_opts(name: :gpu, capacity: 16_384, quota: 0.5) == :ok
    assert Resource.validate_opts(name: :gpu, capacity: 16_384, quota: :infinity) == :ok

    assert {:error, %Arrea.Error{code: :invalid_config} = error} =
             Resource.start_link(unique_name(), "mucha")

    assert error.message =~ "capacity"

    for opts <- [
          [],
          [name: :gpu],
          [name: :gpu, capacity: -1],
          [name: :gpu, capacity: nil],
          [name: :gpu, capacity: 1.5],
          [name: :gpu, capacity: 1, quota: -0.5],
          [name: :gpu, capacity: 1, quota: :mucha]
        ] do
      assert {:error, %Arrea.Error{code: :invalid_config}} = Resource.validate_opts(opts)
    end

    refute match?({:ok, _}, Resource.start_link(unique_name(), -1))
  end
end
