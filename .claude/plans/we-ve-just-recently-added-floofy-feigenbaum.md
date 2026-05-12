# Resolve Credo Tier 2 Findings (v5)

## Context

The baseline Credo run (`docs/reports/credo-baseline-2026-05-12.md`) flagged
three Tier 2 issues. They are correctness-adjacent (real bugs hide here), but
none are flaming. This plan covers two of them:

1. **`ExSlop.Check.Warning.DualKeyAccess` × 80** — code reads maps using both
   `:atom` and `"string"` keys. Each site is a candidate bug where one branch
   silently returns `nil` because the data shape changed at the boundary.
2. **`ExSlop.Check.Warning.GenserverAsKvStore` × 1** at
   `lib/jido_claw/platform/background_process/registry.ex` — a false positive
   we will annotate.

Out of scope (deferred): `Refactor.CyclomaticComplexity` outlier at
`lib/jido_claw/cli/repl.ex:36`. That function is the untested boot
orchestrator; refactor risk outweighs the value of the Credo signal.

Goal: one focused PR that eliminates all 80 dual-key warnings, leaves the
codebase with one canonical module (`JidoClaw.Core.MapKeys`) exposing two
semantically distinct read helpers plus boundary normalization, fixes a
small handful of adjacent `String.to_atom/1`-on-user-input risks, and
annotates the registry false positive.

## Approach

The 80 dual-key sites fall into five shape patterns, each with a different
correct fix. Rather than spot-patch all 80, we will:

1. **Build one shared helper module** (`JidoClaw.Core.MapKeys`) with an API
   carefully scoped to avoid known footguns (struct corruption, `nil`/`false`
   fallback semantics, unbounded `String.to_atom`).
2. **Fold existing private helpers** into the shared module (six known
   copies, not all of which are Credo hits — listed below).
3. **For each cluster, push normalization to the right boundary** so
   downstream code never sees both shapes. Where boundary normalization is
   not feasible (signal consumers, test fixtures), use `MapKeys.field/3` at
   the read site.
4. **Annotate `background_process/registry.ex`** at the actual offending
   line.

## Step 1 — `JidoClaw.Core.MapKeys` design (CAREFUL)

**New file:** `lib/jido_claw/core/map_keys.ex`

### Two read-site helpers with explicit semantics

The existing codebase has TWO different dual-access semantics. Folding all
of them into one helper would silently change behavior. We expose both:

Both helpers accept **either an atom or a binary** as the preferred key.
Whichever shape is passed takes precedence; the counterpart is the
fallback. This matters because existing sites use both polarities:
`Recorder.field(data, :metadata)` (atom-first), `migrate.memory.ex:251`
`field(entry, "key")` (string-first).

```elixir
@doc """
Fetch a value by the preferred key (atom or binary), falling back to the
counterpart key shape only if the preferred key is absent. Returns
`default` if neither key is present, or for non-map input.

Matches `Map.get/3` fetch-default semantics: a present-but-nil value at
the preferred key is returned as-is (no fallback to the counterpart).

Used by: signal-payload readers where the emitter may write either key
shape but a present `nil`/`false` value is meaningful. Folded from
`Recorder.field/2` and `Audit.SignalListener.field/2`.
"""
@spec field(term, atom | binary, term) :: term
def field(map, preferred_key, default \\ nil)

def field(map, atom_key, default) when is_map(map) and is_atom(atom_key) do
  Map.get(map, atom_key, Map.get(map, Atom.to_string(atom_key), default))
end

def field(map, string_key, default) when is_map(map) and is_binary(string_key) do
  case Map.fetch(map, string_key) do
    {:ok, value} -> value
    :error -> field_atom_fallback(map, string_key, default)
  end
end

def field(_, _, default), do: default

defp field_atom_fallback(map, string_key, default) do
  case safe_existing_atom(string_key) do
    {:ok, atom_key} -> Map.get(map, atom_key, default)
    :error -> default
  end
end
```

```elixir
@doc """
Fetch a value by the preferred key (atom or binary), treating `nil` and
`false` as "absent" and falling through to the counterpart key shape.
Matches the `Map.get(map, k1) || Map.get(map, k2)` pattern.

Used by: existing `||`-style sites where falsy values were treated as
absent (e.g. token counts where 0/nil from one provider should fall back
to the other key shape).
"""
@spec coalesce_field(term, atom | binary, term) :: term
def coalesce_field(map, preferred_key, default \\ nil)

def coalesce_field(map, atom_key, default) when is_map(map) and is_atom(atom_key) do
  Map.get(map, atom_key) || Map.get(map, Atom.to_string(atom_key)) || default
end

def coalesce_field(map, string_key, default) when is_map(map) and is_binary(string_key) do
  Map.get(map, string_key) || coalesce_atom_fallback(map, string_key) || default
end

def coalesce_field(_, _, default), do: default

defp coalesce_atom_fallback(map, string_key) do
  case safe_existing_atom(string_key) do
    {:ok, atom_key} -> Map.get(map, atom_key)
    :error -> nil
  end
end
```

