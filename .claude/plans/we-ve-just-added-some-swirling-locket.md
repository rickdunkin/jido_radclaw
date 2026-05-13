# Resolve ExSlop credo findings

## Context

`.credo.exs` recently grew 12 new ExSlop checks (see `git diff HEAD .credo.exs`).
Running `mix credo --format json | jq` surfaces **70 issues** across six of those
checks — none of the new rules without findings need work. The goal is to
drive `mix credo` back to zero for the project without changing valid-input
behavior. (Batch 4 tightens `read_file`'s negative-pagination handling — a
deliberate boundary change, gated by new tests.) Past credo cleanup was
committed in small "Tier" commits, so we'll follow the same pattern (5
focused commits).

Distribution of the 70 findings:

| Check | Count |
|---|---|
| `ExSlop.Check.Readability.UnaliasedModuleUse` | 44 |
| `ExSlop.Check.Refactor.UseMapJoin` | 14 |
| `ExSlop.Check.Refactor.ListLast` | 6 |
| `ExSlop.Check.Refactor.PreferEnumSlice` | 3 |
| `ExSlop.Check.Refactor.LengthInGuard` | 2 |
| `ExSlop.Check.Refactor.FlatMapFilter` | 1 |

---

## Batch 1 — `alias Ash.Changeset` / `alias Ash.Query` in resource files (~28 findings)

Add a single parent-level `alias Ash.Changeset` (and `alias Ash.Query` where
needed) at the top of each resource module. Elixir's lexical alias scope
propagates into inline nested `defmodule Changes.*` / `Preparations.*`
modules defined *after* the alias — this repo already relies on that pattern
(e.g. `MemoryRedaction` is aliased at
`lib/jido_claw/memory/resources/fact.ex:77` and used inside
`Changes.RedactContent` at line 604). One alias per file is less noisy than
per-submodule aliases and matches the existing style.

The `ExSlop.Check.Readability.UnaliasedModuleUse` check is file-aware, so a
single parent alias plus rewriting every `Ash.Changeset.foo` /
`Ash.Query.foo` reference in the file (not just the 3+ uses in the flagged
function) is the correct fix. See verification note below — a file where the
alias is added but only some call sites are rewritten will silently stop
reporting even though it's half-done.

Files:

- `lib/jido_claw/memory/resources/fact.ex` (5 sites — submodules
  `Changes.RedactContent`, `Changes.ResolveInitialEmbeddingStatus`,
  `Changes.InvalidatePriorActiveLabel`, `Changes.MarkPromoted`,
  `Preparations.ForConsolidator`)
- `lib/jido_claw/memory/resources/block.ex` (4 sites — `Changes.CapValueLength`,
  `Changes.WriteRevisionForUpdate`, `Preparations.ApplyScopeChain`,
  `Preparations.HistoryForLabel`)
- `lib/jido_claw/memory/resources/episode.ex` (2 sites)
- `lib/jido_claw/memory/resources/fact_episode.ex` (1 site)
- `lib/jido_claw/memory/resources/link.ex` (2 sites)
- `lib/jido_claw/memory/resources/consolidation_run.ex` (2 sites)
- `lib/jido_claw/memory/changes/mark_invalidated.ex` (top-level — no submodule)
- `lib/jido_claw/memory/changes/validate_scope_fk.ex` (top-level)
- `lib/jido_claw/solutions/resources/solution.ex` (5 sites)
- `lib/jido_claw/conversations/resources/message.ex` (3 sites — incl. one
  `Ash.Query` preparation)
- `lib/jido_claw/conversations/resources/request_correlation.ex` (1 site)
- `lib/jido_claw/audit/resources/event.ex` (1 site)

Pattern (parent-level alias):
```elixir
defmodule JidoClaw.Memory.Fact do
  ...
  alias Ash.Changeset            # NEW — top-of-module, alphabetical
  alias Ash.Query                # NEW — if Preparations.* sites exist
  alias JidoClaw.Security.CrossTenantFk  # existing aliases below
  ...

  defmodule Changes.RedactContent do
    use Ash.Resource.Change
    # no per-submodule alias needed — parent alias propagates

    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs -> ... end)
    end
  end
end
```

