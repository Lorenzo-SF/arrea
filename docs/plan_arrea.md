# Plan for `@arrea` (Asynchronous Orchestrator & Telemetry)

> **Goal** – Expose a clear API for retrieving the current registry mapping and add a CLI‑style `arrea nodes` output. Simplify the supervisor tree representation and strengthen test coverage.

---

## 1. Preparation

| Step | Action | Outcome |
|------|--------|---------|
| 1.1 | Confirm branch `fix-tools-domains` is clean |
| 1.2 | Ensure the working tree is clean (commit any in‑progress changes before starting) |
| 1.3 | `mix deps.get` for local overrides (apero, etc.) |
| 1.4 | Verify `mix.exs` has `path:` overrides when needed |
| 1.5 | Commit any pending changes in this repo before starting modifications |

## 2. Implementation

| Target | Task |
|--------|------|
| **Registry Helper** | Add `Arrea.Registry.all/0` returning `:%{worker_name => pid}` for dynamic workers. |
| **CLI Alias** | Add new mix task `arrea nodes` that formats and prints the registry listing. |
| **Supervisor** | Adjust the `Arrea.Supervisor` docstring, clarify `:rest_for_one` usage and add a small example in comments.

## 3. Tests

| Test File | Coverage Goal | Key Assertions |
|-----------|---------------|----------------|
| `test/arrea/shadow_test.exs` | 100 % on registry helper | • List contains at least one worker
| | | • `nodes` CLI task prints expected format

Run the full suite with `mix test --cover`.

## 4. Documentation

* Update README to include the new `arrea nodes` command and show example output.
* Add an entry in CHANGELOG: ``Fixed worker export and added CLI nodes``.
* Keep documentation of telemetry within `docs/` unchanged.

## 5. Quality

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict --format=json
mix test --cover
mix dialyzer
```

## 6. Commit & Push

```bash
git add -A
git commit -m "Add registry helper and nodes command to arrea"
git push origin fix-tools-domains
```

---

**End of plan for `@arrea`**