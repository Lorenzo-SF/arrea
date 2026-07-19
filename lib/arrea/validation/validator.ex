defmodule Arrea.Validation.Validator do
  @moduledoc """
  Validador de alto nivel para comandos y especificaciones de workers.

  Compone `Arrea.Validation.Rules` para proporcionar puntos de entrada
  de validation usados por `Arrea.Command` y la CLI.
  """

  alias Arrea.Telemetry.Events, as: TE
  alias Arrea.Validation.Rules

  @type validation_error :: atom() | {atom(), term()}

  @doc """
  Valida una cadena de comando shell.

  Executes todas las security checks estandar en secuencia.

  ## Returns

  - `{:ok, command}` si el comando pasa todas las verificaciones
  - `{:error, reason}` en la primera verificacion que falle

  ## Examples

      iex> Validator.validate_command("echo hello")
      {:ok, "echo hello"}

      iex> Validator.validate_command("rm -rf /")
      {:error, {:dangerous_command, "rm -rf"}}
  """
  @spec validate_command(String.t()) :: {:ok, String.t()} | {:error, validation_error()}
  def validate_command(cmd) do
    result =
      with {:ok, cmd} <- Rules.not_empty(cmd),
           {:ok, cmd} <- Rules.max_length(cmd, 4096),
           {:ok, cmd} <- Rules.no_injection(cmd),
           do: Rules.safe_command(cmd)

    case result do
      {:ok, _} -> TE.emit_validation(:passed, %{}, %{command: cmd})
      {:error, reason} -> TE.emit_validation(:failed, %{}, %{command: cmd, reason: reason})
    end

    result
  end

  @doc """
  Valida una lista de comandos, retornando todos los resultados.

  Returns `{:ok, commands}` solo si TODOS los comandos pasan la validation.
  Returns `{:error, errors}` con una lista de tuplas `{indice, razon}` para los fallos.
  """
  @spec validate_commands([String.t()]) ::
          {:ok, [String.t()]} | {:error, [{non_neg_integer(), validation_error()}]}
  def validate_commands(commands) when is_list(commands) do
    results =
      commands
      |> Enum.with_index()
      |> Enum.map(fn {cmd, idx} ->
        case validate_command(cmd) do
          {:ok, _} -> nil
          {:error, reason} -> {idx, reason}
        end
      end)
      |> Enum.reject(&is_nil/1)

    case results do
      [] -> {:ok, commands}
      errors -> {:error, errors}
    end
  end

  @doc """
  Valida una especificacion de worker como keyword list.

  Verifica que los campos requeridos esten presentes y tengan tipos validos.
  """
  @spec validate_worker_spec(keyword()) ::
          {:ok, keyword()} | {:error, validation_error()}
  def validate_worker_spec(spec) do
    with {:ok, _} <- validate_tasks(Keyword.get(spec, :tasks, [])),
         {:ok, _} <- validate_timeout_opt(Keyword.get(spec, :timeout)),
         {:ok, _} <- validate_retry_opt(Keyword.get(spec, :max_retries)) do
      {:ok, spec}
    end
  end

  @doc """
  Valida un nombre de shell contra la lista permitida.
  """
  @spec validate_shell(String.t()) :: {:ok, String.t()} | {:error, validation_error()}
  def validate_shell(shell), do: Rules.allowed_shell(shell)

  @spec validate_tasks(term()) :: {:ok, [function()]} | {:error, :invalid_tasks}
  defp validate_tasks(tasks) when is_list(tasks) do
    all_valid = Enum.all?(tasks, &is_function(&1, 0))
    if all_valid, do: {:ok, tasks}, else: {:error, :invalid_tasks}
  end

  defp validate_tasks(_), do: {:error, :invalid_tasks}

  @spec validate_timeout_opt(term()) :: {:ok, pos_integer() | nil} | {:error, :invalid_timeout}
  defp validate_timeout_opt(nil), do: {:ok, nil}
  defp validate_timeout_opt(timeout), do: Rules.valid_timeout(timeout)

  @spec validate_retry_opt(term()) ::
          {:ok, non_neg_integer() | nil} | {:error, :invalid_retry_count}
  defp validate_retry_opt(nil), do: {:ok, nil}
  defp validate_retry_opt(count), do: Rules.valid_retry_count(count)
end
