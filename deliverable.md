# Cierre de Arrea · dialyzer a cero + RPC dirigido

**Repo:** Arrea · rama `cierre-arrea` · **Base:** `5ae5a72` (el `main` de verdad, con la fase 2 ya dentro)
**Fecha:** 2026-10-10 · 

| | |
|---|---|
| Dialyzer | 6 errores → **0** |
| Tests | 372 → **385** (+13) |
| Fallos | 6, **los mismos 6 de la base** (CLI y Command; ninguno mío) |
| Cobertura total | 66.4% → **66.8%** (base medida con el mismo comando) |
| Mutantes | **8 de 9 cazados** (§7). El noveno se escapa, y se explica |

---

## 1 · Los 6 errores de dialyzer

### 1.1 · Lo que decía el enunciado, medido

Los 6 son **cuatro specs**, y tienen una sola causa raiz. Salida real del primer
`mix dialyzer` sobre `7b46e93` (recortada a lo que importa):

```
Total errors: 6, Skipped: 0, Unnecessary Skips: 0

lib/arrea/bulkhead.ex:98:invalid_contract    run/2  — la funcion se deduce como none()
lib/arrea/bulkhead.ex:100:7:no_return         run/2 has no local return
lib/arrea/bulkhead.ex:125:invalid_contract    run/3  — idem
lib/arrea/bulkhead.ex:127:no_return           run/3 has no local return
lib/arrea/bulkhead.ex:130:10:call             safe_call(name, {:acquire, _}) breaks the contract
lib/arrea/bulkhead.ex:300:invalid_contract    status_map/1: el @spec no coincide con el success typing
```

### 1.2 · La causa: `safe_call/2` decia `atom()` y le llamaban con una tupla

`lib/arrea/bulkhead.ex:275` (antes):

```elixir
@spec safe_call(atom(), atom()) :: term() | :not_found
```

`run/3` la llama con `{:acquire, weight}`. El cuerpo acepta cualquier término y lo
pasa tal cual al `GenServer.call`, de modo que **el spec era lo que estaba mal**,
no el código. Y de ahí caían en cascada los dos `no_return`: con `term()` como
retorno, dialyzer no puede probar que el `case` de `run/3` es exhaustivo, así que
deduce `none()` y avisa de que la función se cae.

El arreglo (el que pediste, y solo el que):

```elixir
@type reply ::
        :ok
        | :full
        | {:available, integer()}
        | {:status, status()}
        | :not_found

@spec safe_call(atom(), term()) :: reply()
```

Con el retorno **real** (`:ok | :full | :not_found` más los dos pares de
`available/1` y `status/1`), los cuatro errores de `safe_call` caen solos. No hizo
falta tocar ni `run/2` ni `run/3`, ni un solo `dialyzer:no_warn`, ni una sola
linea de lógica.

> **No hay specs mintiendo ahora**, y se nota en algo que dialyzer no dice:
> `status()` no declaraba `:available`, y `status_map/1` sí lo devolvía. Eso no
> era solo un `invalid_contract`: el tipo público de `status/1` describía un
> mapa que la función nunca devolvía. Al añadir `available: integer()` al tipo,
> el `invalid_contract` de la línea 300 desaparece **y de paso** el tipo público
> dice la verdad. Un contrato loosening (`(map()) :: status()`) habría puesto el
> dialyzer en verde y habría dejado la mentira puesta.

### 1.3 · Salida final

```
$ mix dialyzer
Total errors: 0, Skipped: 0, Unnecessary Skips: 0
done in 0m5.56s
done (passed successfully)
EXIT=0
```

**Cero. No "los mismos 6".**

### 1.4 · Un detalle que sale de paso

`.dialyzer-ignore-warnings` lista `lib/arrea/worker.ex:493,497,498`, y dialyxir
avisa en cada carrera: `No :ignore_warnings opt specified in mix.exs and default
does not exist.` Ese fichero **no se está leyendo**: `mix.exs` no declara
`ignore_warnings`, así que el fichero es inerte. No lo he tocado (no era el
trabajo), pero conviene saberlo antes de confiar en él: hoy no silencia nada, y
`worker.ex` no da ningún warning. Si alguien lo lee como "estas tres líneas están
tapadas", se está engañando.

---

## 2 · El RPC dirigido: `Worker.request/4`

