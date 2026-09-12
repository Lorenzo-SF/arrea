# arrea — CLI 100% alaja DSL — YA HECHO

> **Fecha**: 2026-09-12
> **Verificación**: arrea ya usa el DSL 100%.

---

## Estado actual

`lib/arrea/cli/definition.ex` (162 LOC) implementa el CLI via `Alaja.CLI.Definition`:

```elixir
defmodule Arrea.CLI.Definition do
  use Alaja.CLI.Definition, otp_app: :arrea

  command "config", "..." do
    flag :show, :boolean, default: false
    flag :action, :atom, default: ""
    flag :key, :string, default: ""
    flag :value, :string, default: ""
    run fn opts -> Arrea.CLI.Commands.Config.run_with_opts(opts) end
  end

  command "action", "..." do ... end
  command "run", "..." do ... end
  command "nodes", "..." do ... end
  ...
end
```

`lib/arrea/cli.ex` (15 LOC) es un thin wrapper:

```elixir
defmodule Arrea.CLI do
  def main(args), do: Arrea.CLI.Definition.main(args)
end
```

**Mandato del usuario cumplido para arrea**.

## Cross-reuse

- arrea consume `Apero.RateLimit` (verificado iter-048).
- arrea provee Command, CircuitBreaker, Worker, Pool a otros.
