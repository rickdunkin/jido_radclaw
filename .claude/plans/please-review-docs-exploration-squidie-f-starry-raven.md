# Phase 4 — Workflow Definition Fingerprint + Replay (T1-3)

## Context

`docs/exploration/squidie/REACTOR-ADOPTION.md` (status reconciliation, 2026-06-09) records Phases 0–3 of the Reactor adoption as complete and names the next scope: **Phase 4 — definition fingerprint + replay** (FEATURES-WORTH-BORROWING T1-3, Reactor doc §4.7). This plan implements it.

**Why this matters:** skills are LLM-edited YAML. Re-running a prior run after the skill file changed would silently execute different semantics, and re-running a step that already performed an irreversible side effect (pushed a commit, sent a message) is a real footgun. The fix: hash the definition at run start, persist it, and give replay two safety gates — refuse on definition mismatch (override: `force`) and refuse when the original run executed irreversible steps (override: `allow_irreversible`).

**Groundwork already in place (Phases 0–3):** the dormant `retry_of_id` column on `WorkflowRun` (accepted by `:create`, never written), and `ReactorMiddleware` stamping `irreversible: true` into `step_*` event payloads explicitly "for the Phase-4 replay gates" (`reactor_middleware.ex` ~280-295).

**Blocking gap discovered:** a run's original inputs are **never durably stored** — they exist only inside the gate checkpoint (`encrypted_resume_checkpoint`), which is cleared on every terminal. Replay therefore must also add durable input storage at create time.

Greenfield: no backwards compat. Pre-existing rows simply read as non-replayable (`:no_inputs` / `:no_hash`).

**Completion bar (per user): `mix precommit` passes** (run as `mise exec -- mix precommit`).

## Decisions (settled; incorporates user review)

1. **Fingerprint basis = canonical semantic term, mirroring compiler semantics — not raw YAML text.** Raw text isn't retained by `Skills.parse_skill_file/1`, tests/tools build `%JidoClaw.Skills{}` structs directly, and comment/whitespace edits shouldn't invalidate replay. Hashing the compiled `%Reactor{}` struct is impossible: `Reactor.Builder.new(id \\ make_ref())` stamps a fresh ref per compile. Module reactors: `module.module_info(:md5)`.
2. **Replay re-resolves skills from DISK, never the cache.** `Skills.get/2` ignores `project_dir` and serves the boot-time GenServer cache (`skills.ex:341-346`) — comparing against it would defeat the hash gate when the YAML changed on disk after the run. Add a public fresh-disk lookup that enumerates `.jido/skills/*.yaml` and finds by `skill.name` field — **never** constructing a path from user-controlled run names.
3. **Durable inputs = second AshCloak-encrypted attribute** on `WorkflowRun` (`replay_inputs`, stored `encrypted_replay_inputs`), written at create, **never cleared** (the `clear_checkpoint` force-clear touches only `encrypted_resume_checkpoint`). Blob: `term_to_binary({@replay_version, inputs, extra_context})` — all-data, `[:safe]`-decodable, preserves atom keys.
4. **Replay preserves durable scope; only synthetic cron scratch is replaced.** `RunSkill.scope_context/1` deliberately forwards `tenant_id`/`session_id`/`session_uuid`/`workspace_id`/`workspace_uuid`/`project_dir`/`user_id`/`actor` (`run_skill.ex:89-100`), and `AgentRunner` uses that scope for child transcript/correlation writes. Keep all of it on replay, except: (a) a `workspace_id` matching `"cron:" <> _` (per-tick scratch, `workflow_runner.ex:64`) is replaced with a fresh `"replay:<original-short-id>:<unique>"`; (b) drop `:actor` from the decoded context — the launch opts supply the live actor (base-wins in `ReactorRunner` already enforces this; dropping avoids carrying a stale embedded actor).
5. **Replay entry point = module function** `JidoClaw.Orchestration.Replay.replay/2` (precedent: `Cases.decide/4`), NOT an Ash action. **Uniform envelope:** `{:ok, new_run} | {:error, reason}` — `{:ok, run}` whenever a replay run came into existence (callers inspect `run.status`/`run.error`, incl. a run that launched and then failed or paused at a gate); `{:error, reason}` for refusals and pre-run launch failures. One two-way branch for every caller.
6. **Hash computation split:** `ReactorRunner` self-computes for module reactors; skill callers (`WorkflowRunner`, `RunSkill`, tests) pass `definition_hash:` since only they hold the `%Skills{}` struct.
7. **Surfaces (user choice): dashboard button + MCP tool — and nothing broader.** Dashboard gets the `force`/`allow_irreversible` override affordances; the **MCP tool exposes `run_id` only — no override flags** (overrides stay operator-only, per the gate philosophy / threat model). The tool is registered in `MCPServer` **only**, NOT in the in-REPL agent's tool list — giving the autonomous agent a replay side-effect lever is broader than the chosen surfaces (trivially reversible later).
8. **Scope guard:** Phase 4 only. No cron idempotency, deadlines, actor-visibility redaction, or graph layout (Phase 5 follow-ups).

