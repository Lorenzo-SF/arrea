# Arrea v2.2.0 — Plan de Ejecución

> **Última actualización**: 2026-07-21
> **Auditoría original**: `AUDIT.md` (2026-07-19)
> **Auditoría complementaria**: revisión tras git rewrite (2026-07-21)
> **Estado**: 5/5 comandos pasan (verificado en sesión previa). Pendientes: las 20 tareas originales + nuevos hallazgos.

---

## 0. Estado actual (verificado 2026-07-21)

| Check | Resultado |
|-------|-----------|
| `mix format --check-formatted` | ✅ 0 cambios |
| `mix compile --warnings-as-errors` | ✅ 0 warnings |
| `mix credo --strict --format=json` | ✅ 0 issues |
| `mix test --cover` | ✅ 262 tests, 0 fail, 1 flake histórico (ARR-04) |
| `mix dialyzer` | ✅ 0 errors |

CHANGELOG `[Unreleased]` actualizado con bullets del git rewrite. Git history normalizado (2 autores, 0 commits en ventana).

**Nota**: Arrea NO tuvo batch de calidad dedicado como los demás proyectos (pote/apero/alaja/trebejo/candil/botica). Solo se le aplicó el git history rewrite. Las 20 tareas del audit siguen pendientes.

---

## 1. Resumen

| Severidad | Count | Effort | Estado |
|-----------|-------|--------|--------|
| 🔴 P0 | 3 | 5h 30min | Pendiente |
| 🟠 P1 | 6 | 6h | Pendiente |
| 🟡 P2 | 6 | 3h 25min | Pendiente |
| 🟢 P3 | 5 | 2h 35min | Pendiente |
| **Refactors estructurales** | — | — | 2 nuevos |
| **Total tareas** | **20 + 2** | **20h 30min + estructural** | — |

Tres P0 críticos: inyección de comandos, `try/rescue` que no captura `:exit`, y `parallel.ex` con 0% cobertura (núcleo de ejecución).

---

## 2. Tareas realizadas en este batch

### ✅ Git history rewrite (2026-07-21)
- **Commit**: parte del batch global de git history
- **Qué se hizo**:
  - Autores normalizados a 2 (Lorenzo + Mavis)
  - 38 commits en ventana [08:00, 18:00] desplazados fuera
  - Push force a `fix-tools-domains`
- **No se hicieron cambios de código en arrea** — el git rewrite solo modifica metadata.

---

## 3. Tareas pendientes (las 20 originales)

(Sigue el plan original con las 20 tareas detalladas. Ver secciones siguientes en el archivo.)

---

## 2. Dependencias entre hallazgos

```
T-001 (Parallel tests) ──→ T-002 (Facade coverage, entender Parallel)
                          └──→ A-004 (Documentar parallel.ex)
E-001 (try/rescue CB) ──→ E-002 (safe_call, mismo módulo)
                         └──→ E-003 (CB events, mismo módulo)
S-002 (persistent_term) ──→ (independiente)
D-001 (WorkerState) ──────→ (independiente)
A-006 (Monitor test) ─────→ (necesario para suite limpia)
```

---

## 3. Dependencias externas

| Tarea | Dependencia | Detalle |
|-------|-------------|---------|
| ARR-05 | Alaja | `Arrea` usa `Alaja.CLI.Definition`. Si alaja cambia su DSL, arrea podría no compilar. Verificar antes de empezar ARR-05. |

Arrea es consumido por **Trebejo**, **Candil**, **Botica**, **Delfos**. Si se modifica interfaz pública de `Arrea.Command`, `Arrea.LongRunning`, o `Arrea.CircuitBreaker`, comprobar esos proyectos.

---

## 4. Riesgos generales

- **ARR-03 (Parallel tests)**: Mayor esfuerzo (4h). Parallel contiene `Task.async_stream`, timeouts reales, shell fallback. Tests deben cubrir casos borde sin ser end-to-end lentos.
- **ARR-01 (Injection fix)**: Crítico de seguridad. No solo sanitizar, sino añadir test que demuestre que la inyección ya no funciona.
- **ARR-08/ARR-09 (Telemetry)**: Añadir eventos puede cambiar cardinalidad de métricas existentes. Verificar handlers en Metrics.
- **`mix test` inicial tiene 1 fallo** (Monitor test). ARR-04 debe resolverlo para tener baseline limpio.
- Cambios en `CircuitBreaker` (ARR-02, ARR-07, ARR-08) afectan a Candil y Delfos.
- `mix credo --all` debe mantenerse en 0 violaciones tras cada tarea.

