defmodule Arrea.Validation.JsonSchema do
  @moduledoc """
  Validator for Arrea JSON actions.

  Defines the expected structure for commands executed via `arrea action`.
  """

  @doc """
  Validates the structure of a JSON action map.

  Expected format:
  %{
    "command" => "show",
    "args" => ["success", "Hello"]
  }
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(map) when is_map(map) do
    command = Map.get(map, "command") || Map.get(map, "action")
    args = Map.get(map, "args") || Map.get(map, "params")

    cond do
      is_nil(command) ->
        {:error, "Missing 'command' or 'action' field"}

      not is_binary(command) ->
        {:error, "'command' must be a string"}

      true ->
        validate_args(args)
    end
  end

  def validate(_), do: {:error, "JSON must be an object"}

  defp validate_args(nil), do: :ok

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      :ok
    else
      {:error, "All elements in 'args' must be strings"}
    end
  end

  defp validate_args(_args), do: {:error, "'args' must be a list of strings"}
end