`safe_existing_atom/1` is the same helper being folded from
`network_facade.ex:152` (wraps `String.to_existing_atom/1` in a rescue).

Tests must cover both polarities for both helpers (atom-preferred and
string-preferred), the `nil`/`false` divergence row, and the non-map
catch-all.

**Important discipline for implementers:** for migration tasks that read
JSON or YAML (Cluster D), the inbound shape is **always strings** — use
string-only access (`entry["key"]`), not the helper, because the
"fallback to atom" branch is unreachable and adds noise. The helpers are
for genuinely ambiguous-shape data (signal payloads, attr maps).

Both clauses tolerate non-map input by returning the default — signal
handlers are exactly the place where defensive non-map handling is useful,
and the existing helpers (`Recorder.field/2`, `SignalListener.field/2`)
already had a `def field(_, _), do: nil` catch-all.

Tests for `field/3` (fetch-default semantics):

- both keys present → atom wins
- only string key present → string wins
- atom present and `nil` → returns `nil` (NOT string fallback)
- atom present and `false` → returns `false` (NOT string fallback)
- neither present → default
- non-map input → default

Tests for `coalesce_field/3` (`||` semantics):

- both keys present → atom wins (truthy)
- only string key present → string wins
- atom present and `nil` → falls through to string key
- atom present and `false` → falls through to string key
- both falsy → default
- non-map input → default

### Per-site mapping (which helper goes where)

When folding existing helpers and replacing dual-access sites, pick the
helper that matches the original code's behavior:

| Original pattern | Replacement |
|------------------|-------------|
| `Map.get(map, :key, Map.get(map, "key"))` | `MapKeys.field/2` |
| `Map.get(map, :key) \|\| Map.get(map, "key")` | `MapKeys.coalesce_field/2` |
| `Recorder.field/2`, `Audit.SignalListener.field/2` | `MapKeys.field/2` (these use fetch-default semantics today) |
| `Trust.present?`, `Trust.verification_score`, `Trust.freshness_score`, etc. | `MapKeys.coalesce_field/2` (these use `\|\|` today) — though see Cluster E for a cleaner refactor that obviates this |
| `migrate.memory.ex:251` `field/2` | `MapKeys.coalesce_field/2` (uses `\|\|`) |
| `run_pipeline.ex:584,587` `merge_usage` | `MapKeys.coalesce_field/2` (uses `\|\|` to skip falsy/zero token counts) |
| `vfs/workspace.ex:225,226` mount entries | `MapKeys.coalesce_field/2` (existing `\|\|`) |
| `context_builder.ex:148,155` event payloads | `MapKeys.coalesce_field/2` (existing `\|\|`) |
| `actor_classifier.ex:55,71` | `MapKeys.coalesce_field/2` (existing `\|\|`); the `non_nil_field/3` helper at lines 62-67 wraps `\|\|` access with a `"" -> nil` step — keep that wrapper, just call `coalesce_field` inside it (do not replace the whole helper with bare `field/3`) |
| `ash_tracer.ex:169` | `MapKeys.coalesce_field/2` (existing `\|\|`) |
| `verify_certificate.ex:197` | check the original code; default to `coalesce_field` if `\|\|` |
| `commands.ex:176,177` (post-normalization in Cluster B) | atom access (no helper) |

When in doubt during implementation, **read the existing line and match its
semantics exactly** — the table above is a guide, not a mandate.

### `normalize_keys/2` — boundary normalization, struct-safe

```elixir
@spec normalize_keys(map, :string | :atom_existing, keyword) :: map
def normalize_keys(map, mode, opts \\ []) when is_map(map) and not is_struct(map)
```

The public function is **map-only** (non-struct map). Implementation
contract:

- Modes:
  - `:string` — atom → string keys. Replaces shallow `Protocol.normalize_keys/1`.
  - `:atom_existing` — string → atom (via `String.to_existing_atom/1`). Replaces `NetworkFacade.normalize_keys/1` and `Harness.atomize_spec_keys/1`.
