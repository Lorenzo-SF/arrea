defmodule Arrea.CLI.Definition do
  @moduledoc """
  CLI command definitions and DSL for Arrea.
  """
  use Alaja.CLI.Definition, otp_app: :arrea

  alias Arrea.CLI.Commands.Action
  alias Arrea.CLI.Commands.Config
  alias Arrea.CLI.Commands.Run
  alias Arrea.CLI.Verify

  @doc false
  def run_handler(%{_args: _args} = opts) do
    if opts[:help] do
      Run.help()
    else
      # Build runtime_opts from asdf/mise flags
      runtime_opts = build_runtime_opts(opts)

      # Validate runtime opts if any were provided
      if runtime_opts != [] do
        Verify.runtime_opts!(runtime_opts)
      end

      # Execute with the extracted runtime opts
      Run.execute_with_opts(opts, runtime_opts)
    end
  end

  @doc false
  def config_handler(%{_args: _args} = opts) do
    if opts[:help] do
      Config.help()
    else
      cond do
        opts[:show] ->
          Config.show_config()

        opts[:action] == "get" and opts[:key] != "" ->
          Config.get_config(opts[:key])

        opts[:action] == "set" and opts[:key] != "" ->
          Config.set_config(opts[:key], opts[:value])

        opts[:action] == "" ->
          Config.help()

        true ->
          # Try to handle as subcommand style: config get KEY or config set KEY VALUE
          handle_config_subcommand(opts)
      end
    end
  end

  @doc false
  def action_handler(%{_args: _args} = opts) do
    if opts[:help] do
      Action.help()
    else
      Action.execute_with_opts(opts)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp build_runtime_opts(opts) do
    # Collect all asdf_* and mise_* flags from opts. The flag atoms are
    # declared at compile time (via `switch :asdf_<lang>` DSL), so they
    # are guaranteed to exist when the CLI runs — `to_existing_atom` is
    # safe here.
    asdf_opts =
      opts
      |> Map.keys()
      |> Enum.filter(&match?({:asdf, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> Enum.map(fn key -> {key, opts[key]} end)

    mise_opts =
      opts
      |> Map.keys()
      |> Enum.filter(&match?({:mise, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> Enum.map(fn key -> {key, opts[key]} end)

    asdf_opts ++ mise_opts
  end

  defp handle_config_subcommand(opts) do
    case opts[:action] do
      "get" ->
        if opts[:key] != "", do: Config.get_config(opts[:key]), else: Config.help()

      "set" ->
        if opts[:key] != "", do: Config.set_config(opts[:key], opts[:value]), else: Config.help()

      _ ->
        Config.help()
    end
  end

  # ── run ─────────────────────────────────────────────────────────────────────

  command "run", "Execute shell commands in parallel with progress tracking" do
    flag(:command, :string, repeatable: true)
    flag(:parallel, :integer, default: 4)
    flag(:timeout, :integer, default: 30_000)
    flag(:quiet, :boolean, short: :q)
    flag(:header, :string, [])
    flag(:header_color, :string, [])
    flag(:subtitle, :string, [])
    flag(:subtitle_color, :string, [])
    flag(:shell, :string, [])
    flag(:help, :boolean, [])

    # Individual asdf tool flags
    flag(:asdf_elixir, :string, [])
    flag(:asdf_node, :string, [])
    flag(:asdf_python, :string, [])
    flag(:asdf_ruby, :string, [])
    flag(:asdf_rust, :string, [])
    flag(:asdf_go, :string, [])

    # Individual mise tool flags
    flag(:mise_node, :string, [])
    flag(:mise_python, :string, [])
    flag(:mise_ruby, :string, [])
    flag(:mise_rust, :string, [])
    flag(:mise_go, :string, [])
    flag(:mise_elixir, :string, [])

    run({Arrea.CLI.Definition, :run_handler})
  end

  # ── config ──────────────────────────────────────────────────────────────────

  command "config", "Manage Arrea engine configuration" do
    flag(:show, :boolean, short: :s)
    flag(:help, :boolean, [])

    # Backward compatibility: positional args
    argument(:action, :string, default: "")
    argument(:key, :string, default: "")
    argument(:value, :string, default: "")

    run({Arrea.CLI.Definition, :config_handler})
  end

  # ── action ──────────────────────────────────────────────────────────────────

  command "action", "Execute Arrea commands from JSON input" do
    flag(:file, :string, short: :f)
    flag(:data, :string, short: :d)
    flag(:stdin, :boolean, short: :s)
    flag(:help, :boolean, [])

    run({Arrea.CLI.Definition, :action_handler})
  end

  command "nodes", "Show registered dynamic workers" do
    run({Arrea.CLI.Commands.Nodes, :execute})
  end
end
