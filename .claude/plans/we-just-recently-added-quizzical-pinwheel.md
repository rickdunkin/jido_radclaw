# Resolve byte-identical Credo "software design" duplicates

## Context

We added Credo with the `ExDNA.Credo` check, which flags duplicate code at the AST level (Type-I exact clones, `min_mass: 30`, `literal_mode: :keep`, variable names normalized). 53 design issues remain after the refactor sweep.

Verification of each pair (MD5 of extracted blocks, side-by-side diffs) splits them into:

- **Byte-identical, safe to extract**: 36 issues across 13 patterns. Refactor.
- **Near-duplicates with intentional differences**: 17 issues across 7 patterns. Mark with `@no_clone true` (which ExDNA's annotator strips from fingerprinting) — except for two cases (`registry.ex`, `hybrid_search_sql.ex`) where extracting the shared epilogue is cleaner than marking.

Two gotchas had to be handled before this plan would compile cleanly:

1. **Raw `@no_clone true` triggers `module attribute @no_clone was set but never used`** under `--warnings-as-errors`. Fix: a tiny `use JidoClaw.NoClone` helper registers the attribute. Verified with `elixir -e`.
2. **ExDNA's annotator only strips `def`/`defp` that follow `@no_clone true`, not `defmodule`** (`deps/ex_dna/lib/ex_dna/ast/annotator.ex:31`). So for the `Changes.*` cases, mark the inner `def change/3` rather than the surrounding `defmodule` — the module body's other lines (`@moduledoc false` + `use Ash.Resource.Change`) are well below `min_mass: 30` once the `def` is stripped.

---

## Part A — Extract byte-identical duplicates

### A1. Ash resource policies block (mass 36 × 13 files = 24 issues)

All 13 flagged resources share an MD5-identical 13-line `policies do ... end` block.

**Create `lib/jido_claw/resource.ex`** with a `__using__` macro:

```elixir
defmodule JidoClaw.Resource do
  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    primary_read_warning? = Keyword.get(opts, :primary_read_warning?, true)

    quote do
      use Ash.Resource,
        otp_app: :jido_claw,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        primary_read_warning?: unquote(primary_read_warning?)

      policies do
        bypass action(:by_id_global) do
          authorize_if(always())
        end

        policy action_type([:create, :update, :destroy]) do
          authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
        end

        policy action_type(:read) do
          authorize_if(expr(tenant_id == ^actor(:tenant_id)))
        end
      end
    end
  end
end
```

**Per-file invocation** (`primary_read_warning?: false` confirmed on 8 of 13 files via grep):

| File | `primary_read_warning?` |
|---|---|
| `memory/resources/{fact,block,block_revision,consolidation_run,episode,fact_episode,link}.ex` | `false` |
| `solutions/resources/solution.ex` | `false` |
| `conversations/resources/{message,session}.ex`, `cron/resources/job.ex`, `solutions/resources/reputation.ex`, `workspaces/resources/workspace.ex` | default (`true`) |

**Spark/Ash integration** — Without these two settings, `mix format` and `ash` tooling won't recognize the wrapper as an Ash resource. Both go in `config/config.exs` (`.formatter.exs` already has `Spark.Formatter` and doesn't need to change):

```elixir
config :jido_claw, base_resources: [JidoClaw.Resource]

config :spark, :formatter,
  "JidoClaw.Resource": [
    type: Ash.Resource,
    extensions: [AshPostgres.DataLayer, Ash.Policy.Authorizer]
  ]
```

The `extensions` list matters because the wrapper hides `data_layer` and `authorizers` from the source `use` call, but files still contain `postgres do` blocks that Spark needs to format correctly.

**Replace in 13 files**: swap the `use Ash.Resource, ...` opts + the policies block for `use JidoClaw.Resource, domain: ...`. The `postgres do`, `multitenancy do`, attribute/action blocks stay untouched.

Out of scope: `global_lookup.ex` (no policies), `request_correlation.ex` (different policy), `reputation_import.ex` (missing `:by_id_global` bypass) — keep as-is.

### A2. Memory change modules (4 issues)

