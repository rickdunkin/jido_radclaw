# v0.6 Phase 3b — Code-review fix plan

## Context

Phase 3b shipped the memory consolidator (Forge harness + scoped MCP
tool surface + per-scope advisory lock + transactional publish). A
post-implementation review surfaced four substantive defects that
together prevent the consolidator from doing the work the plan calls
for. Mixed-priority:

- **P1**: a Forge bootstrap race makes every consolidator run flaky —
  reproducible: a Tidewave end-to-end fake-run probe wrote a `:failed`
  run row with `{:invalid_state, :bootstrapping}` and zero Blocks.
- **P1**: the `claude` CLI flag the runner emits (`--thinking-effort`)
  doesn't exist in the installed CLI (it's `--effort`) — every real
  `:claude_code` run will fail before doing any work.
- **P2**: staged `propose_link` and `propose_update` proposals are
  silently dropped — the model gets `:ok` tool responses but no row
  ever lands.
- **P2**: `tick`'s candidate discovery covers only `:workspace` and
  the load path lacks watermarks, so cadence runs reprocess the same
  facts forever and never see `:session` / `:user` / `:project`
  scopes.

All four are accurate. The fix below is sized to land Phase 3b in
the shape §3.15 actually called for.

---

## Issue 1 (P1) — Forge bootstrap race

**Root cause.** `Forge.Manager.start_session/2`
(`lib/jido_claw/forge/manager.ex:101-117`) goes through
`DynamicSupervisor.start_child`, which only waits for `Harness.init/2`
to return. `init/2` (`lib/jido_claw/forge/harness.ex:88-161`) does
`send(self(), :provision)` and returns with `state.state == :starting`.
Bootstrap then runs as a chain of self-sends:
`:provision → :bootstrap → :init_runner`, with `state` transitioning
through `:bootstrapping` (line 184) and `:initializing` (line 229)
before `:ready` (lines 268/283). Any `run_iteration` call before the
chain finishes hits the catch-all at `harness.ex:373-376` and returns
`{:error, {:invalid_state, <current>}}`.

Today, `RunServer.drive_harness/4`
(`lib/jido_claw/memory/consolidator/run_server.ex:343-355`) calls
`run_iteration` immediately after `start_session` returns — that's
the race.

**Fix.** Use the existing `Forge.PubSub` `:ready` broadcast (emitted
at `harness.ex:275` and `:290`). Subscribe **before** `start_session`
to avoid missing the broadcast, then wait on `{:ready, session_id}`
with a `Process.monitor` fallback for the harness-died case and a
hard timeout. **Critical:** once `start_session` has returned a pid,
the session must always be stopped — `await_ready` timeout, harness
DOWN during bootstrap, or any later raise/exit. Wrap the post-start
work in a `try/after`-style guard.

```elixir
# lib/jido_claw/memory/consolidator/run_server.ex (rewrite of drive_harness/4)
defp drive_harness(_parent, forge_session_id, spec, timeout_ms) do
  :ok = JidoClaw.Forge.PubSub.subscribe(forge_session_id)

  case JidoClaw.Forge.Manager.start_session(forge_session_id, spec) do
    {:ok, %{pid: pid}} ->
      try do
        with :ok <- await_ready(forge_session_id, pid, bootstrap_timeout(timeout_ms)),
             result <-
               JidoClaw.Forge.Harness.run_iteration(forge_session_id, timeout: timeout_ms) do
          result
        else
          {:error, reason} -> {:error, reason}
        end
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, inspect(reason)}
      after
        # Ready, timed-out, harness died, run_iteration crashed — every
        # exit path stops the Forge session. start_session succeeded so
        # the corresponding stop must always run.
        maybe_stop_forge_session(forge_session_id)
      end

    {:error, reason} ->
      {:error, reason}
  end
end

defp await_ready(session_id, pid, timeout) do
  ref = Process.monitor(pid)

  receive do
    {:ready, ^session_id} ->
      Process.demonitor(ref, [:flush])
      :ok

    {:DOWN, ^ref, :process, _, reason} ->
      {:error, "harness_died_during_bootstrap: #{inspect(reason)}"}
  after
    timeout ->
      Process.demonitor(ref, [:flush])
      {:error, "harness_bootstrap_timeout"}
  end
end

defp bootstrap_timeout(run_timeout_ms), do: min(run_timeout_ms, 60_000)

defp maybe_stop_forge_session(forge_session_id) do
  try do
    JidoClaw.Forge.Manager.stop_session(forge_session_id, :normal)
  catch
    _, _ -> :ok
  end
end
```

