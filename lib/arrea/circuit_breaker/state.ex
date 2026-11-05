defmodule Arrea.CircuitBreaker.State do
  @moduledoc false

  @type t :: %__MODULE__{
          name: atom(),
          state: :closed | :open | :half_open,
          failures: non_neg_integer(),
          successes: non_neg_integer(),
          threshold: pos_integer(),
          timeout: pos_integer(),
          # Timestamp in monotonic milliseconds (System.monotonic_time(:millisecond)).
          # Nil while the circuit is closed or it has never failed.
          # Monotonic time is used so that system clock adjustments (NTP, etc.)
          # do not affect the recovery timeout calculation.
          last_failure_at: integer() | nil,
          # True while a single-flight probe is running in :half_open.
          # Guards against the retry storm where every caller probes at once.
          probe_in_progress: boolean()
        }

  defstruct name: nil,
            state: :closed,
            failures: 0,
            successes: 0,
            threshold: 5,
            timeout: 60_000,
            last_failure_at: nil,
            probe_in_progress: false
end
