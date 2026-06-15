# Arrea

Orquestador de procesos asíncronos y telemetría para Elixir.

Arrea es una librería basada en OTP que proporciona ejecución paralela de procesos, gestión de workers, protección con circuit breaker, validación de comandos y telemetría integrada para monitorizar tus aplicaciones Elixir.

## Inicio Rápido

Agrega Arrea a tu `mix.exs`:

```elixir
def deps do
  [
    {:arrea, github: "Lorenzo-SF/arrea"}
  ]
end
```

Arrea arranca su árbol de supervisión automáticamente al incluirse como dependencia. No se requiere configuración manual.

### Ejecutar un comando único

```elixir
# Comando shell
{:ok, result} = Arrea.execute("echo hello")

# O una función
{:ok, result} = Arrea.execute(fn -> :work end)
```

### Ejecutar comandos en paralelo

```elixir
{:ok, result} = Arrea.run(
  [
    fn -> Process.sleep(100); 1 end,
    fn -> Process.sleep(100); 2 end,
    fn -> Process.sleep(100); 3 end
  ],
  workers: 2
)
```

### Suscribirse a eventos

```elixir
:ok = Arrea.subscribe()

receive do
  {:leader_event, %{type: :finished, worker_id: id}} ->
    IO.puts("Worker #{id} terminó")
  {:leader_event, event} ->
    IO.inspect(event, label: "Evento")
end

:ok = Arrea.unsubscribe()
```

### Obtener estadísticas

```elixir
{:ok, stats} = Arrea.stats()
# => %{
#      total_workers: 10,
#      active_workers: 3,
#      completed_tasks: 42,
#      failed_tasks: 2
#    }
```

## Características

- **Ejecución paralela** — Ejecuta comandos y funciones concurrentemente con pools de workers configurables mediante `Arrea.run/2`
- **Ejecución síncrona** — Ejecuta comandos individuales con `Arrea.execute/2`, con timeout real que cancela la ejecución al expirar
- **Circuit breaker** — Protege llamadas externas con transiciones automáticas de estado (cerrado/abierto/semi-abierto) para prevenir fallos en cascada
- **Validación de comandos** — Reglas de validación integradas que bloquean comandos peligrosos (`rm -rf`, `sudo`, `mkfs`, fork bombs, patrones de inyección)
- **Telemetría** — Sistema de eventos completo con ciclo de vida de workers, progreso de tareas, métricas del sistema y estado del circuit breaker
- **Políticas de error** — Manejo de errores configurable: reintento, detener, continuar, o handlers personalizados con conteo y retraso de reintentos
- **Monitorización de workers** — Suscríbete a eventos en tiempo real: inicio, finalización, fallo y actualizaciones de progreso
- **Ejecución por lotes** — Envía lotes de comandos con límites de workers y timeouts por worker
- **Integración asdf/mise** — Gestión de versiones de runtime mediante `asdf` o `mise` con soporte para flags `--asdf-<runtime>` en CLI y wrapping `mise exec`
- **Shell personalizable** — Shell configurable por comando (`--shell`), vía configuración (`Arrea.Config.set(:shell, ...)`), o auto-detectado desde `$SHELL` con carga automática del archivo de configuración
- **Resultados estructurados** — Structs `Arrea.Result` y `Arrea.Error` para tipos de retorno consistentes

## CLI