`send_message/2` **no se ha tocado**. Sigue siendo un `cast` que avisa y sigue,
con su comentario y su razon.

### 2.1 · Lo que se ha construido

La peticion **viaja por la cola que el worker ya sirve**, como una entrada mas, y
la respuesta sale cuando le toca a esa entrada. No hay `call` al worker.

```elixir
@spec request(atom(), atom(), term(), keyword()) :: {:ok, term()} | {:error, term()}
def request(worker_id, queue, message, opts \\ [])
```

```elixir
defp execute_queue_entry(%{payload: {:arrea_request, ref, message}, from: from}, state) do
  send(from, {:arrea_worker_reply, ref, run_request(message)})
  Process.send_after(self(), :poll, state.poll_interval)
  {:noreply, %{state | status: :idle}}
end
```

Tres decisiones de mecanismo, y por que:

1. **El mensaje es una funcion de aridad cero, y su valor de retorno es la
   respuesta.** Es la convencion que ya tenia `execute_queue_entry/2` para los
   payloads de cola; lo unico que cambia es que aqui el retorno no se tira. Arrea
   sigue **sin mirar dentro del mensaje** mas alla de intentar ejecutarlo, y
   sigue sin saber que es un modelo ni que es una GPU.
2. **El `ref` viaja dentro del payload** (`{:arrea_request, ref, mensaje}`),
   porque la cola es opaca: quien contesta no puede saber a quien pertenece la
   respuesta si no viaja con ella. Es el mismo truco que el de `GenServer.call`,
   y por eso una respuesta de una peticion vencida no puede satisfacer a otra.
3. **El monitor al worker va ANTES del empujon.** Si el worker se muere entre el
   `lookup` y el `push`, el `DOWN` ya esta en el buzon. Al reves, la peticion
   estara esperando un plazo que no va a llegar nunca.

### 2.2 · Motivos de respuesta, y lo que cada uno **no** aplana

| Motivo | Cuando | Por que no es otro |
|---|---|---|
| `{:ok, result}` | el worker ejecuto el mensaje | |
| `{:error, :worker_not_found}` | no hay worker con ese id **ahora mismo** | el mismo criterio que `send_message/2` |
| `{:error, :queue_not_found}` | la cola no existe | `Queue.push/3` se va con `:noproc`; sin traducirlo, el proceso de quien pregunta revienta |
| `{:error, :not_executable}` | el mensaje no era una funcion de aridad cero | se responde **cuando el worker lo recoge**, no al vencer el plazo: quien espera tiene derecho a saberlo ya |
| `{:error, {:exception, e}}` / `{:error, {kind, reason}}` | el payload fallo | el fallo es del mensaje de quien pregunta, no del worker; el worker sobrevive y sigue |
| `{:error, {:worker_down, reason}}` | **el worker se fue mientras esperaba** | **decision abierta nº3** (§4) |
| `{:error, :timeout}` | se cumplio el plazo | la entrada **sigue en la cola**: no hay cancelacion |

### 2.3 · Lo que la respuesta **no** puede deshacer

Al vencer el plazo, la peticion no se retira de la cola. Otro worker que sirva
esa cola puede cogerla y ejecutarla, y su respuesta llegara a un `ref` que ya no
mira nadie. **Quien espera puede marcharse; lo que hay en la cola, no.** Y si el
worker muere con la peticion dentro, lo que se ha perdido es la peticion: por eso
`{:worker_down, _}` y no `:not_found` a secas.

---

## 3 · Los tests, antes y después

### 3.1 · Rojo primero (test escrito antes que el código)

`test/arrea/worker_request_test.exs`, 13 tests, contra un `Arrea.Worker` sin
`request/4`:

```
$ mix test test/arrea/worker_request_test.exs
     ** (UndefinedFunctionError) function Arrea.Worker.request/4 is undefined or private
     ** (UndefinedFunctionError) function Arrea.Worker.request/3 is undefined or private
     ... (los 13)
Finished in 4.3 seconds (0.00s async, 4.3s sync)
13 tests, 13 failures
```

Rojo por la razon correcta: la función no existe. No por un typo en el test.

### 3.2 · Verde

```
$ mix test test/arrea/worker_request_test.exs
Finished in 1.1 seconds (0.00s async, 1.1s sync)
13 tests, 0 failures
```

### 3.3 · Que no puede ocurrir, test a test

Ningun test dice solo "responde". Cada uno ata una propiedad:

