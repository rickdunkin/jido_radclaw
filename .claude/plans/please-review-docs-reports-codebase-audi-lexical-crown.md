# Plan — Batch bugfix PR from the 2026-07-04 codebase audit (§1)

## Context

The 2026-07-04 codebase audit (`docs/reports/codebase-audit-2026-07-04.md` §1) hand-verified
~13 bugs, framed by the report's own triage as "small verified bug fixes, each a
one-to-few-line change" (triage step #1). This PR resolves **11** of them as one coherent,
migration-free bugfix effort. Each is an independent, verified defect with an unambiguous
fix; each gets a **red→green regression test** (per the working agreement: write the test,
confirm it fails, then fix — never weaken an assertion), and the PR is done only when full
`mix precommit` passes (credo + reach strict at zero via `jidoclaw.compile_check`).

All 11 were re-verified against source by parallel exploration; three audit inaccuracies were
found and are corrected in the fixes below (1.7 needs an extra case arm, 1.10's helper is
private, 1.11 is 5 assign sites not 6).

**In scope (11):** 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.10, 1.11, 1.13.
**Deferred (documented below):** 1.9 (Forge session fields — needs a wire-vs-delete product
call + a DB migration).
**Out of scope:** 1.12 (JIDO.md self-contradiction — belongs to the §3 doc sweep, since
JIDO.md is a regenerated doc), 1.14 (`rescue` can't catch an exit — inside the dead GitHub
pipeline §2.1, only matters if that pipeline is revived).

---

## Cross-cutting engineering decisions (resolving the forks the audit left open)

- **1.4 → DRY single-source refactor** (not the minimal one-tuple add). Two private
  registries drifting is the actual defect class; collapse to one source of truth.
- **1.8 → central normalization in `Sandbox.run/4`** (not per-runner 124-matching), using
  **exact-message** matching so a user command that genuinely exits 124 is not misread.
- **1.10 → extract a shared `Compactor.Text` module** and migrate all 3 call sites
  (not duplicate the 11-line helper). Duplicating it 3× risks the ExSlop clone gate
  (min_mass 30); a forwarder-only delegate risks the reach trivial-forwarder smell — so
  extract, migrate every caller, delete the original.

---

## The 11 fixes (grouped by subsystem for implementation order)

### Group A — Counting / telemetry accuracy

