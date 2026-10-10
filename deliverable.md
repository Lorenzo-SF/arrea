# F2 · `Arrea.Resource` — entregable de la fase

**Repo:** Arrea · rama `resource-knapsack` (sin commit, sin push, sin PR)
**Fecha:** 2026-10-10 · **Base:** `e1c16ff` · **Contrato:** `notes/f2-contrato.md`

---

## 1 · Qué es esto, en una frase

Un `GenServer` por nombre que lleva **dos cuentas con identidad estricta**: los
**megas** que una carga ocupa de verdad (enteros, exactos, sin margen) y las
**unidades de cuota** que una política le concede (decimales, con tolerancia). La
reserva se queda committeada hasta que alguien devuelve **los dos** importes.

Lo que `Bulkhead` no tiene y esto sí: *quién* tiene cada cosa, dos ejes que se
distinguen, un motivo por eje con sus tres números, y una reserva que sobrevive
a la función que la pidió.

| | |
|---|---|
| Tests | 339 → **372** (+33 tests, +2 propiedades) |
| Fallos | **6 o 7**: los 6 de siempre, y un séptimo **intermitente** que
|        | también aparece en la base (§4) |
| Cobertura | 64.6% → **66.3%** (base medida con el mismo método, §4) |
| `lib/arrea/resource.ex` | **98.0%** (105 líneas relevantes, 2 sin cubrir) |
| Mutantes | **15 de 15 cazados** (§5) |

---

## 2 · Los dos ejes

La pregunta del dueño —«¿y usar ambas?»— es la que define el módulo. Un
knapsack de GPU mezcla dos preguntas que no son la misma:

| Eje | Qué es | Dureza | Tipo |
|---|---|---|---|
| **capacidad** | megas que ocupa de verdad | **dura**: si no cabe, no cabe | **entero** |
| **cuota** | presupuesto de política | **blanda**: es una decisión | **decimal** |

Un modelo entra por megas y se declina por cuota, o al revés. Con un solo eje
esas dos respuestas son el mismo número; con dos, cada rechazo dice **qué** no
daba y **cuánto**:

```elixir
{:error, {:insufficient_capacity, %{requested: 12_288, available: 4_096, capacity: 16_384}}}
{:error, {:quota_exceeded,        %{requested: 0.8,     available: 0.25,   quota: 1.0}}}
```

**Enteros en el eje duro es lo que arregla los defectos 1 y 2**, no la epsilon.
Una GGUF pesa bytes y la caché KV son bytes; si el eje que decide se contara en
decimales, `0.1 + 0.2` volvería a ser `0.30000000000000004` y haría falta una
tolerancia para decidir si algo cabe. **La epsilon se queda, pero solo en la
cuota**, que es donde las diferencias son de nil.

Por defecto `quota` es `:infinity` y el eje blando no rechaza nunca: el
comportamiento por defecto es el de un resource de una sola pregunta, y la
decisión abierta nº1 (round-robin vs FIFO con VIP) no se toca. `quota` es **un
número con nombre**, no un motor de políticas: aquí no hay VIP, ni prioridad, ni
orden. Eso es del dueño.

### La API

```elixir
start_link(name, capacity_mb, opts)         # opts: quota: número | :infinity
acquire(name, holder, cost_mb, quota_cost) :: {:ok, receipt} | {:error, rejection}
release(name, holder)                      :: {:ok, %{capacity:, quota:}} | {:error, :resource_not_found}
available(name)                            :: non_neg_integer()      # megas
quota_available(name)                      :: number() | :infinity   # cuota
status(name)                               :: status | nil
validate_opts(opts)                        :: :ok | {:error, Arrea.Error.t()}
```

`acquire/4` y no `acquire/3`: los dos importes se pasan **siempre**. El que solo
pase uno está diciendo media verdad, y media verdad en un eje duro es un
rechazo que no va a entender nadie.

`release/2` devuelve **los dos** importes. Si devolviera solo uno, la fuga de
capacidad del otro eje se repite en el otro sentido.

### Lo que este módulo NO es

Un motor de políticas. `quota` es un número con nombre; la política vive fuera
(§5, D3/D8 del contrato). No persiste, no lee la GPU, no decide qué se descarga
y no encola.

---

