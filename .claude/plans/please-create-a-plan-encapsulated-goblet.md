# v0.6 Cleanup Sprint — Pre-Phase-4 Gaps (revision 7)

## Context

The v0.6 migration shipped phases 0 through 3c. An audit before
starting Phase 4 found:

1. Six small code gaps where a documented surface was simply not built.
2. Mistaken support for local (Ollama) embeddings — Voyage is the only
   provider; `VOYAGE_API_KEY` must be present.
3. Plan / code drift on the consolidator default, `harness_turns`,
   `:scope_busy` return shape, and the missing `:search` Ash action.
4. Acceptance-test debt where `§X.7` / `§3.19` gates were written as
   plan prose but never authored.

**Scope:** every item below ships in this sprint. No buckets, no
deferred work, no follow-up. Land it and move to Phase 4.

**Out of scope:** Ollama as an *LLM provider*
(`configure_api_key("ollama", ...)` in `lib/jido_claw/cli/setup.ex:134`).
This sprint only strips local *embedding* support.

---

## 1. Strip local embedding support

Voyage is the only embedding provider. `Workspace.embedding_policy`
and `Workspace.consolidation_policy` both become `:default | :disabled`.
The `embedding_model` column on `Solution` and `Memory.Fact` goes away
(the constant `"voyage-4-large"` adds no information that
`embedding IS NOT NULL AND embedding_status = 'ready'` doesn't already
encode).

**Delete entirely:**
- `lib/jido_claw/embeddings/local.ex`

**Edit (drop `:local_only`, drop local-model branches, drop
`embedding_model` column references):**
- `lib/jido_claw/workspaces/resources/workspace.ex` —
  `embedding_policy` (~line 91, 161) + `consolidation_policy`
  (~line 102, 168) constraints; `set_embedding_policy` /
  `set_consolidation_policy` argument constraints; module doc.
- `lib/jido_claw/workspaces/policy_transitions.ex` — collapse
  `apply_embedding/3` to a single `:default` arm that resets
  `:disabled` rows to `:pending` and clears backoff. **No
  `target_model` comparison** — once the column is gone there is
  no model to compare. The fix is a row-status reset, not a
  model swap. Drop lines 7-15 transition table doc; drop
  `aggregate_consolidation_policy` SQL `'local_only' THEN 1`
  arm at lines 167/185.
- `lib/jido_claw/embeddings/policy_resolver.ex` — drop
  `:local_only` from policy type, drop
  `model_for_query/storage` `:local_only` clauses, drop
  `coerce("local_only")` clauses, drop `default_local_model/0`.
- `lib/jido_claw/embeddings/backfill_worker.ex` — drop the
  `:local_only -> embed_via_local(...)` branch (~line 281), drop
  `embed_via_local/3` (~lines 322-333), drop `:local_module`
  test seam, drop `embedding_model` from the worker's UPDATE
  columns and `on_success/4` (line 342).
- `lib/jido_claw/embeddings/rate_pacer.ex` — moduledoc only.
  The existing `maybe_warn_unconfigured/1`
  (`rate_pacer.ex:380-385`) only warns when an API key is set
  but rate config is missing — it is not a missing-key warning.
  No change to that behavior; the boot guard in §2 owns the
  missing-key signal.
- `lib/jido_claw/embeddings/voyage.ex` — keep per-call
  `{:error, :missing_api_key}` (defense in depth); the boot
  guard in §2 turns it into a "should never happen" branch in
  prod/dev.
- `lib/jido_claw/solutions/matcher.ex` — drop
  `compute_for_model("mxbai-embed-large", _, _)`, drop
  `compute_local/3`, drop `%{provider: :local, ...}` branch in
  `resolve_embedding/3`, drop `:local_module` opt; collapse
  `compute_for_model/3` to a single Voyage clause; moduledoc
  bullet list at lines 36-46. The existing `query_embedding`
  opt at line 150 stays — it's reused by the new `:search`
  action (§7).
- `lib/jido_claw/memory/retrieval.ex` — same shape as Matcher.
- `lib/jido_claw/memory/consolidator/policy_resolver.ex`
  (lines 19, 65) — drop the `:local_only` arm of `decide/1`
  since `consolidation_policy` no longer accepts it; the
  `consolidation_local_runner_unavailable` skip-string goes
  away.
- `lib/jido_claw/solutions/hybrid_search_sql.ex` — drop the
  `embedding_model = $11` filter and the `$11` parameter
  binding; rebind to 11 placeholders. Same edits in
  `lib/jido_claw/memory/hybrid_search_sql.ex`.
- `lib/jido_claw/solutions/resources/solution.ex` — drop the
  `embedding_model :string` attribute (~line 344); drop from
  `:store` / `:import_legacy` / `:transition_embedding_status`
  accept lists; `Changes.ResolveInitialEmbeddingStatus` cond at
  ~line 543 collapses to `policy == :default`.
- `lib/jido_claw/solutions/network_facade.ex` — **keep**
  `:embedding_model` in `@forced_inbound_keys` at lines 20-35.
  Even after the column is gone, legacy peers on older versions
  may include it in their share payloads. Keeping it in the
  drop list prevents unknown-input errors and costs nothing.
- `lib/jido_claw/memory/resources/fact.ex` — same as Solution
  (`embedding_model` attribute, accept lists,
  `ResolveInitialEmbeddingStatus`).
- `lib/jido_claw/cli/repl.ex` — drop
  `normalize_policy("local_only")` + the
  `p in [:default, :local_only, :disabled]` guard
  (~lines 591-595).
- `lib/jido_claw/cli/commands.ex` — `/workspace embedding|consolidation`
  parser at ~lines 1167-1230: drop `local_only` from both
  branches, update error string and usage banner.
- `lib/jido_claw/cli/setup.ex` — see §2 for the Voyage prompt
  the embedding prompt is removed entirely (programmatic
  stamp), and the consolidation prompt collapses to Y/N.

**Tests to delete or simplify:**
- `test/jido_claw/embeddings/policy_resolver_test.exs` — drop the
  `:local_only` cases at lines 45-48, 69-74, 87-92.
- `test/jido_claw/solutions/matcher_test.exs` — drop the
  `model_for_query(:local_only)` clause in `StubResolver` at
  lines 31-36.
- `test/jido_claw/memory/consolidator/policy_resolver_test.exs` —
  drop the `:local_only` test at lines 59-72.
- `test/jido_claw/workspaces/workspace_test.exs` — drop
  `set_consolidation_policy(.., :local_only)` test at lines 59-61.
- `test/support/jido_claw/solutions_case.ex` — drop the
  `:embedding_model` keyword from the fixture builder at lines
  75 and 95.
- `test/jido_claw/memory/retrieval_test.exs` — drop the
  `embedding_model: "voyage-4-large"` arguments from fixtures at
  lines 108, 126, 137, 144, 316. The "explicit embedding_model"
  test at line 108 becomes "ANN hits even when FTS+lex miss"
  with no model arg.

### 1.1 Migration: clear bad vectors, drop `embedding_model`, rebuild HNSW

Generated via `mix ash.codegen v062_strip_local_embeddings` so the
filename is timestamped (e.g.
`priv/repo/migrations/20260506HHMMSS_v062_strip_local_embeddings.exs`)
and the matching `priv/resource_snapshots/` files update in the
same commit.

The migration body (hand-edited after codegen):

1. **Clear non-Voyage vectors first, joined to workspace
   policy.** Without this, old `mxbai-embed-large` embeddings
   survive and the Voyage-only ANN query ranks against
   incompatible vector-space rows. Set status by the workspace
   policy so disabled-policy rows don't get re-enqueued by the
   backfill worker:
   ```sql
   UPDATE solutions s
     SET embedding = NULL,
         embedding_status = CASE
           WHEN w.embedding_policy = 'default' THEN 'pending'
           ELSE 'disabled'
         END,
         embedding_attempt_count = 0,
         embedding_next_attempt_at = NULL,
         embedding_last_error = NULL
     FROM workspaces w
     WHERE s.workspace_id = w.id
       AND s.embedding_model IS DISTINCT FROM 'voyage-4-large'
       AND s.embedding IS NOT NULL;
   ```
   Same shape against `memory_facts`. The `:default` →
   `:pending` rows get picked up by the backfill worker after
   migration; the `:disabled` rows stay quiet until the
   workspace flips its policy. After this, the column is safe
   to drop.

2. **Defensive policy reset:**
   ```sql
   UPDATE workspaces SET embedding_policy = 'disabled'
     WHERE embedding_policy = 'local_only';
   UPDATE workspaces SET consolidation_policy = 'disabled'
     WHERE consolidation_policy = 'local_only';
   ```