**1.1 `[H]` AgentTracker double-counts tool calls**
- **Fix:** `lib/jido_claw/agent_tracker.ex:310` — drop the `track_tool/2` call from the
  `:stop` telemetry handler (its own comment admits it's "redundant"); the `:start` handler
  (line 295) already fires once per call and is the single source of truth. Leave the `:stop`
  attach/detach intact. Timeouts route to `:exception` (not `:stop`) so they already count
  once and stay correct.
- **Test:** `test/jido_claw/agent_tracker_test.exs` (new describe — no tool-tracking test
  exists today). Emit both `[:jido,:ai,:tool,:execute,:start]` and `:stop` for a registered
  agent, `drain()`, assert `state.agents[id].tool_calls == 1` (== 2 before fix). Mirror the
  emit pattern at `test/jido_claw/agent_view_test.exs:79-83`; use `register/5` + `drain()` +
  `get_state`.

**1.5 `[H]` Consolidator reports `blocks_revised: 0` forever**
- **Fix:** `lib/jido_claw/memory/consolidator/run_server.ex` — `apply_block_updates/1`
  (~836-854) accumulator `0` → `%{written: 0, revised: 0}`; have
  `maybe_revise_or_write_block/2` (~874-897) tag its result `{:ok, :written, block}` /
  `{:ok, :revised, block}`; `apply_proposals/1` (~768, 780-781) destructures both and sets
  both counts (remove the hardcoded `0` at 781). Telemetry (1181) and CLI
  (`cli/commands.ex:306`) already read `blocks_revised` and light up automatically. Note in
  PR: `blocks_written` now means writes-only (was writes+revises) — intended correction.
- **Test:** `test/jido_claw/memory/consolidator/run_server_test.exs` — add a **revise**
  scenario (none exists): seed an active block for a label, then run a 2nd
  `propose_block_update` for the same label; with a single revise proposal, assert **exact**
  counts — `run.blocks_revised == 1` and `run.blocks_written == 0` (not `>=`) — to pin the
  writes-only semantic change. Mirror the write test (57-93):
  `run_now(scope, fake_proposals:, override_min_input_count: true, await_ms:)`.

**1.2 `[H]` (dev-only) Five LiveDashboard metrics can never fire (event-name mismatch)**
- **Fix:** `lib/jido_claw/core/telemetry.ex` lines 27/33/40/70/96 — add an explicit
  label-preserving `event_name:` to each: session→`[:jido_claw,:session,:stop]`,
  provider.request→`[…,:request,:stop]`, tool.execute→`[…,:execute,:stop]`,
  cron.job→`[…,:job,:stop]`, and `last_value` tenant.count→`[:jido_claw,:tenant,:count]`
  (keep `measurement: :count`).
- **Caveat to record in the PR body:** only **3/5** go live (session, cron, tenant —
  emitters are wired). provider/tool tiles stay empty because
  `emit_provider_request_*` / `emit_tool_*` (telemetry.ex:146-199) have **zero callers**
  (§2.8 dead emitters); wiring or deleting those is a separate decision, not this bug.
- **Test:** new `test/jido_claw/core/telemetry_test.exs` (none exists) — assert
  `JidoClaw.Telemetry.metrics()` structs carry the correct `event_name` (and tenant.count's
  `measurement`). Pure, `async: true`.

### Group B — Tool contract correctness

**1.3 `[H]` `replay_workflow` reports a failed replay as a tool *error***
- **Fix:** `lib/jido_claw/tools/replay_workflow.ex:29` (output_schema key) and `:112`
  (summarize map key) — rename `status` → `run_status`, matching the `inspect_workflow`
  precedent (`inspect_workflow.ex:47`, rationale at 42-46). The shared wrapper's
  `Error.normalize_result/1` (`tools/error.ex:80-84`) promotes `{:ok, %{status: "failed"}}`
  to an error envelope; renaming the key dodges it and honors the tool's own documented
  contract (replay_workflow.ex:103-106). Leave `message` (line 113).
- **Ripple:** existing `test/jido_claw/tools/replay_workflow_test.exs:54` `output.status` →
  `output.run_status`.
- **Test:** same file — new case where the replay's **new** run ends `:failed`, asserting the
  tool stays `{:ok, %{run_status: "failed"}}` with `new_run_id` intact (returns `{:error, _}`
  before the fix). **Drive the failure through the replay launch, not the fixture's terminal
  status:** the replayed run's outcome comes from `ReactorRunner.run/3` at `replay.ex:258`
  (synchronous for module-reactors), so configure a **failing stub/template** via the
  `agent_templates_override` / EchoStub seam (setup 34-36). A `:failed` variant of
  `forge_terminal_run!/2` would only fail the *original* run, not the replayed one.

### Group C — Forge sandbox timeout correctness (two faces of one root inconsistency)

Root cause: the two sandbox backends disagree on timeout representation — HostShell uses the
`:timeout` atom, Docker uses exit `124` — because the `exec` Behaviour spec is integer-only
while `run`/`exec_argv` allow `:timeout`. These two fixes make both honest without the larger
canonicalization refactor.

**1.7 `[H]` `HostShell.exec/3` silently drops the caller's timeout** (bigger than the audit's
one-liner)
- **Fix:** `lib/jido_claw/forge/runner/host_shell.ex` — (1) line 69 `_opts` → `opts`, compute
  `timeout = Keyword.get(opts, :timeout, :infinity)`, and pass `timeout: timeout` (was
  hardcoded `:infinity`) at line 87; (2) **add a case arm**
  `{_partial, :timeout} -> {"timeout after #{timeout}ms", 124}` to the case at 84-91 —
  without it a real timeout is a `CaseClauseError` caught by the `rescue` and misreported as
  exit 1. Return `124` (integer), pinned by the Behaviour spec (`behaviour.ex:4-5`,
  integer-only), Docker parity (`docker.ex:390-391`), and `ForgeBridge`'s exact
  `{"timeout after #{n}ms", 124}` match (`run_command/forge_bridge.ex:28-29`).
