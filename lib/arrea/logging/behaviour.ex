defmodule Arrea.Logging.Behaviour do
  @moduledoc """
  Behaviour contract for custom Arrea Engine loggers.

  Implementing this behaviour allows projects to provide their own
  logger formatter that integrates with Elixir's `:logger` infrastructure
  while maintaining full control over formatting and output style.

  ## Usage

      defmodule MyApp.Logger do
        @behaviour Arrea.Logging.Behaviour

        @impl true
        def log(:info, message, metadata) do
          IO.puts("[INFO] \#{message}")
        end

        @impl true
        def format(level, message, metadata) do
          "\#{DateTime.utc_now()} [\#{level}] \#{message}"
        end
      end

  ## Configuration

      # config/config.exs
      config :arrea, :logger_formatter, MyApp.Logger
  """

  @type level :: :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency
  @type metadata :: keyword()

  @doc """
  Logs a message at the given level.

  Called by the Arrea logging handler for each log event that passes
  the configured level threshold.
  """
  @callback log(level(), String.t(), metadata()) :: :ok

  @doc """
  Formats a log message into a string.

  Used by handlers that need a formatted string rather than direct output.
  The returned string should NOT include a trailing newline.
  """
  @callback format(level(), String.t(), metadata()) :: String.t()

  @doc """
  Returns the minimum log level this logger handles.

  Events below this level will be silently dropped.
  """
  @callback min_level() :: level()

  @optional_callbacks [format: 3, min_level: 0]
end
