defmodule Arrea.Application do
  alias Arrea.Telemetry.Metrics

  @moduledoc """
  OTP Application callback for `Arrea`.

  Starts the `Arrea.Supervisor` supervision tree when the application boots.
  This is invoked automatically by the OTP application system when Arrea is
  included as a dependency — no manual `start_link` call is needed.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Metrics.setup()
    Arrea.Supervisor.start_link([])
  end
end
