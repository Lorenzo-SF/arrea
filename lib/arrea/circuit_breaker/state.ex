defmodule Arrea.CircuitBreaker.State do
  @moduledoc false

  @type t :: %__MODULE__{
          state: :closed | :open | :half_open,
          failures: non_neg_integer(),
          successes: non_neg_integer(),
          threshold: pos_integer(),
          timeout: pos_integer(),
          # Timestamp en milisegundos monotónicos (System.monotonic_time(:millisecond)).
          # Nil mientras el circuito está cerrado o nunca ha fallado.
          # Se usa tiempo monotónico para que ajustes de reloj del sistema (NTP, etc.)
          # no afecten al cálculo del timeout de recuperación.
          last_failure_at: integer() | nil
        }

  defstruct state: :closed,
            failures: 0,
            successes: 0,
            threshold: 5,
            timeout: 60_000,
            last_failure_at: nil
end