| Test | Lo que no puede pasar |
|---|---|
| el payload se ejecuta **dentro** del worker | que la peticion sea un `Task` con otro nombre: el trabajo se haria fuera del presupuesto |
| el que espera puede marcharse | que el worker se quede parado hasta que el que pregunto pase a por la respuesta |
| la respuesta caduca con su peticion | que la respuesta **tardia** de la primera conteste a la segunda |
| la peticion se consume | una entrada respondida que se queda en la cola y otro worker la ejecuta otra vez |
| lo que no se puede ejecutar | quemarse el plazo entero para recibir un silencio |
| un payload que revienta | que el que espere no se entere, o que caiga el worker |
| el worker no recuerda las peticiones | que el worker guarde estado de las peticiones (crece sin limite; y persistencia) |
| una peticion mas prioritaria se sirve antes | que la peticion tenga un camino aparte que se salte la cola |
| una peticion que no cabe en el presupuesto | que se sirva igualmente |
| un worker que nunca existio | esperar el plazo entero para descubrir que no hay nadie |
| un worker que se va mientras espera | que se responda `:worker_not_found` (o `:timeout`) cuando la peticion se ha perdido |
| una cola que no existe | un crash en el proceso de quien pregunta |

Dos detalles de los tests que merecen nombre:

- El orden **no** se comprueba con `assert_receive`: `assert_receive` se salta lo
  que no coincide, asi que si `:normal` llegase antes que `:peticion`, un
  `assert_receive :peticion` pasaria igual. Hay un helper `recoge_etiquetas/2` que
  recoge **en orden** y compara la lista entera.
- "El worker se va" se hace con `Process.exit(pid, :kill)`, **no** con
  `GenServer.stop/1`, y no es capricho: un worker ejecutando un payload esta
  dentro de un callback, y ahi un `stop` educado no se le cuela hasta que el
  payload acaba. Se vio fallando el test (5 segundos de plazo) antes de
  entenderlo. **Es un hallazgo, no un detalle del test** (§8).

---

## 4 · Las tres decisiones abiertas, y mi respuesta

### (1) · ¿Prioridad y peso de la cola, o camino aparte?

**Implementado: por la cola.** La peticion es una entrada mas, con la prioridad
y el peso que se le digan (`:priority`, `:weight` en las opciones), y el
presupuesto la puede rechazar igual que a las demas.

Por que: un camino aparte son dos maquinas de despacho, dos reglas de prioridad y
un segundo sitio donde un trabajo puede quedarse esperando sin que nadie lo sepa.
Encima, el camino aparte tiene que inventarse sus propias excusas: si la peticion
no cabe en el presupuesto, ¿que dice? Aqui dice lo que dice el resto — `:timeout`,
"nadie me ha cogido" — y la entrada sigue ahi para quien tenga hueco.

Lo que se paga: una peticion puede quedarse detras de entradas mas prioritarias.
Es la decision correcta para un sistema donde los agentes se hablan entre ellos, y
es exactamente lo contrario de lo que hacia un `call`.

### (2) · ¿Plazo por defecto?

**Implementado: `30_000` ms**, y **no inventado**: es el unico plazo por defecto
que ya tenia Arrea (`@default_timeout 30_000` en `Arrea.Command`, y el mismo
numero en `Arrea.Leader.CommandRunner`). Dos numeros distintos para lo mismo
serian dos politicas. Se cambia por `:timeout`, y `:infinity` se admite.

Si para Candil tiene sentido otro (una conversacion entre agentes que puede
durar mas de 30 s), es un `opts` y ya; pero **esa cifra es del dueño**, no mia.

### (3) · Si el worker muere mientras espera, ¿que motivo?

**Implementado: `{:error, {:worker_down, reason}}`**, con la razon del `DOWN`
dentro. No `:not_found`, que es el de "no habia nadie".

Porque la distincion es exactamente la que este repo no aplana: uno nunca
existio, el otro se llevo tu pregunta dentro y se fue. Un plano dice "tu peticion
sigue ahi" cuando lo que ha pasado es que se ha perdido. Y el `reason` se conserva
porque "se fue" y "murio" y "le pararon los pies" no son lo mismo para quien
decide si reintenta.

La alternativa que dejo sobre la mesa, si la quieres plana: `:worker_stopped`, sin
la razon. **No lo recomiendo**: pierde informacion que el que espera si tiene.