## 3 · Los 5 gates, con la salida real

### Gate 1 — `mix format --check-formatted` ✅

```
$ mix format --check-formatted
$ echo $?
0
```

### Gate 2 — `mix compile --force --warnings-as-errors` ✅

```
$ mix compile --force --warnings-as-errors
==> arrea
Compiling 47 files (.ex)
Generated arrea app
$ echo $?
0
```

47 ficheros (46 de la base + `resource.ex`). Cero warnings.

### Gate 3 — `mix credo --strict` ⚠️ exit 14 — **exactamente la base**

```
$ mix credo --strict
$ echo $?
14
711 mods/funs, found 3 refactoring opportunities, 2 code readability issues,
10 software design suggestions.
```

Los **15 avisos restantes son los de la base**, en ficheros que no son de esta
fase: `lib/arrea/queue.ex:149` (cond con una sola condición), `lib/arrea/worker.ex`
(40, 240, 252 — orden de alias y complejidad ciclomática), `lib/arrea/cli/definition.ex:33`,
y diez `AliasUsage` en `worker_test.exs`, `long_running_os_process_test.exs`,
`cli/dispatch_test.exs` y `cli/commands/run_test.exs`.

**Cero avisos en `lib/arrea/resource.ex`, `lib/arrea/telemetry/events.ex` y
`lib/arrea/supervisor.ex`.** Los 5 que la ronda anterior de mi trabajo había
añadido (dos `UnsafeToAtom` por un helper que fabricaba átomos en runtime, dos
`AliasUsage` y un `TagTODO` que disparaba la palabra «Todo» en un comentario) están
arreglados de verdad: el helper de nombres ahora usa un pool de átomos **de
compilación** que recorre buscando hueco en el Registry, `Code.Typespec` tiene su
alias arriba, y el comentario está redactado de otra manera. **No hay ni un
`# credo:disable` en el repo.**

Lo dejo en 14 y no en 0 a propósito: llegar a 0 exige refactorizar
`take_from_queues/1` de `worker.ex` (600 líneas, 78% de cobertura) y cuatro
ficheros de test ajenos. Es el mismo criterio que el que fijaste para los 6
errores de dialyzer: son preexistentes, se dejan escritos como tales y no se
tocan. Si quieres el gate en 0, dímelo y me pongo.

### Gate 4 — `MIX_ENV=test mix test --cover` ✅

Corridas repetidas, con su salida real:

```
$ MIX_ENV=test mix test --cover      # x4
5 properties, 372 tests, 7 failures   <-- esta dio 7: el intermitente
 98.0% lib/arrea/resource.ex                         609      104        2
[TOTAL]  66.4%
5 properties, 372 tests, 6 failures
[TOTAL]  66.3%
5 properties, 372 tests, 6 failures
[TOTAL]  66.3%
```

Los 6, y son los 6 estables de la base:

```
test execute/2 accepts environment properties and passes them to shell (Arrea.CommandTest)
test execute/2 successfully executes a command (Arrea.CommandTest)
test execute/2 :validate, false bypasses the safety check for trusted callers (Arrea.CommandTest)
test execute_with_asdf/4 prepends ASDF variables (Arrea.CommandTest)
test Arrea.CLI module main/1 delegates to Arrea.CLI.Definition.main/1 (Arrea.CLITest)
test self hosted CLI Definition main/1 with no command shows help (Arrea.CLITest)
```

Son del entorno, no míos: `/usr/bin/sh: 1: source: not found` y
`/bin/bash: line 1: /workspace/.home/.bashrc: No such file or directory`.

**Y hay un séptimo test que oscila, y no es mío.** `Arrea.CLI.Commands.NodesTest`
—«test module exists and has execute/1»—. Falla en la base en 3 de 4 corridas y
en esta rama en 1 de 10. El recuento de fallos de este repo **no es
determinista**, y el criterio es «los 6 estables, el intermitente cuando
aparezca». Detalle y recuento en §4.

Las 2 líneas sin cubrir de `resource.ex`, obtenidas con
`mix coveralls.detail --filter resource.ex` (no de memoria), y las dos son
defensa en profundidad:

1. `resource.ex:352` — la rama de error de `init/1`. Inalcanzable por la API
   pública: `start_link/3` valida antes de arrancar, e `init/1` vuelve a
   validar. Es la convención que se copia de `Bulkhead`.