## Work items (ordered)

### W0 — Pre-work cleanups the fingerprint depends on

- **`lib/jido_claw/workflows/step_normalizer.ex`**: reconcile the moduledoc's canonical-key prose/count with the actual `@canonical_keys` allowlist (user review flagged a doc/implementation drift around `:compensate` et al.). Extend `test/jido_claw/workflows/step_normalizer_test.exs` to cover `retry`, `compensate`, `irreversible` normalization (string→atom key, idempotence, unknown-key drop).
- **`lib/jido_claw/platform/skills.ex`**: add a public fresh-disk lookup, e.g. `load_skill(name, project_dir)` — reuse the private `load_from_disk/1` + `parse_skill_file/1` (enumerate `skills_dir(project_dir)`, parse all YAMLs, match on `skill.name`). **Handle duplicate names deterministically**: `File.ls/1` is unsorted (`skills.ex:399`), so two files declaring the same `name:` would make replay pick one nondeterministically — return `{:error, {:duplicate_skill_name, name}}` when more than one matches. Returns `{:ok, %Skills{}} | {:error, …}`. Document that replay uses this (cache bypass) while normal launch keeps using the cache.

### W1 — `lib/jido_claw/orchestration/definition_fingerprint.ex` (NEW, pure)

- `for_skill(%JidoClaw.Skills{})` and `for_module(module)` → 64-char lowercase sha256 hex (precedent: `lib/jido_claw/solutions/fingerprint.ex:81-89`). `for_module/1` = `module.module_info(:md5) |> Base.encode16(case: :lower)`.
- **`for_skill/1` builds a normalized semantic term, then hashes `:erlang.term_to_binary({:v1, term}, [:deterministic])`** (deterministic map encoding; the `:v1` tag allows algorithm evolution). Caveat to document: deterministic encoding is stable within an OTP major; an OTP upgrade could theoretically shift encodings → mass `:definition_changed` refusals, recoverable via `force:`.
- **Semantic term mirrors compiler semantics** (user review):
  - `name`; **mode via `Skills.execution_mode/1`** (`:iterative | :dag | :sequential` — the actual compiler branch, `skills.ex:332-339`), not the raw `mode` field; `synthesis`.
  - `max_iterations` included **only for `:iterative`** skills, normalized `nil → 3` (the `IterativeStep` runtime default, `iterative_step.ex:36`); semantically inert for other modes so excluded there.
  - Steps: `StepNormalizer.normalize/1` first (string-keyed ≡ atom-keyed by construction), then per step build a key-sorted list over the canonical allowlist, with compiler-equivalent defaults: `retry` nil→`0` (compiler `max_retries` default), `irreversible` nil→`false` (compiler default, `compiler.ex:332`), `depends_on`/`consumes` normalized-to-list **preserving order** (order IS semantic: the compiler builds `upstream`/`consumes_tuples` in YAML order, `compiler.ex:293`, and `ContextBuilder` renders dependency/artifact prompt sections in received order, `context_builder.ex:36,88` — so reordering changes the prompt the LLM sees), `produces` with keys recursively stringified + key-sorted (map key order is not semantic), string fields normalized nil-consistently.
  - **Exclude `description`** (docs, not semantics).

