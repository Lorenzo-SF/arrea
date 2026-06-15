defmodule Arrea.Config do
  @moduledoc """
  Configuración del engine `Arrea`.

  ## Prioridad de configuración

  ### Arrea como librería (de menor a mayor prioridad)

  1. **`@default`** — Valores baseline compilados en este módulo. Siempre presentes.
  2. **`config :arrea, :engine, [...]`** en el `config.exs` del proyecto consumidor —
     sobreescribe los defaults en tiempo de compilación a través del Application env de OTP.
  3. **`Arrea.Config.set/2`** en tiempo de ejecución — persiste en la sesión actual de la VM
     mediante `Application.put_env`. Sobreescribe la config estática.
  4. **Opts pasadas directamente a las funciones** (`execute/2`, `run/2`, etc.) —
     prioridad máxima. Los llamadores deben comprobar opts antes de recurrir a `Config.get/2`.

  > #### Nota sobre "config propia de Arrea" {: .info}
  >
  > Como librería Elixir/OTP, Arrea no puede tener ficheros de config propios
  > que tengan más prioridad que el proyecto consumidor — es el proyecto consumidor
  > quien siempre gana en la jerarquía de Application env. El `@default` de este
  > módulo es la única configuración "propia" de Arrea, y actúa como baseline.

  ### Arrea como CLI (de menor a mayor prioridad)

  1. **`@default`** — Valores baseline del binario.
  2. **Application env** (si Arrea se usa en contexto mix).
  3. **`arrea config set KEY VALUE`** — Config de sesión. Persiste mientras vive el proceso
     del binario. Usa el mismo mecanismo que `Config.set/2`.
  4. **Args de CLI** — Máxima prioridad. Se aplican solo a la invocación actual.

  ## Ejemplo en `config.exs`

  Acepta tanto keyword list como mapa:

  ```elixir
  # Keyword list (estilo estándar Elixir)
  config :arrea, :engine,
    max_workers: 200,
    circuit_breaker_threshold: 10

  # Mapa equivalente
  config :arrea, :engine, %{max_workers: 200, circuit_breaker_threshold: 10}
  ```

  ## Uso en tiempo de ejecución

  ```elixir
  Arrea.Config.get(:max_workers)        # => 100 (default)
  Arrea.Config.set(:max_workers, 50)    # persiste en la sesión actual
  Arrea.Config.get(:max_workers)        # => 50
  ```
  """

  @default %{
    max_workers: 100,
    max_commands_per_batch: 500,
    default_policy: :retry,
    max_retries: 3,
    retry_delay: 1_000,
    restart_limit: 3,
    circuit_breaker_threshold: 5,
    circuit_breaker_timeout: 60_000,
    validation_rules: [
      :no_rm_rf,
      :no_sudo,
      :no_dd,
      :no_mkfs,
      :no_fork_bomb
    ],
    asdf_enabled: true,
    telemetry_enabled: true,
    log_level: :info,
    shell: nil
  }

  @doc """
  Obtiene un valor de configuración del engine.

  Resolución (de menor a mayor prioridad):
  1. `@default` del módulo
  2. Application env (`config.exs` del consumidor o `Config.set/2` en runtime)

  Los opts de función tienen prioridad sobre este valor y deben comprobarse
  primero en el llamador antes de recurrir a `Config.get/2`.

  ## Ejemplos

      iex> Arrea.Config.get(:max_workers)
      100

      iex> Arrea.Config.get(:nonexistent_key, :fallback)
      :fallback
  """
  @spec get(atom(), any()) :: any()
  def get(key, default \\ nil) do
    env = Application.get_env(:arrea, :engine, %{})

    case env_get(env, key) do
      nil -> Map.get(@default, key, default)
      value -> value
    end
  end

  @doc """
  Obtiene todos los valores de configuración del engine, fusionando los
  defaults con los valores del Application env.

  El resultado refleja la configuración efectiva actual, incluyendo
  sobreescrituras de `config.exs` y cambios aplicados con `Config.set/2`.
  """
  @spec all() :: map()
  def all do
    env = Application.get_env(:arrea, :engine, %{})
    Map.merge(@default, to_map(env))
  end

  @doc """
  Establece un valor de configuración en memoria para la sesión actual.

  Los cambios persisten mientras viva el proceso de la VM. Para cambios
  permanentes, usar `config.exs` del proyecto consumidor.

  En el contexto de CLI, equivale a `arrea config set` — los cambios
  se mantienen mientras el proceso del binario esté activo, pero no
  sobreviven a reinicios.

  ## Ejemplos

      iex> Arrea.Config.set(:max_workers, 50)
      :ok
      iex> Arrea.Config.get(:max_workers)
      50
  """
  @spec set(atom(), any()) :: :ok
  def set(key, value) do
    current = Application.get_env(:arrea, :engine, %{})
    updated = to_map(current) |> Map.put(key, value)
    Application.put_env(:arrea, :engine, updated)
  end

  # ── Helpers internos ──────────────────────────────────────────────────────

  # Normaliza keyword list o mapa a mapa. El Application env puede devolver
  # cualquiera de los dos dependiendo de cómo el consumidor haya configurado
  # la clave (keyword list con `config :arrea, :engine, [...]` o mapa explícito).
  @spec to_map(map() | keyword()) :: map()
  defp to_map(env) when is_map(env), do: env
  defp to_map(env) when is_list(env), do: Map.new(env)
  defp to_map(_), do: %{}

  # Lectura segura que soporta tanto mapa como keyword list.
  @spec env_get(map() | keyword() | term(), atom()) :: any()
  defp env_get(env, key) when is_map(env), do: Map.get(env, key)
  defp env_get(env, key) when is_list(env), do: Keyword.get(env, key)
  defp env_get(_, _), do: nil
end