2. `resource.ex:497` — el `catch :exit, _reason -> :not_found` de `safe_call/2`.
   Solo se alcanza si el proceso muere **entre** el `Registry.lookup` y el
   `GenServer.call`, una carrera de microsegundos. `Bulkhead` deja la misma línea
   sin cubrir por el mismo motivo.

### Gate 5 — `mix dialyzer` ⚠️ los mismos 6 preexistentes

```
Total errors: 6, Skipped: 0, Unnecessary Skips: 0
done (warnings were emitted)
Halting VM with exit status 2
```

Los seis, todos en `lib/arrea/bulkhead.ex`, fichero que **no he tocado**:

```
lib/arrea/bulkhead.ex:98:invalid_contract
lib/arrea/bulkhead.ex:100:7:no_return
lib/arrea/bulkhead.ex:125:invalid_contract
lib/arrea/bulkhead.ex:127:no_return
lib/arrea/bulkhead.ex:130:10:call
lib/arrea/bulkhead.ex:300:invalid_contract
```

`Arrea.Resource`, `Arrea.Telemetry.Events` y `Arrea.Supervisor`: **cero avisos**.

---

## 4 · Antes y después, con la base medida de verdad

La cifra de 62,2% que dio la ronda anterior **era falsa** y está retirada: se
midió con `lib/arrea/resource.ex` ya compilado pero sin sus tests, así que
contaba 69 líneas al 0% que ahí no contaban. La base real se ha medido sobre un
**clon limpio de `e1c16ff`** (`/tmp/arrea_base`, con su propio `MIX_BUILD_ROOT`),
con el mismo método.

| | Base `e1c16ff` | Ahora |
|---|---|---|
| Tests | 339 | **372** |
| Propiedades | 3 | **5** |
| Fallos | **6 estables** + 1 intermitente (4 corridas: 6 y 7) | **6 o 7**, como la base |
| Cobertura total | **64.6%** | **66.3–66.4%** |
| `lib/arrea/resource.ex` | — (no existe) | **98.0%** |

### El recuento de fallos NO es determinista, y hay que decirlo

Tres corridas de la base limpia:

```
3 properties, 339 tests, 6 failures
3 properties, 339 tests, 7 failures
3 properties, 339 tests, 7 failures
```

Y la unión de los tests que fallan en esas tres corridas:

```
3x  test execute/2 accepts environment properties ... (Arrea.CommandTest)
3x  test execute/2 successfully executes a command (Arrea.CommandTest)
3x  test execute/2 :validate, false bypasses ... (Arrea.CommandTest)
3x  test execute_with_asdf/4 prepends ASDF variables (Arrea.CommandTest)
3x  test Arrea.CLI module main/1 delegates ... (Arrea.CLITest)
3x  test self hosted CLI Definition main/1 with no command shows help (Arrea.CLITest)
2x  test module exists and has execute/1 (Arrea.CLI.Commands.NodesTest)   <-- INTERMITENTE
```

**Seis fallan siempre y uno es intermitente.** Y hay que decirlo sin adornos,
porque **el intermitente también aparece en esta rama**: lo vi una vez, en una
corrida con `--cover`, después de haber escrito que «era estable en 3 corridas».
Cosas por esa vía ya hubo una en este entregable, así que va el recuento entero.

**En esta rama, 10 corridas:** 9 de 6 fallos y 1 de 7. La de 7 fue la primera
`--cover` de la tanda final, con `resource.ex` al 98.0% y el total al 66.4%.

**En la base limpia, 4 corridas:** una de 6 (`--cover`) y tres de 7.

El criterio de aceptación correcto no es un número sino este: **los 6 estables
siempre, y el intermitente cuando aparece.** No he tocado ninguno de los dos.

---

## 5 · Verificación por mutación: 11 de 11

Un test que pasa no demuestra nada si el módulo puede estar mal. He falseado el
módulo entero una línea cada vez, sobre una copia, y lo he pasado por los 33
tests. **Los 15 mueren.** Lo relevante es *quién* los mata.

La ronda anterior decía «11 de 11» sobre una tabla de 12 filas: el número estaba
mal porque no se contaba. Ahora son 15 filas y 15 mutantes, y la tabla lleva
número para que se puedan contar.