### (4) · Una cuarta, que no me habias dado

El arity de tu propuesta era `request(atom(), term(), timeout())`. Lo implemented
como **`request(worker_id, queue, message, opts)`**, por dos razones:

1. **La cola es explicita.** `request/3` tendria que deducir por donde encolar,
   y un worker puede servir varias. Elegir una en silencio seria inventarse una
   regla que el modulo no conoce, que es la misma clase de mentira que
   `send_message/2` cometia. Si el worker sirve una sola cola, el nombre ya lo
   tiene quien la creo.
2. **Las opciones, en vez de un plazo suelto.** Si la peticion entra con la
   prioridad y el peso de la cola (decision 1), tiene que poder **fijarlos**, y un
   `timeout` posicional no lleva eso dentro.

Los tres valores por defecto son los de la cola: `priority: 0`, `weight: 1`.

---

## 5 · Los 5 gates, con la salida real

Todos con el arbol tal y como se entrega, `CANDIL_DATA_DIR` a un temporal, y sin
`--seed` para que la salida sea la que sale. Son los mismos cinco que `mix qa`.

### Gate 1 · `mix format --check-formatted`

```
$ mix format --check-formatted
EXIT=0
```

### Gate 2 · `mix compile --warnings-as-errors --force`

```
$ mix compile --warnings-as-errors --force
Compiling 47 files (.ex)
Generated arrea app
EXIT=0
```

### Gate 3 · `mix credo --strict`

```
$ mix credo --strict
Analysis took 4.2 seconds (0.3s to load, 3.8s running 70 checks on 86 files)
723 mods/funs, found 3 refactoring opportunities, 2 code readability issues,
             10 software design suggestions.
EXIT=14
```

**El gate esta en ROJO, y lo estaba antes de tocar nada.** Medido sobre el arbol
limpio (`git stash -u` y recontar):

```
ANTES  : 711 mods/funs, 3 refactoring, 2 readability, 10 design   -> 15 avisos
DESPUES: 723 mods/funs, 3 refactoring, 2 readability, 10 design   -> 15 avisos
```

**Cero avisos nuevos.** Los 15 son los de siempre (`Arrea.Parallel`,
`Arrea.Leader`, `Arrea.Queue.handle_call/3` y `Arrea.Worker.take_from_queues/1`,
este ultimo con complejidad 10 sobre un maximo de 9 y ya lo tenia antes). El CI
de `.github/workflows/ci.yml` tiene el paso de credo **comentado** con un
comentario que lo dice. No lo he arreglado: no es de este trabajo.

### Gate 4 · `MIX_ENV=test mix test --cover`

```
$ MIX_ENV=test mix test --cover
 81.3% lib/arrea/worker.ex                           782      193       36
 89.6% lib/arrea/bulkhead.ex                        334       58        6
[TOTAL]  66.8%
----------------
5 properties, 385 tests, 6 failures
EXIT=2
```

Los 6 fallos, **los mismos 6 de la base** y ninguno mio:

```
1) test self hosted CLI Definition main/1 with no command shows help (Arrea.CLITest)
2) test Arrea.CLI module main/1 delegates to Arrea.CLI.Definition.main/1 (Arrea.CLITest)
3) test execute_with_asdf/4 prepends ASDF variables (Arrea.CommandTest)
4) test execute/2 :validate, false bypasses the safety check for trusted callers (Arrea.CommandTest)
5) test execute/2 accepts environment properties and passes them to shell (Arrea.CommandTest)
6) test execute/2 successfully executes a command (Arrea.CommandTest)
```

Y con matiz, porque decir "6" a secas no cuenta la historia entera: en **5
ejecuciones seguidas** de la suite completa sobre este arbol, una dio **7** fallos.
El septimo, cuando aparece, es siempre el mismo y **tambien cae en la base**:

```
run1: 385 tests, 7 failures
run2: 385 tests, 6 failures
run3: 385 tests, 6 failures
run4: 385 tests, 6 failures
run5: 385 tests, 6 failures

run3 septimo: 7) test module exists and has execute/1 (Arrea.CLI.Commands.NodesTest)
```

Es el "septimo intermitente" que ya mentionaba el entregable de F2 (§8.3).

Comparado con la base, mismo comando:

