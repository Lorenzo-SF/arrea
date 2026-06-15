defmodule Arrea.Error do
  @moduledoc """
  Error returned by the `Arrea` engine.

  ## Fields

    - `code` — Atom identifying the error type (e.g. `:engine_failure`, `:process_exited`, `:parallel_failure`)
    - `message` — Human-readable error description
  """

  defstruct [:code, :message]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t()
        }
end
