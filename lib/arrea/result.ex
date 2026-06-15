defmodule Arrea.Result do
  @moduledoc """
  Result of an `Arrea` engine operation.

  ## Fields

    - `success` — `true` if the operation was successful, `false` otherwise
    - `data` — The value returned by the operation (can be any term)
    - `failures` — List of individual failures in parallel executions
  """

  defstruct [:success, :data, :failures]

  @type t :: %__MODULE__{
          success: boolean(),
          data: any(),
          failures: list()
        }
end