3. **Drop ALL HNSW indexes that reference `embedding_model`
   BEFORE the column drop.** Postgres auto-drops any index whose
   predicate references a dropped column, so issuing
   `DROP INDEX solutions_embedding_voyage_hnsw_idx` *after* the
   `ALTER TABLE ... DROP COLUMN` would fail with "index does not
   exist." Drop both proactively, with `IF EXISTS` for idempotency
   on partial replays:
   ```sql
   DROP INDEX IF EXISTS solutions_embedding_local_hnsw_idx;
   DROP INDEX IF EXISTS solutions_embedding_voyage_hnsw_idx;
   DROP INDEX IF EXISTS memory_facts_embedding_local_hnsw_idx;
   DROP INDEX IF EXISTS memory_facts_embedding_voyage_hnsw_idx;
   ```
   (Verify exact memory_facts index names in
   `priv/repo/migrations/20260504192923_v063_memory.exs:218-222`.)

4. **Drop the column:**
   - `ALTER TABLE solutions DROP COLUMN embedding_model`.
   - `ALTER TABLE memory_facts DROP COLUMN embedding_model`.

5. **Recreate the HNSW indexes as partial on the surviving
   columns** — the partial predicate matches the ANN query path
   (`embedding IS NOT NULL AND embedding_status = 'ready'` is
   already in the CTE), so the planner can use it without
   post-filtering:
   ```sql
   CREATE INDEX solutions_embedding_hnsw_idx
     ON solutions USING hnsw (embedding vector_cosine_ops)
     WHERE embedding IS NOT NULL AND embedding_status = 'ready';
   ```
   Same shape for `memory_facts`.

   **Rollback (`down/0`).** To make rollback safe, the order
   matters:
   1. Drop the new partial HNSW indexes
      (`*_embedding_hnsw_idx`).
   2. Re-add the `embedding_model` text column (nullable) on
      both `solutions` and `memory_facts`.
   3. Backfill `embedding_model = 'voyage-4-large'` for rows
      where `embedding IS NOT NULL` (this is the only model
      ever used post-migration; rows with surviving embeddings
      came from Voyage). Without this backfill, the
      recreated voyage HNSW indexes would be empty because
      their `WHERE embedding_model = 'voyage-4-large'`
      predicate would not match.
   4. Recreate the original
      `solutions_embedding_voyage_hnsw_idx` (with its
      `WHERE embedding_model = 'voyage-4-large'` predicate)
      and the parallel for `memory_facts`.
   5. Do **not** recreate the local mxbai indexes — there is no
      path to repopulate the column with
      `mxbai-embed-large` values, so the index would be
      permanently empty.

6. **Resource snapshots** under
   `priv/resource_snapshots/repo/solutions/` and
   `.../memory_facts/` get regenerated by `mix ash.codegen` in
   step 0 — commit them alongside the migration so
   `mix ash.codegen --check` stays clean.

---

## 2. Voyage credential — boot guard with first-run carve-out

### Constraint

`Mix.Task.run("app.start")` at `lib/mix/tasks/jidoclaw.ex:33` runs
the supervisor *before* `JidoClaw.CLI.Repl.start/1` invokes the
interactive setup. A naive guard inside `RatePacer.init/1` would
prevent the wizard from launching, so a brand-new install couldn't
capture the key in the first place.

`load_dotenv/0` at `lib/jido_claw/application.ex:291-308` reads
`.env` from `File.cwd!()` and `<cwd>/.jido/.env`, ignoring
`Application.get_env(:jido_claw, :project_dir)`. That means
`mix jidoclaw /some/project` may miss that project's `.env`. Fix
this **before** wiring the boot guard, so the guard reads from
the right `.env`.

### Design