Subscribe lands before `start_session` because `Phoenix.PubSub.subscribe/2`
is synchronous — once it returns, we won't miss a broadcast even if
bootstrap completes inside the same scheduler quantum.

**File:** `lib/jido_claw/memory/consolidator/run_server.ex` — replace
`drive_harness/4` (lines 343–355) and add `await_ready/3`,
`bootstrap_timeout/1`, `maybe_stop_forge_session/1` private helpers.

---

## Issue 2 (P1) — Wrong Claude CLI flag

`claude --help` on the installed CLI exposes
`--effort <level>` (values `low|medium|high|xhigh|max`). The runner
emits `--thinking-effort` instead at
`lib/jido_claw/forge/runners/claude_code.ex:92-94`. Default config
sets `thinking_effort: "xhigh"`, so every real `:claude_code` run
exits non-zero before doing MCP work. Verified locally:
`claude --help` only documents `--effort`.

**Fix.** One-line change in
`lib/jido_claw/forge/runners/claude_code.ex` —
`append_thinking_effort/2`'s emit becomes `["--effort", effort]`.
The `xhigh` value passes through unchanged.

```elixir
# lib/jido_claw/forge/runners/claude_code.ex:92-94
defp append_thinking_effort(args, %{thinking_effort: effort})
     when is_binary(effort) and effort != "",
     do: args ++ ["--effort", effort]
```

The function name (`append_thinking_effort`) stays — semantics
haven't changed; only the CLI's spelling did.

---

## Issue 3 (P2) — Dropped link / update proposals

Two distinct dropped-proposal bugs in
`lib/jido_claw/memory/consolidator/run_server.ex`:

### 3a. `propose_link` is staged but never applied

`apply_proposals/1` at `run_server.ex:449-462` hard-codes
`links_added: 0` and there is no `apply_link_creates/1` helper —
the `state.staging.link_creates` list is read by nobody.

**Fix.** Add an apply helper that calls
`JidoClaw.Memory.Link.create_link/1` for each staged proposal.
`Memory.Link.create_link` (`lib/jido_claw/memory/resources/link.ex:48`)
auto-denormalizes scope from `from_fact` and rejects cross-tenant /
cross-scope edges in `before_action`. Three wrinkles:

- The MCP tool schema (`tools/propose_link.ex:8-11`) accepts
  `relation` as a **string**, but the resource constrains it to
  `:supports | :contradicts | :supersedes | :duplicates |
  :depends_on | :related` (atoms). Convert with an explicit allowlist
  — never `String.to_atom` on tool input — and skip unknowns.
- The current schema only accepts `from_fact_id` / `to_fact_id` /
  `relation` — extend it to also accept `reason` (string, optional)
  and `confidence` (float, optional) so `apply_link_creates/1` has
  something to forward to `Link.create_link`. Plan §3.15's
  `propose_link(from_fact_id, to_fact_id, relation, reason)` signature
  expects `reason` to be present.
- `written_by` is left nilable; default to `"consolidator"` for
  audit hygiene.

```elixir
# lib/jido_claw/memory/consolidator/tools/propose_link.ex
schema: [
  from_fact_id: [type: :string, required: true],
  to_fact_id:   [type: :string, required: true],
  relation:     [type: :string, required: true],
  reason:       [type: :string, default: nil],
  confidence:   [type: :float, default: nil]
]
```