- Options:
  - `:deep` (default `false`) — recurse into nested values. Internal
    recursion handles list values (walk and normalize each map element)
    and nested-map values. **Structs always pass through unchanged**,
    regardless of `:deep`, to protect DateTime/NaiveDateTime/Solution
    values in payloads (e.g. `NetworkFacade.to_wire/1` emits
    `s.inserted_at` directly).
  - `:drop_unknown` (default `false`, `:atom_existing` only) — when an
    inbound string key has no existing atom counterpart, drop the entry
    silently. This is the contract of `NetworkFacade.normalize_keys/1` —
    unknown wire keys must not become Ash create errors. Without this
    option, unknown strings are retained as string keys. Implementation
    uses `safe_existing_atom/1` (folded from `network_facade.ex`).
- Never call `String.to_atom/1` (per `usage_rules:elixir`).
- Top-level lists are **not** accepted by this function — wrap with
  `Enum.map(list, &MapKeys.normalize_keys(&1, mode, opts))` at the call
  site (this is what `StepNormalizer.normalize/1` does for the workflow
  steps list).

Test file: `test/jido_claw/core/map_keys_test.exs`. Must cover:

- `field/3`: all six rows above
- `normalize_keys(:string)`: shallow, lists, idempotent on already-string
- `normalize_keys(:atom_existing)`: existing atoms, unknown strings retained vs `drop_unknown: true`
- Struct passthrough at top level AND nested with `:deep` (DateTime is canonical)
- `:deep` on nested maps and lists-of-maps
- Idempotency

### Existing helpers to fold

Six known private copies. All move to (or are replaced by) `MapKeys`:

| File | Line | Helper | After |
|------|------|--------|-------|
| `lib/jido_claw/conversations/recorder.ex` | 820-829 | `field/2`, `metadata_request_id/1` | `MapKeys.field/2`; keep `metadata_request_id` as a 2-liner using it |
| `lib/jido_claw/audit/signal_listener.ex` | 174-178 | `field/2` | `MapKeys.field/2` |
| `lib/jido_claw/network/protocol.ex` | 168-173 | `normalize_keys/1` (shallow, atom→string) | `MapKeys.normalize_keys(map, :string)` |
| `lib/jido_claw/solutions/network_facade.ex` | 136-160 | `normalize_keys/1` (string→atom, drop unknown), `safe_existing_atom/1` | `MapKeys.normalize_keys(map, :atom_existing, drop_unknown: true)` — **shallow, do NOT pass `deep: true`**: the wire payload includes a nested `verification` map whose keys must NOT be touched (they come from heterogeneous verifier outputs and may legitimately use either shape) |
| `lib/jido_claw/forge/harness.ex` | 835 | `atomize_spec_keys/1` | `MapKeys.normalize_keys(map, :atom_existing)` |
| `lib/mix/tasks/jidoclaw.migrate.memory.ex` | 250-252 | `field/2` (uses `String.to_atom/1` — RISK) | **Delete the helper** and switch its call sites to string-only access (`entry["key"]`). JSON-loaded data is always string-keyed, so the atom fallback is unreachable; deleting closes the `String.to_atom/1` risk without introducing a helper call. |

## Step 2 — Apply fixes by cluster

Counts below are from the `mix credo` re-run (verified 80 total / 25 files).

### Cluster A — Signal/audit payloads (read-site `MapKeys.field` OR `coalesce_field`)

Emitter shape is outside consumer control (Jido signal bus, jido_ai usage
maps, Ash audit row payloads). Use a read-site helper at each line.

**Pick the helper per the table in Step 1**: most sites in this cluster
currently use `||` semantics and should use `coalesce_field/3`; the
`Recorder` and `Audit.SignalListener` private helpers use fetch-default
semantics and their folded call sites should use `field/3`. When in
doubt, read the original line and match its semantics exactly.