### W2 — `lib/jido_claw/orchestration/workflow_run.ex`

- Add `definition_hash :string` (`public?(true)`, nilable).
- Add `replay_inputs :binary` (`public?(false)`, nilable); cloak block becomes `attributes([:resume_checkpoint, :replay_inputs])`.
- Widen `:create` accept with `definition_hash`, `replay_inputs` (`retry_of_id` already accepted).
- No new actions ⇒ no credo `MissingCodeInterface`/`ActionMissingDescription` entries expected.

### W3 — `lib/jido_claw/orchestration/reactor_runner.ex`

- New opts: `:definition_hash`, `:retry_of_id` (both `Keyword.get`, default nil). `@replay_version 1`.
- Module branch self-computes hash via `DefinitionFingerprint.for_module/1`; struct branch uses the opt.
- `config` gains `definition_kind: "skill" | "module"` (derived from whether the reactor arg is a module) and, when present in the caller's context map, `project_dir` — so replay can locate the skill dir from string-keyed `config` WITHOUT first decoding the inputs blob (required by W5's resolve-before-decode ordering).
- Encode `replay_inputs = :erlang.term_to_binary({@replay_version, inputs, extra_context})` **in the pre-run body before the `with`** — a raise there lands in the existing body-level rescue → `{:error, {:exception, msg}, nil}`, preserving the never-raises contract with zero new rescue code.
- Thread `definition_hash`, `replay_inputs`, `retry_of_id` into the `WorkflowRun.create` attrs. No changes to `execute/6`/`finalize/3`/checkpoint paths. Update moduledoc.

### W4 — `lib/jido_claw/orchestration/reactor_middleware.ex`

- In `init_for_state/2`'s initial-start branch (~line 139): add `definition_hash` to the `run_started` payload when present on the run from context (reuse the existing `put_present`-style helper). Purely additive; no projection change.

### W5 — `lib/jido_claw/orchestration/replay.ex` (NEW — the chokepoint)

`replay(run_id, opts)` — `tenant:`/`actor:` via **`Keyword.fetch/2` → `{:error, :missing_required_opt}`** (NOT `fetch!` — preserves the uniform never-raise envelope); `force:`/`allow_irreversible:` default false. Pipeline (**re-resolve BEFORE decode** — see step 4/5 ordering note):

