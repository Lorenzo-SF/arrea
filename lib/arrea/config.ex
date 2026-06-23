defmodule Arrea.Config do
  @moduledoc """
  Configuration for the `Arrea` engine.

  ## Configuration priority

  ### Arrea as a library (lowest to highest priority)

  1. **`@default`** — Baseline values compiled in this module. Always present.
  2. **`config :arrea, :engine, [...]`** in the consumer project's `config.exs` —
     overrides the defaults at compile time through OTP's Application env.
  3. **`Arrea.Config.set/2`** at runtime — persists in the current VM session
     via `Application.put_env`. Overrides static config.
  4. **Options passed directly to the functions** (`execute/2`, `run/2`, etc.) —
     highest priority. Callers should check opts before falling back to `Config.get/2`.

  > #### Note on "Arrea's own config" {: .info}
  >
  > As an Elixir/OTP library, Arrea cannot have its own config files with
  > higher priority than the consumer project — the consumer project always
  > wins in the Application env hierarchy. The `@default` in this module
  > is the only "own" Arrea configuration, and it acts as a baseline.

  ### Arrea as a CLI (lowest to highest priority)

  1. **`@default`** — Baseline values of the binary.
  2. **Application env** (if Arrea is used in a mix context).
  3. **`arrea config set KEY VALUE`** — Session config. Persists for the lifetime
     of the binary process. Uses the same mechanism as `Config.set/2`.
  4. **CLI args** — Highest priority. Applied to the current invocation only.

  ## Example in `config.exs`

  Acepta tanto keyword list como mapa:

  ```elixir
  # Keyword list (estilo estándar Elixir)
  config :arrea, :engine,
    max_workers: 200,
    circuit_breaker_threshold: 10

  # Mapa equivalente
  config :arrea, :engine, %{max_workers: 200, circuit_breaker_threshold: 10}
  ```

  ## Runtime usage

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
  Returns a configuration value from the engine.

  Resolution (lowest to highest priority):
  1. `@default` of the module
  2. Application env (consumer's `config.exs` or `Config.set/2` at runtime)

  Function opts take priority over this value and should be checked
  first in the caller before falling back to `Config.get/2`.

  ## Examples

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
  Returns all engine configuration values, merging the defaults with the
  Application env values.

  The result reflects the current effective configuration, including
  `config.exs` overrides and any changes applied with `Config.set/2`.
  """
  @spec all() :: map()
  def all do
    env = Application.get_env(:arrea, :engine, %{})
    Map.merge(@default, to_map(env))
  end

  @doc """
  Sets a configuration value in memory for the current session.

  Los cambios persisten mientras viva el proceso de la VM. Para cambios
  permanentes, usar `config.exs` del proyecto consumidor.

  En el contexto de CLI, equivale a `arrea config set` — los cambios
  se mantienen mientras el proceso del binario esté activo, pero no
  sobreviven a reinicios.

  ## Examples

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