**New module:** `lib/jido_claw/embeddings/boot_guard.ex` —
`assert_voyage_key_or_raise!/0` reads
`Application.get_env(:jido_claw, :embeddings_strict_boot, true)` and
`System.get_env("VOYAGE_API_KEY")`. Strict + unset → `RuntimeError`
with a one-line remediation message ("Set `VOYAGE_API_KEY` in
your environment or `.env`. If you need to run setup, invoke
`mix jidoclaw --setup`.").

**`load_dotenv/0` honors `project_dir` AND loads all matching
files.** `lib/jido_claw/application.ex:291-308` currently uses
`Enum.find_value` with first-match semantics, which silently
ignores `.jido/.env` whenever `.env` exists — only one of the
two ever loads. Both should be considered.

New shape:
```elixir
project_dir =
  Application.get_env(:jido_claw, :project_dir) || File.cwd!()
cwd = File.cwd!()

# Order: most-specific → least-specific. Each parser uses
# unset-only writes (System.put_env only when System.get_env
# returns nil), so earlier paths take precedence over later
# ones. Files that don't exist are silently skipped.
paths =
  [
    Path.join([project_dir, ".jido", ".env"]),
    Path.join(project_dir, ".env"),
    Path.join([cwd, ".jido", ".env"]),
    Path.join(cwd, ".env")
  ]
  |> Enum.uniq()                                 # cwd == project_dir dedupe

Enum.each(paths, fn path ->
  case File.read(path) do
    {:ok, content} ->
      parse_dotenv(content)
      Logger.debug("[JidoClaw] Loaded env from #{path}")

    _ ->
      :ok
  end
end)
```
`parse_dotenv/1` already does the unset-only write, so iterating
all paths in priority order produces the correct precedence
(first parser fills the slot; later parsers can't overwrite).
Project-dir paths take priority over cwd paths; both are
considered when they differ.

**Application start sequence** in
`lib/jido_claw/application.ex` `start/2`:
1. `load_dotenv()` (already at line 13, runs first).
2. `JidoClaw.Embeddings.BootGuard.assert_voyage_key_or_raise!()`.
3. `Supervisor.start_link/2`.

The guard is **skipped** when
`Application.get_env(:jido_claw, :first_run_setup_pending, false)`
is `true`. The setup-task arm sets that flag before invoking
`Mix.Task.run("app.start")`.

**Setup-task arm:** `lib/mix/tasks/jidoclaw.ex` adds an explicit
`--setup` arm:
```elixir
def run(["--setup" | args]) do
  project_dir = JidoClaw.Startup.resolve_project_dir_from_argv(args)
  Application.put_env(:jido_claw, :project_dir, project_dir)
  Application.put_env(:jido_claw, :first_run_setup_pending, true)
  Mix.Task.run("app.start")
  JidoClaw.CLI.Setup.run(project_dir)
  IO.puts("Setup complete — restart with `mix jidoclaw`.")
end
```

**Escript-path mirror:** `lib/jido_claw/cli/main.ex:17` — the
`main(["--setup" | args])` arm currently delegates back to
`main(args)` which boots the app and starts the REPL. Replace
with a dedicated setup path that mirrors the Mix task arm:
```elixir
def main(["--setup" | args]) do
  project_dir = JidoClaw.Startup.resolve_project_dir_from_argv(args)
  Application.put_env(:jido_claw, :project_dir, project_dir)
  Application.put_env(:jido_claw, :first_run_setup_pending, true)
  Application.ensure_all_started(:jido_claw)
  JidoClaw.CLI.Setup.run(project_dir)
  IO.puts("Setup complete — restart with the binary or `mix jidoclaw`.")
  :ok
end
```
The escript exits after setup completes; the user re-invokes
the binary without `--setup` and the boot guard fires. Same
contract as the Mix task arm.

**Wizard captures Voyage key independently of LLM provider —
strict contract.** Today `lib/jido_claw/cli/setup.ex` only
captures the LLM provider's key (line 140-156,
`configure_api_key/2`). Add an **explicit** `prompt_voyage_key/0`
step that runs **regardless of LLM provider choice** — including
when the LLM provider is Ollama and the loop at line 134 returns
early.

Logic:
1. If `System.get_env("VOYAGE_API_KEY")` is set (already in
   shell env from a prior setup or external config), skip the
   prompt; the wizard considers this acceptance. The key is
   not re-written to `.env` — the env source is authoritative.
2. Otherwise, prompt for the key. If supplied:
   a. Write it to `.env` (atomic merge per the writer rules
      below).
   b. Also `System.put_env("VOYAGE_API_KEY", key)` so any
      subsequent steps in the same setup process see the key
      (the app is already running with the guard bypassed;
      later steps may reasonably call `System.get_env/1`).
3. If the user enters nothing, setup **exits with a non-zero
   status** and a message: `"VOYAGE_API_KEY is required.
   Either provide it now or set it in shell env / .env and
   re-run \`mix jidoclaw --setup\`. To run jido_claw without
   embeddings, set \`config :jido_claw, :embeddings_strict_boot,
   false\` in your config."` This is the strict contract: the
   §2 boot guard runs before any DB lookup, so a workspace-
   policy-aware bypass isn't viable. Hard-requiring the key at
   setup time keeps the boot path simple.

**Embedding policy is derived from Voyage-key presence — no
prompt.** Once the strict contract above guarantees the key is
present after a successful setup, there is no decision left to
make at the embedding-policy level. Delete
`pick_embedding_policy/0` from `lib/jido_claw/cli/setup.ex`
entirely. The wizard writes `embedding_policy: default` into
`.jido/config.yaml` (the existing config file
`build_config/3` produces). REPL startup
(`JidoClaw.Startup.ensure_project_state/1` and the workspace
resolver path) reads that config when registering the
Workspace row and stamps the value on the resource. No direct
Workspace write happens from `Setup.run/1` itself —
config-then-resolver matches the existing flow at
`lib/jido_claw/cli/setup.ex:209` (`build_config/3`) and the
resolver consumers downstream. Consolidation policy keeps its
explicit Y/N prompt (separate decision; opt-in by intent), and
its value lands in `.jido/config.yaml` the same way.

**`.env` merge semantics.** Two distinct precedence rules:

1. **At boot (read path):** shell env always wins. `load_dotenv/0`
   only fills variables that `System.get_env/1` reports as
   unset. This is unchanged from today — `parse_dotenv/1`
   already implements the unset-only write.
2. **At setup (write path):** the wizard's persistence to
   `.env` is **always deterministic** and ignores shell env.
   When the user explicitly enters a key, that key is written
   to the project's `.env` regardless of whether the variable
   is already exported in shell env — the wizard's job is to
   make the project file the authoritative source for next
   time. Shell env still wins at next boot, but the persisted
   value is recoverable across shells/sessions.

The writer must:
- Read the existing `<project_dir>/.env` if present.
- Parse line-by-line, preserving comments, blank lines, and
  ordering.
- For each key the wizard captures: update in place if the
  variable is already present, append at the end otherwise.
- Atomic write: write the new content to `<.env>.tmp` and
  `File.rename!/2` to replace, so a crash mid-write doesn't
  leave a partial file.

**Per-call defense:** `Voyage.embed_*/2` keeps returning
`{:error, :missing_api_key}` so non-strict tests fail gracefully
at the call site.

**Config:**
- `config/config.exs` — `config :jido_claw, :embeddings_strict_boot, true`.
- `config/test.exs` — `config :jido_claw, :embeddings_strict_boot, false`.

**Files touched:**
- New: `lib/jido_claw/embeddings/boot_guard.ex`.
- `lib/jido_claw/application.ex` — `load_dotenv/0` honors
  `project_dir`; guard call between `load_dotenv` and supervisor.
- `lib/mix/tasks/jidoclaw.ex` — `--setup` arm.
- `lib/jido_claw/cli/main.ex` — `--setup` mirrors the flag bypass.
- `lib/jido_claw/cli/setup.ex` — add `prompt_voyage_key/0`
  step (strict contract: required, exits if absent); **delete**
  `pick_embedding_policy/0` (~line 73) and stamp
  `embedding_policy: :default` programmatically; collapse
  `pick_consolidation_policy/0` (~line 87) to Y/N (drop the
  `[l]ocal-only` branch).
- `config/config.exs`, `config/test.exs`.

---

## 3. Consolidator `enabled: true` default

- `config/config.exs` ~line 278 — flip `enabled: false` to
  `enabled: true`.
- Delete the explanatory comment block at lines 267-270 that
  justified the divergence; the plan is right.

---

## 4. `harness_turns` wired from runner output

Plumb actual turn count from the runners into the consolidator
telemetry instead of the hardcoded `0`. **Three runners** must
emit `:turns` in their parser metadata so the Fake runner (used
by tests) drives the same code path as the real runners.

- `lib/jido_claw/forge/runners/claude_code.ex` —
  `parse_output/1` (~lines 110-134) accumulates `turns:` count
  alongside `tool_events`. A "turn" maps to lines whose
  `"type" == "assistant"`.
- `lib/jido_claw/forge/runners/codex.ex` — `parse_output/1`
  (~lines 172-192) accumulates `turns:` keyed on
  `"turn.completed"` events.
- `lib/jido_claw/forge/runners/fake.ex` — emit `turns: <n>` in
  result metadata so test fixtures can pin a specific count.
- `lib/jido_claw/memory/consolidator/run_server.ex`:
  - Add `harness_turns` (default `0`) to the `defstruct` at
    line ~44.
  - In the `{:ok, result_map}` clause at ~line 250, capture
    `result_map[:metadata][:turns] || 0` onto state.
  - In `emit_run_telemetry/4` at ~line 1105, use
    `state.harness_turns` in place of the hardcoded `0`.

When the harness fails before emitting any turns
(`runner_unavailable`, `no_credentials`, etc.), `harness_turns`
stays `0` — that's correct semantics, not a placeholder.

---

## 5. `:scope_busy` returns the atom externally; stringify internally

Callers see `{:error, :scope_busy}`; the `ConsolidationRun.error`
text column receives `"scope_busy"`. `finalise/3` at
`run_server.ex:1020-1027` currently writes the reason verbatim,
so it must stringify before persisting.

- `lib/jido_claw/memory/consolidator/run_server.ex:285` — change
  `finalise(state, :skipped, "scope_busy")` to
  `finalise(state, :skipped, :scope_busy)`.
- `run_server.ex` `finalise/3` (~line 1020) — accept either
  atom or binary; coerce `to_string/1` before writing the row's
  `error` column; reply tuple keeps the original reason so
  callers see `{:error, :scope_busy}`.
- `run_server.ex` `maybe_write_run_row/3` — same coercion at the
  `attrs.error = ...` site (depending on shape, may already
  flow through `finalise/3`).
- `lib/jido_claw/memory/consolidator.ex` `run_now/2` typespec —
  update to `{:ok, ConsolidationRun.t()} | {:error, :scope_busy | String.t()}`.
- `lib/jido_claw/cli/commands.ex:326` — match
  `{:error, :scope_busy}`. No other repo references; confirmed
  by grep.

---

## 6. `Memory.Link` relations enum drift

Plan §3.8 specifies `:related, :supports, :contradicts,
:supersedes, :elaborates`. The codebase currently ships
`:supports, :contradicts, :supersedes, :duplicates, :depends_on,
:related`. Three files declare or gate the enum:

- `lib/jido_claw/memory/resources/link.ex:34` — change
  `@relations` to the plan list. Update moduledoc bullets at
  lines 7-12.
- `lib/jido_claw/memory/consolidator/prompt.ex` — update the
  `@link_relations` module attribute (this is the source for the
  harness prompt).
- `lib/jido_claw/memory/consolidator/run_server.ex:41-42` —
  update `@link_relations` (binary list) and
  `@link_relations_atoms`. Without this, the consolidator's
  `propose_link` validator at `map_relation/1`
  (~lines 1010-1016) rejects `:elaborates` proposals.
- `test/jido_claw/memory/consolidator/prompt_test.exs:52` —
  update the assertion list.

**Defensive data migration** for any stray rows in case any
slipped through earlier development. The `v062_strip_local_embeddings`
migration (or a separate timestamped one paired with this
change) runs:
```sql
UPDATE memory_links
SET relation = 'related'
WHERE relation IN ('duplicates', 'depends_on');
```
Cheap and safe — re-mapping the dropped relations to
`:related` preserves the link itself, just with weaker
semantics. After this, `Memory.Link.relation` is constrained
to the new five-value set via Ash `one_of`. If existing rows
are left with the dropped values, future writes that hit the
`:create_link` action will fail validation, which is the
correct safety property — but the defensive update means
existing rows won't fail silent reads.

---

## 7. Add `:search` Ash action on `Solution` (manual read)

Wraps `HybridSearchSql.run/1` in an Ash manual read. Removes the
"D1" docstring drift from `solution.ex:13-23` and `matcher.ex:11`
(neither is a real plan callout — the comment references a
non-existent `D1` heading; the actual status quo is "the read
action wasn't built").

**New module:** `lib/jido_claw/solutions/reads/hybrid_search.ex`
implements `Ash.Resource.ManualRead`. `read/4`:
1. Lifts arguments via `Ash.Query.get_argument(query, :name)`
   (note: `get_argument`, not `argument`).
2. Calls `HybridSearchSql.run/1` with the 11-key map (post-§1
   binding count).
3. Filters by the `:threshold` argument *inside the manual* —
   drops rows whose `combined_score < threshold`. The action's
   threshold contract is enforced here, not in the SQL.
4. Returns `{:ok, [%Solution{} | ...]}` with each row carrying
   `Ash.Resource.put_metadata(sol, :combined_score, score)`.

**Resource declaration:** `lib/jido_claw/solutions/resources/solution.ex`
adds:
```elixir
read :search do
  manual JidoClaw.Solutions.Reads.HybridSearch

  argument :query, :string, allow_nil?: false
  argument :query_embedding, {:array, :float}, allow_nil?: true
  argument :language, :string
  argument :framework, :string
  argument :limit, :integer, default: 10
  argument :threshold, :float, default: 0.0
  argument :workspace_id, :uuid, allow_nil?: false
  argument :tenant_id, :string, allow_nil?: false
  argument :local_visibility, {:array, :atom},
    default: [:local, :shared, :public]
  argument :cross_workspace_visibility, {:array, :atom},
    default: [:public]
end
```

**Why `query_embedding`:** the manual read can't compute the
embedding — that requires the Voyage HTTP path which is
infrastructure, not resource logic. The caller (Matcher)
computes the embedding via `resolve_embedding/3` and passes it
through. Nullable so callers without an embedding (FTS-only
fall-through when Voyage is `:disabled`) still work.
`HybridSearchSql.run/1` already short-circuits the ANN pool
when `query_embedding` is nil (`hybrid_search_sql.ex:73` —
existing behavior).

**Defaults note:** `local_visibility` and
`cross_workspace_visibility` mirror the *current Matcher
behavior* (`[:local, :shared, :public]` and `[:public]`), **not**
the plan's empty-list `cross_workspace_visibility` default. The
Matcher's defaults are what callers depend on; the plan text
stale-drifted from the implementation.

**Code interface:** the existing `code_interface do` block at
`solution.ex:67` adds:
```elixir
define :search, action: :search
```
This makes `Solution.search/1` and `Solution.search!/1` callable.

**Caller migration:** `lib/jido_claw/solutions/matcher.ex`
`find_solutions/2` calls `Solution.search!(args, ...)` instead of
`HybridSearchSql.run/1` directly. Each result's score is read via
`Ash.Resource.get_metadata(sol, :combined_score)`. Existing
return shape `[%{solution: %Solution{}, combined_score: float}]`
is preserved at the *Matcher* layer by wrapping the manual-read
result back into the wrapper map shape, so `find_solution.ex` and
downstream callers don't break.

**Documentation:** delete the "D1" mentions at `solution.ex:13-23`
and `matcher.ex:11`.

---

## 8. Code gaps from the audit (rows 1-6)

### 8.1 `/memory blocks edit <label>` editor flow

`Block.revise(prior, attrs)` takes a `%Block{}` (or id) plus an
attrs map (`lib/jido_claw/memory/resources/block.ex:596`). The
CLI handler must:

1. Look up the active block at the resolved scope chain via
   `Memory.list_blocks_for_scope_chain/1`, find the row matching
   `label`.
2. **Decide same-scope vs override.** If the resolved block's
   `scope_kind` and FK match the current scope, invalidate-and-
   replace via `Block.revise(prior, %{value: new_value})`. If the
   block was inherited from a higher scope (e.g. user-scoped block
   visible at the session), call `Block.write/1` to create a new
   Block at the current scope with the same label — this is an
   override, not a revision; the ancestor stays valid for other
   scopes.
3. Open `$EDITOR` (default `vi`) on a tempfile preloaded with
   the current `value`. Read the file on save.
4. Validate `byte_size(new_value) <= prior.char_limit` before
   the action call; print an error if exceeded and allow re-edit.
5. Call the appropriate action; print the resulting block id.

Files:
- `lib/jido_claw/cli/commands.ex` — new
  `handle_blocks(["edit", label], state)` clause.
- `lib/jido_claw/cli/branding.ex` — add `/memory blocks edit
  <label>` to the help text.

Reuse `Block.revise/2` (same-scope) and `Block.write/1`
(override). No new domain code.

### 8.2 MCP "session" recording

The audit's recommendation to wire `JidoClaw.MCPServer` through
`JidoClaw.chat/4` was wrong. `mcp_server.ex` (lines 12-37) only
publishes tools via `use Jido.MCP.Server`; there is no
user-message dispatch in MCP stdio mode. Forcing one would
fabricate semantics that don't exist.

The correct approach is split into **two parts**:

**(a) `kind: :mcp` Session row at startup.** Reuse the existing
`lib/jido_claw/mcp_scope/initializer.ex` — that module already
resolves `tenant_id: "default"` and the cwd workspace at
`initializer.ex:33` via
`JidoClaw.Workspaces.Resolver.ensure_workspace("default", cwd)`
(note the actual signature is `ensure_workspace(tenant_id,
project_dir, opts \\ [])` — tenant first, project_dir second).
Extend the module to also call
`JidoClaw.Conversations.Resolver.ensure_session("default",
workspace.id, :mcp, "mcp_<inspect(node())>_<pid_int>")` and
merge the resulting `session_uuid` and `session_id` into the
scope map currently stashed under
`:jido_claw_mcp_default_scope` (lines 36-44).

**Convert initializer from `Task` to `GenServer` to fix the
startup race.** The current `use Task` /
`Task.start_link/1` returns to the supervisor *before*
`run/1` finishes — meaning `JidoClaw.MCPServer` (started later
in the supervision tree) can begin accepting MCP calls before
`:jido_claw_mcp_default_scope` is populated, and the very
first MCP tool would observe a missing scope. Convert the
module to `use GenServer` with all resolution work in
`init/1`; `init/1` returns `:ignore` after stashing the env
key. `Supervisor.start_link/2` blocks on each child's
`start_link` returning, so `init/1` synchronously completes
before the supervisor moves on to MCP server children. No new
module — just a shape change to the existing initializer.

Defense in depth: `MCPScope.wrap/4` (see (b) below) lazily
re-resolves the scope when
`Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)`
is missing or lacks `session_uuid`. This handles edge cases
where the initializer's own DB calls failed (e.g.,
transient connection issue) without blocking the MCP server
forever.

**(b) MCP tool-call Message rows** — *constrained by
`Jido.MCP.Server`'s extension surface*. The macro-defined
`init/2` and `handle_tool_call/3` are not overridable; only
`authorize/2` is. Frame `assigns` can carry context but stdio
transport doesn't set assigns. So full Message-row recording
requires a wrapper in JidoClaw code, not a Jido.MCP override.

The cleanest path that doesn't risk double-recording: extend
the existing `JidoClaw.Tools.MCPScope` helper
(`lib/jido_claw/tools/mcp_scope.ex`) with a `wrap/4` function
that tools call from `run/2`:

```elixir
@spec wrap(atom(), map(), map(), (map() -> any())) :: any()
def wrap(tool_name, params, context, fun)
```

Note the function arity: `fun` receives the **enriched** context
(post-`with_default/1`), so tools can read the resolved scope
without separately calling `with_default/1`. Tools like
`StoreSolution`/`FindSolution` that today open with
`context = MCPScope.with_default(context)` switch to
`MCPScope.wrap(:find_solution, params, context, fn context -> ... end)`
and read the enriched `context` directly.

The wrapper:

1. Calls `with_default(context)` to produce the enriched
   context map. If the resolved
   `tool_context.session_uuid` is missing (e.g., initializer
   failed silently), it lazily re-resolves by calling into the
   initializer's exposed
   `JidoClaw.MCPScope.Initializer.ensure_default_scope/0`
   helper, then re-reads. This keeps the MCP server resilient
   if the boot-time DB call hiccupped.
2. Hard-guards on
   `Application.get_env(:jido_claw, :serve_mode) == :mcp`
   AND the resolved `tool_context.session_uuid` being set.
   When either is false, the wrapper invokes
   `fun.(enriched_context)` and returns — no Message rows
   written. This prevents double-recording during normal agent
   runs where the Recorder's `ai.tool.*` signal path already
   produces rows.
3. Builds the `request_id` and `tool_call_id` for this call.
   By default both are fresh UUIDs (per-call). The wrapper
   accepts optional overrides via `context[:mcp_request_id]` /
   `context[:mcp_tool_call_id]` for callers that need stable
   IDs (retries, recovery). Each invocation of `wrap/4` is its
   own operation; "two calls = two pairs" is the intended
   semantic.
4. Appends a `:tool_call` Message row mirroring the recorder's
   `record_tool_call/1` (`recorder.ex:218-243`):
   - `content`: `ToolTranscript.summarize_args(tool_name, params)`
     — see the new shared helper module below.
   - `metadata`: `%{tool_name: tool_name, arguments: envelope}`
     where `envelope = ToolTranscript.envelope(params)`
     (which calls `TranscriptEnvelope.normalize/1` then
     `Transcript.redact/1`).
   - `tool_call_id`: per-call UUID (or override).
   - `session_id` / `tenant_id`: from enriched scope.
5. Invokes `result = fun.(enriched_context)`.
6. On normal return, appends a `:tool_result` row mirroring
   `record_tool_result/1` (`recorder.ex:249-285`):
   - `content`: `ToolTranscript.result_summary(tool_name, result)`.
   - `metadata`: `%{tool_name: tool_name, result: ToolTranscript.envelope(result)}`.
   - `parent_message_id`: the tool_call row's id (returned by
     step 4).
   - `tool_call_id`: same per-call UUID.
   - **Returns `result`** (the tool's value) — the wrapper's
     return is the tool's return, never `{:ok, message}`. The
     append helper's `{:ok, _}` is internal.
7. On exception, appends a `:tool_result` row with an error
   envelope (`metadata.result.error: error_string`),
   then re-raises with the original stacktrace via
   `reraise/2`. Persistence does not swallow the failure.
8. Both `Message.append/1` calls go through a helper that
   mirrors `Recorder.attempt_append/1` (`recorder.ex:422`):
   catches `Ash.Error.Invalid` for the
   `unique_live_tool_row` partial identity. On conflict, the
   helper looks up the existing row via a new
   `Conversations.Message` read action `:by_live_tool_row`
   that filters
   `session_id == ^session_id AND request_id == ^request_id
   AND tool_call_id == ^tool_call_id AND role == ^role`
   (this matches the partial identity's columns; existing
   `Message.tool_call_parent/3` at `recorder.ex:260` filters
   only on the call columns and returns the *parent*, not the
   already-written row of either role). Returns
   `{:ok, existing_message}`. The wrapper itself still
   returns the tool result, never the `{:ok, message}`
   tuple.

Tools opt in by wrapping their `run/2` body. Tools that
already emit `ai.tool.started`/`ai.tool.result` signals via
the agent path do not double-record because the agent path
doesn't fire under MCP serve mode (the agent isn't on the
call path — MCP dispatches the tool directly).

