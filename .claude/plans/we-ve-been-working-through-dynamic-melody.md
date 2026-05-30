# Resolve code-review findings on the T1-2 Compaction (ADOPTED) work

## Context

The T1-2 compaction work (per-agent keying + summarizer retries + full worker
compaction, plan `please-review-docs-exploration-jidoka-fe-unified-rivest.md`)
is finished. A follow-up code review surfaced 3 findings + 1 open question.
I validated all four against the source. This plan fixes the validated issues.
**Done = `mise exec -- mix precommit` green** (compile-werror, system_prompt.check,
deps.unlock --unused, format, credo --strict, dialyzer, test). All `mix` runs go
through `mise exec --` (OTP 28.5) — a bare `mix` uses the wrong toolchain.

### Validation summary (all confirmed)

| Item | Verdict | Evidence |
|---|---|---|
| **F1** message-only handoffs lose always-kept context | **Real bug** | `message` is `required` on the handoff tool (handoff.ex:39-41); `summary`/`reason` optional. `handoff_context_from_owner/1` (router.ex:464) returns `%{}` unless reason/summary present → `inject_system_prompt` (base only). `handoff_block/1` (startup.ex:143) never renders `message`. So the *normal* message-only handoff gets no handoff context in the system prompt the transformer always keeps. |
| **F2** `compact/3` targeting trap | **Valid** | `build_manual_ctx/3` (compactor.ex:741): `compaction_id = opts[:compaction_id] \|\| Identity.main()`; `:agent_id` only labels telemetry/snapshot. Only `:agent_id` is documented (compactor.ex:715-721). **Zero non-test callers** of `compact/3` — safe to change. |
| **F3** stale v1/single-slot docs | **Valid** | Sweep found **15 stale references in 6 files** (reviewer named Compactor/Config/Snapshot/adoption-sketch; extras live in `defaults.ex`, `request_transformer.ex`, FEATURES line 67). All 7 workers are now `:auto`; snapshots are `metadata["compactions"][key]` (plural). |
| **Open Q** `request_correlations.agent_id` nullable vs plan's NOT NULL | **Drift, not a bug** — user chose **make NOT NULL default "main"** | Both stamping paths drop a nil `agent_id` (worker.ex:388 `nil -> acc`; recorder.ex:732 `maybe_put`), so runtime was already safe. `messages.agent_id` is already NOT NULL default "main" (message.ex:344). |

---

## Fixes

### Fix 1 — Handoff `message` survives compaction in the always-kept system prompt

Inject the handoff `message` into the worker's system prompt (kept by the
`RequestTransformer` across every compaction), so message-only handoffs get the
same survival guarantee that reason/summary handoffs do today.

- **`lib/jido_claw/startup.ex` — `handoff_block/1` (143-156):** add a
  `Message: #{message}` line, using the existing `present_or/2` helper
  (`handoff_context |> Map.get(:message) |> present_or("not provided")`). Update
  the `@doc` on `inject_handoff_prompt/4` (111-112) to list `:message`.
- **`lib/jido_claw/agent/handoff/router.ex` — `handoff_context_from_owner/1`
  (464-470):** include `:message` in the returned map and trigger when
  `present?(handoff.message) or present?(handoff.reason) or present?(handoff.summary)`.
  Update the comment at 462-463.
- **Preserve "rehydrated → base-prompt-only".** Rehydration placeholders carry
  `message: "<rehydrated>"`, which is non-empty and would now wrongly trigger a
  handoff block. Guard against it: add `Handoff.rehydrated_marker/0` (a public
  fn returning `"<rehydrated>"` — cross-module, so a fn not a module attr) **and**
  a `rehydrated?/1` predicate to `lib/jido_claw/agent/handoff.ex`. There are
  **two** placeholder sites that hardcode the string — point **both** at
  `Handoff.rehydrated_marker/0` (single source of truth):
  `worker.ex` `seed_handoff_from_metadata/4` (424,427) **and** `router.ex`
  `synthesize_owner/5` (295,298). Short-circuit `handoff_context_from_owner/1`
  to `%{}` when `Handoff.rehydrated?(handoff)`.
- **Tests:** (a) unit — assert `Startup.inject_handoff_prompt/4` output for a
  `%{message: "MARK"}` context contains `MARK` and the base prompt (new
  `test/jido_claw/startup_test.exs`, or fold into existing handoff tests); (b)
  end-to-end regression — in `test/jido_claw/reasoning/compactor/coherence_test.exs`
  describe `"(c)"` (which already has `CapturingAgent` + `FakeRuntime` +
  `HandoffRegistry.put_owner/3`), add a **message-only** `Handoff.new/1` (no
  reason/summary) and assert the captured `{:injected_prompt, prompt}` contains
  the message marker AND the base prompt. Mirror the existing reason/summary test
  (coherence_test.exs:232-311). (c) router rehydration regression — drive
  `synthesize_owner/5` (or install a `rehydrated_marker`-tagged owner) and assert
  `handoff_context_from_owner/1` yields base-prompt-only (no `HANDOFF CONTEXT`
  block), proving the guard holds for both placeholder sites.

