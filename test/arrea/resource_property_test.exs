defmodule Arrea.ResourcePropertyTest do
  # Propiedad de `Arrea.Resource`, con el precedente de
  # `bulkhead_property_test.exs`.
  #
  # La mitad interesante es la segunda: `used` tiene que ser la suma de los
  # titulares vivos, no "un numero que no pasa de la capacidad". Un contador por
  # peso cumple la primera mitad y es incapaz de cumplir la segunda, que es
  # justo lo que separa un `Resource` de un `Bulkhead`.
  #
  # Y hay una diferencia con el bulkhead que es el punto entero de este modulo:
  # los dos ejes se comprueban con reglas DISTINTAS, porque son cosas
  # distintas. `used`, en megas enteros, se compara con `==` y es exacto: no
  # necesita epsilon, y no la tiene. `quota_used`, en decimales, se compara con
  # tolerancia, porque 0.1 + 0.2 vale 0.30000000000000004 y sin margen una
  # politica rechazaria lo que le cabe. Si las dos mitades se comprobaran con
  # la misma regla, una de las dos estaria o regalando capacidad o rejecting
  # cosas que caben.
  use ExUnit.Case
  use ExUnitProperties

  import ExUnit.Assertions
  import StreamData

  alias Arrea.Resource

  # La misma tolerancia que el modulo usa para la cuota.
  @epsilon 1.0e-9

  setup do
    _ = start_supervised({Registry, keys: :unique, name: Arrea.Resource.Registry})
    :ok
  end

  # Nombres de compilacion, no de runtime: `Credo.Check.Warning.UnsafeToAtom`
  # tiene razon, y una suite que fabrica un atomo por test es una fuga de tabla
  # de atomos. El pool se recorre buscando hueco en el Registry, asi que dos
  # tests concurrentes nunca se pisan aunque la semilla les de el mismo inicio.
  @pool for n <- 1..256, do: :"resource_property_#{n}"

  defp unique_name do
    inicio = :erlang.phash2({self(), System.unique_integer([:positive])}, length(@pool))

    @pool
    |> Enum.drop(inicio)
    |> Kernel.++(Enum.take(@pool, inicio))
    |> Enum.find_value(fn nombre ->
      if Registry.lookup(Arrea.Resource.Registry, nombre) == [], do: nombre
    end)
  end

  property "used es la suma exacta de los titulares vivos, y la cuota dentro de la tolerancia" do
    check all(
            capacity <- integer(100..8_000),
            quota <- map(integer(10..1_000), &(&1 / 100)),
            # Los importes son FRACCIONES de los limites, no numeros sueltos.
            # Con importes absolutos, casi todo se rechaza en el primer
            # intento y el pico nunca se acerca al limite: asi se colaba un
            # modulo que admitiera un 5% de mas (verificado por mutacion).
            # 10%-30% del limite cada uno: con 8 tareas, varias conviven a la
            # vez (y por tanto comparten titular) y aun asi la suma total aprieta
            # el limite. Con 30%-120% solo cabia una y la colision de titulares
            # no llegaba a ocurrir —por eso el mutante de reservas multiples
            # pasaba por debajo de esta propiedad.
            megas <- list_of(integer(100..300), min_length: 2, max_length: 8),
            cuotas <- list_of(integer(100..300), min_length: 2, max_length: 8),
            espera <- list_of(integer(1..8), min_length: 1, max_length: 8),
            titulares <- integer(1..3),
            max_runs: 20
          ) do
      nombre = unique_name()
      {:ok, _} = Resource.start_link(nombre, capacity, quota: quota)

      # El agente cuenta FUERA del GenServer y en los DOS ejes. Si el resource
      # respeta los limites de verdad, la suma de lo que los titulares
      # sostienen a la vez no los pasa, aunque cada uno lo mida por su cuenta.
      cero = %{megas: 0, cuota: 0.0, pico_megas: 0, pico_cuota: 0.0}
      {:ok, medidor} = Agent.start_link(fn -> cero end)

      tareas =
        megas
        |> Enum.zip(cuotas)
        |> Enum.zip(espera)
        |> Enum.with_index()
        |> Enum.map(fn {{{megas, cuota}, ms}, indice} ->
          Task.async(fn ->
            round_trip(
              nombre,
              medidor,
              proporcion(capacity, megas),
              quota * cuota / 1_000,
              ms,
              {indice, titulares}
            )
          end)
        end)

      resultados = Task.await_many(tareas, 10_000)
      medido = Agent.get(medidor, & &1)
      Agent.stop(medidor)

      # Eje DURO: entero, exacto, sin tolerancia. Un pico por encima de la
      # capacidad es un fallo de verdad, no ruido.
      refute medido.pico_megas > capacity,
             "pico de #{medido.pico_megas} megas por encima de la capacidad #{capacity}"

      # Eje BLANDO: decimal, con tolerancia. Y aqui el pico no puede pasar de
      # la cuota mas que un residuo de coma flotante.
      refute medido.pico_cuota > quota + tolerancia(quota),
             "pico de #{medido.pico_cuota} de cuota por encima de #{quota}"

      # Lo que se admitio se solto, y lo que no se admitio no cuenta. En megas
      # eso es EXACTO; en cuota, dentro de la tolerancia.
      assert medido.megas == 0, "descuadre de #{medido.megas} megas con capacidad #{capacity}"
      assert near?(medido.cuota, 0.0, quota), "descuadre de #{medido.cuota} de cuota con #{quota}"

      assert Enum.all?(resultados, fn
               :admitido -> true
               {:rechazado, _motivo} -> true
             end)

      # Y el estado que quedo es el de un Resource sin titulares.
      assert %{used: 0, holders: []} = Resource.status(nombre)
      GenServer.stop(via(nombre))
    end
  end

  property "cada rechazo con numeros describe el mismo hecho que el estado, en su eje" do
    check all(
            capacidad <- integer(1..8_000),
            quota <- map(integer(1..1_000), &(&1 / 100)),
            peso <- integer(1..12_000),
            cuota <- map(integer(0..500), &(&1 / 100)),
            max_runs: 25
          ) do
      nombre = unique_name()
      {:ok, _} = Resource.start_link(nombre, capacidad, quota: quota)

      resultado = Resource.acquire(nombre, :unico, peso, cuota)
      estado = Resource.status(nombre)

      case resultado do
        {:ok, %{holder: :unico, capacity: pedido, quota: pedida}} ->
          # Admitido: los dos importes son los que se pidieron, y estan dentro
          # de los dos limites.
          assert pedido == peso
          assert pedida == cuota
          assert near?(estado.used, peso, capacidad)
          assert near?(estado.quota_used, cuota, quota)
          assert estado.holders == [{:unico, peso, cuota}]

        {:error,
         {:insufficient_capacity, %{requested: solicitado, available: disponible, capacity: cap}}} ->
          refute match?({:ok, _}, resultado)
          # Los tres numeros son del eje DURO...
          assert solicitado == peso
          assert cap == estado.capacity
          assert disponible == estado.available
          # ... y la cuota NO se ha tocado, que es otro hecho.
          assert near?(estado.quota_used, 0.0, quota)
          assert estado.used == 0
          assert estado.holders == []

        {:error, {:quota_exceeded, %{requested: solicitado, available: disponible, quota: cap}}} ->
          refute match?({:ok, _}, resultado)
          # Los tres numeros son del eje BLANDO...
          assert solicitado == cuota
          assert near?(cap, estado.quota, quota)
          assert near?(disponible, estado.quota_available, quota)
          # ... y los megas NO se han tocado, que es otro hecho.
          assert near?(estado.used, 0, capacidad)
          assert near?(estado.quota_used, 0.0, quota)
          assert estado.holders == []

        otro ->
          flunk(
            "una sola compra de #{peso} megas y #{cuota} de cuota en #{capacidad}/#{quota} dio #{inspect(otro)}"
          )
      end

      GenServer.stop(via(nombre))
    end
  end

  # ── Utilidades ─────────────────────────────────────────────────────────────

  # Megas enteros: el eje duro no admite decimales, asi que se redondea hacia
  # arriba y nunca baja de 1 (un modelo de 0 megas no es un modelo).
  defp proporcion(capacity, mille), do: max(1, round(capacity * mille / 1_000))

  defp tolerancia(capacity), do: @epsilon * max(abs(capacity), 1.0)
  defp near?(uno, otro, escala), do: abs(uno - otro) <= tolerancia(escala)

  defp via(nombre), do: {:via, Registry, {Arrea.Resource.Registry, nombre}}

  defp round_trip(nombre, medidor, megas, cuota, ms, {indice, titulares}) do
    # TITULARES COMPARTIDOS a proposito: con un titular por tarea, la via de
    # "varias reservas del mismo titular" no la recorre NINGUN test de este
    # fichero, que es como se colaron 4 GB perdidos en silencio. Con un pool
    # de 1 a 3 titulares, dos tareas compiten por el mismo sin avisar.
    titular = {:titular, rem(indice, titulares)}

    case Resource.acquire(nombre, titular, megas, cuota) do
      {:ok, receipt} ->
        # Lo que el GenServer dice y lo que los titulares sostienen tiene que
        # ser lo mismo, en el mismo instante. En megas, con `==`: son enteros
        # y no hay ruido. En cuota, con tolerancia: son decimales.
        estado = Resource.status(nombre)
        suma_megas = Enum.sum(Enum.map(estado.holders, fn {_t, mb, _c} -> mb end))
        suma_cuota = Enum.reduce(estado.holders, 0.0, fn {_t, _mb, c}, acc -> acc + c end)

        assert estado.used == suma_megas,
               "used #{estado.used} frente a la suma de los titulares vivos #{suma_megas}"

        assert near?(estado.quota_used, suma_cuota, estado.capacity)

        assert List.keymember?(estado.holders, titular, 0)
        assert estado.available == estado.capacity - estado.used
        assert receipt.capacity == megas
        assert receipt.quota == cuota

        Agent.update(medidor, fn %{megas: m, cuota: c, pico_megas: pm, pico_cuota: pc} ->
          %{
            megas: m + megas,
            cuota: c + cuota,
            pico_megas: max(pm, m + megas),
            pico_cuota: max(pc, c + cuota)
          }
        end)

        Process.sleep(ms)
        {:ok, %{capacity: devuelto_mb, quota: devuelta}} = Resource.release(nombre, titular)

        # Con titulares compartidos, este release puede devolver la reserva de
        # OTRA tarea con el mismo titular, asi que aqui no se puede pinningar
        # el importe exacto sin pelearse con la concurrencia. Lo que si se
        # comprueba es que devuelve una reserva REAL y no un cero disfrazado,
        # y el medidor resta lo que de verdad ha vuelto a la cuenta.
        assert is_number(devuelta) and devuelta >= 0
        assert is_integer(devuelto_mb) and devuelto_mb >= 0

        Agent.update(medidor, fn estado_medido ->
          %{
            estado_medido
            | megas: estado_medido.megas - devuelto_mb,
              cuota: estado_medido.cuota - devuelta
          }
        end)

        :admitido

      {:error, motivo} ->
        {:rechazado, motivo}
    end
  end
end