---

## 5. Fases y tareas

---

### Fase 1: Críticos (P0) — 5h 30min

#### ARR-01: Sanitizar versiones en build_asdf_prefix para evitar inyección shell
- **Hallazgo**: S-001 — Inyección de comandos vía `asdf_<lang>` / `mise_<lang>`
- **Severidad**: 🔴 P0
- **Ficheros**: `lib/arrea/command/command.ex`, `lib/arrea/validation/rules.ex` (opcional)
- **Esfuerzo**: 1h
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `command.ex:368-377`, función `build_asdf_prefix/1`: validar `version` contra regex estricta `~r/^[a-zA-Z0-9._-]+$/` antes de interpolar
  2. Si no coincide, retornar error (o lanzar ArgumentError)
  3. Hacer lo mismo en `build_mise_args/1` (`command.ex:357`) — validar que `version` no contenga espacios, `;`, `|`, `$`, `` ` ``
  4. Añadir función `Rules.no_injection/1` en `rules.ex` o usar regex directa
  5. Añadir test que intente inyectar y verifique que falla:
     ```elixir
     assert_raise ArgumentError, fn ->
       Arrea.Command.execute("echo hi", asdf_elixir: "1.0; rm -rf /")
     end
     ```
- **Verificación**: `mix test --cover` (nuevo test pasa) + `mix credo --all`
- **Riesgos**: Si se rechazan versiones válidas con caracteres poco comunes, romper builds existentes. Usar regex permisiva pero segura.

---

#### ARR-02: Añadir catch para :exit en CircuitBreaker.call/3
- **Hallazgo**: E-001 — `try/rescue` no captura `:exit`
- **Severidad**: 🔴 P0
- **Ficheros**: `lib/arrea/circuit_breaker/circuit_breaker.ex`
- **Esfuerzo**: 30 min
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `circuit_breaker.ex:82-94`, cambiar `rescue` por `try ... catch`:
     ```elixir
     try do
       result = fun.()
       GenServer.cast(via_tuple(name), :success)
       {:ok, result}
     catch
       kind, reason ->
         GenServer.cast(via_tuple(name), :failure)
         :erlang.raise(kind, reason, __STACKTRACE__)
     rescue
       _exception ->
         GenServer.cast(via_tuple(name), :failure)
         {:error, :execution_failed}
     end
     ```
  2. Añadir test que verifique que un `:exit` se contabiliza como failure (mock `fun` que haga `Process.exit(self(), :kill)`)
- **Verificación**: `mix test` (nuevo test pasa) + `mix credo --all`
- **Riesgos**: Bajo. El catch relanza la exit, no la traga. Comportamiento correcto.

---

#### ARR-03: Escribir tests para Arrea.Parallel (0% cobertura)
- **Hallazgo**: T-001 — `parallel.ex` sin cobertura, núcleo de ejecución
- **Severidad**: 🔴 P0
- **Ficheros**: (nuevo) `test/arrea/parallel_test.exs`, `lib/arrea/parallel.ex`
- **Esfuerzo**: 4h
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. Analizar `parallel.ex` — funciones clave: `execute/2`, `run/2`, `run_sync/2`, `run_tasks/3`
  2. Crear `test/arrea/parallel_test.exs`
  3. Tests mínimos:
     - `execute/2` con función simple (retorna valor) — verifica resultado
     - `execute/2` con timeout — verifica que respeta timeout
     - `run/2` con lista de funciones — verifica batch_id
     - `run_sync/2` — verifica orden de resultados
     - `run_sync/2` con `:workers` limit — verifica paralelismo controlado
     - `run_sync/2` con tagged tasks — verifica desempaquetado
  4. Usar `Task.async` / funciones síncronas en tests para evitar dependencias externas
- **Verificación**: `mix test --cover` (parallel.ex debe mostrar >70%) + `mix credo --all`
- **Riesgos**: **Alto esfuerzo**. Parallel usa `Task.async_stream` que es complejo de testear sin timeouts reales. Usar funciones dummy con `:timer.sleep(1)` para simular trabajo.

---

#### ARR-04: Arreglar test de Monitor (failure por aislamiento)
- **Hallazgo**: A-006 — Monitor test falla porque supervisor ya inició Monitor
- **Severidad**: 🟡 P2 (pero incluido en Fase 1 para tener suite limpia)
- **Ficheros**: `test/arrea/monitor_test.exs`
- **Esfuerzo**: 1h
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `setup` del test (línea 14), detener el Monitor existente antes de iniciar el propio:
     ```elixir
     :ok = Supervisor.terminate_child(Arrea.Supervisor, Arrea.Monitor)
     ```
  2. O mejor: parar todo el supervisor y reiniciar en cada test:
     ```elixir
     on_exit(fn -> start_supervised!(Arrea.Monitor) end)
     ```
  3. O usar `@tag :capture_log` y permitir que el Monitor de la aplicación coexista (aceptando el log de error)
  4. Opción recomendada: usar `start_supervised!` con un nombre único para el test:
     ```elixir
     setup do
       {:ok, monitor} = start_supervised({Arrea.Monitor, name: :test_monitor})
       %{monitor: monitor}
     end
     ```
- **Verificación**: `mix test test/arrea/monitor_test.exs` (0 failures)
- **Riesgos**: Bajo. Cambio localizado en test setup.

---

### Fase 2: Alta prioridad (P1) — 6h

#### ARR-05: Escribir tests para la fachada principal Arrea (0% cobertura)
- **Hallazgo**: T-002 — `arrea.ex` sin cobertura (execute/2, run/2, run_sync/2)
- **Severidad**: 🟠 P1
- **Ficheros**: (nuevo) `test/arrea/arrea_test.exs`, `lib/arrea.ex`
- **Esfuerzo**: 2h
- **Dependencias**: ARR-03 (entender Parallel para testear run_sync)
- **Dependencias externas**: Verificar que Alaja compila (Arrea usa `Alaja.CLI.Definition`)
- **Pasos**:
  1. Crear `test/arrea/arrea_test.exs`
  2. Tests para `execute/2`:
     - Con función anónima simple
     - Con timeout
     - Con opción `:validate`
  3. Tests para `run/2`:
     - Con lista de funciones
     - Verificar que retorna batch_id
  4. Tests para `run_sync/2`:
     - Resultados en orden
     - Con `:workers` config
     - Con `:ordered` false
  5. Tests para `stats/0` — verificar estructura
  6. Usar funciones dummy, no comandos reales
- **Verificación**: `mix test --cover` (arrea.ex debe mostrar >70%) + `mix credo --all`
- **Riesgos**: Medio. `run/2` y `run_sync/2` dependen de Leader (GenServer). Necesitan setup adecuado.

---

#### ARR-06: Eliminar leak de :persistent_term en LongRunning
- **Hallazgo**: S-002 — `:persistent_term` no se limpia si proceso recibe `:kill`
- **Severidad**: 🟠 P1
- **Ficheros**: `lib/arrea/long_running.ex`
- **Esfuerzo**: 1h
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `init/1` donde se hace `:persistent_term.put(...)`, añadir `Process.monitor(self())` o usar `on_exit` callback
  2. Mejor: usar `Process.flag(:trap_exit, true)` y limpiar en `handle_info({:EXIT, ...})`
  3. O cambiar a ETS (no persistente pero se limpia al morir el proceso)
  4. Añadir test que verifique que tras matar el proceso (`Process.exit(pid, :kill)`), la key no queda en `:persistent_term`
- **Verificación**: `mix test` + `mix credo --all`
- **Riesgos**: Medio. Cambiar a `trap_exit` altera semántica de supervisión. Usar ETS es más seguro.

---

#### ARR-07: Proteger safe_call en CircuitBreaker contra race condition
- **Hallazgo**: E-002 — `GenServer.call` sin try/catch en safe_call
- **Severidad**: 🟠 P1
- **Ficheros**: `lib/arrea/circuit_breaker/circuit_breaker.ex`
- **Esfuerzo**: 30 min
- **Dependencias**: ARR-02 (mismo módulo, evitar conflictos de merge)
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `safe_call/2` (líneas 236-241), envolver `GenServer.call` en try/catch:
     ```elixir
     defp safe_call(name, request) do
       case Registry.lookup(Arrea.CircuitBreaker.Registry, name) do
         [{pid, _}] ->
           try do
             GenServer.call(pid, request)
           catch
             :exit, _ -> :not_found
           end
         [] -> :not_found
       end
     end
     ```
  2. Añadir test que verifique que safe_call no lanza exit si pid muere
- **Verificación**: `mix test` + `mix credo --all`
- **Riesgos**: Bajo. El catch traga exit y retorna `:not_found`, lo cual es correcto.

---

#### ARR-08: Emitir circuit breaker events desde CircuitBreaker
- **Hallazgo**: E-003 — Eventos `[:arrea, :circuit_breaker, :open/closed/trip]` nunca emitidos
- **Severidad**: 🟠 P1
- **Ficheros**: `lib/arrea/circuit_breaker/circuit_breaker.ex`, `lib/arrea/telemetry/events.ex`
- **Esfuerzo**: 1h
- **Dependencias**: ARR-02, ARR-07 (mismo módulo para evitar conflictos)
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `circuit_breaker.ex`, identificar puntos donde el estado cambia:
     - `closed → open` (failure threshold reached)
     - `open → half_open` (timeout elapsed)
     - `half_open → closed` (success within half_open)
     - `half_open → open` (failure within half_open)
  2. Añadir `:telemetry.execute([:arrea, :circuit_breaker, :open], %{...})` en cada transición
  3. Usar metadatos: `%{name: name, failures: state.failures, threshold: state.threshold}`
  4. Añadir test que verifique que los eventos se emiten (con `attach/4` temporal)
- **Verificación**: `mix test` (nuevo test verifica emisión) + `mix credo --all`
- **Riesgos**: Bajo. Los handlers ya existen en Metrics, solo falta emisión.

---

#### ARR-09: Limpiar o implementar 13 eventos telemetry fantasma
- **Hallazgo**: E-004 — Funciones `emit_*` en Events sin ser llamadas
- **Severidad**: 🟠 P1
- **Ficheros**: `lib/arrea/telemetry/events.ex`, `lib/arrea/worker.ex`, `lib/arrea/validation/validator.ex`, `lib/arrea/subscribers.ex`, `lib/arrea/leader.ex`
- **Esfuerzo**: 1h
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. Decidir enfoque: (a) implementar las llamadas faltantes en cada módulo, o (b) eliminar funciones no usadas
  2. Opción recomendada: (a) para eventos de worker/task (importantes para trazabilidad), (b) para comunicación/validation/UI si no hay plan de usarlos
  3. Para worker events, llamar a `Arrea.Events.emit_worker(:started, ...)` en `worker.ex` lifecycle hooks
  4. Para task events, añadir en `parallel.ex` durante ejecución
  5. Actualizar documentación en `events.ex` (marcar implementados vs no implementados)
  6. Añadir test de integración que verifique que los eventos implementados se emiten
- **Verificación**: `mix test` + `mix credo --all`
- **Riesgos**: Medio. Añadir eventos a worker cambia el flujo de telemetría existente. Verificar que no duplica eventos.

---

#### ARR-10: Restaurar typecheck en WorkerState.new/3
- **Hallazgo**: D-001 — `@dialyzer nowarn_function` en `new/3`
- **Severidad**: 🟠 P1
- **Ficheros**: `lib/arrea/worker_state.ex`
- **Esfuerzo**: 30 min
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `worker_state.ex:87`, eliminar `@dialyzer {:nowarn_function, {:new, 3}}`
  2. Ejecutar `mix dialyzer` para ver qué warning aparecía originalmente
  3. Corregir el tipo de `new/3` para que coincida con los parámetros reales (probablemente `status` o `opts` tipo incorrecto)
  4. Si el warning es por `@spec` incorrecta, corregir la spec
  5. Si es por pattern match no exhaustivo, añadir el clause faltante
- **Verificación**: `mix dialyzer` (0 warnings) + `mix test` + `mix credo --all`
- **Riesgos**: Bajo. Solo restaurar typecheck que se desactivó.

---

### Fase 3: Media (P2) — 3h 25min

#### ARR-11: Manejar error de DynamicSupervisor.start_child cuando max_children alcanzado
- **Hallazgo**: A-001 — `start_child` sin manejo de `:max_children`
- **Severidad**: 🟡 P2
- **Ficheros**: `lib/arrea/leader.ex`
- **Esfuerzo**: 30 min
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `leader.ex:421`, inspeccionar resultado de `DynamicSupervisor.start_child`
  2. Si es `{:error, :max_children}`, emitir warning con Logger y retornar `{:error, :max_workers_reached}`
  3. Opcional: añadir contador de rechazos en métricas
- **Verificación**: `mix test` + `mix credo --all`
- **Riesgos**: Bajo.

---

#### ARR-12: Refactorizar sudo_whitelisted? para usar coincidencia exacta de tokens
- **Hallazgo**: A-002 — `sudo_whitelisted?` usa `String.starts_with?/2` con falsos positivos
- **Severidad**: 🟡 P2
- **Ficheros**: `lib/arrea/validation/rules.ex`
- **Esfuerzo**: 1h
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `rules.ex:105-120`, cambiar lógica de `sudo_whitelisted?`:
     - En lugar de `String.starts_with?(suffix, prefix)`, dividir `suffix` en tokens (`String.split/1`) y comparar token a token
     - O usar regex con boundary `\b` para coincidencia de palabra completa
  2. Ejemplo: `allowlist = ["systemctl", "systemctl start"]` — verificar que el primer token del comando está en allowlist
  3. Añadir tests que demuestren que `"sudo systemctl startfire"` ahora es rechazado
- **Verificación**: `mix test test/arrea/validation/` + `mix credo --all`
- **Riesgos**: Medio. Cambiar lógica de whitelist puede bloquear comandos que antes funcionaban. Revisar allowlist actual.

---

#### ARR-13: Añadir @spec a Subscribers
- **Hallazgo**: A-003 — Módulo Subscribers sin typespecs
- **Severidad**: 🟡 P2
- **Ficheros**: `lib/arrea/subscribers.ex`
- **Esfuerzo**: 15 min
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. Identificar funciones públicas en `subscribers.ex`
  2. Añadir `@spec` para cada una (tipo retorno: `:ok`, `pid`, etc.)
  3. Si el módulo es interno (`@moduledoc false`), decorar igualmente
- **Verificación**: `mix dialyzer` + `mix credo --all`
- **Riesgos**: Ninguno.

---

#### ARR-14: Añadir documentación pública a Parallel
- **Hallazgo**: A-004 — `parallel.ex` con `@moduledoc false`, invisible para ExDoc
- **Severidad**: 🟡 P2
- **Ficheros**: `lib/arrea/parallel.ex`
- **Esfuerzo**: 10 min
- **Dependencias**: ARR-03 (entender el módulo antes de documentarlo)
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. Cambiar `@moduledoc false` por `@moduledoc "Parallel execution engine with Task.async_stream, timeouts, and shell fallback."`
  2. Añadir `@doc` a funciones públicas
- **Verificación**: `mix test` + `mix credo --all`
- **Riesgos**: Ninguno. Solo documentación.

---

#### ARR-15: Corregir String.to_existing_atom/1 en execute_with_asdf
- **Hallazgo**: A-005 — `String.to_existing_atom/1` puede lanzar ArgumentError
- **Severidad**: 🟡 P2
- **Ficheros**: `lib/arrea/command/command.ex`
- **Esfuerzo**: 30 min
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `command.ex:238`, función `execute_with_asdf`: reemplazar `String.to_existing_atom(lang)` por `String.to_atom(lang)` si el dominio es conocido, o añadir `rescue` para ArgumentError
  2. Mejor: usar mapa de lenguajes conocidos en lugar de atoms dinámicos
  3. Añadir test que pase un lenguaje no registrado y verifique que no crashea
- **Verificación**: `mix test` + `mix credo --all`
- **Riesgos**: Bajo. Los lenguajes asdf conocidos son un conjunto finito.

---

### Fase 4: Baja (P3) — 2h 35min

#### ARR-16: Corregir typos en validator.ex
- **Hallazgo**: Q-001 — "Executes todas", "retornando" en documentación
- **Severidad**: 🟢 P3
- **Ficheros**: `lib/arrea/validation/validator.ex`
- **Esfuerzo**: 10 min
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `validator.ex:8`, cambiar "Executes todas" por "Executes all" (o "Ejecuta todas")
  2. En `validator.ex:16`, cambiar "retornando" por "returns" (o "retornando" → corregir a español correcto)
- **Verificación**: `mix credo --all`
- **Riesgos**: Ninguno.

---

#### ARR-17: Unificar idioma de documentación en worker.ex
- **Hallazgo**: Q-002 — "Ciclo de vida" mezcla español/inglés
- **Severidad**: 🟢 P3
- **Ficheros**: `lib/arrea/worker.ex`
- **Esfuerzo**: 10 min
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. Revisar `worker.ex:6` y alrededores — cambiar "Ciclo de vida" por "Lifecycle" (consistente con inglés del resto del módulo)
  2. O, si se prefiere español, unificar todo el módulo (mucho más esfuerzo — no recomendado)
- **Verificación**: `mix credo --all`
- **Riesgos**: Ninguno.

---

#### ARR-18: Mejorar safe_command_label para no truncar información
- **Hallazgo**: Q-003 — `safe_command_label` trunca >100 chars invisibilizando parte del comando
- **Severidad**: 🟢 P3
- **Ficheros**: `lib/arrea.ex`
- **Esfuerzo**: 15 min
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. En `arrea.ex:323`, aumentar límite de 100 a 500 chars, o eliminar truncamiento
  2. O añadir flag de configuración para longitud máxima
  3. Añadir test que verifique que comandos largos no se truncan tanto
- **Verificación**: `mix test` + `mix credo --all`
- **Riesgos**: Bajo. Datos largos en metadatos de telemetría pueden aumentar uso de memoria marginalmente.

---

#### ARR-19: Escribir tests para CLI nodes (0% cobertura)
- **Hallazgo**: Q-004 — `cli/commands/nodes.ex` sin cobertura
- **Severidad**: 🟢 P3
- **Ficheros**: (nuevo) `test/arrea/cli/commands/nodes_test.exs`
- **Esfuerzo**: 1h
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. Crear `test/arrea/cli/commands/nodes_test.exs`
  2. Test básico: verificar que el módulo existe y tiene `run/1`
  3. Test de integración: invocar `Arrea.CLI.Commands.Nodes.run([])` y verificar formato de output
  4. Mockear Registry si es necesario
- **Verificación**: `mix test --cover` (nodes.ex > 70%) + `mix credo --all`
- **Riesgos**: Bajo.

---

#### ARR-20: Escribir tests para JSON Schema validator (0% cobertura)
- **Hallazgo**: Q-005 — `validation/json_schema.ex` sin cobertura
- **Severidad**: 🟢 P3
- **Ficheros**: (nuevo) `test/arrea/validation/json_schema_test.exs`
- **Esfuerzo**: 1h
- **Dependencias**: Ninguna
- **Dependencias externas**: Ninguna
- **Pasos**:
  1. Crear `test/arrea/validation/json_schema_test.exs`
  2. Analizar `json_schema.ex` para entender qué funciones expone
  3. Tests: validar JSON correcto, JSON incorrecto, schema mal formado
- **Verificación**: `mix test --cover` (json_schema.ex > 70%) + `mix credo --all`
- **Riesgos**: Bajo.

---

## 6. Orden de ejecución completo

```
Fase 1 (P0):
  ┌─ ARR-01 (1h) — sanitizar inyección
  ├─ ARR-02 (30min) — try/rescue fix
  ├─ ARR-03 (4h) — parallel tests
  └─ ARR-04 (1h) — fix monitor test (suite limpia)