| # | Mutante | Qué rompe | Quién lo caza |
|---|---|---|---|
| 1 | `cap` | `fits_capacity?` siempre cierta: nunca rechaza por megas | la propiedad + 9 tests |
| 2 | `quota` | `fits_quota?` siempre cierta: nunca rechaza por cuota | 4 tests |
| 3 | `leak` | admite un 5% de megas de más | el test del límite + la propiedad + 1 test |
| 4 | `quota_leak` | admite un 5% de cuota de más | el test del límite + 1 test |
| 5 | `swap` | un rechazo de megas con el nombre del eje de cuota | 8 tests |
| 6 | `swap2` | un rechazo de cuota con el nombre del eje de megas | 4 tests |
| 7 | `eps` | sin tolerancia en la cuota | «una cuota que cabe por poco no se rechaza» |
| 8 | `pub` | sin redondeo al publicar | 4 tests |
| 9 | `ident` | `===` vuelve a ser `==` | «la identidad es estricta: 1 no es el titular 1.0» |
| 10 | `release1` | `release/2` devuelve solo un eje | 11 tests |
| 11 | `persist` | escribe su estado en el directorio de datos | «la verdad no esta en disco» + el de Candil |
| 12 | `candil` | importa un módulo `Candil.*` de verdad | «el modulo no importa nada de Candil» |
| 13 | `multi` | `release/2` devuelve una reserva y **quita todas** | la propiedad + los 3 tests de titular repetido |
| 14 | `trampa1` | solo encuentra la reserva si es la **primera** de la lista | la propiedad + 2 tests |
| 15 | `trampa2` | quita la suya y **tira las de delante**, que son de otros | la propiedad + 2 tests |

### Los tres mutantes que sobrevivieron

**Tres mutantes sobrevivieron en ronda.** El más importante: `multi` —el del
defecto de las reservas múltiples— pasaba la propiedad entera.

**`quota_leak` sobrevivió a todo en una ronda intermedia.** Un módulo que admitía
un 5% de cuota de más pasaba los 29 tests. La causa era de los **generadores**,
no del módulo: los importes se generaban como números absolutos (0,01–4,00 de
cuota) contra cuotas de 0,10–10,00, así que casi todo se rechazaba en el primer
intento y **el pico nunca se acercaba al límite**. Ahora los importes son
*fracciones* de los límites (30%–120% cada uno), y además hay un test de
frontera determinista —«justo entra y una unidad más no»— que es el que mata a
los dos mutantes de fuga sin depender de la semilla.

**`persist` no lo cazaba el test que decía cazarlo.** El test de «no persiste»
listaba un directorio temporal que **no se le pasaba a nadie**: el refute no
podía fallar porque el módulo no tenía forma de escribir ahí. Ahora el
directorio se le da a la aplicación (`Application.put_env(:arrea, :data_dir, dir)`,
que es donde un módulo de Arrea escribiría si fuera a persistir), y el test
comprueba **además** que el módulo no puede escribir: no tiene funciones de
fichero en su tabla de `imports`. Los dos juntos: el dato de que se escriba y el de que no pueda.

**`multi` sobrevivió porque la propiedad no tenía dos tareas vivas con el mismo
titular.** Con importes del 30%-120% del límite, casi todo se rechazaba en el
primer intento: sólo cabía una carga a la vez, así que la colisión de titulares
no llegaba a ocurrir. Ahora los importes son del 10%-30% y el pool de titulares
tiene 1 a 3 elementos, de modo que varias cargas conviven y compiten por el
mismo titular — y la propiedad, con sus medidores por fuera del GenServer, ve
cómo se desvanece la cuenta.

**El mismo agujero, en el test de la frontera con Candil

`for {:import, module, _f, _a} <- imports` recorriera **cero entradas**: el chunk
`imports` de un BEAM son triplas `{módulo, función, aridad}`, no cuartetas. El
refute se ejecutaba 0 veces. Medido: 28 entradas, 0 coincidencias con la forma
esperada. Ahora el `for` usa la forma real y hay dos aserciones que impiden que
vuelva a pasar en silencio: que la tabla no esté vacía, y que contenga una
entrada conocida. La última fila de la tabla de mutantes es la prueba: metiendo
un `import Candil.Fake` de verdad, el test cae con
`Arrea.Resource importa Candil.Fake: la frontera con Candil esta cruzada`.