```elixir
@link_relations ~w(supports contradicts supersedes duplicates depends_on related)
@link_relations_atoms Enum.map(@link_relations, &String.to_atom/1)

defp apply_link_creates(state) do
  Enum.reduce(state.staging.link_creates, 0, fn args, acc ->
    with {:ok, relation} <- map_relation(Map.get(args, :relation)),
         attrs = %{
           from_fact_id: Map.get(args, :from_fact_id),
           to_fact_id:   Map.get(args, :to_fact_id),
           relation:     relation,
           reason:       Map.get(args, :reason),
           confidence:   Map.get(args, :confidence),
           written_by:   "consolidator"
         },
         {:ok, _} <- JidoClaw.Memory.Link.create_link(attrs) do
      acc + 1
    else
      err ->
        # Partial-publish contract: log and skip rather than
        # rolling back the whole batch. See "Apply-step error
        # handling" below. Log narrowed metadata only — never raw
        # proposal args (which may contain user memory content
        # in fact/block helpers that follow this same pattern).
        Logger.warning(
          "[Consolidator] link create skipped: " <>
            "from=#{inspect(Map.get(args, :from_fact_id))} " <>
            "to=#{inspect(Map.get(args, :to_fact_id))} " <>
            "relation=#{inspect(Map.get(args, :relation))} " <>
            "error=#{inspect(err)}"
        )
        acc
    end
  end)
end

defp map_relation(rel) when rel in @link_relations,
  do: {:ok, String.to_existing_atom(rel)}

defp map_relation(rel) when rel in @link_relations_atoms,
  do: {:ok, rel}

defp map_relation(_), do: {:error, :unknown_relation}
```

### 3b. `propose_update` invalidates but never replaces

`apply_fact_updates/1` (`run_server.ex:539-548`) only calls
`Fact.invalidate_by_id`. The `propose_update` tool moduledoc
(`tools/propose_update.ex:1`) and plan §3.15 step 4
(`docs/plans/v0.6/phase-3b-memory-consolidator.md:429`) both
describe the action as "invalidate + new row at same label" with a
`:supersedes` Link from new → old. `new_content` and `tags` from
the proposal are dropped on the floor.

**Fix.** Read the original Fact, call `Fact.record/1` to write the
replacement row at the same `(tenant, scope, label)` — the
`Changes.InvalidatePriorActiveLabel` change
(`fact.ex:636-669`) auto-invalidates the prior active row inside the
same transaction. For unlabeled facts, `InvalidatePriorActiveLabel`
short-circuits, so we explicitly invalidate the old row first.
Finally, stage a `:supersedes` Link from new → old per plan §3.15.

```elixir
defp apply_fact_updates(state) do
  Enum.reduce(state.staging.fact_updates, {0, 0, 0}, fn args, {added, invalidated, links} ->
    with {:ok, original} <- Ash.get(Fact, Map.get(args, :fact_id), domain: JidoClaw.Memory.Domain),
         :ok <- maybe_invalidate_unlabeled(original),
         {:ok, replacement} <- write_replacement(original, args, state) do
      link_acc =
        case JidoClaw.Memory.Link.create_link(%{
               from_fact_id: replacement.id,
               to_fact_id:   original.id,
               relation:     :supersedes,
               reason:       "consolidator_update",
               written_by:   "consolidator"
             }) do
          {:ok, _} -> links + 1
          _ -> links
        end

      # Labeled case: InvalidatePriorActiveLabel already invalidated the prior
      # row inside Fact.record's transaction. Unlabeled case: maybe_invalidate_unlabeled
      # ran above. Either way, exactly one invalidation occurred.
      {added + 1, invalidated + 1, link_acc}
    else
      _ -> {added, invalidated, links}
    end
  end)
end

defp maybe_invalidate_unlabeled(%Fact{label: nil} = fact) do
  case Fact.invalidate_by_id(fact, %{reason: "consolidator_update"}) do
    {:ok, _} -> :ok
    err -> err
  end
end

defp maybe_invalidate_unlabeled(_), do: :ok

defp write_replacement(original, args, state) do
  Fact.record(%{
    tenant_id:    original.tenant_id,
    scope_kind:   original.scope_kind,
    user_id:      original.user_id,
    workspace_id: original.workspace_id,
    project_id:   original.project_id,
    session_id:   original.session_id,
    label:        original.label,
    content:      Map.get(args, :new_content),
    tags:         Map.get(args, :tags, original.tags),
    source:       :consolidator_promoted,
    trust_score:  0.85,
    written_by:   "consolidator"
  })
end
```

