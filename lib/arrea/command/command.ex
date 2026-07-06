defmodule Arrea.Command do
  @moduledoc """
  Synchronous command execution with version manager support.

  Provides a clean interface to run shell commands with validation,
  shell selection, automatic detection of configuration files,
  asdf/mise integration, and structured result parsing.

  For parallel execution, use `Arrea.Parallel` or `Arrea.Leader`.

  ## Shell resolution

  The shell is resolved with the following priority (lowest to highest):
  1. `Config.get(:shell)` — consumer project or runtime config
  2. `$SHELL` environment variable
  3. Current user login shell (`/etc/passwd`)
  4. `:shell` option passed to `execute/2` — **highest priority**
  5. `"sh"` as a last resort if none of the above is valid

  Both names (`"zsh"`) and paths (`"/bin/zsh"`) are accepted.
  Names are resolved to paths via `System.find_executable/1`.
  If the configured shell does not exist, it falls back to the system
  default (`$SHELL` or `"sh"`).

  Based on the detected shell, its configuration file is forced to load
  (e.g. `~/.bashrc` for bash, `~/.zshrc` for zsh, `~/.config/fish/config.fish` for fish).

  ## Real timeout

  The timeout is enforced **during** execution: if the command does not
  finish within `timeout` ms, the execution process is cancelled. The
  underlying OS process receives SIGKILL when the Erlang port is closed
  as its owner dies.

  ## asdf/mise version management

  Runtime versions can be forced via two mechanisms:

  * **asdf** — `asdf_<language>` option: emits
    `export ASDF_<LANG>_VERSION=<version>` before the command. Works
    with both asdf and mise.

  * **mise** — `mise_<language>` option: wraps the command with
    `mise exec <language>@<version> -- <command>`.

  ## Examples

      iex> Arrea.Command.execute("echo hello")
      {:ok, %{stdout: "hello\\n", exit_code: 0, duration_ms: 3}}

      iex> Arrea.Command.execute("mix test", asdf_elixir: "1.18.0")
      {:ok, %{stdout: "...", exit_code: 0, duration_ms: 1200}}

      iex> Arrea.Command.execute("node -v", mise_node: "20.0.0")
      {:ok, %{stdout: "v20.0.0\\n", exit_code: 0, duration_ms: 80}}

      iex> Arrea.Command.execute("sleep 60", timeout: 500)
      {:error, :timeout}
  """

  alias Arrea.Config
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
  Resolves a shell name to its absolute path.

  If it is already a path (contains `/`), it is returned as-is if it exists.
  If it is just a name, it is looked up in PATH via `System.find_executable/1`.
  Returns `nil` if the executable cannot be found.
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
  Resolves the shell to use, by priority (lowest to highest):
  1. `Config.get(:shell)` (project config or `Config.set/2`)
  2. `$SHELL` environment variable
  3. User login shell in `/etc/passwd`
  4. `:shell` option passed in `opts` — highest priority
  5. `"sh"` as a fallback if none is valid

  If the resolved shell is a name (e.g. `"zsh"`), it is looked up in PATH.
  If not found, it falls back to the system default.
  """
  @spec resolve_shell(keyword()) :: String.t()
  def resolve_shell(opts \\ []) do
    candidate =
      Keyword.get(opts, :shell) ||
        Config.get(:shell) ||
        default_user_login_shell() ||
        "sh"

    case resolve_shell_path(candidate) do
      nil -> System.get_env("SHELL") || "sh"
      path -> path
    end
  end

  @doc """
  Resolves the path to the shell configuration file.

  Returns the expanded path to the config file (e.g. `~/.zshrc` for zsh)
  or `nil` if the shell has no known config file.
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
  Returns `true` if the given command exists in the system `PATH`.

  Thin wrapper around `System.find_executable/1` exposed publicly so
  consumers (Apero.Proc, Botica.Batteries.*) don't have to redefine it
  and can centralise the lookup through Arrea for future observability.

  ## Examples

      iex> Arrea.Command.command_exists?("echo")
      true

      iex> Arrea.Command.command_exists?("definitely_not_a_real_binary_12345")
      false
  """
  @spec command_exists?(String.t()) :: boolean()
  def command_exists?(cmd) when is_binary(cmd) and byte_size(cmd) > 0 do
    System.find_executable(cmd) != nil
  end

  def command_exists?(_), do: false

  @doc """
  Returns the full path of a command if found in `PATH`, or `nil`.

  Counterpart to the POSIX `which(1)` command. Wraps
  `System.find_executable/1` for consistency with `command_exists?/1`.

  ## Examples

      iex> Arrea.Command.which("echo")
      "/usr/bin/echo"

      iex> Arrea.Command.which("not_a_real_binary_12345")
      nil
  """
  @spec which(String.t()) :: String.t() | nil
  def which(cmd) when is_binary(cmd) and byte_size(cmd) > 0 do
    System.find_executable(cmd)
  end

  def which(_), do: nil

  @doc """
  Executes a command string synchronously with optional configuration.

  The command is validated before execution unless `:validate` is set to
  `false`. Invalid or dangerous commands return `{:error, reason}`
  without executing anything.

  The timeout is **real**: if the command does not finish within the
  limit, the execution process is actively cancelled (not post-hoc).

  ## Options

  - `:timeout` — Maximum execution time in ms (default: `30_000`)
  - `:cd` — Working directory (default: current directory)
  - `:shell` — Shell to use — takes highest priority over config and env
  - `:shell_config` — Path to the shell configuration file to load (optional)
  - `:env` — Additional environment variables as a map (optional)
  - `:quiet` — If true, suppress stderr capture (default: false)
  - `:validate` — Run the safety validator before execution (default: `true`).
    Set to `false` for trusted internal callers (e.g. Apero's OS info commands)
    that would otherwise pay the per-call validation cost or hit false positives.
  - `:asdf_elixir` — Force Elixir version via asdf/mise
  - `asdf_<lang>` — Force any language version via asdf/mise
  - `mise_<lang>` — Force version via `mise exec`

  ## Returns

  - `{:ok, result}` — Map with `:stdout`, `:exit_code`, `:duration_ms`
  - `{:error, :timeout}` — The command was cancelled for exceeding the timeout
  - `{:error, reason}` — Validation or execution error
  """
  @spec execute(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def execute(cmd, opts \\ []) do
    with :ok <- maybe_validate(cmd, opts) do
      shell = resolve_shell(opts)
      opts = enrich_opts(opts, shell)
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      cd = Keyword.get(opts, :cd, ".")
      env = build_env(opts)
      full_cmd = build_full_command(cmd, opts)

      do_execute(shell, full_cmd, cd, env, timeout)
    end
  end

  @doc """
  Executes a command with a language version managed by ASDF.

  Convenience wrapper around `execute/2` that prepends the asdf shim activation.

  ## Examples

      iex> Command.execute_with_asdf("mix test", :elixir, "1.18.0")
      {:ok, %{stdout: "...", exit_code: 0, duration_ms: 1200}}
  """
  @spec execute_with_asdf(String.t(), atom(), String.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def execute_with_asdf(cmd, language, version, opts \\ []) do
    lang_key = String.to_existing_atom("asdf_#{language}")
    execute(cmd, Keyword.put(opts, lang_key, version))
  end

  @doc """
  Parses a raw result map into a structured form.

  Detects common error patterns and returns tagged results.
  """
  @spec parse_result(result()) :: {:ok, result()} | {:error, {:exit_code, non_neg_integer()}}
  def parse_result(%{exit_code: 0} = result), do: {:ok, result}
  def parse_result(%{exit_code: code} = _result), do: {:error, {:exit_code, code}}

  # Runs `Arrea.Validation.Validator.validate_command/1` unless the caller
  # passed `:validate, false`. Trusted internal callers (e.g. Apero's info
  # commands) can opt out to avoid the per-call cost.
  @spec maybe_validate(String.t(), keyword()) :: :ok | {:error, term()}
  defp maybe_validate(cmd, opts) do
    if Keyword.get(opts, :validate, true) do
      case Validator.validate_command(cmd) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  # ── Internal execution ─────────────────────────────────────────────────────

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

  # ── Command construction ──────────────────────────────────────────────

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