| | base (`7b46e93`) | este arbol |
|---|---|---|
| tests | 372 | **385** (+13) |
| fallos | 6, o 7 con `--seed 99` | 6, o 7 con `--seed 99` y en ~1 de cada 5 |
| cobertura | 66.4% | **66.8%** |

### Gate 5 · `mix dialyzer`

```
$ mix dialyzer
Total errors: 0, Skipped: 0, Unnecessary Skips: 0
done in 0m5.56s
done (passed successfully)
EXIT=0
```

---

## 6 · Los tests, los mismos, antes y después

| Fichero | antes | despues |
|---|---|---|
| `test/arrea/worker_request_test.exs` | **no existe** | 13 tests, 0 fallos |
| suite completa | 372 tests, 6 fallos | 385 tests, 6 fallos |

`Arrea.Worker` no habia cambiado de numero de tests: los 13 son nuevos y todos
en el fichero nuevo. Ni `worker_test.exs` ni `worker_serves_queues_test.exs` se
tocaron.

---

## 7 · Mutacion: 8 de 9 cazados

Se muta el codigo a proposito, se ejecuta `test/arrea/worker_request_test.exs`, y
se restaura. Lo que se busca no es "falla", es **que test lo caza**.

| # | Mutante | Resultado |
|---|---|---|
| M1 | la peticion se empuja con `priority: 0, weight: 1` fijos | **CAZADO** · 13 tests, 1 fallo |
| M2 | se acepta cualquier respuesta, sin mirar el `ref` | **CAZADO** · 13 tests, 1 fallo |
| M3 | un worker que se va se responde `:worker_not_found` | **CAZADO** · 13 tests, 1 fallo |
| M4 | el worker no se vigila mientras espera | **CAZADO** · 13 tests, 11 fallos |
| M5 | el worker ejecuta el payload y **tira** el resultado, responde `:ok` | **CAZADO** · 13 tests, 5 fallos |
| M6 | lo no ejecutable se responde como las demas entradas: un log y nada mas | **CAZADO** · 13 tests, 1 fallo |
| M7 | el payload se ejecuta sin `try`: si revienta, cae el worker | **CAZADO** · 13 tests, 1 fallo |
| M8 | se borra la clausula de peticion: la entrada cae en el camino viejo | **CAZADO** · 13 tests, 7 fallos |
| M9 | `demonitor` sin `[:flush]` | **SE ESCAPA** · 13 tests, 0 fallos |

**M9 se escapa, y no tengo un test que lo cace.** Explico por que, porque
"escapa" sin explicar es una deuda camuflada de verde: para que el `[:flush]`
importe tiene que caer un `DOWN` en el buzon **entre** el `send` de la respuesta y
el `demonitor` de quien espera, que es una ventana de microsegundos. Y no se puede
provocar desde un test, porque la respuesta se manda **despues** de que el payload
termina: un payload que mate al worker mata al worker antes de que exista
respuesta que enmascarar. Se queda por revision, no por test. El riesgo real es
un `{:DOWN, _, :process, _, _}` suelto en el buzon de un proceso que ya termino,
que es ruido, no corrupcion.

---

## 8 · Hallazgos que NO he arreglado (y por que)

### 8.1 · `Arrea.Queue` sirve la prioridad **mas baja** primero

El moduledoc dice *":priority | an ordering. **Higher runs first**"*, y el worker
si elige la mayor prioridad entre colas. Pero dentro de una sola cola:

```elixir
defp first_fitting(entries, budget) do
  entries
  |> :gb_trees.to_list()      # ascendente por {priority, sequence}
  |> Enum.find(fn {_key, entry} -> entry.weight <= budget end)
end
```

Medido, no leido:

```
$ Queue.push(:q, :baja, priority: 0); Queue.push(:q, :alta, priority: 9)
$ Queue.push(:q, :media, priority: 5); Enum.map(1..3, &Queue.claim(:q, 100).payload)
orden de claim: [:baja, :media, :alta]
```

**Es un bug preexistente de `Arrea.Queue`, no mio, y no lo he tocado**: cambiarlo
altera el orden de entrega de todo lo que ya consume la cola, y esa es una
decision del dueño, no un efecto secundario de cerrar dialyzer. El arreglo no es
voltear la lista (eso cambiaria el FIFO dentro de una prioridad por LIFO): es
recorrer bandas de prioridad de mayor a menor, y dentro de cada banda seguir
tomando la mas antigua.