Files:
- `lib/jido_claw/mcp_scope/initializer.ex` — session ensure +
  `session_uuid`/`session_id` merged into the existing scope
  stash; converted from `use Task` to `use GenServer` with all
  resolution work in `init/1` (returns `:ignore` after
  stashing). Add a public `ensure_default_scope/0` helper that
  re-resolves and stashes when the env key is missing — used
  by the `MCPScope.wrap/4` lazy fallback.
- `lib/jido_claw/conversations/tool_transcript.ex` (new) —
  shared formatter helpers used by both the Recorder and the
  MCP wrapper:
  - `summarize_args(tool_name, params) :: String.t()` — one-line
    `"tool_name(arg=value, ...)"` summary; replaces
    `Recorder.summarize_args/1`.
  - `result_summary(tool_name, result) :: String.t()` — one-line
    result summary; replaces the inline `result_summary/2` in
    the recorder.
  - `envelope(payload) :: map()` — runs
    `TranscriptEnvelope.normalize/1` then
    `Security.Redaction.Transcript.redact/1`. Both Recorder and
    MCP wrapper call this instead of the two-step pipeline
    inline.
  Recorder updates to call into this module (`recorder.ex:225,
  227, 256, 268` swap to the helper); the existing private
  `summarize_args/1` and `result_summary/2` in the Recorder
  are removed in favor of the shared module — no public
  Recorder surface gets exposed.
