defmodule Arrea.CLI.Verify do
  @moduledoc false

  @doc """
  Verifies that all runtime versions requested via runtime_opts exist in
  their respective tool managers (asdf or mise).

  Returns `:ok` on success, or `{:error, reason}` on failure. The caller
  (CLI handler) is responsible for printing the error and exiting.
  """
  @spec runtime_opts(map() | keyword()) :: :ok | {:error, term()}
  def runtime_opts(runtime_opts) do
    Enum.reduce_while(runtime_opts, :ok, fn {key, version}, acc ->
      key_str = to_string(key)

      cond do
        String.starts_with?(key_str, "asdf_") ->
          runtime = String.replace_prefix(key_str, "asdf_", "")
          tool = find_asdf()
          verify_asdf_version(tool, runtime, version)

        String.starts_with?(key_str, "mise_") ->
          runtime = String.replace_prefix(key_str, "mise_", "")
          verify_mise_version(runtime, version)

        true ->
          {:cont, acc}
      end
    end)
  end

  # Backwards-compatible bang variant that still halts on error.
  @doc false
  @spec runtime_opts!(map() | keyword()) :: :ok | no_return()
  def runtime_opts!(runtime_opts) do
    case runtime_opts(runtime_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  defp format_error({:asdf_not_found}),
    do: "asdf is not installed. Install asdf or use --mise-* flags."

  defp format_error({:asdf_plugin_missing, plugin}),
    do: "asdf plugin #{plugin} not installed. Run: asdf plugin add #{plugin}"

  defp format_error({:asdf_version_missing, plugin, version}),
    do: "asdf version #{version} not found for #{plugin}"

  defp format_error({:mise_not_found}),
    do: "mise is not installed. Install mise or use --asdf-* flags."

  defp format_error({:mise_plugin_missing, plugin}),
    do: "mise plugin #{plugin} not installed. Run: mise plugins install #{plugin}"

  defp format_error({:mise_version_missing, plugin, version}),
    do: "mise version #{version} not found for #{plugin}"

  defp format_error(reason), do: inspect(reason)

  defp find_asdf do
    case System.find_executable("asdf") do
      nil ->
        case System.find_executable("mise") do
          nil -> nil
          _ -> :mise
        end

      _ ->
        :asdf
    end
  end

  defp verify_asdf_version(:asdf, runtime, version) do
    case System.cmd("asdf", ["plugin", "list"], stderr_to_stdout: true) do
      {output, 0} ->
        plugins = output |> String.split("\n") |> Enum.map(&String.trim/1)

        if runtime in plugins do
          {:cont, verify_asdf_version(runtime, version)}
        else
          {:halt, {:error, {:asdf_plugin_missing, runtime}}}
        end

      {_output, _} ->
        {:halt, {:error, :asdf_not_found}}
    end
  rescue
    _ -> {:halt, {:error, :asdf_not_found}}
  end

  defp verify_asdf_version(:mise, runtime, version) do
    {:cont, verify_mise_version(runtime, version)}
  end

  defp verify_asdf_version(nil, runtime, _version) do
    {:halt, {:error, {:asdf_not_found, runtime}}}
  end

  defp verify_asdf_version(runtime, version) do
    case System.cmd("asdf", ["list", runtime], stderr_to_stdout: true) do
      {output, 0} ->
        versions = output |> String.split("\n") |> Enum.map(&String.trim/1)

        if version in versions do
          {:cont, :ok}
        else
          {:halt, {:error, {:asdf_version_missing, runtime, version}}}
        end

      {_output, _} ->
        {:halt, {:error, {:asdf_not_found, runtime}}}
    end
  end

  defp verify_mise_version(runtime, version) do
    if System.find_executable("mise") == nil do
      {:halt, {:error, :mise_not_found}}
    else
      case System.cmd("mise", ["ls", runtime, "--json"], stderr_to_stdout: true) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, versions} ->
              versions_list = Enum.map(versions, fn %{"version" => v} -> v end)

              if version in versions_list do
                {:cont, :ok}
              else
                {:halt, {:error, {:mise_version_missing, runtime, version}}}
              end

            {:error, _} ->
              {:halt, {:error, :mise_not_found}}
          end

        {_output, _exit_code} ->
          {:halt, {:error, {:mise_plugin_missing, runtime}}}
      end
    end
  end

  defp list_mise_versions(runtime) do
    case System.cmd("mise", ["ls", runtime, "--json"], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, versions} -> Enum.map(versions, fn %{"version" => v} -> v end)
          {:error, _} -> []
        end

      _ ->
        []
    end
  end

  @doc false
  def __list_mise_versions__(runtime), do: list_mise_versions(runtime)
end
