# Reach smell burndown — drive `--smells` to zero

## Context

`mix reach.check --arch` is **green** and `.reach.exs` is configured. The config header states the
goal: drive `mix reach.check --arch --smells --strict` to **zero**, then add it to the `precommit`
alias so it stays there. Policy (recorded): **fix-to-zero, no `.reach-baseline.json`**, and
**"fix real data, scope the rest"** — fix genuine issues; for false positives use reach's local
suppression rather than contorting working code.

Live count (verified this session): **235 findings**, no per-finding severity. Architecture is
unaffected — this is entirely the `--smells` set.

| Count | Kind | Disposition summary |
|------:|------|---------------------|
| 133 | `bare_rescue` | narrow data-access rescues (per-site lists); scope intentional OTP/boundary catch-alls |
| 37 | `suboptimal` | mechanical — but two need correctness care (see Phase 1) |
| 26 | `fixed_shape_map` | scope single-file contracts; structurally fix/triage cross-file shapes |
| 18 | `string_building` | mechanical (iolists / `Enum.map_join`) |
| 6 | `eager_pattern` | 5 mechanical; `project_info` → scope (ordering-preserving) |
| 6 | `ecto_interpolated_repo_query` | **all false positives** → scope with pragmas |
| 4 | `redundant_computation` | mechanical (hoist into a binding) |
| 2 | `behaviour_candidate` | scope via config module-ignore (one is a false positive) |
| 2 | `identity_float_coercion` | mechanical |
| 1 | `trivial_forwarder` | inline the delegate |

**Decisions locked (this session):** SQLi → scope with pragmas; `fixed_shape_map` → scope
enforced/external contracts, convert only clean domain shapes (not `tools/error.ex`); pacing →
clear the mechanical categories autonomously, then **stop for review** before the judgment work.

---

## Suppression mechanics — IMPORTANT (corrects the prior draft)

Reach finding **anchors are non-deterministic across runs** (verified: the audit-event
`fixed_shape_map` anchored at `auth_controller.ex:43` on one run and `signal_listener.ex:105` on
the next; single-file anchor lines also drift, e.g. `chat_controller :43→:83`). Therefore:

- **`# reach:disable-next-line <kind>`** is only safe at a **stable real code site** — i.e. the SQLi
  `Repo.query!` calls. **Do not** use it for `fixed_shape_map`/`behaviour_candidate` (the anchor moves out from under it).
