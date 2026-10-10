defmodule Arrea.Resource do
  @moduledoc """
  Resource — two budgets, a hard one and a soft one, both with **identity**.

  A `Bulkhead` already counts weight: `capacity` and `used`, and a GPU-sized
  example in its own `@moduledoc`. What a bulkhead cannot answer is *whose*
  weight a number is. `release` is `{:release, weight}` — the caller subtracts a
  quantity and the server never learns a name. That is fine when every holder
  weighs 1. It is not fine when two 4 GB models share 16 GB.

  ## Los dos ejes, y por qué son dos y no uno

  Un knapsack de GPU mezcla dos preguntas que no son la misma, y la fase viene
  pidiendo Separarlas desde el §7.5 del diseño del motor:

    - **Capacidad física** — los megas que la carga ocupa de verdad. Es un
      hecho: si no cabe, no cabe. Es **entera**, en megas.
    - **Cuota** — el presupuesto de una política: un modelo no puede comerse
      el 80% de la GPU aunque quepa. Es una **decisión**, y por eso es decimal.

  Un modelo puede entrar por megas y ser declinado por cuota, o al revés. Con un
  solo eje esas dos respuestas son el mismo número y no se distinguen; con dos,
  cada rechazo dice **qué** no daba y **cuánto**:

      {:error, {:insufficient_capacity, %{requested: 12_288, available: 4_096, capacity: 16_384}}}
      {:error, {:quota_exceeded, %{requested: 0.8, available: 0.25, quota: 1.0}}}

  **Enteros en el eje duro es lo que de verdad arregla las cosas.** Una GGUF
  pesa bytes y la caché KV son bytes, así que el eje que decide si algo se
  puede cargar se cuenta en megas enteros: la aritmética es **exacta** y no
  necesita epsilon. `0.1 + 0.2` no aparece en la capacidad porque los megas no
  son decimales.

  ## La epsilon se queda, pero solo en la cuota

  El eje blando **sí** es decimal, y ahí las diferencias son de nil. La
  comparación de cuota lleva una tolerancia relativa con suelo absoluto, y lo
  derivado se publica redondeado a `@precision` decimales, porque un router va
  a leer estos números. El eje de capacidad no se toca: es entero.

  Lo que el que llama da se devuelve **tal cual**: el peso del recibo, el
  `requested` de cada rechazo y los importes de `holders`.

  ## La reserva no termina con la función que la pidió

  `Bulkhead.run/3` libera en un `after`: el slot vive exactamente lo que la
  función. Un modelo cargado no. Así que aquí no hay `run/3`. Lo que devuelve
  `acquire/4` está **committeado** —un `receipt`— y sigue commiteado hasta que
  alguien llama a `release/2`, que devuelve los **dos** importes. Si el que
  llama se muere, la capacidad sigue ocupada, porque fingir que una GPU se ha
  liberado sola es cómo un knapsack empieza a mentir.

      {:ok, receipt} = Resource.acquire(:cuda0, :embedder, 1_024, 0.1)
      # ... luego, y quiza desde otro proceso ...
      {:ok, %{capacity: 1_024, quota: 0.1}} = Resource.release(:cuda0, :embedder)

  ## Un coste que no se declara no es un coste de cero

  Hay cuatro rechazos y son cuatro hechos distintos:

    - `:unknown_cost` — el que llama no ha declarado uno de los dos importes.
      Tratarlo como `0` admite todo lo no declarado y convierte el knapsack en
      una suposición con presupuesto.
    - `:invalid_weight` — un número que no es un importe: negativo, o fraccional
      en el eje de megas, que es entero.
    - `{:insufficient_capacity, detail}` — megas que no caben, con tres números.
    - `{:quota_exceeded, detail}` — cuota agotada, con tres números.

  Por defecto `quota` es `:infinity` y el eje blando no rechaza nunca, así que el
  comportamiento por defecto es el de un resource de una sola pregunta.

  ## El titular es opaco, y su identidad es estricta

  Sea `:modelo`, un pid, un `%{…}` o un string: se guarda entero y se devuelve
  entero. Arrea nunca mira dentro y nunca sabe qué es un modelo; ver
  `Arrea.Queue`, cuyo payload lleva la misma regla. **La identidad es estricta**:
  la reserva del titular `1` solo la devuelve `release(name, 1)`, nunca
  `release(name, 1.0)`, porque en Erlang `1 == 1.0` es verdad y con `==` uno se
  llevaría la reserva de otro.

  ## Qué NO hace

  No persiste. El estado vive en el GenServer y está **hecho** para perderse al
  reiniciar: dos verdades sobre la misma GPU, escritas por dos repos, son peor
  que ninguna. No lee el dispositivo, no decide qué se descarga y no encola —eso
  es `Arrea.Queue`—. Y `quota` es **un número con nombre**, no un motor de
  políticas: aquí no hay round-robin, ni VIP, ni prioridad. Eso es una decisión
  del dueño y este módulo no la toma.

  ## Telemetría

    - `[:arrea, :resource, :acquired]` — una reserva quedó commiteada
    - `[:arrea, :resource, :released]` — una reserva se devolvió
    - `[:arrea, :resource, :rejected]` — se pidió y no se dio
    - `[:arrea, :resource, :unknown_cost]` — no se declaró un importe

  Metadata tipada (`Arrea.Telemetry.Events.resource_metadata/0`):
  `%{name: atom(), capacity: non_neg_integer(), used: non_neg_integer(),
     quota_used: number(), holders: non_neg_integer()}`.

  ## Registro

  Cada resource se registra en `Registry` con un nombre único bajo
  `Arrea.Resource.Registry`.
  """

  use GenServer

  alias Arrea.Telemetry.Events, as: TE

  @typedoc "El nombre de un resource, que es también la clave en el registro."
  @type name :: atom()

  @typedoc """
  Megas enteros: el eje DURO, el físico.

  Entero a propósito. Una GGUF pesa bytes y la caché KV son bytes; si este eje
  fuera decimal, `0.1 + 0.2` volvería a ser `0.30000000000000004` y volvería
  hacen falta una tolerancia para decidir si algo cabe. Aquí la cuenta es
  exacta y no la tiene.
  """
  @type capacity_mb :: non_neg_integer()

  @typedoc """
  Unidades de cuota: el eje BLANDO, el de la política.

  Decimal, porque una política reparte en fracciones («este modelo no puede
  pasar del 30%»). Aquí sí hace falta tolerancia al comparar y redondeo al
  publicar.
  """
  @type quota_units :: number()

  @typedoc "Sea lo que sea el que llama use para nombrar una reserva. Opaco."
  @type holder :: term()

  @typedoc """
  Por qué no hubo reserva.

  Deliberadamente no el `:bulkhead_full` del bulkhead: los dos módulos
  rechazan por hechos distintos y la verdad sobre cuál ocurrió no puede ser
  ambigua.
  """
  @type rejection ::
          {:insufficient_capacity,
           %{requested: capacity_mb(), available: capacity_mb(), capacity: capacity_mb()}}
          | {:quota_exceeded,
             %{requested: quota_units(), available: quota_units(), quota: quota_units()}}
          | :unknown_cost
          | :invalid_weight
          | :resource_not_found

  @typedoc "Lo que devuelve `release/2`: lo que ha vuelto a la cuenta."
  @type released :: %{capacity: capacity_mb(), quota: quota_units()}

  @typedoc "La cuenta entera, en los dos ejes."
  @type status :: %{
          name: name(),
          capacity: capacity_mb(),
          used: capacity_mb(),
          available: capacity_mb(),
          quota: quota_units() | :infinity,
          quota_used: quota_units(),
          quota_available: quota_units() | :infinity,
          holders: [{holder(), capacity_mb(), quota_units()}],
          accepted: non_neg_integer(),
          rejected: non_neg_integer()
        }

  @typedoc "Prueba de una reserva, para poder devolver exactamente la misma."
  @type receipt :: %{
          holder: holder(),
          capacity: capacity_mb(),
          quota: quota_units(),
          acquired_at: integer()
        }

  # Tolerancia RELATIVA de la comparación de CUOTA, con suelo absoluto. No la
  # necesita el eje de megas, que es entero y exacto.
  @epsilon 1.0e-9

  # Decimales con los que se PUBLICA la cuota. La cuenta va entera; el
  # redondeo es solo de salida.
  @precision 6

  @doc """
  Arranca un resource con `capacity` megas.

  ## Opciones

    - `:quota` — presupuesto de política, un número `>= 0`. Por defecto
      `:infinity`: el eje blando no rechaza nunca.

  Una capacidad que no sea un entero `>= 0` se rechaza con
  `{:error, %Arrea.Error{code: :invalid_config}}`. `0` es una capacidad
  legítima: significa «ahora no cabe nada», que no es lo mismo que «no lo sé».
  """
  @spec start_link(name(), capacity_mb(), keyword()) :: GenServer.on_start()
  def start_link(name, capacity, opts \\ []) when is_atom(name) do
    case validate_opts([name: name, capacity: capacity] ++ opts) do
      :ok ->
        GenServer.start_link(__MODULE__, [name: name, capacity: capacity] ++ opts,
          name: via_tuple(name)
        )

      {:error, %Arrea.Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Commitea `cost` megas y `policy_cost` unidades de cuota a `holder`.

  Los dos importes se pasan siempre: el que solo pase uno está diciendo media
  verdad, y media verdad en un eje duro es un rechazo que no va a entender
  nadie.

  `cost` es un entero `> 0` — nadie tiene un modelo de 0 megas—. `policy_cost`
  es un número `>= 0`, porque «este modelo no consume cuota» es una afirmación
  de política legítima.

  La reserva sigue puesta hasta que `release/2` devuelva **ese** titular, desde
  el proceso que sea y cuando sea. Nada se libera al acabar la función que la
  pidió: esa es la diferencia con `Bulkhead.run/3`, y es el punto.

  Devuelve `{:error, :unknown_cost}` si falta alguno de los dos importes,
  `{:error, :invalid_weight}` si alguno no es un importe válido, y el rechazo
  del eje que no da, con sus tres números. Un rechazo no reserva nada.

  Si el resource no está registrado, `{:error, :resource_not_found}` — nunca un
  `exit`.
  """
  @spec acquire(name(), holder(), term(), term()) :: {:ok, receipt()} | {:error, rejection()}
  def acquire(name, holder, cost, policy_cost) when is_atom(name) do
    case safe_call(name, {:acquire, holder, cost, policy_cost}) do
      {:ok, reply} -> reply
      :not_found -> {:error, :resource_not_found}
    end
  end

  @doc """
  Devuelve la reserva que `holder` tiene, en los dos ejes.

  Devuelve *esa* reserva, no «un peso»: liberar `:a` no puede decrementar lo de
  `:b`. Que el titular no tenga nada no es un error —la cuenta ya está en ese
  estado— y lo que se devuelve entonces son ceros, que es exactamente lo que
  ha vuelto a la cuenta.

  Es un `call` y no un `cast`: devolver es un hecho que quien llama necesita
  saber que ha ocurrido, por el mismo motivo que `Queue.claim/2` es un `call`.
  """
  @spec release(name(), holder()) :: {:ok, released()} | {:error, :resource_not_found}
  def release(name, holder) when is_atom(name) do
    case safe_call(name, {:release, holder}) do
      {:ok, {:released, released}} -> {:ok, released}
      :not_found -> {:error, :resource_not_found}
    end
  end

  @doc """
  Megas libres ahora mismo, en el eje duro.

  Consulta pura: no reserva nada y no cambia nada, la pareja de `Queue.peek/2`.
  Devuelve `0` si el resource no está registrado.
  """
  @spec available(name()) :: capacity_mb()
  def available(name) do
    case safe_call(name, :available) do
      {:ok, {:available, free}} -> free
      :not_found -> 0
    end
  end

  @doc """
  Unidades de cuota libres ahora mismo, en el eje blando.

  Devuelve `:infinity` si el resource se_arrancó sin cuota, y si el nombre no
  está registrado, como el resto de la API.
  """
  @spec quota_available(name()) :: quota_units() | :infinity
  def quota_available(name) do
    case safe_call(name, :quota_available) do
      {:ok, {:quota_available, free}} -> free
      :not_found -> :infinity
    end
  end

  @doc """
  La cuenta entera: los dos ejes, y **quién** tiene qué.

  `holders` es lo que ningún contador escalar puede dar, y sin la lista de
  titulares «devolver exactamente lo que se devolvió» no se puede implementar.
  Devuelve `nil` si el resource no está registrado.

  ## Ejemplo

      iex> Arrea.Resource.status(:workers)
      %{name: :workers, capacity: 10_240, used: 0, available: 10_240, quota: :infinity,
        quota_used: 0.0, quota_available: :infinity, holders: [], accepted: 0, rejected: 0}
  """
  @spec status(name()) :: status() | nil
  def status(name) do
    case safe_call(name, :status) do
      {:ok, {:status, status}} -> status
      :not_found -> nil
    end
  end

  @doc """
  Valida las opciones de un resource.

  `:ok` si son válidas, o `{:error, %Arrea.Error{code: :invalid_config}}` si
  falta `:name`, si falta `:capacity`, si `:capacity` no es un entero `>= 0`, o
  si `:quota` no es un número `>= 0` ni `:infinity`.
  """
  @spec validate_opts(keyword()) :: :ok | {:error, Arrea.Error.t()}
  def validate_opts(opts) do
    cond do
      not Keyword.has_key?(opts, :name) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "name option is required"}}

      not Keyword.has_key?(opts, :capacity) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "capacity is required"}}

      invalid_capacity?(opts) ->
        {:error, %Arrea.Error{code: :invalid_config, message: "capacity must be an integer >= 0"}}

      invalid_quota?(opts) ->
        {:error,
         %Arrea.Error{code: :invalid_config, message: "quota must be a number >= 0 or :infinity"}}

      true ->
        :ok
    end
  end

  # ── Callbacks del GenServer ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    case validate_opts(opts) do
      :ok ->
        {:ok,
         %{
           name: Keyword.fetch!(opts, :name),
           capacity: Keyword.fetch!(opts, :capacity),
           used: 0,
           quota: Keyword.get(opts, :quota, :infinity),
           quota_used: 0.0,
           holders: [],
           accepted: 0,
           rejected: 0
         }}

      {:error, %Arrea.Error{} = error} ->
        {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_call({:acquire, holder, cost, policy_cost}, _from, state) do
    case cost_error(cost, policy_cost) do
      nil -> admit(state, holder, cost, policy_cost)
      reason -> refuse(state, reason)
    end
  end

  @impl true
  def handle_call({:release, holder}, _from, state) do
    case take_holder(state.holders, holder) do
      :none ->
        {:reply, {:released, %{capacity: 0, quota: 0.0}}, state}

      {capacity, quota, kept} ->
        freed = %{
          state
          | holders: kept,
            used: state.used - capacity,
            quota_used: max(0.0, state.quota_used - quota)
        }

        TE.emit_resource(:released, metadata(freed))
        {:reply, {:released, %{capacity: capacity, quota: publish(quota)}}, freed}
    end
  end

  @impl true
  def handle_call(:available, _from, state) do
    {:reply, {:available, state.capacity - state.used}, state}
  end

  @impl true
  def handle_call(:quota_available, _from, state) do
    {:reply, {:quota_available, quota_free(state)}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:status, status_map(state)}, state}
  end

  # ── Decisiones ───────────────────────────────────────────────────────────

  @spec admit(map(), holder(), capacity_mb(), quota_units()) :: {:reply, tuple(), map()}
  defp admit(state, holder, capacity, quota) do
    cond do
      not fits_capacity?(state, capacity) ->
        refuse(state, {:insufficient_capacity, capacity_detail(state, capacity)})

      not fits_quota?(state, quota) ->
        refuse(state, {:quota_exceeded, quota_detail(state, quota)})

      true ->
        commit(state, holder, capacity, quota)
    end
  end

  @spec commit(map(), holder(), capacity_mb(), quota_units()) :: {:reply, tuple(), map()}
  defp commit(state, holder, capacity, quota) do
    receipt = %{holder: holder, capacity: capacity, quota: quota, acquired_at: now_ms()}

    taken = %{
      state
      | used: state.used + capacity,
        quota_used: state.quota_used + quota,
        holders: state.holders ++ [{holder, capacity, quota}],
        accepted: state.accepted + 1
    }

    # La telemetria sale DESPUES, con la cuenta ya commiteada: un `:acquired`
    # que dijera el `quota_used` de antes de la compra seria un numero falso.
    TE.emit_resource(:acquired, metadata(taken))

    {:reply, {:ok, receipt}, taken}
  end

  @spec refuse(map(), rejection()) :: {:reply, tuple(), map()}
  defp refuse(state, reason) do
    counted = %{state | rejected: state.rejected + 1}
    TE.emit_resource(refusal_event(reason), metadata(counted))
    {:reply, {:error, reason}, counted}
  end

  # El eje duro es entero: esto no necesita tolerancia y no la tiene.
  @spec fits_capacity?(map(), capacity_mb()) :: boolean()
  defp fits_capacity?(state, capacity), do: state.used + capacity <= state.capacity

  # El eje blando es decimal: aquí sí hace falta, porque `0.1 + 0.2` vale
  # 0.30000000000000004 y sin margen una política rechazaria lo que le cabe.
  @spec fits_quota?(map(), quota_units()) :: boolean()
  defp fits_quota?(state, quota) do
    case state.quota do
      :infinity -> true
      limite -> state.quota_used + quota <= limite + tolerance(limite)
    end
  end

  @spec tolerance(number()) :: float()
  defp tolerance(quota), do: @epsilon * max(abs(quota), 1.0)

  # Se aplica AL PUBLICAR, nunca al calcular. Por debajo de `@epsilon` se
  # publica 0.0: un residuo de 5.5e-17 no es un uso, es ruido de coma
  # flotante. Un uso real de 0.0000001 se ve, porque está por encima del suelo.
  @spec publish(number()) :: number()
  defp publish(value) when is_float(value) do
    if abs(value) < @epsilon, do: 0.0, else: Float.round(value, @precision)
  end

  defp publish(value), do: value

  @spec capacity_detail(map(), capacity_mb()) :: map()
  defp capacity_detail(state, capacity) do
    %{requested: capacity, available: state.capacity - state.used, capacity: state.capacity}
  end

  @spec quota_detail(map(), quota_units()) :: map()
  defp quota_detail(state, quota) do
    %{requested: quota, available: publish(quota_free(state)), quota: state.quota}
  end

  @spec quota_free(map()) :: quota_units() | :infinity
  defp quota_free(%{quota: :infinity}), do: :infinity
  defp quota_free(state), do: publish(state.quota - state.quota_used)

  # `nil` significa «los dos importes son válidos», y el llamante puede pasar a
  # la cuenta. Los dos ejes se validan por separado porque sus reglas son
  # distintas: los megas son enteros, la cuota es decimal.
  @spec cost_error(term(), term()) :: :unknown_cost | :invalid_weight | nil
  defp cost_error(cost, policy_cost) do
    cond do
      not is_number(cost) or not is_number(policy_cost) -> :unknown_cost
      not valid_capacity_cost?(cost) -> :invalid_weight
      not valid_quota_cost?(policy_cost) -> :invalid_weight
      true -> nil
    end
  end

  @spec valid_capacity_cost?(term()) :: boolean()
  defp valid_capacity_cost?(cost), do: is_integer(cost) and cost > 0

  @spec valid_quota_cost?(term()) :: boolean()
  defp valid_quota_cost?(cost), do: is_number(cost) and cost >= 0

  @spec refusal_event(rejection()) :: atom()
  defp refusal_event(:unknown_cost), do: :unknown_cost
  defp refusal_event(_reason), do: :rejected

  # ── Helpers privados ─────────────────────────────────────────────────────

  @spec invalid_capacity?(keyword()) :: boolean()
  defp invalid_capacity?(opts) do
    case Keyword.get(opts, :capacity) do
      nil -> true
      value -> not (is_integer(value) and value >= 0)
    end
  end

  @spec invalid_quota?(keyword()) :: boolean()
  defp invalid_quota?(opts) do
    case Keyword.get(opts, :quota, :infinity) do
      :infinity -> false
      value -> not (is_number(value) and value >= 0)
    end
  end

  @spec now_ms() :: integer()
  defp now_ms, do: System.monotonic_time(:millisecond)

  # Una reserva liberada, UNA devuelta.
  #
  # Un titular puede tener VARIAS reservas —el mismo modelo cargado dos veces—,
  # y `release/2` devuelve una por llamada. Con dos `acquire` y un `release`, la
  # segunda reserva se queda puesta para siempre, sin ningun aviso: era
  # exactamente lo que hacia la version anterior, que encontraba todas las
  # reservas del titular, devolvia la primera y quitaba todas.
  #
  # Y la identidad es ESTRICTA: `===` y no `==`. Con `==`, `release(n, 1)`
  # se llevaría la reserva del titular `1.0`, porque en Erlang `1 == 1.0` es
  # verdad. Eso es el eje del contrato —devolver lo que se devolvió, no lo que
  # se parece a ello— y un `==` lo rompe sin avisar.
  @spec take_holder([{holder(), capacity_mb(), quota_units()}], holder()) ::
          {capacity_mb(), quota_units(), [{holder(), capacity_mb(), quota_units()}]} | :none
  defp take_holder(holders, holder) do
    not_mine = fn {candidate, _capacity, _quota} -> candidate !== holder end

    case Enum.split_while(holders, not_mine) do
      # La cabeza de `rest` es la PRIMERA reserva del titular, y solo esa sale.
      # Ojo con las dos trampas que hay aqui, y las dos se han pagado:
      #   1. Si el patron exige `{[], ...}`, solo se encuentra la reserva cuando
      #      es la PRIMERA de la lista, y soltar a un titular que no estaba el
      #      primero devuelve cero en silencio.
      #   2. Si se devuelve solo `rest`, se TIRAN las reservas que habian antes
      #      (`before`), y esas son de OTROS titulares: la cuenta de otro se
      #      desvanece sin que nadie lo toque.
      # Lo que se queda es todo menos esa: `before` y `rest` pegados.
      {before, [{_holder, capacity, quota} | rest]} ->
        {capacity, quota, before ++ rest}

      _nada_de_este_titular ->
        :none
    end
  end

  @spec safe_call(atom(), term()) :: {:ok, term()} | :not_found
  defp safe_call(name, request) do
    case Registry.lookup(Arrea.Resource.Registry, name) do
      [{pid, _}] ->
        try do
          {:ok, GenServer.call(pid, request)}
        catch
          :exit, _reason -> :not_found
        end

      [] ->
        :not_found
    end
  end

  @spec via_tuple(atom()) :: {:via, Registry, {Arrea.Resource.Registry, atom()}}
  defp via_tuple(name), do: {:via, Registry, {Arrea.Resource.Registry, name}}

  @spec metadata(map()) :: TE.resource_metadata()
  defp metadata(%{name: name, capacity: capacity, used: used, quota_used: quota_used, holders: h}) do
    %{
      name: name,
      capacity: capacity,
      used: used,
      quota_used: publish(quota_used),
      holders: length(h)
    }
  end

  @spec status_map(map()) :: status()
  defp status_map(state) do
    %{
      name: state.name,
      capacity: state.capacity,
      used: state.used,
      available: state.capacity - state.used,
      quota: state.quota,
      quota_used: publish(state.quota_used),
      quota_available: quota_free(state),
      # Los importes de los titulares se devuelven TAL CUAL los dio el que
      # llama: son suyos. Lo derivado se redondea; lo recibido, no.
      holders: state.holders,
      accepted: state.accepted,
      rejected: state.rejected
    }
  end
end