- `lib/jido_claw/conversations/resources/message.ex` — new
  `read :by_live_tool_row` action with arguments
  `session_id`, `request_id`, `tool_call_id`, `role` and the
  filter
  `expr(session_id == ^arg(:session_id) and request_id ==
  ^arg(:request_id) and tool_call_id == ^arg(:tool_call_id)
  and role == ^arg(:role))`. Code interface exposes
  `Message.by_live_tool_row(session_id, request_id,
  tool_call_id, role)` for the wrapper's conflict-recovery
  path. (Existing `Message.tool_call_parent/3` at
  `recorder.ex:260` filters on the call columns and returns
  the *parent* row, not the already-written row of either
  role — different shape, can't be reused.)
- `lib/jido_claw/tools/mcp_scope.ex` — new `wrap/4` helper
  with the serve-mode/session_uuid hard guard.
- All MCP-published tool modules listed in
  `mcp_server.ex:16-36` — wrap their `run/2` body once via the
  new `MCPScope.wrap/4`. No new code paths in the tool itself,
  no double-record risk.

This is more work than the audit suggested; the audit
underestimated the MCP runtime extension surface. It's still
in scope — the §0 plan's `kind: :mcp` enum is meaningless
without it.

### 8.3 Telemetry columns on `Conversations.Message`

Plan §2.1 lists `run_id`, `model`, `input_tokens`,
`output_tokens`, `latency_ms` as first-class columns. The
recorder doesn't write user/assistant rows —
`Session.Worker.add_message/4`
(`platform/session/worker.ex:142-149`) does — so threading these
in requires a write-time path.

**Plumbing via `RequestCorrelation`.** The resource already
stores per-`request_id` scope; it's the natural place to also
stash per-request telemetry. Recorder writes telemetry to the
correlation row when `ai.llm.response` / `ai.request.completed`
fires; `Session.Worker.add_message` reads the correlation by
`request_id` before calling `Message.append` and merges the
fields.

**Critical race fix: don't destroy the correlation row in
`finalize_request`.** Today `recorder.ex:340-342` calls
`Cache.delete(request_id)` and then
`RequestCorrelation.complete(request_id)` (which is a `destroy`
action). Both fire on `ai.request.completed` /
`ai.request.failed` — *before* `Session.Worker.add_message`
appends the assistant row, because that happens after
`Recorder.flush/1` returns to the caller in `lib/jido_claw.ex`.
A naive read in `add_message` would miss both the cache and the
durable row.

Fix: drop the `RequestCorrelation.complete(request_id)` call
from `finalize_request/2`. The cache `delete` stays — the
recorder's own bookkeeping doesn't need the cache after flush.
The durable row is left for the
`RequestCorrelation.Sweeper` to handle on TTL expiry (10 min
default per `request_correlation.ex:23`). `add_message`'s
fallback read via `RequestCorrelation.lookup/1` (already
implemented at `request_correlation.ex:65`) finds the durable
row when the cache misses.

Storage cost: ~10 minutes of correlation rows per active
request. Bounded and trivial — at 1000 rps that's 600k rows
in flight; at the more realistic 0.1-1 rps for an interactive
agent, it's negligible. **Performance note:** because the cache
is deleted on `request.completed` but the assistant `add_message`
reads after flush returns, the assistant-row telemetry merge
typically hits Postgres rather than ETS. That's a single indexed
lookup per assistant turn, not the per-tool-signal hot path —
acceptable.

**Lifecycle docs need updating.** The current
`request_correlation.ex` moduledoc (lines 1-39) frames the
contract as "terminal request completion destroys the row." That
contract changes: terminal completion now only clears the cache;
expiry is sweeper-owned. Update the moduledoc to:
- Explain the new lifecycle: register at request start, telemetry
  merged into the row by the Recorder, cache cleared on
  terminal signal, durable row destroyed by Sweeper at TTL
  expiry.
- Note that downstream consumers (e.g.
  `Session.Worker.add_message`) read the durable row when the
  cache misses; the row's lifetime extends past completion to
  cover this lookup.

Tests under `test/jido_claw/conversations/request_correlation/`
that asserted "row destroyed on completion" must be updated to
assert "cache cleared on completion, row remains for Sweeper."

Changes:

- `lib/jido_claw/conversations/resources/request_correlation.ex` —
  - Add columns `run_id text`, `model text`,
    `input_tokens bigint`, `output_tokens bigint`,
    `latency_ms integer` (all nullable). Add to `:register`
    accept list as optional.
  - New `update :record_telemetry` action whose `accept` list
    contains **only** the five telemetry fields:
    `[:run_id, :model, :input_tokens, :output_tokens, :latency_ms]`.
    `request_id` is **not** in `accept` — it's the
    primary-key-style fetch key used by the code interface
    `get_by`, not a mutable field. Cross-tenant FK validation
    already in place.
  - Add to the `code_interface do` block:
    `define(:record_telemetry, action: :record_telemetry, get_by: [:request_id])`.
    The code interface's first positional arg becomes
    `request_id`; the second is the attrs map of telemetry
    fields. Recorder calls
    `RequestCorrelation.record_telemetry(request_id, telemetry_attrs)`.
- `lib/jido_claw/conversations/recorder.ex` —
  - The dispatch order matters:
    `ai.llm.response`/`ai.request.completed` handlers must
    record telemetry **before** `finalize_request/2` clears
    the cache. Today
    `handle_signal(%{type: "ai.request.completed"} = signal, state)`
    at lines 202-205 routes straight to `finalize_request/2`.
    Restructure to:
    1. Extract telemetry payload (model, input_tokens,
       output_tokens, latency_ms, run_id) from
       `signal.data` / `signal.data["metadata"]`.
    2. Call `RequestCorrelation.record_telemetry(request_id,
       telemetry_attrs)` to persist to the durable row.
    3. Update the ETS cache with the merged scope+telemetry
       map (`Cache.put(request_id, merged_scope)`) so a
       cache hit before `finalize_request` runs sees full
       data.
    4. Call `finalize_request/2` (which clears the cache).
    `ai.llm.response`'s existing reasoning-row write path
    (lines 197-200) stays intact; the telemetry recording is
    additive, runs alongside the reasoning write.
  - **Drop** the `RequestCorrelation.complete(request_id)`
    call in `finalize_request/2` at line 342. Cache `delete`
    stays. The durable row persists for `Sweeper` TTL
    expiry, and `Session.Worker.add_message`'s fallback read
    via `RequestCorrelation.lookup/1` finds it.
- `lib/jido_claw/platform/session/worker.ex:142-149` — extend
  the `handle_call({:add_message, role, content, request_id},
  ...)` to:
  1. `RequestCorrelation.Cache.lookup(request_id)` first.
  2. If cache hit but the cached map lacks telemetry fields
     (e.g., the row was registered before `record_telemetry`
     fired), fall through to
     `RequestCorrelation.lookup(request_id)` for the durable
     row.
  3. If cache miss, fall through to the durable lookup.
  4. Merge `{model, run_id, input_tokens, output_tokens,
     latency_ms}` into the `Message.append/1` attrs.
  In practice the cache is cleared on `request.completed`
  *before* the assistant `add_message` fires (because flush
  returns to the caller after completion), so the typical
  path is cache miss → Postgres lookup. The cache update in
  step 3 of the Recorder change above is for the rarer race
  where `add_message` fires *during* the request lifetime
  (e.g., partial assistant streaming). The cache-with-stale-
  data fallback handles the case where a cached scope-only
  entry exists from an `ai.tool.*` signal that ran before
  the LLM-response telemetry signal.
- `lib/jido_claw/conversations/request_correlation/cache.ex` —
  extend the stored shape (line 24-29) to include the
  telemetry fields; lookups continue to return the full map.
- `lib/jido_claw/conversations/resources/message.ex` — add
  attributes `run_id text`, `model text`, `input_tokens bigint`,
  `output_tokens bigint`, `latency_ms integer` (nullable). Add
  to the `:append` accept list.

### 8.4 `(request_id, role)` composite index on messages

Per plan §2.1.

- `lib/jido_claw/conversations/resources/message.ex` — add
  `index([:request_id, :role], where: "request_id IS NOT NULL", name: "messages_request_id_role_idx")`
  to the `custom_indexes do` block at lines 81-84. The explicit
  `name:` is set so the audit-named index is the actual
  identifier.

### 8.5 `Session.next_sequence` non-null

- `lib/jido_claw/conversations/resources/session.ex:217-221` —
  flip `allow_nil?(true)` to `allow_nil?(false)`. The migration
  generated for this change must also `ALTER COLUMN
  next_sequence SET NOT NULL` on the `conversation_sessions`
  table; if `mix ash.codegen` doesn't emit it, hand-add to the
  migration.

### 8.6 Migration for §8.3 / §8.4 / §8.5

`mix ash.codegen v062_message_telemetry_and_constraints`. The
migration must:

- Add the five telemetry columns to `messages` (note: the table
  is **`messages`**, not `conversation_messages` — see
  `message.ex:73`).
- Add the five telemetry columns to `request_correlations`.
- Add the partial composite index `messages_request_id_role_idx`.
- Set `conversation_sessions.next_sequence NOT NULL` (hand-add
  if codegen omits).
- Update resource snapshots under
  `priv/resource_snapshots/repo/{messages,request_correlations,conversation_sessions}/`.

---

## 9. Implementation gaps surfaced by acceptance tests

Two of the planned tests describe behavior that doesn't exist
yet. The implementation ships before the test:

### 9.1 `shadowed_by` Ash metadata projection in retrieval

The §3.19 acceptance gate "combined precedence dedup" asserts
each kept row carries a `shadowed_by` list naming the duplicates
that were filtered out. `Memory.Fact` does **not** have a
general `:metadata` map column; this projection is response-only
data, not a schema change.

Implementation uses Ash's per-record metadata mechanism:

- `lib/jido_claw/memory/retrieval.ex` — extend the post-RRF
  scope+source dedup step. When merging duplicates with the same
  `label`, the kept `%Fact{}` gets
  `Ash.Resource.put_metadata(fact, :shadowed_by, [%{id: ..., scope_kind: ..., source: ...}, ...])`
  for every dropped duplicate. Tests read via
  `Ash.Resource.get_metadata(fact, :shadowed_by)`.
- `lib/jido_claw/memory/hybrid_search_sql.ex` — return the dropped
  rows alongside the kept ones (or surface them via an extra CTE)
  so `retrieval.ex` has the data to project.
- `dedup: :none` opt — when set, skip the dedup step entirely;
  return all rows, no metadata projected (each row's
  `Ash.Resource.get_metadata(fact, :shadowed_by)` returns `nil`).

No schema migration needed — `put_metadata`/`get_metadata` work
on any Ash resource record.

### 9.2 Round-trip exporter canonicalization

The §X.7 byte-equivalent gate requires the exporter to produce
deterministic JSON/JSONL output: sorted keys, ISO8601 timestamps
in fixed precision (microseconds), no pretty-printing, sorted
output rows by primary key.

Files:
- `lib/mix/tasks/jidoclaw.export.solutions.ex`
- `lib/mix/tasks/jidoclaw.export.conversations.ex`
- `lib/mix/tasks/jidoclaw.export.memory.ex`

Each task gains a canonicalization helper (or imports a shared
one from `JidoClaw.Export.Canonical`) that sorts JSON object keys
recursively, formats datetimes to a fixed precision, and emits
rows in deterministic order. Without this, the round-trip
acceptance tests are flaky and useless.

The corresponding `migrate` tasks
(`jidoclaw.migrate.{solutions,conversations,memory}.ex`) are
read-only on input shape — no change needed unless they have
their own non-determinism, which they shouldn't.

---

## 10. Acceptance tests — author all of them

Every §X.7 / §3.19 gate that the audit found unauthored ships in
this sprint. No bucketing, no deferral.

**Cross-tenant FK regressions**:
- `test/jido_claw/solutions/solution_test.exs` (new) — two-tenant
  workspace mismatch on `:store`, two-tenant session mismatch on
  `:store`, same on `:import_legacy`. Pin `:cross_tenant_fk_mismatch`.
- `test/jido_claw/conversations/message_test.exs` — cross-session
  A/B mismatch on `:import` (the migrator-specific risk).

**Soft-delete leakage**: `test/jido_claw/solutions/solution_test.exs` —
deleted row excluded from every public read action; `:with_deleted`
toggle includes it.

**Concurrent sequence ordering**: `test/jido_claw/conversations/message_test.exs` —
50 concurrent `:append` under `Task.async_stream`, same session;
assert sequences monotonic, gap-free, no nils.

**`:scope_busy` concurrency**: `test/jido_claw/memory/consolidator/run_server_test.exs` —
race two `Consolidator.run_now/1` calls against the same scope;
assert `{:ok, run}` and `{:error, :scope_busy}` (atom).

**Round-trip `import → export` byte-equivalent** (one per phase) —
fixtures generated by the exporter itself
(`import → export → snapshot`), then tests assert
`re-import → re-export` produces identical bytes:
- `test/mix/tasks/jidoclaw_solutions_export_test.exs`
- `test/mix/tasks/jidoclaw_conversations_export_test.exs`
- `test/mix/tasks/jidoclaw_memory_export_test.exs`
- Each test runs both a sanitized fixture (no §1.4 redaction
  patterns) and a redaction-delta fixture (asserts
  `<file>.redaction-manifest.json` matches actual redactions).

**Reputation import-ledger idempotency**:
`test/jido_claw/solutions/reputation_test.exs` (new) — re-running
`mix jidoclaw.migrate.solutions` is a no-op via
`(tenant_id, source_sha256)` ledger.

**Three-turn cache stability with mid-session Block write**:
`test/jido_claw/agent/prompt_snapshot_test.exs` — build snapshot,
simulate three turns of tool use, one mid-session `Block.revise`,
assert the snapshot is byte-identical across all three turns.

**`harness_turns` derivation**:
`test/jido_claw/memory/consolidator/run_server_test.exs` — feed
the Fake runner output with N synthetic assistant events + emit
`turns: N` in metadata; assert recorded telemetry's
`harness_turns` matches.

**Three-driver scope propagation**:
`test/jido_claw/workflows/scope_propagation_test.exs` — extend
the existing `SkillWorkflow` test as a parametrized test across
`SkillWorkflow.run/4`, `PlanWorkflow.run/4`,
`IterativeWorkflow.run/4`. Same echo-stub assertion shape.

**MCP scoped-server lifecycle**:
`test/jido_claw/memory/consolidator/run_server_test.exs` — assert
per-run Bandit endpoint shuts down on cleanup, port unbound, temp
files unlinked.

**Recorder restart resilience**:
`test/jido_claw/conversations/recorder_test.exs` — clear ETS
cache, emit `ai.tool.result`, assert the recorder rehydrates from
Postgres and writes the row.

**Recorder telemetry race regression** (new gate from §8.3):
`test/jido_claw/conversations/recorder_test.exs` —
- Emit a full turn (`ai.tool.started` → `ai.tool.result` →
  `ai.llm.response` → `ai.request.completed`), then call
  `Session.Worker.add_message(:assistant, ...)`. Assert the
  resulting Message row carries `model` / `input_tokens` /
  `output_tokens` / `latency_ms` / `run_id` from the
  signal payloads — i.e., the correlation row was *not*
  destroyed before the lookup.
- Telemetry-record-before-finalize ordering: emit
  `ai.request.completed` carrying telemetry; assert the
  durable `RequestCorrelation` row has the telemetry fields
  populated (proving telemetry was recorded before the
  `Cache.delete` cleared the cache).
- Cache-with-stale-data fallback: pre-populate the ETS cache
  with a scope-only entry (no telemetry); insert a durable
  row with telemetry; call `add_message`; assert the
  resulting Message row carries the durable row's
  telemetry, not the cache's stale (empty) values.

**Cron `start_system_jobs` registration**:
`test/jido_claw/memory/consolidator_system_jobs_test.exs` — boot,
query `Cron.Scheduler.list_jobs("system")`, assert
`memory_consolidator` registered with expected cadence.

**Tool envelope `arguments` vs `result` regression**:
`test/jido_claw/conversations/recorder_test.exs` — emit
`ai.tool.started` with `arguments`, then `ai.tool.result` with
`result`; assert the Message rows carry the correct field shape.

**Double-fire dedup on `unique_live_tool_row`**:
`test/jido_claw/conversations/recorder_test.exs` — emit the same
`tool_result` twice for the same `(request_id, tool_call_id)`;
assert exactly one Message row.

**TTL sweep eviction**:
`test/jido_claw/conversations/request_correlation/sweeper_test.exs` —
insert backdated `expires_at`; run sweep; assert row deleted.

**Trigram index plan stability**:
`test/jido_claw/memory/lexical_index_test.exs` (new) — three
independent assertions, each diagnostic on its own:

1. **Index existence** — query `pg_indexes` for
   `memory_facts_lexical_text_trgm_idx`; assert it exists. This
   is the cheapest, most stable check; if it fails, the
   migration regressed.
2. **Plan choice on large fixture** — insert ≥1000 facts so the
   planner doesn't prefer seq scan; `SET LOCAL enable_seqscan = off`
   inside the test transaction; run
   `EXPLAIN (FORMAT JSON)` (no `ANALYZE` — plan shape is
   sufficient). Parse the **entire** plan tree (recurse `Plans`
   children), find any `Bitmap Index Scan` whose `Index Name`
   matches; assert at least one. Failure includes the full plan
   in the assertion message so a regression doesn't require
   re-running locally to diagnose.
3. **Query correctness** — same large fixture; run a substring
   query through the public retrieval path; assert the expected
   rows come back. This is the user-visible contract; even if
   the planner heuristic shifts on a future PG version, the
   user-visible behavior stays pinned.

The split makes failures self-explanatory: an index drop fails
(1); a planner regression fails (2); a query regression fails
(3). Brittle planner-only tests are the antipattern this avoids.

**Combined precedence dedup tests** (depends on §9.1 implementation):
`test/jido_claw/memory/retrieval_test.exs` — assert
`metadata.shadowed_by[]` projection on kept rows; assert
`dedup: :none` returns all candidates without merging; combined
scope+source precedence (closer scope wins, then source rank).

**Bitemporal `{:full_bitemporal, w, s}` matrix**:
`test/jido_claw/memory/retrieval_test.exs` — four-cell matrix
product test (current/world-time × current/system-time); assert
each cell returns the correct row set.

**`max_turns_reached` failure path**:
`test/jido_claw/memory/consolidator/run_server_test.exs` — Fake
runner script that advances turns without ever calling
`commit_proposals`; assert `ConsolidationRun.status: :failed,
error: "max_turns_reached"`.

**Voyage boot guard**:
`test/jido_claw/embeddings/boot_guard_test.exs` (new) — with
`embeddings_strict_boot: true` and unset key, assert
`BootGuard.assert_voyage_key_or_raise!/0` raises; with the flag
unset, assert no-op; with `first_run_setup_pending: true`, assert
the `application.ex` start path skips the guard.

**`load_dotenv` honors `project_dir`** (new gate from §2):
`test/jido_claw/application_test.exs` (or a focused test on the
helper) — set `project_dir` to a fixture path containing a
`.env`, call the helper, assert the env var is loaded; assert
fallback to `cwd` when `project_dir` is unset.

**MCP session creation**:
`test/jido_claw/mcp_scope/initializer_test.exs` — boot the
initializer; assert a `Conversations.Session` row with
`kind: :mcp` exists with the per-process `external_id`; assert
`Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)`
contains `:session_uuid` and `:session_id` populated from the
new row.

**MCP tool wrap behavior**:
`test/jido_claw/tools/mcp_scope_test.exs` —
- Call `MCPScope.wrap/4` outside MCP serve mode; assert it's
  a no-op pass-through (no Message rows written, function
  result is returned).
- Set `:serve_mode = :mcp` and ensure a default scope; call
  `wrap/4` once; assert exactly one `:tool_call` and one
  `:tool_result` Message row, both tied to the MCP
  `session_uuid`, both carrying the same per-call
  `request_id`/`tool_call_id`, with `parent_message_id` on
  the result row pointing at the call row.
- Call `wrap/4` twice with the same `(tool_name, params)`;
  assert **two** distinct `(tool_call, tool_result)` pairs
  with **distinct** `request_id` / `tool_call_id` UUIDs (the
  default fresh-IDs-per-call semantic; each invocation is
  its own operation).
- Call `wrap/4` once passing explicit
  `context[:mcp_request_id]` and `context[:mcp_tool_call_id]`,
  then call again with the **same** override IDs; assert the
  second call's `Message.append` attempts hit the
  `unique_live_tool_row` identity and return the existing
  row (idempotent). This pins the
  `attempt_append`-mirroring no-op behavior; matches
  `Recorder.attempt_append/1` at `recorder.ex:422`.
- Verify row shape parity with recorder-written rows:
  the MCP-written `tool_call` has `metadata.tool_name` and
  `metadata.arguments` keys (envelope-shaped), the
  `tool_result` has `metadata.tool_name` and
  `metadata.result`, and `content` is a one-line summary in
  both cases — same shape as
  `recorder.ex:218-243`/`249-285` produces.

**Embedding-space isolation gate** — *removed* from the backlog.
The Voyage-only world makes it moot.

---

## 11. Critical files to modify

Source:

- `config/config.exs`, `config/test.exs`
- `lib/jido_claw/application.ex`
- `lib/jido_claw/cli/branding.ex`
- `lib/jido_claw/cli/commands.ex`
- `lib/jido_claw/cli/main.ex`
- `lib/jido_claw/cli/repl.ex`
- `lib/jido_claw/cli/setup.ex`
- `lib/jido_claw/conversations/recorder.ex`
- `lib/jido_claw/conversations/request_correlation/cache.ex`
- `lib/jido_claw/conversations/resources/message.ex` (new
  `:by_live_tool_row` read action; new telemetry columns;
  partial composite index)
- `lib/jido_claw/conversations/tool_transcript.ex` (new
  shared envelope/summary helpers used by Recorder + MCP
  wrapper)
- `lib/jido_claw/conversations/resources/request_correlation.ex`
- `lib/jido_claw/conversations/resources/session.ex`
- `lib/jido_claw/embeddings/backfill_worker.ex`
- `lib/jido_claw/embeddings/boot_guard.ex` (new)
- `lib/jido_claw/embeddings/local.ex` (delete)
- `lib/jido_claw/embeddings/policy_resolver.ex`
- `lib/jido_claw/embeddings/rate_pacer.ex`
- `lib/jido_claw/embeddings/voyage.ex`
- `lib/jido_claw/forge/runners/claude_code.ex`
- `lib/jido_claw/forge/runners/codex.ex`
- `lib/jido_claw/forge/runners/fake.ex`
- `lib/jido_claw/mcp_scope/initializer.ex`
- `lib/jido_claw/memory/consolidator.ex`
- `lib/jido_claw/memory/consolidator/policy_resolver.ex`
- `lib/jido_claw/memory/consolidator/prompt.ex`
- `lib/jido_claw/memory/consolidator/run_server.ex`
- `lib/jido_claw/memory/hybrid_search_sql.ex`
- `lib/jido_claw/memory/resources/fact.ex`
- `lib/jido_claw/memory/resources/link.ex`
- `lib/jido_claw/memory/retrieval.ex`
- `lib/jido_claw/platform/session/worker.ex`
- `lib/jido_claw/solutions/hybrid_search_sql.ex`
- `lib/jido_claw/solutions/matcher.ex`
- `lib/jido_claw/solutions/network_facade.ex` (keep
  `:embedding_model` in the drop list)
- `lib/jido_claw/solutions/reads/hybrid_search.ex` (new)
- `lib/jido_claw/solutions/resources/solution.ex`
- `lib/jido_claw/tools/mcp_scope.ex` (new `wrap/4` helper)
- MCP-published tool modules (every entry in
  `lib/jido_claw/core/mcp_server.ex:16-36`):
  `read_file.ex`, `write_file.ex`, `edit_file.ex`,
  `list_directory.ex`, `search_code.ex`, `run_command.ex`,
  `git_status.ex`, `git_diff.ex`, `git_commit.ex`,
  `project_info.ex`, `run_skill.ex`, `store_solution.ex`,
  `find_solution.ex`, `network_share.ex`, `network_status.ex` —
  each wraps its `run/2` body once via
  `JidoClaw.Tools.MCPScope.wrap(tool_name, params, context, fn enriched_context -> ... end)`
- `lib/jido_claw/workspaces/policy_transitions.ex`
- `lib/jido_claw/workspaces/resources/workspace.ex`
- `lib/mix/tasks/jidoclaw.ex`
- `lib/mix/tasks/jidoclaw.export.solutions.ex`
- `lib/mix/tasks/jidoclaw.export.conversations.ex`
- `lib/mix/tasks/jidoclaw.export.memory.ex`
- `lib/jido_claw/export/canonical.ex` (new — shared canonicalization helper)

Migrations (timestamped via `mix ash.codegen`):
- `<ts>_v062_strip_local_embeddings.exs`
- `<ts>_v062_message_telemetry_and_constraints.exs`

Resource snapshots (regenerated by codegen, committed):
- `priv/resource_snapshots/repo/solutions/`
- `priv/resource_snapshots/repo/memory_facts/`
- `priv/resource_snapshots/repo/messages/`
- `priv/resource_snapshots/repo/request_correlations/`
- `priv/resource_snapshots/repo/conversation_sessions/`
- `priv/resource_snapshots/repo/workspaces/`
- `priv/resource_snapshots/repo/memory_links/`

---

## 12. Existing functions to reuse

- `Memory.Block.revise/2` — same-scope edit path;
  `Block.write/1` for override-from-ancestor.
- `Memory.list_blocks_for_scope_chain/1` — looks up the visible
  block at the current scope.
- `Solutions.HybridSearchSql.run/1` — wrap, don't rewrite. The
  existing `:query_embedding` map key (line 73) carries through
  the new `:search` action argument.
- `Conversations.Resolver.ensure_session/4` — used for MCP
  session init.
- `RequestCorrelation.lookup/1` (durable) and
  `RequestCorrelation.Cache.lookup/1` (ETS) — telemetry merging
  at `Session.Worker.add_message`.
- `RequestCorrelation.Sweeper.sweep_expired/0` — handles cleanup
  of correlation rows that the recorder no longer destroys
  eagerly.
- `Forge.Runners.Fake` — drives `:scope_busy`, `harness_turns`,
  `max_turns_reached` tests deterministically.
- `Cron.Scheduler.list_jobs/1` — system-jobs registration test.

---

## 13. Verification

**After every change:**
```
mix format --check-formatted
mix compile --warnings-as-errors
mix ash.codegen --check
```

**Migrations apply cleanly from scratch:**
```
mix ecto.reset
```
Confirm:
- `embedding_model` column gone from `solutions` and
  `memory_facts`.
- `solutions_embedding_local_hnsw_idx` and
  `memory_facts_embedding_local_hnsw_idx` gone.
- Recreated partial HNSW indexes on the surviving column with
  the new predicate
  `WHERE embedding IS NOT NULL AND embedding_status = 'ready'`.
- `messages` has columns `run_id`, `model`, `input_tokens`,
  `output_tokens`, `latency_ms` plus partial composite index
  `messages_request_id_role_idx`.
- `request_correlations` carries the same telemetry columns.
- `conversation_sessions.next_sequence` is `NOT NULL`.
- `Workspace.embedding_policy` and `consolidation_policy` only
  accept `:default | :disabled`.
- `Memory.Link.relation` accepts only the plan's five values.

**Voyage boot guard:**
```
unset VOYAGE_API_KEY
iex -S mix
# expect: RuntimeError raised during application start; app
# does not boot.
mix jidoclaw --setup
# expect: app boots (flag suppresses guard); wizard runs;
# prompts for Voyage key independently of LLM provider choice;
# writes prompted keys to .env (env-provided keys are
# accepted as already configured and not re-written);
# also calls System.put_env in-process; writes
# embedding_policy: default into .jido/config.yaml; prints
# "restart" message; exits.
mix jidoclaw
# expect: boots cleanly with the captured key.
mix jidoclaw /some/other/project
# expect: load_dotenv reads /some/other/project/.env (and
# .jido/.env) before falling back to cwd.
MIX_ENV=test mix test
# expect: bypasses guard via :embeddings_strict_boot, false.
```

**Test suite:**
```
mix test
```
All green. Every test enumerated in §10 passes deterministically.
No skipped tests, no `@tag :skip` left behind.

**Manual smoke:**
- `mix jidoclaw --setup` — wizard prompts for Voyage key
  independently of the LLM provider chosen; if the user
  declines (or supplies an empty key), setup exits with a
  non-zero status and the strict-contract message. When
  setup succeeds, `embedding_policy` is stamped `:default`
  programmatically (no prompt). Consolidation prompt offers
  Y/N only.
- `/workspace embedding default` works; `/workspace embedding
  local_only` errors with the new usage banner; same for
  `/workspace consolidation`.
- `/memory blocks edit <label>` — opens `$EDITOR`, saves a
  revision; the override path correctly creates a new
  same-scope row when editing an inherited block.
- `/memory consolidate` — runs immediately (consolidator default
  is now `enabled: true`).
- Run two `/memory consolidate` calls in parallel against the
  same scope: one succeeds, the other prints "consolidation
  already running for this scope" (the atom-matched CLI branch).
- Tail telemetry events for
  `[:jido_claw, :memory, :consolidator, :run]` —
  `harness_turns` reflects actual count, not zero.
- Connect via MCP stdio (`mix jidoclaw --mcp`) — confirm a
  `Conversations.Session` row with `kind: :mcp` appears, and
  invoking an MCP tool (e.g. `read_file`) writes a corresponding
  pair of `tool_call`/`tool_result` Message rows tied to that
  session_uuid via the `MCPScope.wrap/4` helper. Confirm
  invoking the same tool from the REPL (non-MCP serve mode)
  produces only one set of rows via the recorder path — no
  double recording.
- `mix jidoclaw.export.solutions`, `.export.conversations`,
  `.export.memory` against a freshly-migrated DB produce
  byte-equivalent output to a prior export of the same data.
- A full LLM turn through the REPL produces a `messages` row
  whose `model`, `input_tokens`, `output_tokens`, `latency_ms`
  are populated (proving the §8.3 telemetry race fix).
- Solution retrieval via `Solution.search/1` returns ranked
  results with `:combined_score` available via
  `Ash.Resource.get_metadata/2`.