- **Test:** `test/jido_claw/forge/runner/host_shell_test.exs` — drive
  `HostShell.exec(client, <sleep>, timeout: <short>)`, assert `{_, 124}`. Mirror the
  `exec_argv` timeout block (132-150) and the output-cap `exec/3` test (82-90). (File comment
  116-119 already flags this exact gap.)

**1.8 `[M]` Docker timeouts misclassified by the claude_code/codex runners**
- **Fix (central normalization in `Sandbox.run/4`, `lib/jido_claw/forge/sandbox.ex:26-37`):**
  Docker manufactures exactly `{"timeout after #{timeout}ms", 124}` (`docker.ex:389-391`)
  from the same `timeout` opt that flows through `Sandbox.run/4`, whose `@spec` already
  permits `:timeout`. Normalize that back to `:timeout` so both runners
  (`runners/claude_code.ex:86`, `runners/codex.ex:128`) — which already handle `:timeout` —
  classify it as `harness_timeout`. The `exec` path (which ForgeBridge matches on 124) is
  untouched; do **not** reclassify 153 (output-limit) or 127 — separate judgment.
  - **Match only the exact manufactured tuple — one path, no looser fallback.** `Sandbox.run/4`
    has `opts \\ []`, so fetch safely (`Keyword.fetch(opts, :timeout)`, **not** `fetch!`); only
    when it's a positive integer `t`, build `expected = "timeout after #{t}ms"` and rewrite
    **only** `{^expected, 124}` → `{expected, :timeout}`. Absent/`:infinity` ⇒ passthrough
    unchanged. No prefix match and no `\d+ms` regex — both could still misclassify a real
    exit-124 whose output happens to read `timeout after <n>ms`; the only tuple that matches is
    the one Docker itself manufactures for the timeout in play.
- **Implementation check:** confirm the runners call `Sandbox.run/4` (exploration evidence
  says they do — grep found no other consumers). If any runner dispatches to the backend
  module directly, fall back to per-runner arms (Option A) in both runners.
- **Test:** `test/jido_claw/forge/runners/codex_test.exs` — program the stub with a message
  matching the timeout the runner actually passes to `Sandbox.run/4`. **The plan's earlier
  `"timeout after 5000ms"` literal was wrong:** Codex defaults to `600_000ms`, Claude to
  `300_000ms`, so either pass an explicit short `timeout: 5000` through the runner call (if
  the API threads it) and program `{"timeout after 5000ms", 124}`, or build the expected
  message from the runner's default timeout — the programmed message **must** equal
  `"timeout after #{t}ms"` for whatever `t` the runner passes, since the fix matches that exact
  string. Assert `%{status: :error, error: "harness_timeout"}` (mirror the `:timeout`
  test at 240-244). Add a **new** `run_iteration/3` describe to
  `test/jido_claw/forge/runners/claude_code_test.exs` (it has only `init/2` tests today),
  cloned from codex's, for the same assertion.

### Group D — Data safety

**1.10 `[M]` UTF-8-unsafe byte truncation in compaction persistence** (audit's fix is wrong —
helper is private)
- **Fix:** extract `utf8_safe_prefix/2` + `do_utf8_safe_prefix/2` from
  `lib/jido_claw/reasoning/compactor.ex:553-568` into a new module
  `JidoClaw.Reasoning.Compactor.Text` (public `def`). Migrate all 3 sites:
  - `compactor.ex:547` — call `Text.utf8_safe_prefix/2`, delete the private copy;
  - `reasoning/compactor/snapshot.ex:157` — `head = Text.utf8_safe_prefix(string, limit)`
    (keep `head <> "…"`);
  - `reasoning/compactor/summarizer.ex:210` — `Text.utf8_safe_prefix(text, limit)`.
  Both raw `<<head::binary-size(^limit), _::binary>>` cuts can split a multibyte codepoint,
  producing invalid UTF-8 that fails Jason/Postgrex in `Storage.persist` and silently drops
  the (best-effort) compaction.
