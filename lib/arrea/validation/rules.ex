defmodule Arrea.Validation.Rules do
  @moduledoc """
  Validation rules for commands and worker specifications.

  All functions return `{:ok, value}` on success or
  `{:error, reason}` on failure. Rules are composable using
  `with` chains.
  """

  alias Arrea.Config

  @dangerous_commands [
    "rm -rf",
    "rm -r /",
    "sudo ",
    "dd if=",
    "mkfs",
    "chmod -r 777",
    ":(){ :|:& };:",
    "> /dev/sda",
    "shutdown",
    "reboot",
    "halt",
    "kill -9 1",
    "pkill -9",
    "chown "
  ]

  @allowed_shells ~w[sh bash zsh fish dash]

  @doc """
  Valida que una cadena de comando no este vacia.
  """
  @spec not_empty(String.t()) :: {:ok, String.t()} | {:error, :empty_command}
  def not_empty(""), do: {:error, :empty_command}

  def not_empty(cmd) when is_binary(cmd) do
    if String.trim(cmd) == "" do
      {:error, :empty_command}
    else
      {:ok, cmd}
    end
  end

  def not_empty(_), do: {:error, :invalid_command_type}

  @doc """
  Valida que un comando no exceda la longitud maxima permitida.
  """
  @spec max_length(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, :command_too_long}
  def max_length(cmd, max) when byte_size(cmd) <= max, do: {:ok, cmd}
  def max_length(_cmd, _max), do: {:error, :command_too_long}

  @doc """
  Valida que un comando no contenga patrones de inyeccion de shell.

  Verifica vectores de inyeccion comunes: `$(...)`, backticks, y null bytes.
  """
  @spec no_injection(String.t()) :: {:ok, String.t()} | {:error, :possible_injection}
  def no_injection(cmd) do
    injection_patterns = [
      ~r/\$\(/,
      ~r/`[^`]*`/,
      ~r/\x00/
    ]

    injection_found? = Enum.any?(injection_patterns, &Regex.match?(&1, cmd))

    if injection_found? do
      {:error, :possible_injection}
    else
      {:ok, cmd}
    end
  end

  @doc """
  Valida que un comando no coincida con ningun patron peligroso conocido.

  Honours `Config.get(:sudo_allowlist, [])` for granular sudo exemptions.
  When the dangerous match is the `"sudo "` pattern, the part of the
  command after `"sudo "` is checked against the allowlist (list of
  prefixes). If it starts with any allowlisted prefix, the command is
  accepted even though it contains `"sudo "`. Other dangerous patterns
  (`rm -rf`, `dd if=`, etc.) are never overridable.
  """
  @spec safe_command(String.t()) :: {:ok, String.t()} | {:error, {:dangerous_command, String.t()}}
  def safe_command(cmd) do
    cmd_lower = String.downcase(cmd)

    dangerous =
      Enum.find(@dangerous_commands, fn pattern ->
        String.contains?(cmd_lower, pattern) and not sudo_whitelisted?(pattern, cmd_lower)
      end)

    case dangerous do
      nil -> {:ok, cmd}
      found -> {:error, {:dangerous_command, found}}
    end
  end

  # Returns true when the matched dangerous pattern is "sudo " and the
  # part of the command after "sudo " starts with any allowlisted prefix.
  # The check is purely string-based — the allowlist is a list of literal
  # prefixes like ["systemctl start", "systemctl restart"].
  @spec sudo_whitelisted?(String.t(), String.t()) :: boolean()
  defp sudo_whitelisted?("sudo ", cmd_lower) do
    case String.split(cmd_lower, "sudo ", parts: 2) do
      [_, suffix] ->
        allowlist = Config.get(:sudo_allowlist, [])

        Enum.any?(allowlist, fn prefix ->
          String.starts_with?(String.trim(suffix), prefix)
        end)

      _ ->
        false
    end
  end

  defp sudo_whitelisted?(_, _), do: false

  @doc """
  Valida que el shell este en la lista de shells permitidos.
  """
  @spec allowed_shell(String.t()) :: {:ok, String.t()} | {:error, {:disallowed_shell, String.t()}}
  def allowed_shell(shell) do
    shell_name = Path.basename(shell)

    if shell_name in @allowed_shells do
      {:ok, shell}
    else
      {:error, {:disallowed_shell, shell_name}}
    end
  end

  @doc """
  Validates that a timeout value is positive and within reasonable limits.
  """
  @spec valid_timeout(pos_integer()) :: {:ok, pos_integer()} | {:error, :invalid_timeout}
  def valid_timeout(timeout) when is_integer(timeout) and timeout > 0 and timeout <= 3_600_000 do
    {:ok, timeout}
  end

  def valid_timeout(_), do: {:error, :invalid_timeout}

  @doc """
  Validates that a retry count is non-negative and within limits.
  """
  @spec valid_retry_count(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_retry_count}
  def valid_retry_count(count) when is_integer(count) and count >= 0 and count <= 100 do
    {:ok, count}
  end

  def valid_retry_count(_), do: {:error, :invalid_retry_count}

  @doc """
  Validates that a string does not contain dangerous path patterns.
  """
  @spec validate_path(String.t()) ::
          {:ok, String.t()} | {:error, :path_contains_dangerous_pattern}
  def validate_path(path) when is_binary(path) do
    if String.contains?(path, [";", "|", "&", "$("]) do
      {:error, :path_contains_dangerous_pattern}
    else
      {:ok, path}
    end
  end

  @doc """
  Valida el nombre de una variable de entorno.
  """
  @spec validate_env_name(String.t()) :: {:ok, String.t()} | {:error, :invalid_env_name}
  def validate_env_name(name) when is_binary(name) do
    if name =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/ do
      {:ok, name}
    else
      {:error, :invalid_env_name}
    end
  end

  @doc """
  Valida una cadena URL.
  """
  @spec validate_url(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and uri.host do
      {:ok, url}
    else
      {:error, :invalid_url}
    end
  end

  @doc """
  Returns la lista de patrones de comandos peligrosos bloqueados por `safe_command/1`.
  """
  @spec dangerous_commands() :: [String.t()]
  def dangerous_commands, do: @dangerous_commands

  @doc """
  Returns la lista de nombres de shells permitidos.
  """
  @spec allowed_shells() :: [String.t()]
  def allowed_shells, do: @allowed_shells
end