| File | Lines |
|------|-------|
| `lib/jido_claw/conversations/recorder.ex` | 248, 249, 302, 308 |
| `lib/jido_claw/reasoning/telemetry.ex` | 240, 241, 242, 243 |
| `lib/jido_claw/audit/actor_classifier.ex` | 55, 71 (and `non_nil_field/3` at line 62 — keep the wrapper's `"" -> nil` handling; replace its internal `\|\|` access with `MapKeys.coalesce_field`) |
| `lib/jido_claw/audit/ash_tracer.ex` | 169 |
| `lib/jido_claw/forge/context_builder.ex` | 148, 155 |
| `lib/jido_claw/forge/persistence.ex` | 441 |
| `lib/jido_claw/tools/verify_certificate.ex` | 197 |
| `lib/jido_claw/tools/run_pipeline.ex` | 584, 587 (`merge_usage` — token counts from heterogeneous LLM responses; the `||` semantics matter here because some providers send `nil` token counts) |

Test fixtures in this cluster (use the helper matching the current
expression — `field/3` if the assertion uses `Map.get(_, _, default)`
style, `coalesce_field/3` if it uses `||`; fixtures intentionally mirror
on-the-wire shapes):

| File | Lines |
|------|-------|
| `test/jido_claw/audit/producers_test.exs` | 57, 331, 338, 377, 421, 459 |
| `test/jido_claw/audit/signal_listener_test.exs` | 89, 90 |
| `test/jido_claw/reasoning/telemetry_test.exs` | 300, 304 |
| `test/jido_claw/signal_bus_test.exs` | 59 |

### Cluster B — Workflow step dicts (normalize at EVERY public entry)

The module is **`JidoClaw.Skills`** (file lives at
`lib/jido_claw/platform/skills.ex` but the namespace omits `Platform`).

A YAML-load-only boundary is insufficient: tests at
`test/jido_claw/workflows/scope_propagation_test.exs:162,197,238`,
`test/jido_claw/workflows/step_action_test.exs:131`, and
`test/jido_claw/workflows/iterative_workflow_test.exs` build
`%JidoClaw.Skills{steps: [%{"name" => ...}]}` structs by hand and call
`SkillWorkflow.run/4`, `PlanWorkflow.run/4`, `IterativeWorkflow.run/4`, and
`IterativeWorkflow.extract_roles/1` directly. Normalizing only at
`Skills.parse_skill_file/1` would break every test that bypasses YAML
loading (and likely break unknown production callers).

**Fix: normalize at every public workflow entry, and at the YAML loader.**

**New module:** `lib/jido_claw/workflows/step_normalizer.ex` with one
function:

```elixir
@doc """
Normalize step map keys to atoms via `MapKeys.normalize_keys(:atom_existing)`.
Idempotent — already-atom-keyed steps pass through unchanged.

This does NOT validate step shape. A future workflow-hardening pass can
add validation; the goal here is only to eliminate dual-key reads.
"""
@spec normalize([map] | map | nil) :: [map]
def normalize(steps)
```

No validation — that's wider than a Credo cleanup and risks changing
parse-time behavior. Pure key normalization, idempotent.

**Wire-up at four call sites:**

1. `Skills.parse_skill_file/1` at `lib/jido_claw/platform/skills.ex:402`
   — `steps: StepNormalizer.normalize(Map.get(data, "steps", []))`.
2. `SkillWorkflow.run/4` — normalize `skill.steps` at function entry.
3. `PlanWorkflow.run/4` — normalize `skill.steps` at function entry.
4. `IterativeWorkflow.run/4` and `IterativeWorkflow.extract_roles/1` —
   normalize `skill.steps` at each function entry.

Because `normalize/1` is idempotent, double-normalization (parse-then-run)
is safe and cheap.

**Adjacent readers — defensively normalize at function entry, do NOT
assume callers have normalized:**

- `JidoClaw.Skills.has_dag_steps?/1`
- `JidoClaw.Skills.execution_mode/1`

These are public-ish: tests call them with hand-built skill structs whose
steps may still be string-keyed. Each should call
`StepNormalizer.normalize(skill.steps)` at function entry (cheap because
the normalizer is idempotent) rather than depending on upstream
normalization. This is the same defensive pattern Trust uses (Cluster E).

Other readers can rely on the boundary:

- `lib/jido_claw/cli/commands.ex:176,177` (REPL `:skills` display loop) — these only run after `Skills.parse_skill_file/1`, atom access is safe
- Any other `Map.get(step,` site within `lib/jido_claw/platform/skills.ex` and `lib/jido_claw/workflows/`

Verification before finalizing this cluster: grep `Map.get(step,` and
`step["` across `lib/jido_claw/platform/skills.ex`, `lib/jido_claw/workflows/`,
and `lib/jido_claw/cli/` to find every reader. The boundary only holds if
every reader assumes atoms.

Per-driver dual-access sites that disappear after the boundary holds:

- `plan_workflow.ex:74,81,92,93,94` (and `normalize_*_field/2` helpers at 104-114 can be deleted)
- `iterative_workflow.ex:282-285` (`assign_step_names`)
- `skill_workflow.ex:112,113,114`
- `cli/commands.ex:176,177`

### Cluster C — Ash checkpoint / forge metadata (load boundary)

Promote `Harness.atomize_spec_keys/1` → `MapKeys.normalize_keys(:atom_existing)`
and apply once on checkpoint metadata load.

- `lib/jido_claw/forge/harness.ex` — lines 755, 756, 757, 772, 773 (`recover_runner`, `recover_extra_sandboxes`). The fix: normalize the checkpoint metadata blob at load, before the recovery functions read fields.
- `test/jido_claw/forge/multi_sandbox_test.exs` — line 654 (test fixture; use the helper matching the current expression)

`forge/persistence.ex:441` is already covered in Cluster A; the checkpoint
load site is in `harness.ex`.

### Cluster D — File-loaded JSON/YAML migration (tighten boundary)

Migration mix tasks read user files via Jason or YamlElixir. Both decoders
return **string keys only**, so dual access is defensive overkill — switch
to string-only.

- `lib/mix/tasks/jidoclaw.migrate.solutions.ex` (Jason-decoded) — lines 254, 257, 258, 259, 260 (`legacy_to_attrs/2`, `coerce_legacy_reputation/1`)
- `lib/mix/tasks/jidoclaw.migrate.cron.ex` (YamlElixir-decoded, see line 55) — lines 108, 109, 110, 111

The `migrate.memory.ex` `field/2` helper at line 250 is **not** a Credo
hit but uses `String.to_atom/1` on user input (memory leak risk per
`usage_rules:elixir`). The source data is `Jason.decode`'d, so it's
always string-keyed — the atom fallback branch is unreachable. **Delete
the helper** and switch its call sites to string-only access
(`entry["key"]`). No `MapKeys` helper needed here; introducing one would
just reintroduce a dead code path.

`lib/mix/tasks/jidoclaw.export.solutions.ex:105` uses `String.to_atom/1`
during **SQL column → atom conversion**, not on JSON-loaded user input —
the columns come from a Postgrex result set. The risk is bounded
(column names are SQL identifiers we control), but `String.to_atom/1`
should still be eliminated. Use an explicit column-to-atom mapping built
from the known Solution attribute set (`@solution_columns %{"id" => :id,
"problem_signature" => :problem_signature, ...}`) or
`String.to_existing_atom/1` — the former is clearer because the caller is
in full control of the column set.

### Cluster E — Trust scoring (normalize at every public entry, NO public API change)

**Revised from v1.** `Trust.compute/2` publicly accepts `%Solution{}` or
"any map with matching fields" (per `trust.ex:13` moduledoc), and the test
suite (`trust_test.exs:25-...`) explicitly exercises both string-keyed and
atom-keyed plain maps. Tightening to require a struct is a breaking API
change.

**Public API surface (all four must normalize their own input):**

- `compute/2` (line 38)
- `verification_score/1` (line 60)
- `completeness_score/1` (line 80)
- `freshness_score/2` (line 113)

Normalizing only in `compute/2` would regress direct callers that invoke
the individual scorers with string-keyed maps.

**Fix:** add a private `normalize/1` that handles both shapes:

```elixir
defp normalize(%_struct{} = s), do: Map.from_struct(s)
defp normalize(map) when is_map(map), do: MapKeys.normalize_keys(map, :atom_existing)
```

Call `normalize/1` at the top of `compute/2`, `verification_score/1`,
`completeness_score/1`, and `freshness_score/2`. The seven internal
dual-access sites at the top level (`verification_score/1` line 61,
`freshness_score/2` lines 115-118, `present?/3` line 169,
`tags_present?/1` line 174, `verification_present?/1` line 179,
`sharing_not_local?/1` line 184) then read atom-only.

**Important: the nested `verification` map is shallow-normalized only.**
The `score_verification/1` private function pattern-matches against
`%{status: "passed"}` AND `%{"status" => "passed"}` (and the `partial`
variants) because tests pass nested fixtures like
`%{verification: %{"status" => "passed"}}`. Top-level `normalize/1` does
NOT walk into the verification value (shallow `MapKeys.normalize_keys`
without `:deep`), so **keep the dual-shape pattern clauses in
`score_verification/1` unchanged**. Deep-walking the verification payload
would be a behavior change with possible regressions across heterogeneous
verifier outputs — that's outside this PR's scope.

Module doc stays accurate. Tests continue to pass with no changes.

Lines affected (top-level dual access only): 61, 115, 116, 117, 169, 174, 179, 184.

### Cluster F — User-supplied attr maps (entry-point normalize)

- `lib/jido_claw/memory.ex` — lines 243, 244, 247, 267. Add
  `attrs = MapKeys.normalize_keys(attrs, :atom_existing)` at the top of
  `do_remember/3` (around line 216).
- `lib/jido_claw/vfs/workspace.ex` — lines 225, 226. Use `MapKeys.coalesce_field/2`
  inside `mount_from_config/2`'s per-entry loop (matches existing `||`
  semantics). **Also fix line 236**: `adapter |> to_string() |> String.to_atom()`
  runs on user config. The valid adapter set is already enumerated by the
  `to_adapter_spec/2` private function (`:local`, `:in_memory`, `:github`,
  `:s3`, `:git` per lines 281, 288, 296, 308, 323). Replace with an
  explicit mapping:

  ```elixir
  @adapter_keys %{
    "local" => :local,
    "in_memory" => :in_memory,
    "github" => :github,
    "s3" => :s3,
    "git" => :git
  }
  @valid_adapters Map.values(@adapter_keys)

  defp parse_adapter_key(adapter) when is_atom(adapter) and adapter in @valid_adapters do
    {:ok, adapter}
  end

  defp parse_adapter_key(adapter) when is_binary(adapter) do
    case Map.fetch(@adapter_keys, adapter) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:unknown_adapter, adapter}}
    end
  end

  defp parse_adapter_key(_), do: {:error, :invalid_adapter}
  ```

  Validating the atom against `@valid_adapters` puts the one validation
  point in `parse_adapter_key/1` rather than depending on
  `to_adapter_spec/2` to reject unknown atoms downstream.

  Then `mount_from_config/2` calls `parse_adapter_key(adapter)` and logs +
  skips on `{:error, _}`, matching the existing `log_mount_warning/3` path.
  Clearer than `String.to_existing_atom/1` and prevents future drift if
  someone adds an unrelated atom that happens to match a wire string.