---

## 6 · Lo que la revisión round 2 encontró, y tres correcciones mías

### 6.1 · El defecto que quedaba: una reserva de más, perdida para siempre

`take_holder/2` encontraba **todas** las reservas de un titular, devolvía **la
primera** y quitaba **todas**. Con el escenario de todos los días —el mismo
modelo cargado dos veces— dos `release` se llevaban 8 GB sin avisar:

```
acquire(:m, :llama7b, 4_000, 1.0)
acquire(:m, :llama7b, 4_000, 1.0)
acquire(:m, :llama7b, 4_000, 1.0)
release(:m, :llama7b) x3
  -> used=8000  quota_used=2.0  holders=[]    # 8 GB y 2.0 de cuota, sin dueño
```

`used: 8000` con `holders: []` es un `available/1` que miente para siempre. Y
violaba el `@doc` del propio módulo, que ya decía lo correcto («dos `acquire`
del mismo titular son dos reservas, y cada `release` devuelve una»): el
código hacía lo contrario de lo documentado. **No era una regresión de esta
ronda**: la versión de la ronda 1 usaba `Enum.split_with` y tenía lo mismo.

**Arreglo:** una reserva devuelta, una devuelta, y `before ++ rest` para que lo
que había antes de la coincidencia se conserve. Cazado por el mutante 13.

**Y por qué nadie lo caía**, que es la parte instructiva: de los ~50 `acquire`
de los dos ficheros de test, **ninguno repetía titular**, y la propiedad
generaba `titular = {:titular, unique_integer}` por tarea, siempre distinto.
Ninguno de los ~50 `acquire`, ningún mutante y el 98% de cobertura se pasaban
por encima. Un camino entero sin iluminar.

### 6.2 · Me caí en la misma trampa dos veces al arreglarla

Arreglando `take_holder` escribí una versión que sólo buscaba la reserva si era
**la primera** de la lista (`{[], [{_h, ...} | rest]}`). Con un titular de tres,
soltar al del medio devolvía cero. Y la segunda versión devolvía sólo `rest`,
**tirando las reservas que había antes** —que son de otros titulares—, y la
cuenta de otro se desvanecía sin que nadie la tocara.

Las dos las cazó la simulación con titulares compartidos, y las dos eran
silenciosas. Por eso hay dos mutantes más en la tabla, `trampa1` y `trampa2`, y
un test que suelta **al titular del medio** de una lista de tres, que es el que
no existía y que más daño habría hecho.

### 6.3 · Corrección 1: el `2.77e-17` también era del módulo

Escribí que el residuo venía del medidor del test y no del módulo. **Era falso.**
Lo medí con la etiqueta puesta: cuatro reservas de 0.1 devueltas una a una dan
`2.7755575615628914e-17` en la aritmética IEEE-754, y tanto el medidor del test
como la cuenta del módulo acumulan ese mismo residuo. En mi reproducción el
módulo salía limpio (`used: 0.0`) porque los titulares eran distintos y el orden
de las operaciones cancelaba — fue una casualidad, no una diferencia de fondo.

Lo que hoy mantiene la cuenta del módulo en cero son **dos** mecanismos
independientes, y los dos medidos: el `max(0.0, ...)` del `release`, que se
queda con el suelo, y `publish/1`, que manda a `0.0` cualquier cosa por debajo
de `1.0e-9`. El arreglo de fondo sigue siendo el bueno y el primero: **el eje
duro es entero y no tiene nada que ver con esto.

### 6.4 · Corrección 2: la identidad no era *el* problema de capacidad

Presenté el defecto 3 —la identidad laxa, `==` en vez de `===`— como si cerrara
el problema de la fuga. Cerraba **una** fuga y dejaba otra abierta, y peor: la
de las reservas múltiples perdía megas y cuota de verdad, y la de la identidad
era un caso particular de la misma regla. El `@doc` lo decía bien y el código
no; ahora los dos lo hacen bien, y hay un test para cada regla.

### 6.5 · Corrección 3: la cuenta de mutantes