- **Name/doc the budget as bytes, not chars:** the helper is a **byte** cap
  (`utf8_safe_prefix(str, max_bytes)`), and its callers pass `limit`/`max_summary_chars`
  values that are really byte budgets. Keep the byte-accurate name and add a one-line doc note
  on `Compactor.Text` (and at the call sites) that the budget is bytes — so the fix doesn't
  deepen the existing char/byte misnomer around `summarizer.ex:206`'s `max_summary_chars`
  (renaming that config is out of scope; just don't reinforce it).
- **Test:** `test/jido_claw/reasoning/compactor/snapshot_test.exs` (preview/2 describe,
  106-117) — add `text = String.duplicate("é", 10)`, `assert String.valid?(Snapshot.preview(text, 5))`
  (RED today). `test/jido_claw/reasoning/compactor/summarizer_test.exs` — add a
  `MultibyteBackend` returning `String.duplicate("😀", 10)`, `config(…, max_summary_chars: 6)`,
  assert `String.valid?(summary)` **and** `byte_size(summary) <= 6` (use `<=`, not `==`).
  Optional direct `Compactor.Text` unit test.

### Group E — Web UI error surfacing

**1.11 `[H]` LiveView load errors written to assigns that are never rendered** (template-only;
5 assign sites, not 6)
- **Fix:** `lib/jido_claw/web/live/workflows_live.ex` — replace the single empty-state row
  (~385-389) with an error row `:if={@runs_error}` **plus** a gated empty row
  `:if={is_nil(@runs_error) and @runs == []}` (colspan 6), mirroring `@steps_error`
  (301-303). `lib/jido_claw/web/live/projects_live.ex` — same shape, colspan 4 (~49-53). The
  `runs_error`/`projects_error` assigns already flow; no handler changes.
- **Test:** `test/jido_claw/web/live/workflows_live_test.exs` — the existing `render_runs/1`
  helper (89-107) hardcodes `runs_error: nil`, so first make it overrideable
  (`render_runs(runs, overrides \\ [])`, merging into the assigns with `runs_error: nil` as
  the default) or build a direct assigns map in the new test. Then render with
  `runs: [], runs_error: "Could not load workflow runs"`,
  `assert html =~ "Could not load workflow runs"` and `refute html =~ "No workflow runs yet"`.
  New `test/jido_claw/web/live/projects_live_test.exs` (none exists) — pure render test
  building the assigns map (`projects: []`, `projects_error: …`, `flash: %{}`, `__changed__: %{}`).

### Group F — Cosmetic / hygiene

**1.6 `[H]` Boot banner hardcodes "6 agent types"**
- **Fix:** `lib/jido_claw/cli/branding.ex` — mirror the `tools_count` sibling: add
  `templates_count: opts[:templates_count] || length(JidoClaw.Agent.Templates.names())` to
  the `info` map (~line 57) and interpolate `#{info.templates_count}` at line 90. Use
  `Templates.names/0` (Map.keys), not `list/0` (hydrates every template). 16 templates exist.
- **Test:** new `test/jido_claw/cli/branding_test.exs` — `CaptureIO` around
  `Branding.boot_sequence(tmp_dir)`, assert output contains
  `"#{length(JidoClaw.Agent.Templates.names())} agent types"` (wired to source, not a literal
  16). Slightly slow (the animation sleeps); acceptable.

**1.13 `[M]` `Inspection.skills_summary/0` mislabels a field**
- **Fix:** `lib/jido_claw/inspection.ex:363` — `version:` → `max_iterations:` (value
  `Map.get(s, :max_iterations)` unchanged; the Skill struct has no `:version`). Update the
  `@type skill_summary` at `lib/jido_claw/inspection/summary.ex:28`
  (`version: term()` → `max_iterations: pos_integer() | nil`). No prod reader consumes the
  key (MCP projection drops skills), so nothing breaks. (The unused `tool_summary` `version:`
  at summary.ex:27 is a separate latent nit — flag only, out of scope.)
- **Test:** `test/jido_claw/inspection_test.exs` — inspect a module target and assert the
  `skills` entries expose `:max_iterations`, not `:version`.

**1.4 `[H]` Release patch registries desynced (STDIO patch beam not relocated in prod)**
- **Fix (DRY — collapse the drifting registries to one source of truth). Four sites:**
  1. `lib/jido_claw/core/dependency_patches.ex` — add a public `patched_modules/0` accessor
     returning the existing private `@patched_modules` (already the correct 5, incl.
     `{Jido.MCP.Transport.STDIO, :jido_mcp}`).
  2. `lib/mix/tasks/compile.jidoclaw_release_patches.ex` — delete `@patched_dependency_beams`
     (lists only 4 — missing STDIO). Add a pure `patched_beams/0` returning
     `JidoClaw.Core.DependencyPatches.patched_modules()` (with a defensive
     `Code.ensure_loaded!/1`) and have `run/1` iterate `patched_beams()`. Compile ordering is
     safe: `compilers/0` (mix.exs:82-87) inserts `:jidoclaw_release_patches` *after* `:elixir`
     (`:app -> [:jidoclaw_release_patches, :app]`), so `DependencyPatches` is already compiled
     when the task runs.
  3. `lib/jido_claw/core/mcp_stdio_transport_patch.ex:29` — fix the stale header comment to
     reference the single list.
  4. **`mix.exs:15-30`** — the comment documenting `ignore_module_conflict: true` (line 31)
     says "Intentionally redefining **four** upstream modules" and enumerates only the anubis
     + 3 jido_shell patches, omitting the STDIO patch it *also* silences. Update it to
     **five**, adding the `mcp_stdio_transport_patch.ex` entry. (Same patch-inventory drift
     1.4 targets — sweep every inventory, prose comments included.)
- **Severity note for the PR:** the observable impact is **release hygiene**, not a missing
  runtime patch — `DependencyPatches.ensure_loaded!/0` (`application.ex:31`) force-loads the
  STDIO patch at boot in every env, so the env-scrubbing behavior still applies in prod; the
  bug is that prod ships two beams for the module and relies on boot force-load instead of a
  clean relocated release.
- **Test:** new `test/jido_claw/core/dependency_patches_test.exs` — a **pure, env-independent**
  guard using the site-2 seam (the real `run/1` is prod-gated, so don't drive it): assert
  `{Jido.MCP.Transport.STDIO, :jido_mcp} in DependencyPatches.patched_modules()` **and**
  `Mix.Tasks.Compile.JidoclawReleasePatches.patched_beams() == DependencyPatches.patched_modules()`
  (use the full module name or an explicit alias — the bare form is shorthand). Fails today
  (task's private 4-item list, no STDIO); passes once both read the single source, and
  re-fails if anyone re-introduces a private list in the task.

---

## Deferred: Bug 1.9 findings (documented per request, not implemented here)

**1.9 `[H]` Forge session UI fields that can only ever be 0 / nil** — `lib/jido_claw/forge/resources/session.ex`.
Needs a wire-vs-delete product call **and** a DB migration, so it is out of scope for this
migration-free batch. Full findings, captured so they need not be rediscovered:

- **`execution_count` is always 0.** Only writer is `set_attribute(:execution_count, 0)` in
  the `:start` action (session.ex:82), and it's in `upsert_fields` (line 75) so every
  wake/re-upsert re-zeroes it. No increment exists anywhere. Read at `forge_view.ex:126` and
  rendered at `forge_live.ex:38` (under the "Executions" `<th>`).
- **`last_error` is always nil.** Writers are `set_attribute(:last_error, nil)` in `:start`
  (session.ex:81, also in upsert_fields) and `set_attribute(:last_error, arg(:error))` in
  `:mark_failed` (session.ex:100) — but **`:mark_failed` has zero callers**. Failures route
  through `Persistence.update_session_phase/2` (`persistence.ex:271`, `:update_phase` action),
  which never touches `last_error` (e.g. `manager.ex:123`, harness terminal `harness.ex:799`).
  Doubly dead: the map key it's put into (`forge_view.ex:130`) has no reader either.
- **Three dead Ash actions ride along:** `:mark_failed`, `:cancel` (cancellation uses
  `update_session_phase(:cancelled)`), `:list_active` (ForgeView filters phases directly at
  forge_view.ex:105-116). All zero prod callers.
- **Delete path (smaller, recommended if the dashboard doesn't need live values):** drop the
  `execution_count` + `last_error` attributes (session.ex:220-229), remove both from
  `upsert_fields` (74-75) and their `set_attribute` changes (81-82), delete `:mark_failed`
  (95-102 + define 44), optionally `:cancel` (112-117 + define 46) and `:list_active`
  (127-143 + define 48), and remove the two render cells (`forge_view.ex:126,130`,
  `forge_live.ex:30,38`). **Requires an Ecto migration** to drop the two columns. Tiny
  consumer surface.
- **Wire path:** remove `:execution_count` from `upsert_fields` + drop the `:start` zero-set
  (the `default(0)` at session.ex:223 covers genuine creates); add
  `update :record_execution do change atomic_update(:execution_count, expr(execution_count + 1)) end`
  + a code_interface define; **call it at execution completion** — the ambiguous part is
  *where* "an execution" is (harness running→ready seam ~harness.ex:465/496). For `last_error`,
  route terminal failures through `:mark_failed` (or extend `update_session_phase` to accept
  an error string) and thread the error text to the terminal call site.
- **Test conventions if picked up:** `test/jido_claw/forge_view_test.exs`
  (`use JidoClaw.TenantCase, async: false`, `Persistence.record_session_started/2` seeding);
  a new `test/jido_claw/forge/session_test.exs` could unit-test the increment / `:mark_failed`
  actions directly.

**Durable-doc task (part of this PR):** persist the above into the repo (recommended: a short
`docs/reports/forge-session-fields-1.9-followup.md`, or expand the §1.9 entry in the audit
report) so the deferral carries its own implementation notes.

---

## Verification

1. **Per-bug red→green:** for each fix, run the new/updated test first with the fix reverted
   to confirm RED, then with the fix to confirm GREEN. Never weaken an assertion to pass.
   - Single-file runs, e.g. `mix test test/jido_claw/agent_tracker_test.exs`,
     `mix test test/jido_claw/tools/replay_workflow_test.exs`,
     `mix test test/jido_claw/forge/runner/host_shell_test.exs`,
     `mix test test/jido_claw/reasoning/compactor/summarizer_test.exs`, etc.
2. **Behavioral spot-checks (Tidewave / REPL where cheap):**
   - 1.1 — emit `:start`+`:stop` telemetry for a registered agent, confirm `swarm_status`
     shows one call.
   - 1.6 — run `mix jidoclaw` and confirm the banner reads the live template count (16), not 6.
   - 1.3 — replay a workflow whose run fails; confirm the tool returns `{:ok, run_status: "failed"}`
     with `new_run_id` intact, not an error envelope.
3. **Full gate:** `mix precommit` (mix.exs:255) runs, in order,
   `jidoclaw.compile_check` → `jidoclaw.system_prompt.check` → `deps.unlock --unused` →
   `format --check-formatted` → `reach.check --arch --smells --strict` → `credo --strict` →
   `dialyzer --format short` → `test` (full suite, `MIX_ENV=test`). Budget for it — dialyzer
   (PLT) and the full suite are the slow parts. Run the bare command and read its own verdict
   lines; never pipe through `tail`/`head`/`grep` (masks exit codes). Report exact exit code +
   test counts.
4. **Staging:** stage only the files touched by these fixes + their tests + the 1.9 follow-up
   doc; never sweep unrelated edits. Commit only when asked.

### Watch-outs baked in
- **Precommit runs dialyzer + the full suite**, not just compile/format/credo/reach:
  - **Dialyzer** sees the `@type skill_summary` change (1.13) and the `Sandbox.run/4` spec
    surface (1.8) — keep both green; refresh the PLT if stale.
  - **Full `test`** may surface the known-flaky `MemoryExportTest` (capture_log race under
    full precommit — passes in isolation); not a regression from this PR.
  - **`system_prompt.check`** — none of these fixes touch the tool catalog/system prompt, so
    it should stay green; if it flags, something unexpected changed.
- **1.10 / 1.4** extractions: migrate every call site and delete the original (no
  duplicate-clone, no trivial-forwarder) so the `reach --smells --strict` gate stays at zero.
- **1.3** existing test line 54 must be updated in lockstep with the key rename.
- **1.5** `blocks_written` semantic change (writes-only) documented in the PR body.
- **1.2** provider/tool tiles stay empty (dead emitters) — noted as a known, separate item.