### Cluster G — Test fixtures (sweep with the matching helper)

Tests that build string-keyed payload fixtures and dual-access "to be
safe". Use the helper matching the current expression — `field/3` for
`Map.get(_, _, default)` style, `coalesce_field/3` for `||` style:

- `test/jido_claw/tools/reason_test.exs` — lines 170, 189, 251, 276, 417
- `test/jido_claw/tools/run_pipeline_test.exs` — lines 60, 649, 789, 860, 863

## Step 3 — Annotate `background_process/registry.ex` (CORRECTED)

The Credo finding at `lib/jido_claw/platform/background_process/registry.ex:73`
points to `def handle_call({:get, id}, _from, state)` — the line the check's
heuristic identifies as KV-shaped. The disable annotation must go there, not
on the `defstruct` at line 14 (the v1 plan was wrong).

**Action:** prefer a module-level disable since the whole module has the
KV-shaped overall structure that triggers the heuristic, with a moduledoc
note explaining why. Append to the existing `@moduledoc`:

```
This module would superficially fit ETS or Agent (state is a map keyed by
process id), but it also owns:
  - SIGTERM→SIGKILL two-phase termination timers (Process.send_after)
  - A recurring :cleanup tick
  - A terminate/2 callback that walks state on shutdown
  - Serialized read-modify-write on output_buffer with byte-cap trimming
Neither ETS nor Agent supports those primitives, so this stays a GenServer.
```