Watch-outs:
- `Credo.Check.Readability.AliasOrder` will fire if `alias Ash.*` is inserted
  below `alias JidoClaw.*`. Always insert at the top of the alias block.
- `require Ash.Query` stays where it is — aliasing doesn't replace the require
  for `Ash.Query.filter/2` macros.
- Every `Ash.Changeset.x` / `Ash.Query.x` reference in the file must be
  rewritten, not just the ones in the flagged function. See verification.

---

## Batch 2 — `alias` remaining modules used 3+ times per function (~15 findings)

Same fix shape, applied to flat modules and tests:

| File | Alias to add | Notes |
|---|---|---|
| `lib/jido_claw/core/stats.ex` | `alias JidoClaw.SignalBus` | Used 4× in `init/1` |
| `lib/jido_claw/memory/consolidator/lock_owner.ex` | `alias JidoClaw.Repo` | Used 3× |
| `lib/jido_claw/platform/cron/worker.ex` | `alias JidoClaw.Telemetry` | Used 3× |
| `lib/jido_claw/shell/session_manager.ex` | `alias JidoClaw.Display` | Used 3× near line 1338; check alias block for collisions |
| `lib/jido_claw/tools/spawn_agent.ex` | `alias JidoClaw.AgentTracker` | Used 4× in `run/2` |
| `lib/jido_claw/forge/persistence.ex` | `alias Ash.Query` | Update all 8 `Ash.Query.*` call sites in the file for consistency |
| `lib/jido_claw/solutions/reads/hybrid_search.ex` | `alias Ash.Query` | Update all 9 sites |
| `lib/jido_claw/github/webhook_pipeline.ex` | `alias Plug.Conn` | Used 3× in `process/2` |
| `lib/jido_claw/vfs/resolver.ex` | `alias Jido.VFS, as: JidoVFS` | Use the `as:` rename — bare `VFS.read/2` inside `JidoClaw.VFS.Resolver` reads ambiguously against the local subsystem |
| `test/support/jido_claw/solutions_case.ex` | `alias Ecto.UUID` | Used 3× in `bulk_insert_solutions/4` |
| `test/jido_claw/solutions/hybrid_search_sql_test.exs` | `alias Ecto.UUID` | |
| `test/jido_claw/embeddings/backfill_worker_test.exs` | `alias Ecto.UUID` | |

---

## Batch 3 — Replace `Enum.map |> Enum.join` with `Enum.map_join` (13 findings)

Mechanical pipe rewrites. The 14th `UseMapJoin` finding sits in
`tools/read_file.ex` and is handled in Batch 4 with its overlapping
`PreferEnumSlice` issues.

Files: `lib/jido_claw/cli/branding.ex` (1), `lib/jido_claw/cli/formatter.ex`
(2), `lib/jido_claw/display.ex` (1), `lib/jido_claw/forge/sandbox/docker.ex`
(1), `lib/jido_claw/memory/consolidator/prompt.ex` (1),
`lib/jido_claw/platform/jido_md.ex` (1),
`lib/jido_claw/reasoning/strategy_store.ex` (1),
`lib/jido_claw/tools/reason.ex` (1), `lib/jido_claw/tools/run_pipeline.ex`
(1), `lib/jido_claw/tools/run_skill.ex` (1),
`lib/jido_claw/tools/store_solution.ex` (1),
`lib/jido_claw/tools/verify_certificate.ex` (1).

Transformation:
```elixir
# before
coll |> Enum.map(fun) |> Enum.join(sep)
# after
Enum.map_join(coll, sep, fun)
```

Run `mix format` after — pipe-to-call rewrites can shift line lengths.

---

## Batch 4 — `lib/jido_claw/tools/read_file.ex` combined fix (4 findings in one chain)