`apply_proposals/1` reworks to thread the new tuple shape:

```elixir
defp apply_proposals(state) do
  blocks_written = apply_block_updates(state)
  facts_added_from_adds = apply_fact_adds(state)
  {added_from_updates, invalidated_from_updates, supersede_links} = apply_fact_updates(state)
  invalidated_from_deletes = apply_fact_deletes(state)
  links_added = apply_link_creates(state) + supersede_links

  %{
    # facts and messages stay in their own counters — don't fold
    # messages into facts_processed.
    messages_processed: length(state.messages || []),
    facts_processed: length(state.inputs || []),
    blocks_written: blocks_written,
    blocks_revised: 0,
    facts_added: facts_added_from_adds + added_from_updates,
    facts_invalidated: invalidated_from_deletes + invalidated_from_updates,
    links_added: links_added
  }
end
```

(`state.messages` is loaded by issue 4.)

### Apply-step error handling (explicit contract)

The outer `do_publish/1` already runs inside `Ash.transact/2`, so a
hard failure (raise / `Ash.DataLayer.rollback/2`) rolls back the
entire batch including the `ConsolidationRun` row. Each
`apply_*` helper currently swallows individual `{:error, _}`
returns and counts only successes — the reviewer flagged this as a
silent partial-publish risk.

Decision for this PR: **keep the count-and-skip pattern**, but log
every skipped failure via `Logger.warning` so the operator can see
the delta between staged proposals and published rows. **Logs
include only narrowed metadata** (ids, relation/label, error
inspect) — never raw proposal `args`, which may contain user memory
content. This applies to `apply_link_creates/1`,
`apply_fact_adds/1`, `apply_fact_updates/1`, `apply_fact_deletes/1`,
and `apply_block_updates/1` uniformly. The pattern in
`apply_link_creates/1` above is the template; replicate the
narrowed-shape logging into the others.

This count-and-skip behavior is intentional: most apply-step
failures are "target fact was invalidated by a concurrent writer
between staging and apply" or similar transient races, and tanking
a 60-proposal run because one link's target moved is worse than
logging and continuing.

If the team wants strict atomicity later, the change is one
line per helper: replace the `_ -> acc` arm with
`err -> Ash.DataLayer.rollback(JidoClaw.Memory.Domain, err)`. Out
of scope for this PR.

**Files:** `lib/jido_claw/memory/consolidator/run_server.ex` —
add `apply_link_creates/1`, rewrite `apply_fact_updates/1` and
`apply_proposals/1`. The relation allowlist module attributes go
near the top of the module.

---

## Issue 4 (P2) — Watermarks + multi-scope discovery

Three intertwined gaps to close (per agreed scope, full plan §3.15):

### 4a. Add `Conversations.Message.for_consolidator` read (session-scoped only)

The existing `since_watermark` action takes an integer `sequence`;
the plan needs an `(inserted_at, id)` tuple watermark. For 3b, the
consolidator only invokes message loading on `:session` candidates
(matches plan §3.15 step 2: "messages for this scope's sessions" —
which for `:session` is just one session). Cross-session message
consolidation at the workspace/user/project tiers is a 3c-or-later
question; locking it out of `Message.for_consolidator` keeps the
contract honest.

```elixir
# lib/jido_claw/conversations/resources/message.ex (in actions block)
read :for_consolidator do
  argument(:tenant_id, :string, allow_nil?: false)
  argument(:scope_kind, :atom, allow_nil?: false,
           constraints: [one_of: [:session]])
  argument(:scope_fk_id, :uuid, allow_nil?: false)
  argument(:since_inserted_at, :utc_datetime_usec, allow_nil?: true)
  argument(:since_id, :uuid, allow_nil?: true)
  argument(:limit, :integer, allow_nil?: true, default: 500)

  prepare({__MODULE__.Preparations.ForConsolidator, []})
end
```

The preparation filters `tenant_id == ^tenant and session_id == ^fk`
and applies the strict `(inserted_at, id) > (since_*, since_*)`
lex-order predicate ordered ascending by `(inserted_at, id)`:

```elixir
filter(
  expr(
    inserted_at > ^since_inserted_at or
    (inserted_at == ^since_inserted_at and id > ^since_id)
  )
)
```

…with the nil case (no prior watermark) skipping the filter.

The code_interface entry mirrors `Fact.for_consolidator`'s
no-positional-args style so callers pass a single map of arguments
(`Fact.for_consolidator(%{tenant_id: …, scope_kind: …, …})`):

```elixir
# lib/jido_claw/conversations/resources/message.ex (in code_interface block)
define(:for_consolidator, action: :for_consolidator)
```

Call site in `RunServer.load_inputs/1`:

```elixir
Message.for_consolidator(%{
  tenant_id:         scope.tenant_id,
  scope_kind:        :session,
  scope_fk_id:       scope.session_id,
  since_inserted_at: messages_wm_at,
  since_id:          messages_wm_id,
  limit:             max_messages_per_run
})
```

**Files:** `lib/jido_claw/conversations/resources/message.ex` —
add the action, the preparation module, and the code_interface entry.

If a later phase needs cross-session message loading at
workspace/user/project scope, extend `:scope_kind`'s `one_of` and
add the join query in the preparation. That's a deliberate
extension point, not a 3b deliverable.

### 4b. Persist contiguous-prefix watermarks on `ConsolidationRun`

`ConsolidationRun` already accepts the four watermark columns
(`consolidation_run.ex:73-76`) — `do_publish/1`
(`run_server.ex:416-447`) just doesn't compute or write them.

The plan §3.15 step 7 invariant: walk loaded rows in `(inserted_at, id)`
ASC order, stop at the first row that wasn't published. A "published"
row is any loaded row whose cluster wasn't deferred via
`defer_cluster`. Cluster shape today (`clusterer.ex:12-15`):
`%{id, label, fact_ids}`. To cover both streams, unify the cluster
shape with a discriminator + member-id list per type:

```elixir
# lib/jido_claw/memory/consolidator/clusterer.ex
@type cluster :: %{
        id: String.t(),
        label: String.t() | nil,
        type: :facts | :messages,
        fact_ids: [Ecto.UUID.t()],
        message_ids: [Ecto.UUID.t()]
      }
```

`cluster/2` produces clusters with `type: :facts`, `message_ids: []`,
`id: "facts:<label>"`. New `cluster_messages/2` produces clusters
with `type: :messages`, `fact_ids: []`,
`id: "messages:<session_id>"`. The RunServer carries a single
`state.clusters` list holding both. **This is what lets the harness
`defer_cluster` either kind** — `list_clusters` and `get_cluster`
already iterate `state.clusters`, so message clusters appear in
those tools automatically once the unified shape is in place.
Without this, the model can never defer a message cluster and the
message watermark would mis-advance over deferred message rows.

`get_cluster` (`lib/jido_claw/memory/consolidator/tools/get_cluster.ex`)
needs a small update so the response payload includes message rows
when `type == :messages` (today it only walks `fact_ids`); the same
goes for `find_similar_facts` (no change needed — facts only).

```elixir
defp compute_watermarks(state) do
  deferred_cluster_ids =
    state.staging.cluster_defers
    |> Enum.map(&Map.get(&1, :cluster_id))
    |> MapSet.new()

  deferred_clusters =
    Enum.filter(state.clusters || [], fn c ->
      MapSet.member?(deferred_cluster_ids, c.id)
    end)

  deferred_fact_ids =
    deferred_clusters
    |> Enum.flat_map(& &1.fact_ids)
    |> MapSet.new()

  deferred_message_ids =
    deferred_clusters
    |> Enum.flat_map(& &1.message_ids)
    |> MapSet.new()

  facts_wm = contiguous_prefix(state.inputs || [], deferred_fact_ids)
  messages_wm = contiguous_prefix(state.messages || [], deferred_message_ids)

  %{
    facts_processed_until_at: elem(facts_wm, 0),
    facts_processed_until_id: elem(facts_wm, 1),
    messages_processed_until_at: elem(messages_wm, 0),
    messages_processed_until_id: elem(messages_wm, 1)
  }
end

defp contiguous_prefix([], _), do: {nil, nil}

defp contiguous_prefix(rows, deferred_ids) do
  rows
  |> Enum.sort_by(fn r -> {r.inserted_at, r.id} end)
  |> Enum.take_while(fn r -> not MapSet.member?(deferred_ids, r.id) end)
  |> List.last()
  |> case do
    nil -> {nil, nil}
    last -> {last.inserted_at, last.id}
  end
end
```