Then add `# credo:disable-for-this-file ExSlop.Check.Warning.GenserverAsKvStore`
**at the very top of the file, before `defmodule`** — Credo's
`disable-for-this-file` directive must be at file scope, not inside the
module body. After this PR, re-run `mix credo --checks ExSlop.Check.Warning.GenserverAsKvStore`
to confirm the count is `0`; if it isn't (e.g. the directive doesn't take
effect at that scope in our Credo version), fall back to a
`# credo:disable-for-next-line` directly above `def handle_call({:get, id}, ...)`
at line 73.

**Note:** the module currently has zero non-test callers, but it is
documented in `docs/ARCHITECTURE.md:65` and its `terminate/2` callback was
just added per the `mossy-noodling-karp` plan — it's intentional WIP
infrastructure for a future `run_bash --background` style tool, not stale
code. Do **not** delete it in this PR.

## Critical files to modify

**New:**

- `lib/jido_claw/core/map_keys.ex`
- `test/jido_claw/core/map_keys_test.exs`
- `lib/jido_claw/workflows/step_normalizer.ex`
- `test/jido_claw/workflows/step_normalizer_test.exs` (cover atom/string YAML inputs, missing optional fields, list inputs)

**Modified (lib/), grouped by cluster:**

Cluster A:
- `lib/jido_claw/audit/actor_classifier.ex`
- `lib/jido_claw/audit/ash_tracer.ex`
- `lib/jido_claw/audit/signal_listener.ex` (fold existing `field/2`)
- `lib/jido_claw/conversations/recorder.ex` (fold existing `field/2`)
- `lib/jido_claw/forge/context_builder.ex`
- `lib/jido_claw/forge/persistence.ex`
- `lib/jido_claw/reasoning/telemetry.ex`
- `lib/jido_claw/tools/run_pipeline.ex`
- `lib/jido_claw/tools/verify_certificate.ex`