**`Changes.ValidateScopeFk`** (`fact.ex:590` ↔ `consolidation_run.ex:299`, mass 67) — byte-identical, but **`consolidation_run.ex` calls `Fact.scope_fk_for/2` against a ConsolidationRun changeset** (works incidentally because both resources share the `*_id` attribute names). Naive `change({Shared, resource: __MODULE__})` would break: `ConsolidationRun.scope_fk_for/2` does not exist.

**Fix**: make the shared change resolve scope→FK from the changeset's attributes directly (no resource module reference):

```elixir
defmodule JidoClaw.Memory.Changes.ValidateScopeFk do
  use Ash.Resource.Change

  @scope_attrs %{user: :user_id, workspace: :workspace_id,
                 project: :project_id, session: :session_id}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      scope_kind = Ash.Changeset.get_attribute(cs, :scope_kind)

      case Map.get(@scope_attrs, scope_kind) do
        nil ->
          add_missing(cs, scope_kind)

        attr ->
          case Ash.Changeset.get_attribute(cs, attr) do
            nil -> add_missing(cs, scope_kind)
            _id -> cs
          end
      end
    end)
  end

  defp add_missing(cs, scope_kind),
    do: Ash.Changeset.add_error(cs, field: :scope_kind,
                                message: "scope_fk_required",
                                vars: [scope_kind: scope_kind])
end
```