1. **load** — `WorkflowRun.by_id` (tenant-scoped ⇒ tenant isolation for free); nil → `{:error, :not_found}`.
2. **ensure terminal** — status ∉ `[:completed, :failed, :cancelled, :abandoned]` → `{:error, {:not_replayable, :run_not_terminal}}`.
3. **resolve config** — `config["definition_kind"]` ∈ {"skill","module"} (config is string-keyed jsonb on read); `config["reactor"]` is the identity.
4. **re-resolve definition (fresh) — FIRST, before decoding the blob**, so the definition's atoms are interned/loaded when `[:safe]` decode runs (after a fresh VM start, module-specific input-key atoms may not exist yet — decoding first would false-fail as `:corrupt_inputs`; same concern `gate_resume.ex:136`'s two-stage decode addresses). *skill*: **`Skills.load_skill(name, project_dir*)`** (the W0 disk-backed lookup — NOT the cached `Skills.get`) + `Compiler.compile` + `for_skill`. *module*: prefix allowlist `"JidoClaw.Orchestration.Reactors."` (note: config identity is `inspect(module)` — **no** `Elixir.` prefix, unlike GateResume's checkpoint strings) → `String.to_existing_atom("Elixir." <> identity)` (rescue ArgumentError) + `Code.ensure_loaded?` + `Spark.Dsl.is?(module, Reactor)` + `for_module`. (*Skill path sources `project_dir` from string-keyed `config["project_dir"]` — recorded at create by W3 — else `File.cwd!()`; it must not depend on the not-yet-decoded blob.*)
5. **decode inputs** — `Ash.load(run, :replay_inputs)` (mirror `gate_resume.ex:122-134` cloak-decrypt incl. its `# reach:disable-next-line bare_rescue`); nil → `:no_inputs`; `binary_to_term([:safe])` matching `{@replay_version, inputs, extra}` with typed `ArgumentError` rescue → `:corrupt_inputs`. Blob preserves **atom keys** (vs string-keyed config — respect the asymmetry).
6. **hash gate** — stored nil → `:no_hash`; mismatch → `{:error, {:definition_changed, stored, current}}` unless `force` (log a warning when forcing past a diff).
7. **irreversible gate** — scan `WorkflowEvent.for_run(original)` for `kind in [:step_started, :step_completed, :step_failed]` with `payload["irreversible"] == true` (string-keyed jsonb) → `{:error, :irreversible_steps_executed}` unless `allow_irreversible`. A `for_run` read error bubbles up — never permit an unsafe replay on a failed read.
8. **launch** — `ReactorRunner.run(reactor, inputs, tenant:, actor:, name: original.name, async?: skill→true / module→false, context: replay_context(extra, original), definition_hash: (skill: current hash / module: nil — runner self-computes), retry_of_id: original.id)`. `replay_context/2` per Decision 4: keep durable scope verbatim; replace only a `"cron:" <> _` `workspace_id` with `"replay:<short-id>:<unique>"`; drop `:actor`.
9. **map envelope** — `{:ok, _value, run}` → `{:ok, run}`; `{:error, _reason, %WorkflowRun{} = run}` → `{:ok, run}` (replay launched; outcome lives on the run); `{:error, reason, nil}` → `{:error, {:launch_failed, reason}}`.

Refusal taxonomy: `:not_found` · `{:not_replayable, :run_not_terminal | :no_definition_kind | :no_inputs | :corrupt_inputs | :no_hash | :skill_unavailable | {:compile_failed, _} | :module_unavailable | {:disallowed_module, _}}` · `{:definition_changed, stored, current}` · `:irreversible_steps_executed` · `{:launch_failed, _}`.

### W6 — Wire the skill callers (one line each)

- `lib/jido_claw/orchestration/workflow_runner.ex` and `lib/jido_claw/tools/run_skill.ex`: after `Compiler.compile(skill)`, add `definition_hash: DefinitionFingerprint.for_skill(skill)` to the `ReactorRunner.run` opts.

### W7 — Dashboard replay button (`lib/jido_claw/web/live/workflows_live.ex`)

- The **whole row currently has `phx-click="toggle_steps"`** (`workflows_live.ex:55-60`). Add a 5th **Actions** column and prevent double-fire: either move the toggle binding onto the data cells (Name/Type/Status/Started) leaving the Actions cell unbound, or stop propagation on the Actions cell. Update both `colspan="4"` occurrences (expanded-steps row, empty state) to 5.
- Replay button rendered only for terminal-status runs → `handle_event("replay", …)` → `Replay.replay(id, tenant:, actor:)` using the socket's current tenant/actor (follow how the LiveView already scopes its reads).
- `{:ok, run}` → flash (include new run status) + refresh list. `{:error, {:definition_changed, …}}` → flash offering a force re-click (`phx-value-force`). `{:error, :irreversible_steps_executed}` → flash offering `allow_irreversible`. Other refusals → informative flash.
- Consult the phoenix-framework skill for LiveView idiom when implementing.

### W8 — MCP tool (`lib/jido_claw/tools/replay_workflow.ex` NEW + registration)

- `use JidoClaw.Tools.Action` — the wrapper **already** wraps `run/2` with MCPScope, redaction, and output limiting (`tools/action.ex:37`), so do NOT copy `RunSkill`'s manual `MCPScope.wrap` call; **mirror `WorkflowStatus`'s simpler shape** instead (plus `RunSkill`'s `resolve_tenant`/`resolve_actor` helpers for tenant/actor extraction from `tool_context`).
- Schema: `run_id` (required) **only — deliberately no `force`/`allow_irreversible` params**; the tool description states refusals require the dashboard.
- Map `{:ok, run}` → `{:ok, %{new_run_id, status, …}}`; refusals to clear error strings.
- **Register in `JidoClaw.MCPServer`'s `publish.tools` list (`lib/jido_claw/core/mcp_server.ex:16`) — MCP-only.** Deliberately do NOT add it to the agent `tools:` list (`lib/jido_claw/agent/agent.ex`): the chosen surfaces are dashboard + MCP, and handing the in-REPL agent a replay side-effect lever is broader than asked. (One-line change later if wanted.) Consequently `priv/defaults/system_prompt.md` likely needs no change — `jidoclaw.system_prompt.check` in precommit confirms.
- **Anubis dispatch**: the runtime patch atomizes string argument keys via `String.to_existing_atom/1` for any key (`lib/jido_claw/core/anubis_tools_handler_patch.ex:184` — no allowlist to update); defining `run_id` in the tool schema interns `:run_id` at compile. Ensure that holds and cover it with an MCP dispatch test.
- **AGENTS.md's "Exposed tools" list is stale (says 15; code publishes 20)** — reconcile it with the actual `MCPServer` list + the new tool, don't just do 15→16.

### W9 — Migration

```
mise exec -- mix ash.codegen add_replay_fingerprint_columns
mise exec -- mix ecto.migrate
```

Expect `definition_hash` (text) + `encrypted_replay_inputs` (bytea) on `workflow_runs`. Verify the generated migration names the encrypted column correctly. No backfill.

### W10 — Docs

- `REACTOR-ADOPTION.md`: move fingerprint/replay out of "Next-phase scope (NOT started)"; add a §4.7 implementation note (canonical semantic-term hashing / `module_info(:md5)`; module function not Ash action; cloaked `replay_inputs` blob; fresh-disk skill re-resolution; irreversible gate scans `step_*` payloads; MCP tool has no override flags).
- `FEATURES-WORTH-BORROWING.md` T1-3: note "hash the resolved skill YAML" shipped as canonical-semantic-term hashing (raw text isn't retained) and the entry point is a module function.

## Tests (house patterns)

- **`test/jido_claw/orchestration/definition_fingerprint_test.exs`** (plain ExUnit, `async: true`, mirrors `solutions/fingerprint_test.exs`): 64-hex shape; determinism; string-keyed ≡ atom-keyed steps; description-insensitive; sensitive to task/step-count/execution-mode/irreversible changes **and to `depends_on`/`consumes` reordering** (order is prompt-semantic); `irreversible: false` ≡ omitted; `retry: 0` ≡ omitted; `max_iterations` nil ≡ 3 for iterative and inert for non-iterative; `produces` map key order insensitive; `for_module` deterministic hex.
- **`test/jido_claw/orchestration/replay_test.exs`** (`use JidoClaw.TenantCase, async: false`; `seed_tenant`/`actor_for`; EchoStub via `:agent_templates_override`; local `kinds/2` over `WorkflowEvent.for_run`):
  - Happy path via a **compiled skill**: run → completes; `Replay.replay` → `{:ok, new_run}` with `retry_of_id == original.id`, equal hashes, full `run_started → … → run_completed` timeline (proves middleware re-wired), `run_started` payload carries `definition_hash`.
  - **Disk-edit test (catches the cache bug):** temp project dir + `.jido/skills/<fixture>.yaml`; initial run compiled from `Skills.load_skill(name, tmp_dir)` with `context: %{project_dir: tmp_dir}`; **edit the YAML file on disk** (semantic change); replay → `{:error, {:definition_changed, _, _}}`; `force: true` → `{:ok, run}` whose `definition_hash` equals the NEW disk hash. Also a comment/description-only edit → replay proceeds (hash unchanged). Mutating an in-memory struct would not catch this — must touch disk.
  - Scope preservation: replay of a run whose stored context carried `workspace_uuid`/`session_uuid`/`user_id` keeps them; a `"cron:..."` `workspace_id` is replaced; `:actor` is not carried.
  - Refusals: non-terminal original (reuse `GatedTestReactor` parked at `:awaiting_approval`); `:irreversible_steps_executed` (skill step with `irreversible: true`) then `allow_irreversible: true` → `{:ok, run}`; `:no_inputs` / `:no_hash` (forge rows via the corruption-sim precedent — `:set_status` with `authorize?: false`, as in `human_gates_test.exs`); `{:disallowed_module, _}` (config claiming a module outside `Reactors.*`); `:not_found`; cross-tenant id → not found (isolation).
  - Note: prove full replay *launch* via the skill path only — `ProjectRegistration`'s unique writes would fail a verbatim-input second run; module-reactor persistence is covered in the runner test instead.
- **Extend `reactor_runner_test.exs`**: module run → `definition_hash == for_module(...)`, `config["definition_kind"] == "module"`, `encrypted_replay_inputs` non-nil; struct run with `definition_hash:` opt stored verbatim + `"skill"` kind.
- **Extend `reactor_middleware_test.exs`**: `run_started` payload includes/omits `definition_hash`.
- **Extend `step_normalizer_test.exs`**: `retry`/`compensate`/`irreversible` keys (W0).
- **`Skills.load_skill/2` tests** (temp-dir pattern from `skills_test.exs`): finds by `name:` field regardless of filename; `{:error, {:duplicate_skill_name, _}}` when two files declare the same name; reads fresh disk state after an edit (no cache).
- **MCP tool test** (mirror existing tool tests, e.g. `workflow_status`): happy path + a refusal mapped to an error string; assert the schema has no force params; an MCP-dispatch-shaped test with string-keyed `%{"run_id" => …}` args proving `:run_id` interning/atomization works through the anubis patch path.
- **Update `test/jido_claw/mcp_server_test.exs`**: it pins the published tool count at 20 (`mcp_server_test.exs:59`) — bump to 21 and extend the inclusion assertions with `JidoClaw.Tools.ReplayWorkflow`.
- Dashboard: extend the existing `WorkflowsLive` coverage (`workflow_step_projection_test.exs` precedent) with a replay-click test (incl. that the Actions-cell click does not toggle steps) if cheap; otherwise rely on the LiveView render + `handle_event` unit shape used elsewhere in `test/jido_claw/web/`.

## Gates / config touches

- **Credo**: no new Ash actions ⇒ no `.credo.exs` changes expected. Confirm `SensitiveFieldInAccept` doesn't newly fire on `replay_inputs` in `:create` (precedent: `resume_checkpoint` accepted on `set_checkpoint` without exclusion).
- **Reach**: one `# reach:disable-next-line bare_rescue` on the cloak-decrypt rescue in Replay (GateResume precedent). Typed `ArgumentError` rescues need no pragma.
- **No new deps.**

## Verification

1. `mise exec -- mix test test/jido_claw/orchestration/definition_fingerprint_test.exs test/jido_claw/orchestration/replay_test.exs test/jido_claw/orchestration/reactor_runner_test.exs test/jido_claw/orchestration/reactor_middleware_test.exs test/jido_claw/workflows/step_normalizer_test.exs test/jido_claw/skills_test.exs test/jido_claw/mcp_server_test.exs` (plus the new MCP tool test file)
2. End-to-end sanity via Tidewave `project_eval`: run a skill (`Compiler.compile` + `ReactorRunner.run`), then `Replay.replay(run.id, tenant:, actor:)`; inspect both runs' event timelines and `retry_of_id`; confirm `encrypted_replay_inputs` is ciphertext via `execute_sql_query`.
3. **`mise exec -- mix precommit` — must pass (completion bar).** Runs: `jidoclaw.compile_check`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format`, `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`, `test`.
4. Known flaky tests (MCPServer, Prompt, PipelineStore, MultiSandbox singletons) move under load even at fixed seed — verify any failure in isolation before attributing it to this change.

## Out of scope (Phase 5 follow-ups, in docs)

Cron idempotency (T2-3), deadline read-model (T2-1), actor-visibility redaction (T2-2), graph layout (T3-1), §4.11 lease implementation / live-run cancellation.