### Fix 2 — `Compactor.compact/3` `:agent_id` drives targeting + docs

Make the documented `:agent_id` option actually target that agent's slice when
no explicit `:compaction_id` is given, and keep the snapshot label consistent.

- **`lib/jido_claw/reasoning/compactor.ex` — `build_manual_ctx/3` (735-765):**
  keep the target and the snapshot/telemetry label **identical** — one resolved id:
  ```elixir
  target_id = opts[:compaction_id] || opts[:agent_id] || Identity.main()
  agent_id  = target_id
  ```
  (`compaction_id = target_id` drives the slice/key; `ctx.agent_id`/`base_metadata`
  use the same value.) Avoids the divergence where passing both opts would label a
  snapshot differently from the slice it summarized.
- **Doc `compact/3` `## Options` (715-721):** document `:compaction_id` as the
  slice/key target, clarify `:agent_id` is an alias for the same target when
  `:compaction_id` is absent, and that the snapshot's `agent_id` always equals the
  compacted slice's id.
- **Tests:** in `test/jido_claw/reasoning/compactor/compactor_test.exs` add a
  case passing only `agent_id: "coder_1"` (no `:compaction_id`) and assert the
  snapshot's `summarized_request_ids` are coder-only, `snap.agent_id == "coder_1"`,
  and `Session.metadata["compactions"]` has key `"coder_1::default"` (not
  `"main::default"`). Reuse the per-agent fixture from `agent_slice_test.exs:100-141`
  and the metadata-read pattern from `coherence_test.exs:156-159`. Existing
  callers (`agent_id: "main"` or explicit `:compaction_id`) keep passing.

### Fix 3 — Scrub all stale v1 / single-slot / workers-`:off` docs

Pure doc/comment edits (no behavior change). Rewrite to the per-agent model:
all agents compact, snapshots are `metadata["compactions"][key]` (plural), workers
are `:auto`. Own the full sweep, not just the reviewer-named files
(`[[feedback_no_preexisting]]`).

- **`lib/jido_claw/reasoning/compactor.ex`:** line 3 ("for the main `JidoClaw.Agent`"),
  line 15 (`metadata["compaction"]` → plural+`[key]`), **lines 32-37 delete/rewrite
  the entire `## Scope (v1)` block** (workers `:off` / "deferred to v2"), line 799
  ("single-agent callers").
