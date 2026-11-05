defmodule Arrea.Telemetry.CommunicationMetrics do
  @moduledoc """
  Metrics for inter-worker communication events.

  Defines the metrics emitted when workers send messages to each other
  via the leader/monitor pipeline. Pair this with a reporter such as
  `Telemetry.Metrics.ConsoleReporter` or a Prometheus exporter.

  Currently this module is documentation-only. Hook it up by adding
  `Arrea.Telemetry.CommunicationMetrics` to your `Telemetry.Metrics.ConsoleReporter`
  or `TelemetryMetricsPrometheus` configuration.
  """

  def metrics do
    [
      %{
        name: "arrea.communication.message.sent",
        type: :counter,
        description: "Total de mensajes enviados entre workers",
        tags: [:from, :to]
      },
      %{
        name: "arrea.communication.message.received",
        type: :counter,
        description: "Total de mensajes recibidos por workers",
        tags: [:worker_id]
      },
      %{
        name: "arrea.communication.message.latency",
        type: :distribution,
        description: "Latencia de entrega de mensajes (ms)",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 10, 50, 100, 500, 1000, 5000]]
      }
    ]
  end
end