«11 de 11» sobre una tabla de 12 filas. El número estaba mal porque no se
contó. Ahora hay 15 filas numeradas y 15 mutantes, y la tabla lleva índice para
que se puedan contar con los dedos.

### 6.6 · Los cinco defectos de la revisión round 1

| # | Defecto | Arreglo | Verificado por |
|---|---|---|---|
| 1 | la propiedad es falsa con fracciones | eje duro **entero** (exacto, sin epsilon); eje blando con **tolerancia** | mutantes 3 y 4 |
| 2 | rechaza lo que cabe y publica basura | **tolerancia relativa** en la cuota + **redondeo a 6 decimales al publicar** | mutantes 7 y 8 |
| 3 | fuga de capacidad por identidad | `===` en vez de `==` — y **no era la única**: la de reservas múltiples seguía abierta (§6.1) | mutante 9, y el 13 para la otra |
| 4 | tres tests que no podían fallar | imports, persistencia y propiedades **verificados mutando el módulo** | §5 |
| 5 | tres cifras falsas en el entregable | base sobre clon limpio; no determinación **declarada** | §4 |

---

## 7 · Ficheros tocados

| Fichero | Cambio |
|---|---|
| `lib/arrea/resource.ex` | **nuevo**, 609 líneas. El módulo. |
| `lib/arrea/telemetry/events.ex` | `resource_metadata/0` con los dos ejes, `emit_resource/2`. |
| `lib/arrea/supervisor.ex` | `+Arrea.Resource.Registry` antes de `Arrea.Monitor`, y la numeración del `@moduledoc`. |
| `test/arrea/resource_test.exs` | 33 tests. |
| `test/arrea/resource_property_test.exs` | 2 propiedades. |
| `deliverable.md` | este fichero. |

**No tocado:** `mix.exs`, `Bulkhead`, `Queue`, `Registry`, ropero, Candil, ningún
fichero ajeno a la fase, y los tests de `command`/`cli`.

---

## 8 · Lo que no he podido verificar

| | |
|---|---|
| **CI** | No ejecutado. Sin commit, sin push, sin PR: el commit es tuyo porque tienes que mirar el CI antes de pedir el merge. |
| `mix credo --strict` en 0 | Sale 14. Los 15 avisos son de `queue.ex`, `worker.ex`, `cli/definition.ex` y tres ficheros de test ajenos. Dime si quieres que los ataque. |
| `mix dialyzer` en 0 | Los 6 errores son de `bulkhead.ex`, preexistentes, no tocados por indicación tuya. |
| `mix docs` | Fuera de los gates. `Arrea.Resource` no está en `groups_for_modules` de `mix.exs` (no lo toco por restricción), así que ExDoc lo dejará en «módulos sin agrupar». |
| Documentos de Candil | D6 del contrato sin tocar: los dos documentos que dicen que `Bulkhead` «cuenta slots» y que «no se puede pesar» ya se pueden corregir. Y la decisión abierta nº1 (round-robin vs VIP) sigue viva: `quota` es el número donde va a caer, no el motor. |
| Los 4 tests de Candil que mienten (§3.1) | Siguen buscando dos literales. Está bien: no hay refusal todavía. Cuando lo escribas, que miren el `@type reason` de `Candil.Error`. |
| Gates sobre un árbol limpio | Todo corre sobre el `_build` de `/opt/candil-build`, que ya venía sucio de una sesión anterior (los beams llevan `source:` con una ruta NFS antigua). La base sí la medí en un árbol limpio, en `/tmp/arrea_base`, y con su propio build. |

---

## 9 · Lo que me queda por decidir a ti

1. **El nombre del eje blando.** Lo he llamado `quota`. La alternativa que
   apuntaste era `policy_budget`. El nombre importa: es el que la decisión
   abierta nº1 va a usar durante años.
2. **Si `quota` es un número o una lista por política.** Hoy es un número, como
   dijiste. Si mañana hay VIP, cabe dentro del mismo número (más cuota) o pide
   otra cosa, y eso no lo decido yo.
3. **Los gates de credo y dialyzer en 0**, si quieres que ataque los preexistentes.
4. **La doc de Candil** (D6) y la **decisión abierta nº1**, que este módulo ya
   tiene dónde vivir: `Arrea.Resource`, el número `quota`.