- **Create `lib/jido_claw/memory/changes/validate_scope_fk.ex`** as above.
- Update `fact.ex` and `consolidation_run.ex` to `change(JidoClaw.Memory.Changes.ValidateScopeFk)`; remove both inline `Changes.ValidateScopeFk` defmodules.
- Existing per-resource `scope_fk_for/2` helpers stay (they're used by *other* code paths) — only the inline change module gets removed.

**`Changes.MarkInvalidated`** (`fact.ex:807` ↔ `block.ex:422`, mass 43) — byte-identical, fully generic.

- **Create `lib/jido_claw/memory/changes/mark_invalidated.ex`** — no opts needed.
- Update both resources' inline references.

### A3. Memory scope/uuid helper (1 issue)

**`uuid_dump/1`** (`fact.ex:956` ↔ `hybrid_search_sql.ex:247`, mass 31) — byte-identical 3-clause `defp`.

- **Create `lib/jido_claw/memory/scope_fk.ex`** with `uuid_dump/1` as public.
- Update `fact.ex` and `hybrid_search_sql.ex` to call `JidoClaw.Memory.ScopeFk.uuid_dump/1`; remove both `defp uuid_dump` definitions.

### A4. CLI utilities (5 issues) — split by responsibility

The user pushed back on dumping everything into `Formatter` (terminal probing isn't formatting). Split:

- **`truncate_value/1`** (mass 51) — `display.ex:787` ↔ `formatter.ex:85`. Lives in `JidoClaw.CLI.Formatter` already, but **as `defp`** in both files. Promote the Formatter version to `def truncate_value/1` (public); delete from `display.ex`; update display.ex's call site.

- **`format_elapsed/1`** (mass 62) — `repl.ex:569` ↔ `commands.ex:915`. Add as `def format_elapsed/1` in `JidoClaw.CLI.Formatter`. Update both call sites; remove both private definitions.

- **`terminal_cols/0` / `detect_terminal_width/0`** (mass 45) — `branding.ex:315` ↔ `display.ex:797`. **Create `lib/jido_claw/cli/terminal.ex`** with `terminal_cols/0`. Update both call sites. Note: `commands.ex:922` has a shorter no-tput variant; leave it (different behavior, not flagged).

- **`detect_project_type/1` / `detect_type/1`** (mass 36) — `project_info.ex:41` ↔ `branding.ex:346`. Body byte-identical (Credo normalizes `cwd` vs `dir`). **Create `lib/jido_claw/project_type.ex`** with `detect/1`. Update both call sites.

### A5. Shell type_hint (1 issue, largest single duplicate at mass 103)

**`type_hint/1`** — `shell/server_registry.ex:529` ↔ `shell/profile_manager.ex:586`. 10 identical clauses.

- **Create `lib/jido_claw/shell/util.ex`** with `type_hint/1` as public.
- Carry the security comment from `profile_manager.ex:582-585` into the new module — it documents intent.
- Update both call sites; remove both inline `defp type_hint` blocks.

### A6. Reasoning helper (1 issue)

**`fetch_name/1`** (mass 48) — `strategy_store.ex:236` ↔ `pipeline_store.ex:200`. Byte-identical name-validation helper.

- **Create `lib/jido_claw/reasoning/yaml_store.ex`** as a shared utility module.
- Update both stores; remove both inline `defp fetch_name` blocks.

### A7. Tool helpers (5 issues)

**`extract_output/1`** (3-way, mass 67) — `tools/reason.ex:206`, `tools/run_pipeline.ex:565`, `tools/verify_certificate.ex:208`. Verified byte-identical.

- **Create `lib/jido_claw/reasoning/output.ex`** with `extract_output/1` as public.
- Update all three call sites; remove all three inline blocks.

**`extract_result/1`** (mass 59) — `tools/get_agent_result.ex:53` ↔ `workflows/step_action.ex:189`. Byte-identical.

- Add to `lib/jido_claw/reasoning/output.ex` (companion to `extract_output/1`).
- Update both call sites.

**`register_child_correlation/1`** (3-way, mass 43) — `workflows/step_action.ex:195`, `tools/spawn_agent.ex:89`, `tools/send_to_agent.ex:73`. All three MD5-identical. Already wraps `JidoClaw.register_correlation/5`.

- **Add `register_child_correlation/1` to the top-level `JidoClaw` module** (`lib/jido_claw.ex`). Annotate with `@doc false` — it's shared internal plumbing for these three call sites, not intended as public API.
- Update all three call sites; remove all three private definitions.

---

## Part B — Within-file extractions (replaces blanket `@no_clone` for two cases)

User pushed back: extracting is clearer than suppression when the shared region is a clean unit.

### B1. `registry.ex` shared "mark killed" epilogue (mass 33, same file)

`handle_info({:force_kill, ...})` at line 160 and `handle_info({:force_kill_pid, ...})` at line 173 have different kill mechanisms (Port `kill -9` vs `Process.exit`) but share a 4-line trailing `case Map.get(state.processes, id)` epilogue.

- **Extract `defp mark_killed(state, id)` returning the updated state.** Idiomatic GenServer style keeps the `{:noreply, ...}` tuple in the callback:

  ```elixir
  def handle_info({:force_kill, id, port}, state) do
    # ... port-specific kill ...
    {:noreply, mark_killed(state, id)}
  end

  def handle_info({:force_kill_pid, id, pid}, state) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    {:noreply, mark_killed(state, id)}
  end

  defp mark_killed(state, id) do
    # the shared 4-line epilogue, returns updated state
  end
  ```

### B2. `hybrid_search_sql.ex` shared fact-loader (mass 31, same file)

`load_facts_by_ids/2` at line 229 (standalone, order-preserving) and the inline loader at line ~800 (within a case branch, attaches shadow metadata) both build the same `Fact |> Ash.Query.for_read(...) |> filter(...) |> read!() |> Map.new(...)` query.

- **Extract `defp load_fact_map(ids, tenant_id)`** that returns the `%{id => fact}` map. Include an empty-IDs short-circuit clause to preserve the existing no-query behavior:

  ```elixir
  defp load_fact_map([], _tenant_id), do: %{}

  defp load_fact_map(ids, tenant_id) do
    require Ash.Query

    Fact
    |> Ash.Query.for_read(:read, %{}, actor: Actor.system(tenant_id), tenant: tenant_id)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!()
    |> Map.new(fn f -> {f.id, f} end)
  end
  ```

  Both call sites then apply their own post-processing (`Enum.flat_map` for order, shadow-attach for the search path).

---

## Part C — Mark intentional near-duplicates with `@no_clone true`

### C0. Helper to suppress the unused-attribute warning

`@no_clone true` plain triggers `warning: module attribute @no_clone was set but never used` (verified). Under `--warnings-as-errors` this would fail CI before Credo even runs.

**Create `lib/jido_claw/no_clone.ex`**:

```elixir
defmodule JidoClaw.NoClone do
  @moduledoc """
  Mixin that suppresses the "@no_clone was set but never used" warning for
  modules that use the ExDNA `@no_clone true` annotation to opt out of
  duplicate detection. Place `use JidoClaw.NoClone` inside the module
  that owns the annotated function, then write the annotations as:

      @impl true
      @no_clone true
      def change(...)

  Order matters: `@no_clone true` must be the LAST attribute before the
  `def`/`defp` so ExDNA's annotator pattern-matches the immediately-next
  node. `@impl true` (if present) goes above it.

  Scope: `use JidoClaw.NoClone` only registers the attribute in the
  module it's invoked in — NOT in nested defmodules. For Ash change
  modules nested inside a resource (e.g. `Fact.Changes.ValidateCrossTenant`),
  add `use JidoClaw.NoClone` inside the nested defmodule, not the parent.

  ExDNA's annotator (deps/ex_dna/lib/ex_dna/ast/annotator.ex) strips both
  the attribute and the following def/defp from the AST before hashing.
  """
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :no_clone, accumulate: true, persist: false)
    end
  end
end
```

`accumulate: true` suppresses the unused-attribute warning. ExDNA's annotator pattern-matches on the AST node `{:@, _, [{:no_clone, _, [true]}]}` — that shape is independent of the accumulate setting (the AST is what's written in the source, before macro expansion).

**Annotation pattern** — for every case in C1–C5, the annotation block looks like:

```elixir
@impl true        # only if the original had it
@no_clone true
def change(...)   # or defp, depending on the original
```

`@no_clone true` must be the LAST attribute before the def. `use JidoClaw.NoClone` must appear inside whichever module body contains the annotated def — for nested change modules, that's the nested defmodule itself, NOT the surrounding resource.

### C1. `ValidateCrossTenant` (fact.ex:616, block.ex:376, mass 58)

Bodies match but `fact.ex` carries a load-bearing comment (`# User and Project lack tenant_id columns — see plan §0.5.2.`), and the broader codebase has inconsistently-named variants (`ValidateCrossTenantFk` in `consolidation_run.ex:325`, `solution.ex`, `message.ex`, `request_correlation.ex`) with different FK lists. Unifying is a real design task, out of scope for the byte-identical sweep.

- Inside each `defmodule Changes.ValidateCrossTenant do` (in `fact.ex` and `block.ex`), add `use JidoClaw.NoClone` and mark the inner `def change(changeset, _opts, _context) do`.

### C2. `ResolveInitialEmbeddingStatus.change/3` (fact.ex:669, solution.ex:569, mass 46)

`change/3` body byte-identical, but `resolve_status_from_policy(cs, nil, _actor)` diverges: fact forces `:disabled`, solution returns `cs` unchanged. Fact's moduledoc literally says "Mirror of Solutions.Solution.Changes.ResolveInitialEmbeddingStatus".

- Inside each `defmodule Changes.ResolveInitialEmbeddingStatus do`, add `use JidoClaw.NoClone` and mark the inner `def change(changeset, _opts, context) do`.

### C3. `resolve_scope/1` (signal_listener.ex:128, recorder.ex:751, mass 48)

`recorder.ex` has an extra leading `defp resolve_scope(nil), do: :error` clause and logs a warning in the `rescue` block; `signal_listener.ex` swallows silently.

- Add `use JidoClaw.NoClone` to each top-level module (`JidoClaw.Audit.SignalListener`, `JidoClaw.Conversations.Recorder`).
- Mark `defp resolve_scope(request_id)` at `signal_listener.ex:128` and `recorder.ex:751`. The leading `resolve_scope(nil)` one-liner clause in recorder.ex is not flagged and needs no annotation.

### C4. `load_from_disk/1` (strategy_store.ex:177, pipeline_store.ex:133, mass 38)

Different parse function names (`parse_strategy_file` vs `parse_pipeline_file`), different `Logger` tags (`[StrategyStore]` vs `[PipelineStore]`). Could be unified with a small behaviour, but that's a design change, not a byte-identical extraction.

- Add `use JidoClaw.NoClone` to both `StrategyStore` and `PipelineStore`.
- Mark `defp load_from_disk(project_dir) do` in both.

### C5. `sync_file/3` (codex.ex:309, claude_code.ex:180, mass 38)

Bodies match but `Logger.debug` tags differ (`[Codex]` vs `[ClaudeCode]`) and code comments differ.

- Add `use JidoClaw.NoClone` to both runner modules.
- Mark `defp sync_file(client, source, dest) do` in both.

---

## Files to create

- `lib/jido_claw/resource.ex` (A1)
- `lib/jido_claw/memory/changes/validate_scope_fk.ex` (A2)
- `lib/jido_claw/memory/changes/mark_invalidated.ex` (A2)
- `lib/jido_claw/memory/scope_fk.ex` (A3)
- `lib/jido_claw/cli/terminal.ex` (A4)
- `lib/jido_claw/project_type.ex` (A4)
- `lib/jido_claw/shell/util.ex` (A5)
- `lib/jido_claw/reasoning/yaml_store.ex` (A6)
- `lib/jido_claw/reasoning/output.ex` (A7)
- `lib/jido_claw/no_clone.ex` (C0)

## Files to modify

A1 (13 files): `lib/jido_claw/conversations/resources/{message,session}.ex`, `lib/jido_claw/cron/resources/job.ex`, `lib/jido_claw/memory/resources/{block,block_revision,consolidation_run,episode,fact,fact_episode,link}.ex`, `lib/jido_claw/solutions/resources/{reputation,solution}.ex`, `lib/jido_claw/workspaces/resources/workspace.ex`

A2: `lib/jido_claw/memory/resources/{fact,block,consolidation_run}.ex`

A3: `lib/jido_claw/memory/resources/fact.ex`, `lib/jido_claw/memory/hybrid_search_sql.ex`

A4: `lib/jido_claw/cli/{formatter,branding,repl,commands}.ex`, `lib/jido_claw/display.ex`, `lib/jido_claw/tools/project_info.ex`

A5–A7: `lib/jido_claw/shell/{server_registry,profile_manager}.ex`, `lib/jido_claw/reasoning/{strategy_store,pipeline_store}.ex`, `lib/jido_claw/tools/{reason,run_pipeline,verify_certificate,get_agent_result,spawn_agent,send_to_agent}.ex`, `lib/jido_claw/workflows/step_action.ex`, `lib/jido_claw.ex`

B1–B2: `lib/jido_claw/platform/background_process/registry.ex`, `lib/jido_claw/memory/hybrid_search_sql.ex`

C: `lib/jido_claw/memory/resources/{fact,block}.ex`, `lib/jido_claw/solutions/resources/solution.ex`, `lib/jido_claw/audit/signal_listener.ex`, `lib/jido_claw/conversations/recorder.ex`, `lib/jido_claw/reasoning/{strategy_store,pipeline_store}.ex`, `lib/jido_claw/forge/runners/{codex,claude_code}.ex`

Config: `config/config.exs` (A1: `base_resources` + Spark formatter entry)

## Suggested commit slicing (no commits without explicit request)

1. `JidoClaw.Resource` macro + Spark/Ash config + 13 resource conversions (A1) — biggest blast radius, test in isolation
2. Memory change modules + scope helper (A2, A3)
3. CLI utilities + Terminal + ProjectType (A4)
4. Shell + reasoning + tool helpers (A5, A6, A7)
5. Within-file extractions (B1, B2)
6. `JidoClaw.NoClone` helper + `@no_clone` annotations (C0–C5)

## Verification

After each slice:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --format json | jq '[.issues[] | select(.category == "design")] | length'
```

End-state target: design-issue count drops from **53 → 0**. The C-marked functions still exist with their original behavior; ExDNA stops fingerprinting them.

Slice-specific sanity checks:

- **After A1**: `mix jidoclaw` — boot the REPL to confirm all 13 resources still compile and the macro emits valid Ash DSL.
- **After A2**: trigger a Fact create with missing scope FK via Tidewave's `project_eval` — expect the same `scope_fk_required` error.
- **After A7**: spawn a sub-agent and verify a `request_correlation` row gets created with the parent's scope.
- **After C0–C5**: `mix compile --warnings-as-errors` must still pass (proves the `@no_clone` helper suppresses the unused-attribute warning).