`do_publish/1` merges the four watermark fields into `run_attrs`
before `ConsolidationRun.record_run/1`.

### 4c. Load messages for `:session` scope; load facts for all four

Rewrite `load_inputs/1` (`run_server.ex:392-407`) to:

1. Read prior watermarks via the existing code-interface, called
   **map-style** (matching `Fact.for_consolidator`'s shape — neither
   action declares positional `args`):

   ```elixir
   ConsolidationRun.latest_for_scope(%{
     tenant_id:   tenant_id,
     scope_kind:  kind,
     scope_fk_id: fk,
     status:      :succeeded
   })
   ```

   The `latest_for_scope` action already accepts `:status`
   (`consolidation_run.ex:99`). Carry forward null fields from older
   runs (per plan: a successful run that loaded no rows of one kind
   leaves that pair null; look back further). For 3b, simplest
   correctness: if the latest succeeded run's pair is null, query
   a small history window via `history_for_scope` (also map-style)
   and pick the most recent non-null. This is bounded and rare.
2. Pass `since_inserted_at` / `since_id` for facts to
   `Fact.for_consolidator`.
3. Pass the same to the new `Message.for_consolidator` **only when
   `scope_kind == :session`** (matches 4a's resource-side
   constraint). For `:user` / `:workspace` / `:project` scopes,
   `state.messages` is `[]` and the messages watermark is left
   `nil`.
4. Cluster facts with the existing `Clusterer.cluster/2`. Add a
   `Clusterer.cluster_messages/2` that groups by `session_id`,
   sorts by `(sequence)`, and emits clusters with
   `type: :messages`, `id: "messages:<session_id>"`,
   `message_ids: [...]`, `fact_ids: []`. Concatenate fact and
   message clusters into the single `state.clusters` list per the
   unified shape in 4b.
5. Carry `state.messages` on the `RunServer` struct alongside
   `state.inputs`. Clusters live on `state.clusters` (no separate
   `message_clusters` field — the unified shape removes that need).

The min-input gate compares the **sum** of loaded facts + loaded
messages against `min_input_count`. The `messages_processed`
audit-row counter is `length(state.messages || [])` in the success
path and `0` on skip.

**Files:**
- `lib/jido_claw/memory/consolidator/run_server.ex` — `load_inputs/1`,
  `do_publish/1`, struct field (`messages`),
  `apply_proposals/1` (for the `messages_processed` count).
- `lib/jido_claw/memory/consolidator/clusterer.ex` — add
  `cluster_messages/2` and update the `cluster/2` return shape to
  the unified discriminator (back-compat: existing call sites only
  read `id` / `label` / `fact_ids`, none of which change).
- `lib/jido_claw/memory/consolidator/tools/get_cluster.ex` —
  branch on `type` so message clusters return their member message
  rows instead of fact rows.

### 4d. Multi-scope candidate enumeration

Rewrite `candidate_scopes/1` (`consolidator.ex:132-151`) to fan out
across all four scope kinds. Use the existing
`Workspaces.PolicyTransitions.resolve_consolidation_policy_for_user/2`
and `…_for_project/2` aggregates so the gate sees the right policy.

```elixir
defp candidate_scopes(max_candidates) do
  workspaces = read_workspaces()
  workspace_scopes = Enum.map(workspaces, &workspace_scope/1)
  user_scopes = unique_user_scopes(workspaces)
  project_scopes = unique_project_scopes(workspaces)
  session_scopes = active_session_scopes(workspaces)

  (workspace_scopes ++ user_scopes ++ project_scopes ++ session_scopes)
  # Tenant-scoped dedup: same scope_kind + fk under different
  # tenants must NOT collapse to a single candidate.
  |> Enum.uniq_by(fn s -> {s.tenant_id, s.scope_kind, Scope.primary_fk(s)} end)
  |> Enum.take(max_candidates)
rescue
  _ -> []
end
```