Cluster B:
- `lib/jido_claw/cli/commands.ex` (atom access post-normalization)
- `lib/jido_claw/platform/skills.ex` (wire `StepNormalizer`; update `has_dag_steps?/1`, `execution_mode/1`)
- `lib/jido_claw/workflows/iterative_workflow.ex`
- `lib/jido_claw/workflows/plan_workflow.ex`
- `lib/jido_claw/workflows/skill_workflow.ex`

Cluster C:
- `lib/jido_claw/forge/harness.ex` (use `MapKeys.normalize_keys`, drop `atomize_spec_keys/1`)

Cluster D:
- `lib/mix/tasks/jidoclaw.export.solutions.ex` (opportunistic `String.to_atom` fix at line 105)
- `lib/mix/tasks/jidoclaw.migrate.cron.ex`
- `lib/mix/tasks/jidoclaw.migrate.memory.ex` (fold `field/2`)
- `lib/mix/tasks/jidoclaw.migrate.solutions.ex`

Cluster E:
- `lib/jido_claw/solutions/trust.ex` (internal normalize, NO public API change)

Cluster F:
- `lib/jido_claw/memory.ex`
- `lib/jido_claw/vfs/workspace.ex` (also fix line 236 `String.to_atom` on user input)

Fold-only (not Credo hits):
- `lib/jido_claw/network/protocol.ex` (line 168 helper → `MapKeys.normalize_keys(:string)`)
- `lib/jido_claw/solutions/network_facade.ex` (lines 136-160 helper → `MapKeys.normalize_keys(:atom_existing, drop_unknown: true)`; preserve drop-unknown contract!)

Annotation:
- `lib/jido_claw/platform/background_process/registry.ex` (file-level credo disable + moduledoc note)

**Modified (test/):**

- `test/jido_claw/audit/producers_test.exs`
- `test/jido_claw/audit/signal_listener_test.exs`
- `test/jido_claw/forge/multi_sandbox_test.exs`
- `test/jido_claw/reasoning/telemetry_test.exs`
- `test/jido_claw/signal_bus_test.exs`
- `test/jido_claw/tools/reason_test.exs`
- `test/jido_claw/tools/run_pipeline_test.exs`

## Verification

1. **Dual-key count drops to zero:**
   `mix credo --checks ExSlop.Check.Warning.DualKeyAccess --format json | jq '.issues | length'` → `0`
2. **Registry check stays at zero:**
   `mix credo --checks ExSlop.Check.Warning.GenserverAsKvStore --format json | jq '.issues | length'` → `0`
3. **Full suite green:** `mix test`. Critical paths to confirm cover the
   changes:
   - `test/jido_claw/core/map_keys_test.exs` (new)
   - `test/jido_claw/workflows/step_normalizer_test.exs` (new)
   - `test/jido_claw/audit/` (Cluster A producers + signal listener)
   - `test/jido_claw/conversations/recorder_test.exs` if present
   - `test/jido_claw/reasoning/telemetry_test.exs` (Cluster A)
   - `test/jido_claw/forge/` (Cluster C)
   - `test/jido_claw/solutions/trust_test.exs` and `reputation_test.exs` (Cluster E — these MUST pass unchanged)
   - `test/jido_claw/network/protocol_test.exs` if present (helper fold)
   - `test/jido_claw/solutions/network_facade_test.exs` if present (drop-unknown contract)
   - `test/jido_claw/vfs/` (Cluster F)
   - `test/jido_claw/memory_test.exs` if present
4. **Format:** `mix format --check-formatted`
5. **Strict compile:** `mix compile --warnings-as-errors`
6. **Skills end-to-end (non-interactive):** add a minimal test under
   `test/jido_claw/platform/skills_test.exs` (or extend an existing one) that
   loads a sample skill YAML with mixed atom/string step keys and asserts
   `StepNormalizer` produces atom-keyed steps consumed by the workflow drivers.
7. **Migration tasks compile + smoke:**
   `mix help jidoclaw.migrate.solutions`, `mix help jidoclaw.migrate.cron`,
   `mix help jidoclaw.migrate.memory`. If a sample legacy fixture exists in
   `test/fixtures/`, run the task against a copy.