- **`# reach:disable-for-this-file <kind>`** is robust for a finding whose evidence is **entirely
  within one file** (it's line-independent). Use this for single-file `fixed_shape_map` scopes.
- **Pragma formatting:** reach tokenizes the pragma line literally, so the human reason goes on its
  **own comment line above** the pragma — never appended (`# reach:disable-next-line kind: reason` is mis-tokenized):
  ```elixir
  # <why this is safe / intentional>
  # reach:disable-next-line ecto_interpolated_repo_query
  ```
- **Config `ignore` takes only `paths:` and `modules:`** — no `reason:` key. Put the rationale as an adjacent comment in `.reach.exs`.
- **Cross-file aggregated findings** (evidence spans >1 file) cannot be held by an inline pragma →
  resolve **structurally** (a shared constructor/struct so the literal exists once) or via
  **config-level** `smells: [<kind>: [ignore: [modules: [...]]]]` in `.reach.exs`.
- **`behaviour_candidate`** is inherently multi-module → scope via config `ignore: [modules: [...]]`.
- **After every scope action, re-run reach and confirm the count dropped** — not merely relocated to a new anchor.

Use fresh `mix reach.check --smells --format json` locations at execution time; treat line numbers in this plan as indicative.

---

## Phase 0 — Re-baseline + verification loop (no code)

1. Snapshot `mise exec -- mix reach.check --smells --format json` counts per kind.
2. **Per-batch loop** (run after every batch):
   - `mise exec -- mix reach.check --smells --format json` → touched category dropped as expected, **no new kinds, no relocated findings**.
   - `mise exec -- mix compile` (or `mix jidoclaw.compile_check` for the allowlist-aware strict check).
   - `mise exec -- mix credo --strict` (critical for `bare_rescue` — see Risks).
   - `mise exec -- mix test`.

---

## Phase 1 — Mechanical batch (~67 findings) · autonomous, then GATE for review

Clear all five categories, run the loop, then **stop and report** before Phase 2. Two items below
are **not** pure swaps — handle them as noted (or defer to the gate if they feel like judgment calls).

- **`redundant_computation` (4):** hoist the repeated call into a binding — `reasoning/llm_tiebreak.ex` (`Exception.message` ×2), `tools/run_skill.ex` (`length` ×2), `tools/mcp_scope.ex` (`Exception.message` ×2), `display.ex` (`String.split` ×2).
- **`identity_float_coercion` (2):** `reasoning/statistics.ex`, `lib/mix/tasks/jidoclaw.migrate.solutions.ex`.
- **`eager_pattern` (6):** 5 genuine fixes — `reasoning/strategy_store.ex`, `reasoning/pipeline_store.ex`, `platform/skills.ex` (`map`⇒`flat_map`), `workflows/plan_workflow.ex` (`map`⇒`max_by`), `display/status_bar.ex` (`map`⇒`sum_by`). **`tools/project_info.ex` `detect_top_level_files/1` → SCOPE** (stable single site → `# reach:disable-next-line eager_pattern`, or file-level since it's the file's only `eager_pattern` finding). Reason: `Enum.sort |> Enum.take(30)` returns the lexicographically-first 30 entries; there is no idiomatic partial-sort for tiny input, and a heap would have to reproduce that exact ordering. Suppress, don't rewrite.
- **`suboptimal` (37):** mostly mechanical — `case`→`match?/2` (10), `Enum.at/2`-in-loop (6, mostly `memory/hybrid_search_sql.ex`), `++`-in-`reduce` (4), guard-vs-literal→head-match (3), `reverse |> hd`→`List.last` (2), `Keyword.get(_,_,nil)` (2), and singles. **Correctness exception:** `web/controllers/chat_controller.ex` `create/2` does `messages |> Enum.at(-1) |> Map.get("content", "")`; on empty `messages` this raises (and `List.last/1` returns `nil`, so a bare swap still crashes at `Map.get`). Fix with an empty/`nil` guard returning `""`, not a pure swap. For every `Enum.at` fix, preserve existing `nil`-handling.
- **`string_building` (18):** `<>`-in-`reduce` ⇒ iolists / `Enum.map_join/3`. Concentrated: `memory/consolidator/run_server.ex` (13), `export/canonical.ex` (4), `shell/session_manager.ex` (1); plus one `Enum.join`-wrap in `memory/hybrid_search_sql.ex`. Keep emitted bytes identical (especially in `run_server.ex`).

---

## Phase 2 — Judgment batches (~168 findings) · after the review gate

### 2a · `ecto_interpolated_repo_query` (6) — scope (security-led, quick)

All false positives (interpolated value is a compile-time allowlisted table name; user data is `$N`-bound). These are stable real code sites, so inline pragmas are appropriate.
- `# reach:disable-next-line ecto_interpolated_repo_query` + reason at **only the 6 flagged `Repo.query!` sites**: `workspaces/policy_transitions.ex` (3) and `embeddings/backfill_worker.ex` (3).
- **Do not add inert pragmas to unflagged sites.** Reach currently flags `Repo.query!` only, so the same-pattern builders it does *not* flag — `backfill_worker.ex` `transition_to_disabled/2`, and the variable-built interpolated SQL passed to `Repo.query/2` in `claim_batch/2` / `claim_by_id/3` (~`backfill_worker.ex:180`/`:223`) — get **no pragma** (it would be dead/confusing).
- Instead, document the boundary **once** at the `@embedding_tables` (`policy_transitions.ex:34`) and `@resources` (`backfill_worker.ex:61`) declarations: the allowlist is the injection boundary for **all** SQL builders in the module (`query!` and `query` alike). Already partly documented.

### 2b · `fixed_shape_map` (26) — scope single-file contracts; structurally fix/triage cross-file

**Buckets verified this session** (single-file vs evidence spanning >1 file):

**Single-file → scope with `# reach:disable-for-this-file fixed_shape_map` + reason (line-independent):**
- `tools/error.ex` (13×) — LLM wire contract (`@type t`). **Do not convert.**
- `forge/runner.ex` (5×) — `@type iteration_result`, built by the `continue/done/needs_input/blocked/error` constructors in this file. Typed-map contract → scope (do **not** extract; see 2d).
- `error/normalize.ex` (8× and 3×) — error-normalizer internals (same rationale as `error.ex`).
- `application.ex` (3×) — OTP `child_spec` map.
- `web/controllers/chat_controller.ex` (3×) — OpenAI response shape (external contract).
- `memory/hybrid_search_sql.ex` (5×) — SQL-builder accumulator (`next/params/sql`), internal.
- `lib/mix/tasks/jidoclaw.migrate.memory.ex` (5×) — one-off migration stats.

  *Caveat — `disable-for-this-file` is broad:* it silences the kind file-wide, so a future *unrelated* shape in that file would be masked. Fine where every shape is the same internal-contract kind (`error/normalize.ex`). For broader files (`application.ex`, `memory/hybrid_search_sql.ex`) write a precise adjacent reason and lean on the verify-loop step ("dropped, not relocated/masked") to catch a hidden new finding.

**Single-file → convert (genuine recurring domain entity, in-file constructions):**
- `setup/credential_validator.ex` (9×) `%{configured?, valid?, provider}` → `defstruct` (e.g. `JidoClaw.Setup.CredentialCheck`). **Surface (verified):** convert **every** construction site **including the `validate_ollama/0` rescue fallback** (`credential_validator.ex:52`); consumers are `setup/wizard.ex` **and** `web/live/setup_live.ex:74` (via `Wizard.run/0`). Struct field access / `%{...}` read-patterns keep working (structs satisfy map patterns); verify both consumers. **Fallback:** if conversion gets messy, this file is single-file so `disable-for-this-file` cleanly scopes it instead.
- Triage the remaining single-file shapes (`inspection.ex` token-usage 3×, `tools/get_agent_result.ex` 78/93, `agent_view.ex:190`, `conversations/transcript_envelope.ex`, `forge/harness.ex` 5×) by the rule: convert if a clean small-blast-radius domain entity, else `disable-for-this-file`.

**Cross-file (9 findings) → structural fix or config (inline pragma will NOT hold):**
- **Audit-event attrs (10×, 6 files: `audit/signal_listener.ex`, `audit/producers.ex` ×5 lines, `audit/ash_tracer.ex`, `web/plugs/api_key_auth.ex`, `web/controllers/auth_controller.ex`, `memory/resources/block.ex`).** Recommend a small `JidoClaw.Audit.EventAttrs.new/1` constructor used by all sites — DRYs genuine 10-site duplication and removes the finding structurally. (Refines the earlier "scope producers" call: pragma-scoping is unreliable across files, so a constructor is the robust "fix real data".) **Constructor shape matters:** take **keyword args** — `EventAttrs.new(tenant_id: ..., event_kind: ..., ...)` — and return a **plain map** for `AsyncWriter`. A map-literal argument (`new(%{tenant_id: ..., ...})`) would just relocate the same shape and **keep the smell**. Do **not** pass a struct into the Ash action unless you explicitly `Map.from_struct/1` first. Decide constructor-vs-leave at this gate.
- The other cross-file shapes — `tools/reason.ex` (5×, 4f: reasoning-call input), `jido_claw.ex:482/483` (two near-identical message projections — consider unifying), `memory/consolidator/run_server.ex` (Memory.Block attrs, Ash-enforced), `workflows/plan_workflow.ex` (skill input), `memory/consolidator.ex` (RuntimeScope shape — check for an existing scope helper/struct first), `cli/commands.ex` + `cli/commands/solutions_stats.ex` (CLI stats), `conversations/recorder.ex` (Ash Message attrs), `solutions/matcher.ex` (match result) — each gets a per-shape call at this gate: shared constructor/struct, or accept. **No inline pragmas for these.**

### 2c · `bare_rescue` (133) — narrow data-access (per-site lists); scope boundaries

`rescue e in @attr ->` with a module-attribute list **does compile** (verified). Two sub-passes; run the loop after each.

**Narrow — but with per-site exception lists, not one universal set.** Template in-repo at `forge/persistence.ex:341-348`:
```elixir
rescue
  e in [Ash.Error.Invalid, Ash.Error.Unknown, Ash.Error.Query.NotFound,
        DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
    # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
    ...
```
- Use a per-file `@db_errors` attribute for Ash read/write sites, **but tailor per boundary**: Ash calls can also raise `Ash.Error.Forbidden` (policy) and others; raw Ecto/Postgrex sites differ (`Ecto.Query.CastError`, `Ecto.ConstraintError`); `System.cmd` sites raise `ErlangError`. The chosen list **must cover what the wrapped call can actually raise**, or a real exception escapes and crashes a boundary that previously stayed up.
- **Do not narrow sites whose job is to catch everything** (GenServer handlers, public-API entry points, the pluggable harness) — scope those instead (below).
- Keep existing `# credo:disable-for-previous-line ...` lines. Apply across `forge/persistence.ex`, `agent_view.ex`, `agent/handoff/router.ex`, `memory/consolidator/run_server.ex`, `tools/mcp_scope.ex`, `jido_claw.ex`, `setup/credential_validator.ex` (`validate_ollama/0` → `ErlangError`), etc.

**Scope — deliberate "never crash this boundary" catch-alls (legitimate per the single-user/reliability threat model):**
- **File-level** `# reach:disable-for-this-file bare_rescue` + moduledoc reason: `audit/producers.ex` ("audit write must never fail the producer", already documented). For `setup/prerequisite_checker.ex` (`System.cmd` probes) prefer **narrowing to `ErlangError`** (tighter, just as cheap).
- **Line-level** `# reach:disable-next-line bare_rescue` + reason (stable real code sites): `jido_claw.ex` public-API entries + one-line worker, `run_server.ex` harness boundary, `mcp_scope.ex` (rescue **+reraise** — already correct) and boot best-effort, `agent/handoff/router.ex` registry/test-seam, `agent_view.ex` sites paired with `catch :exit, _`, `run_server.ex` GenServer handlers.

### 2d · `behaviour_candidate` (2) + `trivial_forwarder` (1)

- **Forge runners** (`ClaudeCode/Codex/Custom/Fake/Shell/Workflow`, shared `init/2, run_iteration/3, apply_input/3`): **false positive** — these are exactly `JidoClaw.Forge.Runner`'s callbacks and the runners **already** `@behaviour JidoClaw.Forge.Runner`. **Do not extract anything.** Scope via config: `behaviour_candidate: [ignore: [modules: ["JidoClaw.Forge.Runners.*"]]]`, rationale as an adjacent `.reach.exs` comment (not a `reason:` key — see Suppression mechanics). (The related `forge/runner.ex` `iteration_result` map shape is handled in 2b.)
- **View modules** (`ForgeView/SwarmView/WorkflowView`, shared `list/1, snapshot/2, to_mcp_map/1`): deliberate surface-neutral parallel projections (cf. recent "Surface-neutral view projection" commit). Recommend **scope** via config `ignore: [modules: ["JidoClaw.ForgeView", "JidoClaw.SwarmView", "JidoClaw.WorkflowView"]]` rather than imposing a behaviour on freshly-designed parallel modules. (Extracting a `@behaviour` is a viable alternative if you want the contract enforced — your call at this gate.)
- **`trivial_forwarder` (1):** `swarm_view.ex` `defp scope_keys/0` → inline the call to `JidoClaw.AgentTracker.scope_keys/0` (private fn; safe).

---

## Phase 3 — Confirm zero + wire precommit (capstone)

1. `mise exec -- mix reach.check --arch --smells --strict` must **exit 0**.
2. Wire the gate into the `precommit` alias (`mix.exs:245-253`), **before** `credo --strict`:
   ```elixir
   "format",
   "reach.check --arch --smells --strict",   # ← new
   "credo --strict",
   ```
   Do **not** add `reach.otp --concurrency` (prints only; never halts).
3. Run `mise exec -- mix precommit` end-to-end.

---

## Critical files & patterns

- **`bare_rescue` narrowing template:** `lib/jido_claw/forge/persistence.ex:341-348` (exception list + credo pragma).
- **SQLi allowlist boundary:** `lib/jido_claw/embeddings/backfill_worker.ex:57-64`, `lib/jido_claw/workspaces/policy_transitions.ex:34`.
- **Wire/typed-map contracts (do-not-convert):** `tools/error.ex` (`@type t`), `forge/runner.ex` (`@type iteration_result`).
- **Existing runner behaviour (proves the false positive):** `lib/jido_claw/forge/runner.ex:21-30`.
- **Config-level scoping slot:** `.reach.exs` — add a `smells:` key (currently absent) for the two `behaviour_candidate` module-ignores.
- **Precommit alias:** `mix.exs:245-253`; allowlist-aware compile: `lib/mix/tasks/jidoclaw.compile_check.ex`.

## Verification

Per-batch loop (Phase 0) after **every** batch; final gate is `reach.check --arch --smells --strict` → 0 plus a clean `mix precommit`. Targeted checks:
- After scope actions: re-run reach and confirm the finding is **gone, not relocated**.
- After 2b convert: `setup/wizard.ex` **and** `web/live/setup_live.ex` still read credential fields correctly; all `CredentialCheck` construction sites (incl. the `validate_ollama/0` rescue) return the struct.
- After 2c narrow: `mix credo --strict` stays green, and confirm no narrowed list omits an exception the wrapped call can raise (esp. `Ash.Error.Forbidden`).
- `tools/error.ex` stays scoped, not converted — its ~87 test pattern-matches remain untouched and green.

## Risks & notes

- **Anchor instability** is the headline risk — see Suppression mechanics. Never trust a stale anchor line; verify suppression by re-running reach.
- **`bare_rescue` ≠ credo `RescueWithoutReraise`** — narrowing satisfies reach; verify credo on the first file before the whole batch.
- **Over-narrowing** a rescue can let a real exception escape a boundary — only narrow where the list provably covers the wrapped call; scope true catch-alls.
- **Count/anchor drift** — re-baseline at Phase 0; treat tables here as indicative.

## Commit policy

Batches map cleanly to `refactor:`/`fix:`/`docs:` commits, but **no commits will be made without an explicit request** — slicing here is guidance only. `.reach.exs` will gain a `smells:` block (2d) and belongs in the eventual commit.