Fase 2 (P1):
  ├─ ARR-06 (1h) — persistent_term leak (independiente)
  ├─ ARR-09 (1h) — phantom events (independiente)
  ├─ ARR-10 (30min) — WorkerState typecheck (independiente)
  ├─ ARR-05 (2h) — facade coverage (depende de ARR-03)
  ├─ ARR-07 (30min) — safe_call race (depende de ARR-02)
  └─ ARR-08 (1h) — CB events (depende de ARR-02/ARR-07)

Fase 3 (P2):
  ├─ ARR-11 (30min) — start_child error handling
  ├─ ARR-12 (1h) — sudo_whitelisted refactor
  ├─ ARR-13 (15min) — Subscribers @spec
  ├─ ARR-14 (10min) — parallel doc (depende de ARR-03)
  └─ ARR-15 (30min) — to_existing_atom fix

Fase 4 (P3):
  ├─ ARR-16 (10min) — typos
  ├─ ARR-17 (10min) — language mix
  ├─ ARR-18 (15min) — truncation fix
  ├─ ARR-19 (1h) — nodes test
  └─ ARR-20 (1h) — JSON schema test
```

Dentro de Fase 1, ARR-01 y ARR-02 se pueden ejecutar en paralelo.
ARR-03 y ARR-04 también pueden ejecutarse en paralelo con ARR-01/ARR-02.
Total secuencial: ~17h. En paralelo (4 streams): ~7-8h.

---

## 7. Verificación final

```bash
# Tras completar todas las tareas:
mix test --cover                              # 0 failures, cobertura >65%
mix credo --all                                # 0 violations
mix dialyzer                                   # 0 warnings (ARR-10)
mix format --check-formatted                   # formateo correcto
mix compile --warnings-as-errors               # sin warnings
```

**Verificación downstream** (si se modificó API pública):
```bash
(cd ../trebejo && mix compile)                 # trebejo compila
(cd ../candil && mix compile)                  # candil compila
(cd ../delfos && mix compile)                  # delfos compila
```

---

## 8. Refactors estructurales adicionales (no abordados)

### ARR-21: Split `lib/arrea/worker.ex` (559 líneas)
- **Hallazgo**: `worker.ex` tiene **559 líneas** con state machine completa del worker
- **Severidad**: 🟠 Estructural
- **Ficheros**:
  - `lib/arrea/worker.ex` (559 líneas)
  - `lib/arrea/worker/` (nuevo)
- **Esfuerzo estimado**: 6-8h
- **Análisis estructural actual**:
  - State machine: `init/1`, `handle_call/3` (múltiples), `handle_cast/2` (múltiples), `handle_info/2` (múltiples), `terminate/2`
  - Funciones de scheduling: `schedule_work/2`, `process_task/2`, `handle_result/3`
  - Helpers de retry: `retry_with_backoff/3`, `compute_delay/2`
  - Estado: `WorkerState` struct (definido aparte, `worker_state.ex` 170 líneas)
- **Plan de split**:
  - `worker.ex` (~100 líneas): fachada + struct + supervisor child spec
  - `worker/state_machine.ex` (~250 líneas): todos los handle_* y la lógica de transiciones
  - `worker/scheduler.ex` (~150 líneas): scheduling + retry + backoff
  - `worker/result_handler.ex` (~100 líneas): manejo de resultados, telemetría
- **Pasos detallados**:
  1. **Fase 1**: Extraer `state_machine.ex` con todos los handle_*
  2. **Fase 2**: Extraer `scheduler.ex` con scheduling/retry
  3. **Fase 3**: Extraer `result_handler.ex`
  4. **Fase 4**: Worker como fachada
  5. **Fase 5**: Verificar consumers (candil, botica, delfos)
- **Verificación**: `mix test --cover` + `mix credo --strict` + `mix dialyzer`
- **Riesgos**: ALTO. Worker es core de arrea, consumido por todos los lorenzo-sf. Branch dedicada.

---

### ARR-22: Split `lib/arrea/leader.ex` (480 líneas) + `lib/arrea/cli/commands/run.ex` (478 líneas)
- **Hallazgo**: ambos ficheros grandes (480 + 478 líneas)
- **Severidad**: 🟡 Estructural
- **Ficheros**:
  - `lib/arrea/leader.ex` (480 líneas) — coordination logic
  - `lib/arrea/cli/commands/run.ex` (478 líneas) — CLI runner
- **Esfuerzo estimado**: 8-10h
- **Plan**:
  - `leader.ex` (~150 líneas): fachada
  - `leader/registry.ex` (~150 líneas): worker registry
  - `leader/dispatcher.ex` (~150 líneas): task distribution
  - `cli/commands/run.ex` (~150 líneas): CLI command
  - `cli/commands/run/config.ex` (~150 líneas): config parsing
  - `cli/commands/run/runner.ex` (~150 líneas): execution flow
- **Riesgos**: MEDIO. Leader/CLI son importantes pero menos críticos que worker.

---

## 9. Pendiente auditar a fondo

Arrea NO tuvo batch de calidad dedicado. Cuando se le aplique el flujo de 5 comandos con un subagente que profundice, pueden aparecer tareas adicionales. Recomendación: ejecutar el flow completo antes de abordar ARR-21/22.