8. **Wire-protocol round-trip:** if `test/jido_claw/network/protocol_test.exs`
   covers decode, ensure a payload with a DateTime field round-trips without
   the DateTime being walked (struct passthrough). If no such test exists,
   add one to `map_keys_test.exs` to lock in the contract.

## Commit plan (suggested slicing — NOT authorization to commit)

A single PR is appropriate. Suggested commits for reviewability:

1. `refactor: add JidoClaw.Core.MapKeys shared helper`
   (new module + tests + fold the six existing helpers)
2. `refactor: read-site MapKeys.field for signal/audit payloads`
   (Cluster A lib/ + Cluster A tests + Cluster G test fixtures)
3. `refactor: normalize workflow steps at YAML load and workflow entries`
   (Cluster B: new `StepNormalizer` + `Skills.parse_skill_file/1` + defensive normalize in `Skills.has_dag_steps?/1` and `Skills.execution_mode/1` + entry-normalize in `SkillWorkflow.run/4`, `PlanWorkflow.run/4`, `IterativeWorkflow.run/4` and `extract_roles/1` + `commands.ex` reader)
4. `refactor: normalize forge checkpoint metadata at load`
   (Cluster C)
5. `refactor: tighten file-load migration tasks to string-keyed access`
   (Cluster D + adjacent `String.to_atom` fixes in `migrate.memory.ex`, `export.solutions.ex`)
6. `refactor: normalize Trust.compute input internally (no API change)`
   (Cluster E)
7. `refactor: normalize memory and VFS workspace attr maps at entry`
   (Cluster F + workspace.ex:236 `String.to_atom` fix)
8. `chore: scope GenServer-as-KV credo disable to registry module`
   (registry.ex annotation)

Do **not** run `git commit` without an explicit request from me.

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| `String.to_existing_atom/1` raises at runtime in `:atom_existing` mode | `:drop_unknown` option + rescue inside `safe_existing_atom/1` (folded from `network_facade.ex`); test covers unknown strings explicitly |
| Recursive `normalize_keys(:deep)` corrupts DateTime/Solution structs in network payloads | Struct passthrough enforced unconditionally; explicit test with DateTime payload (`NetworkFacade.to_wire/1` at `network_facade.ex` lines 131-132 emits raw `s.inserted_at` / `s.updated_at` DateTime structs that must survive the round trip) |
| Folding `Recorder.field/2` and `Audit.SignalListener.field/2` (fetch-default) into a `\|\|`-semantics helper would silently change behavior on `nil`/`false` values | Two distinct helpers: `field/3` for fetch-default sites and `coalesce_field/3` for `\|\|` sites. Per-site mapping table in Step 1 lists which to use for each existing helper and call site |
| Non-map input to `field/3` or `coalesce_field/3` crashes signal handlers | Both helpers have a `def name(_, _, default), do: default` catch-all (matches the existing `def field(_, _), do: nil` clauses) |
| Replacing `NetworkFacade.normalize_keys/1` drops the drop-unknown contract → Ash create errors | `:drop_unknown: true` option preserves the contract; do not omit it at the call site |
| Workflow step normalizer is added at `Skills.parse_skill_file/1` only → tests bypassing YAML load break | Normalize at all four public entries (`parse_skill_file/1` + `SkillWorkflow.run/4` + `PlanWorkflow.run/4` + `IterativeWorkflow.run/4` & `extract_roles/1`); normalizer is idempotent |
| `Skills.has_dag_steps?/1` / `execution_mode/1` still use string access → dual access just moves | Grep `Map.get(step,` / `step["` across `platform/skills.ex`, `workflows/`, and `cli/` before the cluster's PR commit; update every adjacent reader |
| Trust normalize at `compute/2` only — direct callers of `verification_score/1`, `completeness_score/1`, `freshness_score/2` regress | Normalize at all four public entries; `trust_test.exs` and `reputation_test.exs` must pass with zero edits |
| `NetworkFacade.normalize_keys` deep walk corrupts nested `verification` payload from heterogeneous verifiers | Explicitly shallow at that call site (`deep: false`, the default); table entry calls this out; protocol decode is also shallow today |
| REPL boot orchestrator (`repl.ex:36`) is left at complexity 23 | Out of scope; tracked in baseline report; will be revisited after this PR |

## Out of scope (Tier 2 deferred)

- `lib/jido_claw/cli/repl.ex:36` cyclomatic complexity 23. Untested boot
  orchestrator. Revisit in a follow-up with a "extract testable seams first,
  then decompose" sequence.