The pipeline at `lib/jido_claw/tools/read_file.ex:49-57` triggers three
`PreferEnumSlice` findings and one `UseMapJoin`. A single rewrite resolves
all of them — but `Enum.slice(offset, limit)` is **not** equivalent to
`Enum.drop(offset) |> Enum.take(limit)` for negative inputs. The current
schema declares `:integer`, so a direct Elixir caller (e.g. `ReadFile.run/2`
from tests or another Jido action) can pass negatives. `Enum.slice/3` raises
when `amount < 0`, while the existing code silently returns data.

`use Jido.Action` exposes `validate_params/1`, but the user-defined `run/2`
is callable directly and does not auto-validate. Existing tests in this repo
call action modules' `run/2` directly. So a schema change alone is
insufficient — `run/2` must guard against negatives itself.

Three-part fix:

1. Tighten the schema at `lib/jido_claw/tools/read_file.ex:29-30` so the
   public-API contract is explicit:
   ```elixir
   offset: [type: :non_neg_integer, default: 0, doc: "Start line (0-indexed)"],
   limit: [type: :non_neg_integer, default: 2000, doc: "Max lines to read"]
   ```

2. Add a runtime guard at the top of `run/2` to reject negatives from direct
   callers before they reach `Enum.slice/3`. Example:
   ```elixir
   def run(%{path: path} = params, context) do
     offset = Map.get(params, :offset, 0)
     limit = Map.get(params, :limit, 2000)

     cond do
       offset < 0 -> {:error, "offset must be non-negative"}
       limit < 0 -> {:error, "limit must be non-negative"}
       true -> do_read(path, params, context, offset, limit)
     end
   end
   ```
   (Exact shape — `cond`, multi-clause `run/2`, or a `with` — should match
   the surrounding error-tuple conventions in `lib/jido_claw/tools/`.)

3. Rewrite the chain:
   ```elixir
   numbered =
     lines
     |> Enum.with_index(1)
     |> Enum.slice(offset, limit)
     |> Enum.map_join("\n", fn {line, n} ->
       "#{String.pad_leading(Integer.to_string(n), 4)} │ #{line}"
     end)
   ```

4. Add tests in `test/jido_claw/tools/read_file_test.exs` covering: negative
   `offset`, negative `limit`, both negative, and `offset` greater than the
   number of lines (should return empty content cleanly — confirm `Enum.slice/3`
   semantics match the prior `Enum.drop |> Enum.take` behavior for in-bounds
   non-negative inputs).

---

## Batch 5 — ListLast / LengthInGuard / FlatMapFilter (9 findings)

### LengthInGuard (2)

- `lib/jido_claw/reasoning/auto_select.ex:173` — drop the redundant guard:
  `[_, _ | _] = tied when length(tied) >= 2 ->` becomes `[_, _ | _] = tied ->`.
  The pattern already enforces ≥ 2.
- `lib/jido_claw/reasoning/classifier.ex:254` — replace `matches when
  length(matches) >= 2 -> true` with `[_, _ | _] -> true`.

### FlatMapFilter (1)

`lib/jido_claw/workflows/plan_workflow.ex:177` — collapse the outer
`Enum.flat_map` + inner `Enum.flat_map`/`if` into a single-pass comprehension:

```elixir
# before
missing =
  Enum.flat_map(named_steps, fn step ->
    Enum.flat_map(step.depends_on, fn dep ->
      if Map.has_key?(step_map, dep), do: [], else: [{step.name, dep}]
    end)
  end)

# after
missing =
  for step <- named_steps,
      dep <- step.depends_on,
      not Map.has_key?(step_map, dep),
      do: {step.name, dep}
```

The comprehension is single-pass, more idiomatic, and clears the outer
`Enum.flat_map` along with the flagged inner one.

### ListLast (6) — per-site judgment