- **`lib/jido_claw/reasoning/compactor/config.ex`:** line 3 ("for the main agent"),
  line 7 ("Workers explicitly set `mode: :off` on v1"), line 13 ("`:off` is the
  worker opt-out"), line 93 ("v1 defaults for the main agent"), lines 95-96
  ("Workers opt out …" — they opt *in* to `:auto`), line 116 ("(workers)").
- **`lib/jido_claw/reasoning/compactor/snapshot.ex`:** line 5 (`metadata["compaction"]`
  → plural+`[key]`).
- **`lib/jido_claw/reasoning/compactor/request_transformer.ex`:** line 14 (drop
  "v1 limitation"; it's a steady-state legacy-untagged-row carve-out).
- **`lib/jido_claw/agent/defaults.ex`:** line 28 ("the default for v1 workers" →
  no-op fallback for callers that don't opt in).
- **`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md`:** line 67 ("No retries
  on v1." → configurable transient-phase retries), line 87 (adoption sketch's
  singular `metadata["compaction"]` → annotate shipped path `metadata["compactions"][key]`).
  Status block (58/368) and the ✓ diagram are already correct — leave them.

### Fix 4 — `request_correlations.agent_id` → NOT NULL default "main" (user choice)

Match the plan summary's stated contract and align with `messages.agent_id`.

- **`lib/jido_claw/conversations/resources/request_correlation.ex` (194-197):**
  `allow_nil?(false)` + `default("main")`; rewrite the comment (189-193) to state
  NOT NULL/default "main" (drop the "Nullable: …" sentence).
- **`lib/jido_claw.ex` — `register_correlation/6` (333):** default the opt to
  avoid an explicit `nil` reaching the `:register` create:
  `agent_id = Keyword.get(opts, :agent_id) || Identity.main()` (mirrors how
  `subagent` defaults to `false` on line 334). Other call sites already pass a
  non-nil identity via `CompactionIdentity.resolve/3`.
- **Migration + snapshot:** use the **ash-framework skill** — edit the resource,
  then regenerate so `request_correlations.agent_id` is `NOT NULL DEFAULT 'main'`.
  The migration `priv/repo/migrations/20260530131424_add_compaction_identity_to_messages.exs:19`
  (`add :agent_id, :text`) and its resource snapshot are **untracked + greenfield**
  (`[[project_greenfield_no_migrations]]`), so fold the change into that migration
  (`add :agent_id, :text, null: false, default: "main"`) rather than stacking a
  second one, then `mise exec -- mix ecto.reset` to rebuild. Keep migration and
  Ash snapshot in sync (regenerate; don't hand-edit one only).
- **Tests:** run the conversations suite; confirm registration with an omitted
  `agent_id` still succeeds (defaults to "main") and sub-agent registration keeps
  its tag.

---

## Files to change

| File | Fix | Change |
|---|---|---|
| `lib/jido_claw/startup.ex` | 1 | `handoff_block/1` renders `message`; `@doc` lists `:message` |
| `lib/jido_claw/agent/handoff/router.ex` | 1 | `handoff_context_from_owner/1` includes/triggers on `message` + rehydration guard; `synthesize_owner/5` uses `rehydrated_marker/0` |
| `lib/jido_claw/agent/handoff.ex` | 1 | `rehydrated_marker/0` + `rehydrated?/1` (single source of truth) |
| `lib/jido_claw/platform/session/worker.ex` | 1 | `seed_handoff_from_metadata/4` uses `rehydrated_marker/0` |
| `lib/jido_claw/reasoning/compactor.ex` | 2,3 | `build_manual_ctx/3` targeting + `compact/3` `## Options`; moduledoc/`latest` docs |
| `lib/jido_claw/reasoning/compactor/config.ex` | 3 | moduledoc + `default/0`/`off/0` docs |
| `lib/jido_claw/reasoning/compactor/snapshot.ex` | 3 | moduledoc path |
| `lib/jido_claw/reasoning/compactor/request_transformer.ex` | 3 | drop "v1 limitation" |
| `lib/jido_claw/agent/defaults.ex` | 3 | moduledoc "v1 workers" |
| `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` | 3 | lines 67, 87 |
| `lib/jido_claw/conversations/resources/request_correlation.ex` | 4 | `agent_id` NOT NULL + default "main" + comment |
| `lib/jido_claw.ex` | 4 | `register_correlation/6` defaults `agent_id` to `Identity.main()` |
| migration `20260530131424_*.exs` + resource snapshot | 4 | regenerate `agent_id` NOT NULL default "main" |
| `test/.../compactor/coherence_test.exs`, `test/.../compactor/compactor_test.exs`, `test/jido_claw/startup_test.exs` (new) | 1,2 | regression tests |

## Reuse / conventions
- `present_or/2` (startup.ex:158), `present?/1` (router.ex:472) — reuse, don't re-add.
- `JidoClaw.Reasoning.Compactor.Identity.main/0` for the "main" literal in Fix 2 & 4.
- Coherence test's `CapturingAgent`/`FakeRuntime`/`HandoffRegistry.put_owner/3` and
  `agent_slice_test.exs` per-agent fixture — reuse for the new tests.
- Invoke the **ash-framework skill** before the `request_correlation` resource +
  migration edits (Fix 4).
- Watch Credo on Fix 1/2 (cyclomatic ≤ 11, nesting ≤ 3, no `BlanketRescue`); keep the
  new predicate/guard simple. No dialyzer-relevant type changes (Handoff `message`
  stays `String.t()`; rehydration is sentinel-guarded, not nil).

## Verification
1. Targeted, fastest signal first:
   `mise exec -- mix test test/jido_claw/agent/handoff/ test/jido_claw/reasoning/compactor/ test/jido_claw/conversations/ test/jido_claw/startup_test.exs`
2. Fix 4 schema: `mise exec -- mix ecto.reset` — **destructive: drops + recreates
   the dev DB** (acceptable under greenfield, but state it before running). Then
   Tidewave `execute_sql_query` to confirm `request_correlations.agent_id` is
   `NOT NULL DEFAULT 'main'`.
3. **Gate:** `mise exec -- mix precommit` green.
4. Manual smoke (optional, `mise exec -- mix jidoclaw`): a **message-only** handoff,
   drive the worker past the compaction threshold, confirm via `inspect_agent`/Trace
   the handoff message is still in the worker's system prompt post-compaction.

## Out of scope
- Relocating `register_correlation/*` into `RequestCorrelation` (pre-existing follow-up).
- Real `context_ref` lanes; orphaned-snapshot pruning (carried from the prior plan).
- No `git commit` without an explicit request (`[[feedback_never_commit_unprompted]]`).