Arrea incluye una interfaz de línea de comandos construida con [Alaja](https://github.com/lorenzo-sf/alaja):

```bash
# Construir el escript
mix escript.build

# Ejecutar localmente
./arrea run --command "echo hello"

# Instalar en ~/bin
mix install
```

### `arrea run`

Ejecuta comandos shell en paralelo con seguimiento de progreso.

```bash
# Comando único
arrea run --command "echo hello"

# Múltiples comandos (paralelo)
arrea run --command "echo a" --command "echo b"

# Con límite de workers
arrea run --command "sleep 1" --command "sleep 2" --parallel 2

# Timeout personalizado (ms)
arrea run --command "sleep 10" --timeout 5000

# Modo silencioso (sin progreso)
arrea run --command "echo done" --quiet

# Shell personalizado
arrea run --command "echo $0" --shell zsh

# Con versión ASDF
arrea run --command "mix test" --asdf-elixir 1.18.0

# Con versión mise
arrea run --command "node -v" --mise-node 20.0.0
```

### `arrea config`

Gestiona la configuración del engine Arrea en tiempo de ejecución.

```bash
# Mostrar toda la config
arrea config --show

# Obtener un valor
arrea config get max_workers

# Establecer un valor
arrea config set max_workers 200
arrea config set default_policy stop
arrea config set asdf_enabled true
arrea config set log_level debug
```

### `arrea action`

Ejecuta comandos Arrea desde entrada JSON (stdin, archivo o inline).

```bash
# Desde stdin
echo '{"command":"run","args":["--command","echo hello"]}' | arrea action

# Desde archivo
arrea action --file ./pipeline.json

# JSON inline
arrea action --data '{"command":"run","args":["--command","echo hi","--quiet"]}'

# Acciones por lotes
arrea action --data '{
  "actions": [
    {"command": "run", "args": ["--command", "echo first"], "order": 0},
    {"command": "run", "args": ["--command", "echo second", "--quiet"], "order": 1}
  ]
}'
```

## Arquitectura

```
┌─────────────────────────────────────────────────────┐
│                    Arrea (Fachada)                   │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│              Arrea.Leader (GenServer)                │
│     Coordina ejecución, gestiona workers,            │
│     emite {:leader_event, event} a suscriptores      │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│       Arrea.WorkerSupervisor (DynamicSupervisor)     │
│            Crea workers efímeros                     │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│            Arrea.Worker (GenServer)                  │
│     Ejecuta tareas individuales, maneja políticas,   │
│     reporta progreso vía Leader                      │
└─────────────────────────────────────────────────────┘

  Arrea.Monitor (GenServer)   — Estadísticas del ciclo de vida de workers
  Arrea.CircuitBreaker        — Tolerancia a fallos para dependencias externas
```

Todos los procesos se ejecutan bajo `Arrea.Supervisor` con estrategia `:rest_for_one`, usando dos Registries (`Arrea.Registry` para workers, `Arrea.CircuitBreaker.Registry` para circuit breakers). Con `:rest_for_one`, solo se reinician los procesos que dependen del proceso que falló, minimizando el impacto sobre los batches activos.

## API

### `Arrea.execute/2`

Ejecuta un comando único (cadena shell o función sin argumentos).

```elixir
@spec execute(binary() | (-> term()), keyword()) ::
        {:ok, Arrea.Result.t()} | {:error, Arrea.Error.t()}
```

Opciones:

- `:timeout` — Timeout en ms (por defecto: `30_000`). **Timeout real**: cancela la ejecución si se supera.
- `:retry` — Si se debe reintentar en caso de fallo
- `:shell` — Shell a usar — prioridad máxima, sobreescribe config y `$SHELL`
- `:shell_config` — Ruta al archivo de configuración del shell (auto-detectado por defecto)
- `:asdf_<runtime>` — Forzar versión de runtime vía asdf/mise (ej: `asdf_elixir: "1.18.0"`)
- `:mise_<runtime>` — Usar `mise exec` (ej: `mise_node: "20.0.0"`)

### `Arrea.run/2`

Ejecuta múltiples comandos en paralelo.

```elixir
@spec run([binary() | (-> term())], keyword()) ::
        {:ok, Arrea.Result.t()} | {:error, Arrea.Error.t()}
```

Opciones:

- `:workers` — Workers paralelos máximos (por defecto: `max_workers()`)
- `:timeout` — Timeout total en ms

### `Arrea.subscribe/0` / `Arrea.unsubscribe/0`

Suscribe (o cancela la suscripción de) el proceso actual a los eventos del Leader.

Los mensajes recibidos tienen la forma `{:leader_event, event}`, donde `event` es un mapa con al menos la clave `:type`:

| Tipo               | Claves adicionales                               |
| ------------------ | ------------------------------------------------ |
| `:worker_started`  | `worker_id`                                      |
| `:progress`        | `worker_id`, `percent`, `task_index`, `total`    |
| `:finished`        | `worker_id`                                      |
| `:error`           | `worker_id`, `reason`                            |
| `:result`          | `worker_id`, `data`                              |

```elixir
@spec subscribe() :: :ok
@spec unsubscribe() :: :ok
```

### `Arrea.stats/0`

Obtiene las estadísticas actuales del engine (provistas por `Arrea.Monitor`).

```elixir
@spec stats() :: {:ok, map()} | {:error, :monitor_unavailable}
```

### `Arrea.max_workers/0`

Obtiene el máximo de workers configurado.

```elixir
@spec max_workers() :: non_neg_integer()
```

## Configuración

### Prioridad (de menor a mayor)

**Como librería:**

1. `@default` en `Arrea.Config` — baseline compilado, mínima prioridad
2. `config :arrea, :engine, [...]` en el `config.exs` del proyecto consumidor — sobreescribe el baseline
3. `Arrea.Config.set/2` en tiempo de ejecución — sobreescribe la config estática en la sesión actual
4. Opts pasadas directamente a las funciones — máxima prioridad, solo aplican a esa llamada

**Como CLI:**

1. `@default` baseline
2. Application env (si aplica)
3. `arrea config set KEY VALUE` — persiste mientras el proceso del binario está activo
4. Args de CLI — máxima prioridad, solo aplican a la invocación actual

### Ejemplo en `config.exs`

Acepta tanto keyword list como mapa:

```elixir
config :arrea, :engine,
  max_workers: 100,
  max_commands_per_batch: 500,
  default_policy: :retry,
  max_retries: 3,
  retry_delay: 1_000,
  restart_limit: 3,
  circuit_breaker_threshold: 5,
  circuit_breaker_timeout: 60_000,
  validation_rules: [:no_rm_rf, :no_sudo, :no_dd, :no_mkfs, :no_fork_bomb],
  telemetry_enabled: true,
  log_level: :info
```

| Clave                       | Tipo    | Por defecto | Descripción                                     |
| --------------------------- | ------- | ----------- | --------------------------------------------- |
| `max_workers`               | integer | `100`       | Workers paralelos máximos                       |
| `max_commands_per_batch`    | integer | `500`       | Comandos máximos por lote                       |
| `default_policy`            | atom    | `:retry`    | Política de error por defecto para workers       |
| `max_retries`               | integer | `3`         | Intentos máximos de reintento                   |
| `retry_delay`               | integer | `1_000`     | Retraso entre reintentos (ms)                   |
| `restart_limit`             | integer | `3`         | Límite de reinicio de workers                   |
| `circuit_breaker_threshold` | integer | `5`         | Fallos antes de abrir el circuito               |
| `circuit_breaker_timeout`   | integer | `60_000`    | Tiempo antes de intento semi-abierto (ms)       |
| `validation_rules`          | list    | ver abajo   | Patrones de comandos bloqueados                 |
| `asdf_enabled`              | boolean | `true`      | Activar gestión de versiones ASDF               |
| `telemetry_enabled`         | boolean | `true`      | Activar telemetría                             |
| `log_level`                 | atom    | `:info`     | Nivel de logging                               |
| `shell`                     | string  | `nil`       | Shell por defecto (ej: `"/bin/zsh"`)         |

**Reglas de validación** (por defecto):
- `:no_rm_rf` — bloquea `rm -rf`
- `:no_sudo` — bloquea `sudo`
- `:no_dd` — bloquea `dd`
- `:no_mkfs` — bloquea `mkfs`
- `:no_fork_bomb` — bloquea fork bombs

### Config en tiempo de ejecución

```elixir
Arrea.Config.get(:max_workers)      # => 100
Arrea.Config.set(:max_workers, 50)  # persiste en la sesión actual de la VM
Arrea.Config.all()                  # => mapa de config efectiva completa
```

## Eventos de Telemetría

Arrea emite los siguientes eventos de `:telemetry`:

### Eventos de worker

| Evento                          | Mediciones | Metadatos             |
| ------------------------------- | ---------- | --------------------- |
| `[:arrea, :worker, :started]`   | —          | `worker_id`           |
| `[:arrea, :worker, :completed]` | `duration` | `worker_id`           |
| `[:arrea, :worker, :error]`     | —          | `worker_id`, `reason` |
| `[:arrea, :worker, :message]`   | —          | `worker_id`           |

### Eventos de tarea

| Evento                        | Mediciones | Metadatos             |
| ----------------------------- | ---------- | --------------------- |
| `[:arrea, :task, :started]`   | —          | —                     |
| `[:arrea, :task, :completed]` | `duration` | —                     |
| `[:arrea, :task, :error]`     | —          | `worker_id`, `reason` |

### Eventos del engine

| Evento                                | Mediciones | Metadatos            |
| ------------------------------------- | ---------- | -------------------- |
| `[:arrea, :engine, :execute, :start]` | —          | `command`            |
| `[:arrea, :engine, :execute, :stop]`  | `duration` | `command`, `success` |
| `[:arrea, :engine, :execute, :error]` | `duration` | `command`, `reason`  |
| `[:arrea, :engine, :run, :start]`     | —          | `count`, `workers`   |
| `[:arrea, :engine, :run, :stop]`      | —          | `batch_id`           |

### Eventos de circuit breaker

| Evento                                | Mediciones | Metadatos                     |
| ------------------------------------- | ---------- | ----------------------------- |
| `[:arrea, :circuit_breaker, :open]`   | —          | `breaker_id`                  |
| `[:arrea, :circuit_breaker, :closed]` | —          | `breaker_id`                  |
| `[:arrea, :circuit_breaker, :trip]`   | —          | `breaker_id`, `failure_count` |

### Eventos de comunicación

| Evento                                        | Mediciones | Metadatos |
| --------------------------------------------- | ---------- | --------- |
| `[:arrea, :communication, :message_sent]`     | —          | —         |
| `[:arrea, :communication, :message_received]` | —          | —         |
| `[:arrea, :communication, :error]`            | —          | —         |
| `[:arrea, :communication, :retry]`            | —          | —         |

### Eventos de UI (CLI / componentes alaja)

| Evento                          | Mediciones | Metadatos |
| ------------------------------- | ---------- | --------- |
| `[:arrea, :ui, :render]`        | —          | —         |
| `[:arrea, :ui, :keypress]`      | —          | —         |
| `[:arrea, :ui, :focus_change]`  | —          | —         |

### Eventos de validación / ejecución / sistema

| Evento                             | Mediciones | Metadatos |
| ---------------------------------- | ---------- | --------- |
| `[:arrea, :validation, :passed]`   | —          | —         |
| `[:arrea, :validation, :failed]`   | —          | —         |
| `[:arrea, :execution, :started]`   | —          | —         |
| `[:arrea, :execution, :completed]` | —          | —         |
| `[:arrea, :execution, :failed]`    | —          | —         |
| `[:arrea, :system, :started]`      | —          | —         |
| `[:arrea, :system, :stopped]`      | —          | —         |

### Adjuntar un handler personalizado

```elixir
:telemetry.attach(
  "my-handler",
  [:arrea, :worker, :completed],
  fn _event, measurements, metadata, _config ->
    IO.puts("Worker #{metadata.worker_id} terminó en #{measurements.duration}ms")
  end,
  nil
)
```

### Métricas y debug integrados

```elixir
# Configurar métricas ETS (contadores de workers/tareas/circuit breakers)
Arrea.Telemetry.setup()

# Obtener snapshot actual de métricas
Arrea.Telemetry.get_current()

# Activar handler de debug para desarrollo
Arrea.Telemetry.attach()

# Medir una función con telemetría
Arrea.Telemetry.measure(fn -> hacer_trabajo() end, metadata: %{tag: "lote-1"})
```

## Políticas

Arrea proporciona políticas de error configurables para workers:

```elixir
# Política por defecto (reintentar 3 veces con 1s de retraso)
policy = Arrea.Policies.default()

# Política estricta (detener en el primer error)
policy = Arrea.Policies.strict()

# Política tolerante (reintentar hasta 10 veces con 2s de retraso)
policy = Arrea.Policies.tolerant(max_retries: 10, retry_delay: 2000)

# Handler personalizado
policy = Arrea.Policies.custom(fn error, retry_count, context ->
  if retry_count < 5, do: :retry, else: :stop
end)
```

Los workers sin política explícita usan `Arrea.Config.get(:default_policy)`, que por defecto es `:retry`.

Los mapas de políticas soportan los siguientes campos:

| Campo         | Tipo                                                | Por defecto | Descripción                   |
| ------------- | --------------------------------------------------- | ----------- | ----------------------------- |
| `on_error`    | `:retry \| :stop \| :continue \| function`          | `:retry`    | Acción ante error de tarea    |
| `on_warning`  | `:log \| :notify \| :continue \| :promote_to_error` | `:log`      | Acción ante advertencia       |
| `on_timeout`  | `:retry \| :stop \| :continue`                      | `:retry`    | Acción ante timeout           |
| `max_retries` | integer                                             | `3`         | Intentos máximos de reintento |
| `retry_delay` | integer                                             | `1000`      | Retraso entre reintentos (ms) |
| `timeout`     | integer                                             | `30000`     | Timeout por tarea (ms)        |

## Validación de Comandos

Arrea valida todos los comandos shell antes de ejecutarlos, bloqueando patrones peligrosos:

```elixir
iex> Arrea.Validation.Validator.validate_command("echo hello")
{:ok, "echo hello"}

iex> Arrea.Validation.Validator.validate_command("rm -rf /")
{:error, {:dangerous_command, "rm -rf"}}

iex> Arrea.Validation.Validator.validate_command("$(whoami)")
{:error, :possible_injection}
```

## Mensajería entre Workers

Los workers pueden enviarse mensajes entre sí:

```elixir
# Mensaje estructurado
Arrea.Worker.send_message(:worker_1, %{type: :ping})

# Enrutar un mensaje a otro worker
Arrea.Worker.send_message(:worker_1, {:send_to_worker, :worker_2, %{type: :data, value: 42}})
```

## Dependencias

- **alaja** — Librería interna de UI/CLI (impulsa el CLI de Arrea)
- **jason** — Codificación/decodificación JSON
- **telemetry** — Emisión y manejo de eventos
- **telemetry_metrics** — Definición de métricas
- **telemetry_poller** — Recolección periódica de métricas

## Instalación

Agrega `arrea` a las dependencias de tu `mix.exs`:

```elixir
def deps do
  [
    {:arrea, github: "Lorenzo-SF/arrea"}
  ]
end
```

Luego ejecuta:

```bash
mix deps.get
```

## Licencia

Licencia MIT. Consulta el [repositorio fuente](https://github.com/lorenzo-sf/arrea) para más detalles.
