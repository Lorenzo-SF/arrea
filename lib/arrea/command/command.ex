defmodule Arrea.Command do
  @moduledoc """
  Ejecución síncrona de comandos con soporte para gestión de versiones.

  Proporciona una interfaz limpia para ejecutar comandos shell con validación,
  selección de shell, detección automática de archivos de configuración,
  integración con asdf/mise y parseo estructurado de resultados.

  Para ejecución en paralelo, usar `Arrea.Parallel` o `Arrea.Leader`.

  ## Resolución de shell

  El shell se resuelve con la siguiente prioridad (de menor a mayor):
  1. `Arrea.Config.get(:shell)` — config del proyecto consumidor o runtime
  2. Variable de entorno `$SHELL`
  3. Login shell del usuario actual (`/etc/passwd`)
  4. Opción `:shell` pasada a `execute/2` — **máxima prioridad**
  5. `"sh"` como último recurso si ninguno de los anteriores es válido

  Se aceptan tanto nombres (`"zsh"`) como rutas (`"/bin/zsh"`).
  Los nombres se resuelven a rutas mediante `System.find_executable/1`.
  Si el shell configurado no existe, cae al default del sistema (`$SHELL` o `"sh"`).

  Según el shell detectado, se fuerza la carga de su archivo de configuración
  (ej: `~/.bashrc` para bash, `~/.zshrc` para zsh, `~/.config/fish/config.fish` para fish).

  ## Timeout real

  El timeout se aplica **durante** la ejecución: si el comando no termina
  en `timeout` ms, el proceso de ejecución es cancelado. El proceso OS subyacente
  recibe SIGKILL cuando el puerto de Erlang es cerrado al morir el proceso propietario.

  ## Gestión de versiones asdf/mise

  Se pueden forzar versiones de runtimes mediante dos mecanismos:

  * **asdf** — opción `asdf_<lenguaje>`: genera `export ASDF_<LANG>_VERSION=<version>`
    antes del comando. Funciona tanto con asdf como con mise.

  * **mise** — opción `mise_<lenguaje>`: envuelve el comando con
    `mise exec <lenguaje>@<version> -- <comando>`.

  ## Ejemplos

      iex> Arrea.Command.execute("echo hello")
      {:ok, %{stdout: "hello\\n", exit_code: 0, duration_ms: 3}}

      iex> Arrea.Command.execute("mix test", asdf_elixir: "1.18.0")
      {:ok, %{stdout: "...", exit_code: 0, duration_ms: 1200}}

      iex> Arrea.Command.execute("node -v", mise_node: "20.0.0")
      {:ok, %{stdout: "v20.0.0\\n", exit_code: 0, duration_ms: 80}}

      iex> Arrea.Command.execute("sleep 60", timeout: 500)
      {:error, :timeout}
  """

  alias Arrea.Validation.Validator

  @type result :: %{
          stdout: String.t(),
          exit_code: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @default_timeout 30_000

  @shell_configs %{
    "bash" => "~/.bashrc",
    "zsh" => "~/.zshrc",
    "sh" => "~/.profile",
    "fish" => "~/.config/fish/config.fish",
    "dash" => "/etc/profile",
    "ksh" => "~/.kshrc"
  }

  @doc """
  Resuelve el nombre de un shell a su ruta absoluta.

  Si ya es una ruta (contiene `/`), se devuelve tal cual si existe.
  Si es solo un nombre, se busca en PATH via `System.find_executable/1`.
  Retorna `nil` si no se encuentra el ejecutable.
  """
  @spec resolve_shell_path(String.t()) :: String.t() | nil
  def resolve_shell_path(shell) do
    if String.contains?(shell, "/") do
      if File.exists?(shell), do: shell, else: nil
    else
      System.find_executable(shell)
    end
  end

  @doc """
  Resuelve el shell a usar según la prioridad (de menor a mayor):
  1. `Arrea.Config.get(:shell)` (config del proyecto o `Config.set/2`)
  2. Variable de entorno `$SHELL`
  3. Login shell del usuario en `/etc/passwd`
  4. Opción `:shell` pasada en opts — máxima prioridad
  5. `"sh"` como fallback si ninguno es válido

  Si el shell resuelto es un nombre (ej: `"zsh"`), lo busca en PATH.
  Si no se encuentra, cae al default del sistema.
  """
  @spec resolve_shell(keyword()) :: String.t()
  def resolve_shell(opts \\ []) do
    candidate =
      Keyword.get(opts, :shell) ||
        Arrea.Config.get(:shell) ||
        default_user_login_shell() ||
        "sh"

    case resolve_shell_path(candidate) do
      nil -> System.get_env("SHELL") || "sh"
      path -> path
    end
  end

  @doc """
  Resuelve la ruta al archivo de configuración del shell.

  Retorna la ruta expandida al archivo de config (ej: `~/.zshrc` para zsh)
  o `nil` si el shell no tiene un archivo de config conocido.
  """
  @spec resolve_shell_config(String.t()) :: String.t() | nil
  def resolve_shell_config(shell) do
    shell_name = Path.basename(shell)

    case Map.get(@shell_configs, shell_name) do
      nil -> nil
      path -> expand_path(path)
    end
  end

  @doc """
  Ejecuta una cadena de comando de forma síncrona con configuración opcional.

  El comando se valida antes de la ejecución. Comandos inválidos o peligrosos
  retornan `{:error, razon}` sin ejecutar nada.

  El timeout es **real**: si el comando no termina dentro del límite,
  el proceso de ejecución es cancelado activamente (no post-hoc).

  ## Opciones

  - `:timeout` — Tiempo máximo de ejecución en ms (default: `30_000`)
  - `:cd` — Directorio de trabajo (default: directorio actual)
  - `:shell` — Shell a usar — tiene prioridad máxima sobre config y env
  - `:shell_config` — Ruta al archivo de configuración del shell a cargar (opcional)
  - `:env` — Variables de entorno adicionales como mapa (opcional)
  - `:quiet` — Si es true, suprime la captura de stderr (default: false)
  - `:asdf_elixir` — Forzar versión de Elixir via asdf/mise
  - `asdf_<lang>` — Forzar versión de cualquier lenguaje via asdf/mise
  - `mise_<lang>` — Forzar versión via `mise exec`

  ## Retorna

  - `{:ok, result}` — Mapa con `:stdout`, `:exit_code`, `:duration_ms`
  - `{:error, :timeout}` — El comando fue cancelado por exceder el timeout
  - `{:error, reason}` — Error de validación o ejecución
  """
  @spec execute(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def execute(cmd, opts \\ []) do
    with {:ok, validated_cmd} <- Validator.validate_command(cmd) do
      shell = resolve_shell(opts)
      opts = enrich_opts(opts, shell)
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      cd = Keyword.get(opts, :cd, ".")
      env = build_env(opts)
      full_cmd = build_full_command(validated_cmd, opts)

      do_execute(shell, full_cmd, cd, env, timeout)
    end
  end

  @doc """
  Ejecuta un comando con una versión de lenguaje gestionada por ASDF.

  Envoltorio conveniente para `execute/2` que antepone la activación del shim de asdf.

  ## Ejemplos

      iex> Command.execute_with_asdf("mix test", :elixir, "1.18.0")
      {:ok, %{stdout: "...", exit_code: 0, duration_ms: 1200}}
  """
  @spec execute_with_asdf(String.t(), atom(), String.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def execute_with_asdf(cmd, language, version, opts \\ []) do
    lang_key = String.to_atom("asdf_#{language}")
    execute(cmd, Keyword.put(opts, lang_key, version))
  end

  @doc """
  Parsea un mapa de resultado crudo a una forma estructurada.

  Detecta patrones comunes de error y retorna resultados etiquetados.
  """
  @spec parse_result(result()) :: {:ok, result()} | {:error, {:exit_code, non_neg_integer()}}
  def parse_result(%{exit_code: 0} = result), do: {:ok, result}
  def parse_result(%{exit_code: code} = _result), do: {:error, {:exit_code, code}}

  # ── Ejecución interna ─────────────────────────────────────────────────────

  # Lanza el comando en un Task y aplica timeout real con Task.yield/2.
  # Si el timeout expira, Task.shutdown/2 con :brutal_kill mata el proceso Elixir.
  # Al morir el proceso propietario del puerto, Erlang cierra el puerto y el
  # proceso OS subyacente recibe SIGKILL.
  @spec do_execute(String.t(), String.t(), String.t(), [{String.t(), String.t()}], pos_integer()) ::
          {:ok, result()} | {:error, term()}
  defp do_execute(shell, cmd, cd, env, timeout) do
    started_at = System.monotonic_time(:millisecond)
    task = Task.async(fn -> exec_with_shell_safe(shell, cmd, cd, env, started_at) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  # Intenta ejecutar con el shell configurado; si no existe (:enoent),
  # cae al shell del sistema como último recurso.
  @spec exec_with_shell_safe(String.t(), String.t(), String.t(), list(), integer()) ::
          {:ok, result()} | {:error, term()}
  defp exec_with_shell_safe(shell, cmd, cd, env, started_at) do
    case exec_with_shell(shell, cmd, cd, env, started_at) do
      {:error, :enoent} ->
        fallback = System.get_env("SHELL") || "sh"
        exec_with_shell(fallback, cmd, cd, env, started_at)

      other ->
        other
    end
  end

  @spec exec_with_shell(
          String.t(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          integer()
        ) :: {:ok, result()} | {:error, term()}
  defp exec_with_shell(shell, cmd, cd, env, started_at) do
    system_opts =
      [stderr_to_stdout: true, cd: cd]
      |> then(fn opts -> if env == [], do: opts, else: Keyword.put(opts, :env, env) end)

    case System.cmd(shell, ["-c", cmd], system_opts) do
      {output, exit_code} ->
        duration = System.monotonic_time(:millisecond) - started_at

        {:ok,
         %{
           stdout: output,
           exit_code: exit_code,
           duration_ms: duration
         }}
    end
  rescue
    error ->
      case error do
        %ErlangError{original: :enoent} -> {:error, :enoent}
        _ -> {:error, {:execution_error, error}}
      end
  end

  # ── Construcción del comando ──────────────────────────────────────────────

  @doc false
  @spec build_full_command(String.t(), keyword()) :: String.t()
  def build_full_command(cmd, opts) do
    asdf_prefix = build_asdf_prefix(opts)
    shell_source = build_shell_source(opts)

    inner_parts =
      [shell_source, asdf_prefix, cmd]
      |> Enum.reject(&(&1 == ""))

    inner_cmd = Enum.join(inner_parts, "; ")

    case build_mise_args(opts) do
      [] -> inner_cmd
      args -> "mise exec #{Enum.join(args, " ")} -- #{inner_cmd}"
    end
  end

  @doc """
  Extrae los argumentos `mise_<lang>` de las opciones y los formatea
  como `"lang@version"` para el comando `mise exec`.
  """
  @spec build_mise_args(keyword()) :: [String.t()]
  def build_mise_args(opts) do
    opts
    |> Enum.filter(fn {key, _} -> key |> to_string() |> String.starts_with?("mise_") end)
    |> Enum.map(fn {key, version} ->
      lang = key |> to_string() |> String.replace_prefix("mise_", "")
      "#{lang}@#{version}"
    end)
  end

  @doc false
  @spec build_asdf_prefix(keyword()) :: String.t()
  def build_asdf_prefix(opts) do
    if Keyword.get(opts, :asdf_local, false) do
      "asdf local"
    else
      opts
      |> Enum.filter(fn {key, _} -> key |> to_string() |> String.starts_with?("asdf_") end)
      |> Enum.map(fn {key, version} ->
        lang = key |> to_string() |> String.replace_prefix("asdf_", "")
        "export ASDF_#{String.upcase(lang)}_VERSION=#{version}"
      end)
      |> Enum.map_join("; ", & &1)
    end
  end

  @spec build_shell_source(keyword()) :: String.t()
  defp build_shell_source(opts) do
    config =
      case Keyword.get(opts, :shell_config) do
        nil ->
          if shell = Keyword.get(opts, :shell), do: resolve_shell_config(shell)

        path ->
          path
      end

    case config do
      nil -> ""
      path -> "source #{path}"
    end
  end

  defp enrich_opts(opts, shell) do
    opts
    |> Keyword.put(:shell, shell)
    |> Keyword.put(:shell_config, resolve_shell_config(shell))
  end

  @spec build_env(keyword()) :: [{String.t(), String.t()}]
  defp build_env(opts) do
    opts
    |> Keyword.get(:env, %{})
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp expand_path("~" <> rest) do
    Path.join(System.get_env("HOME", "/root"), rest)
  end

  defp expand_path(path), do: path

  defp default_user_login_shell do
    case System.get_env("SHELL") do
      nil -> get_shell_from_passwd()
      val -> val
    end
  end

  defp get_shell_from_passwd do
    user = System.get_env("USER") || "root"

    case File.read("/etc/passwd") do
      {:ok, content} ->
        line = content |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "#{user}:"))
        parse_passwd_shell(line)

      _ ->
        "/bin/sh"
    end
  end

  defp parse_passwd_shell(line) when is_binary(line) do
    shell_path = line |> String.split(":") |> List.last()
    if File.exists?(shell_path), do: shell_path, else: "/bin/sh"
  end

  defp parse_passwd_shell(_), do: "/bin/sh"
end