**Como afecta a este trabajo:** mis tests **no** miden el orden dentro de una sola
cola, precisamente para no dejar escrito como verdad un bug. El test de prioridad
mide el caso que si es del worker y si esta probado (elegir entre **dos** colas),
y el resto afirma cosas que el bug no toca: la peticion viaja con su prioridad y su
peso, y el presupuesto la rechaza.

### 8.2 · `GenServer.stop/1` no interrumpe a un worker que ejecuta un payload

Descubierto porque el test de "el worker se va mientras espera" fallaba con
`:timeout` en vez de con el motivo del worker. Un worker ejecutando un payload esta
dentro de un callback, y ahi el `stop` educado no se le cuela hasta que el payload
acaba: **cinco segundos de `Process.sleep(5_000)` en el payload, cinco segundos de
`GenServer.stop`**. Solo un `kill` lo para.

Consecuencia para Candil: **`Worker.stop/1` no es una parada de emergencia.** Si un
worker se ha quedado atascado en un payload, la unica forma de pararlo es matarlo.
No lo he cambiado; lo señalo porque es el tipo de dato que hace falta antes de
usarlo en un sistema de agentes.

### 8.3 · El séptimo fallo intermitente

Con `--seed 99` (y solo con seed 99, en cuatro ejecuciones seguidas) cae un
septimo: `test module exists and has execute/1 (Arrea.CLI.Commands.NodesTest)`.
Sin fijar semilla aparece en ~1 de cada 5. Pasa en solitario y falla en la suite
completa. **Es de la base y sigue siendo de la base**: identico antes y despues
con la misma semilla. Es el "septimo intermitente" que ya mencionaba el
entregable de F2. No lo he tocado.

---

## 9 · Lo que NO he verificado

Con nombre, como pidiste:

1. **El CI.** No he ejecutado `.github/workflows/ci.yml`. Ni el lint, ni el
   compile & test, ni el dialyzer, que en el CI solo corre en `main` y en
   `cleanup/audit-and-i18n` —esta rama no la dispara ni por push ni por PR sin
   tocar el `if`—. Lo que he corrido son los 5 gates de `mix qa` en local.
2. **Credo en verde.** No lo he arreglado (§5, gate 3). Sigue en rojo con los
   mismos 15 avisos de la base.
3. **Los 6 fallos de `Arrea.Command` y `Arrea.CLI`.** Siguen rojos. No he
   investigated por que: no son de este trabajo y no los he tocado.
4. **El mutante M9.** Se escapa, y el test que lo cace no existe (§7).
5. **`mix docs`.** No he generado la documentacion; el `@doc` de `request/4` no se
   ha visto renderizado, solo compilado.
6. **Carga y concurrencia real.** 13 tests en un solo proceso, sin `async: true` y
   sin presion. El comportamiento bajo peticiones simultaneas desde muchos procesos
   (que es el caso de Candil fase 5) **no esta medido**. En particular: no he
   medido si dos peticiones simultaneas al mismo worker se responden con el `ref`
   correcto, y el unico test de `ref` es secuencial.
7. **El fallo de `Arrea.Queue` (§8.1)**: sin medir de forma reproducible bajo
   concurrencia; la medicion de §8.1 es de un solo proceso.
8. **Sin commit, sin push, sin PR**, como pediste. El arbol esta en la rama
   `cierre-arrea` con `lib/arrea/bulkhead.ex` y
   `lib/arrea/worker.ex` modificados y `test/arrea/worker_request_test.exs` sin
   seguimiento.
9. **Este `deliverable.md` sustituye al de F2 en el arbol de trabajo**, porque
   me dijiste que escribiera aqui. **No se ha perdido nada**: el de F2 esta
   commiteado en `7b46e93` y se saca con `git show 7b46e93:deliverable.md`.
   Lo que no he hecho (y no hago sin que me lo digas) es el commit de este.

---

## 10 · Que cambia, en dos lineas

**Dialyzer a cero** arreglando el unico spec que estaba mal (`safe_call/2`), mas
el tipo publico `status()`, que no declaraba el `:available` que su propia funcion
devolvia. Sin `no_warn`, sin tocar la logica.

**`Worker.request/4`**: la peticion entra por la cola que el worker ya sirve, con
su prioridad y su peso, y la respuesta sale cuando le toca — con `ref` propio,
con plazo, y distinguiendo "no habia worker" de "el worker se llevo tu pregunta".