`active_session_scopes/1` reads `Conversations.Session` rows whose
`workspace_id` is in the non-disabled workspace set (filter
`closed_at IS NULL` to skip closed sessions). Per-scope policy gating
still happens inside `RunServer` — this list is the candidate pool;
`PolicyResolver.gate/1` filters out anything opted-out at run time.

**Watermark-anchored discovery is deferred.** The plan calls for
candidates filtered by "has rows newer than last successful
watermark," but with watermarks wired into the load path (4b/4c)
the per-scope min-input gate already short-circuits empty scopes —
correctness is preserved. The cost is operator noise (skip rows
written for stale scopes every tick). Implementing the
watermark-anchored filter at the candidate-discovery layer is a
worthwhile follow-up but is **not** required to close this review;
flagged explicitly so the deferral is intentional, not forgotten.

**File:** `lib/jido_claw/memory/consolidator.ex` — rewrite
`candidate_scopes/1` and add the four enumeration helpers.

---

## Critical files

- `lib/jido_claw/memory/consolidator/run_server.ex` — issues 1, 3, 4
  (`drive_harness/4` + `await_ready/3` + `maybe_stop_forge_session/1`;
  `apply_link_creates/1`; `apply_fact_updates/1`; `apply_proposals/1`;
  `compute_watermarks/1`; `load_inputs/1`; `do_publish/1`; struct
  field for `messages`).
- `lib/jido_claw/forge/runners/claude_code.ex` — issue 2
  (`append_thinking_effort/2`: `--thinking-effort` → `--effort`).
- `lib/jido_claw/memory/consolidator/tools/propose_link.ex` — issue 3
  (extend schema with `reason` and `confidence`).
- `lib/jido_claw/conversations/resources/message.ex` — issue 4a
  (new session-only `:for_consolidator` read + preparation +
  code_interface).
- `lib/jido_claw/memory/consolidator/clusterer.ex` — issue 4c
  (new `cluster_messages/2`; unified cluster shape with `type` /
  `fact_ids` / `message_ids`).
- `lib/jido_claw/memory/consolidator/tools/get_cluster.ex` — issue 4c
  (branch on cluster `type` to return message rows for message
  clusters).
- `lib/jido_claw/memory/consolidator.ex` — issue 4d
  (`candidate_scopes/1` + four enumeration helpers; tenant-scoped
  dedup).

No migration is required — `ConsolidationRun` already has the four
watermark columns and `Fact.for_consolidator` already accepts
`since_inserted_at` / `since_id`.

## Reused, do not duplicate

- `JidoClaw.Forge.PubSub.subscribe/1` and the existing `:ready`
  broadcast at `harness.ex:275/290` — no new wait API on `Harness`.
- `JidoClaw.Memory.Link.create_link/1`
  (`lib/jido_claw/memory/resources/link.ex:48`) — auto-denormalizes
  scope and rejects cross-tenant / cross-scope edges.
- `Fact.record/1` + the
  `Changes.InvalidatePriorActiveLabel` hook
  (`fact.ex:636-669`) — handles the labeled-case
  invalidate-and-replace inside one transaction.
- `Fact.for_consolidator` and `ConsolidationRun.latest_for_scope`
  / `record_run` — already accept the columns and arguments we
  need to wire up.
- `Workspaces.PolicyTransitions.resolve_consolidation_policy_for_user/2`
  / `…_for_project/2` — used by `PolicyResolver.gate/1`; nothing new
  needed for the most-restrictive aggregate in candidate enumeration.

---

## Verification

**Compile & format**
- `mix compile --warnings-as-errors`
- `mix format`
- `mix ash_postgres.generate_migrations --check` (should still pass —
  no resource attribute changes).

**Unit / integration tests**

Add or extend:

1. **`test/jido_claw/memory/consolidator/run_server_test.exs`
   (new — the headline regression test)**
   - **Forge bootstrap regression test** — drives a full `:fake`
     run end-to-end. Without the fix, this asserts the run lands
     `{:invalid_state, :bootstrapping}` (or the published-status
     row is `:failed` with that error string). With the fix, it
     asserts a `:succeeded` `ConsolidationRun` row plus at least
     one Block row from a staged `propose_block_update`. **This
     is the regression test the current suite is missing — it
     should be authored to fail without the fix and pass with it.**
   - Stages `propose_link` proposals and asserts `Link` rows land
     with the expected relations and `reason` / `confidence`
     forwarded.
   - Stages `propose_update` proposals; asserts the original Fact
     is invalidated, a new row at the same label exists with the
     proposal's `new_content` / `tags`, and a `:supersedes` link
     points new → old.
   - Stages `defer_cluster` for one cluster (both fact and message
     variants); asserts the corresponding watermark advances only
     to the row before the deferred cluster's first loaded row.
   - Stages no proposals; asserts the run is `:failed` with
     `max_turns_reached` (existing behavior — keeps the current
     contract observable).
   - Asserts the Forge session is stopped on every exit path
     (await_ready timeout, harness DOWN, run_iteration crash) by
     checking `Forge.Manager.list_sessions/0`.

2. `test/jido_claw/memory/consolidator/consolidator_test.exs` (new)
   - Seeds workspaces with `:default` policy, sessions, messages,
     facts. Calls `tick/0`. Asserts candidates fan out across all
     four scope kinds and the gate filters opted-out scopes.
   - Asserts tenant-scoped dedup: two tenants with the same
     `scope_fk_id` produce two candidates, not one.

3. `test/jido_claw/conversations/message_test.exs` — add cases for
   the new `:for_consolidator` read on `:session` scope (the only
   `one_of` value). Cover: no prior watermark, strict
   `(inserted_at, id)` lex predicate, limit cap, ordering.

4. `test/jido_claw/forge/runners/claude_code_test.exs` (or wherever
   the runner CLI args are asserted) — assert the args list
   contains `["--effort", "xhigh"]` when `thinking_effort: "xhigh"`,
   and never contains `"--thinking-effort"`.

5. `test/jido_claw/memory/consolidator/clusterer_test.exs` —
   add cases for `cluster_messages/2` (group by session_id, sort
   by sequence) and confirm the unified shape (existing tests
   read only `id` / `label` / `fact_ids`, all unchanged).

6. Existing
   `test/jido_claw/memory/consolidator/{staging,policy_resolver}_test.exs`
   should still pass without modification.

**End-to-end probe** (matches the reproducer in the review):

```sh
mix tidewave  # or however the project's Tidewave probe is invoked
```

Run the same fake-runner consolidator probe that was producing
`{:invalid_state, :bootstrapping}`. Expected post-fix:
- `:succeeded` `ConsolidationRun` row.
- Non-null watermarks for the streams that had inputs.
- One Block row from `propose_block_update`, plus link / fact rows
  for the staged proposals.
- A second tick with no new content writes a `:skipped` row
  (`below_min_input_count`) without re-loading the same facts —
  observable by stable watermarks across runs.

**Suite**
- `mix test test/jido_claw/memory/consolidator/`
- `mix test test/jido_claw/forge/runners/`
- `mix test test/jido_claw/conversations/`
- `mix test` (full suite — currently 1296 tests at 0 failures).

---

## Out of scope (deferred, intentional)

- Watermark-anchored candidate filtering at the discovery layer
  (§4d): correctness lands via the load-path watermark, but stale
  scopes still write skip rows every tick. Follow-up.
- Cross-session message loading at workspace/user/project scope
  (Message.for_consolidator restricted to `:session`): extension
  point preserved, no current consumer.
- Strict apply-step rollback on individual `{:error, _}` returns:
  current behavior (count-and-skip with a `Logger.warning`) is
  documented; a one-line-per-helper switch to
  `Ash.DataLayer.rollback/2` is the upgrade path.
- Local-runner branch for `:local_only` workspaces — still 3c.
- The `Forge.Resources.Session.tenant_id` debt called out in §0.5.2.
- Worker-template prompt-cache propagation (the
  `anthropic_prompt_cache: true` follow-up sweep called out in
  Phase 3b's discoveries section).
- The Codex sibling runner.