| Site | Action | Rationale |
|---|---|---|
| `lib/jido_claw/web/controllers/chat_controller.ex:33,65` | Extract the last message's `content` **once** in `create/2` and pass it down to `sync_response/_` and `stream_response/_` instead of re-deriving in each branch | Avoids the lint-dodge of swapping `List.last` for `Enum.at(-1)`. Both helpers currently call `List.last(messages) \|> Map.get("content", "")` on the same input — hoist that into `create/2` so the list is walked once and the helpers take `content` (or the last message map) as a parameter |
| `test/jido_claw/tool_context_shape_test.exs:118` | rewrite to `Enum.at(args, -1)` | `args` is the AST args list bounded to length 3 by the `when ... length(args) == 3` guard above; `Enum.at` is widely used in the codebase and not flagged |
| `lib/jido_claw/display.ex:554` | `# credo:disable-for-next-line` with rationale | `:binary.matches/2` already scanned the binary; walking the resulting `{pos, len}` list to its tail is cheap, and rewriting with `:binary.split/3` would re-scan |
| `lib/jido_claw/workflows/iterative_workflow.ex:144` | `# credo:disable-for-next-line` with rationale | Comment immediately above documents that "last VERDICT wins" is intentional; Regex.scan results are bounded by the small number of verdict tokens an LLM emits |
| `test/jido_claw/reasoning/auto_select_test.exs:22` | `# credo:disable-for-next-line` with rationale | Test stub `PickLastTiebreaker` is deliberately picking the last candidate; comment above explains why |

Disable comments follow the existing project convention (see
`lib/jido_claw/forge/persistence.ex:272,366` and
`lib/jido_claw/platform/background_process/registry.ex:2`).

---

## Verification

After **each** batch:
1. `mix format`
2. `mix compile --warnings-as-errors` — only catches a *totally* unused
   alias, not a partially-rewritten file (see step 3).
3. `mix credo --strict --only ExSlop.Check` — confirm batch findings cleared
   and nothing new surfaced.

After **Batch 1 and Batch 2 specifically**: `mix compile --warnings-as-errors`
is not sufficient because `UnaliasedModuleUse` collects aliases file-wide.
Once `alias Ash.Changeset` exists in a file, the check stops complaining
even if some `Ash.Changeset.foo` references remain fully-qualified. After
each of these batches:

```
git diff --name-only HEAD | xargs -0 -I{} echo {} | tr '\n' '\0' | \
  xargs -0 rg -n 'Ash\.Changeset\.|Ash\.Query\.|Plug\.Conn\.|JidoClaw\.SignalBus\.|JidoClaw\.Repo\.|JidoClaw\.Telemetry\.|JidoClaw\.Display\.|JidoClaw\.AgentTracker\.|Jido\.VFS\.|Ecto\.UUID\.'
```
(or simply `rg ... $(git diff --name-only HEAD)` when the diff contains no
generated/whitespace paths — usually the case here.)

Expect zero hits in the modified files. Any hit means a stale fully-qualified
reference slipped through.

After **Batch 4**: `mix test test/jido_claw/tools/read_file_test.exs` —
this is the only batch with a real semantic edge (negative-input handling,
schema tightening). The targeted test catches regressions before the
full-suite run.

After **Batch 5** (final):
4. `mix credo --strict --only ExSlop.Check` — expect 0 issues.
5. `mix credo --strict` — confirm `Credo.Check.Readability.AliasOrder` did
   not regress.
6. `mix test` — Batches 1–2 touch runtime code on every memory, solutions,
   conversations, and audit test path.
7. `git diff --stat` — sanity check the change surface (~30 files).

## Critical files

- `/Users/rickdunkin/workspace/claws/jido_radclaw/.credo.exs`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/memory/resources/fact.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/memory/resources/block.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/solutions/resources/solution.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/conversations/resources/message.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/forge/persistence.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/solutions/reads/hybrid_search.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/tools/read_file.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/workflows/plan_workflow.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/display.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/workflows/iterative_workflow.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/web/controllers/chat_controller.ex`
