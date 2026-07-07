# Executor Seam PR-1 — template `executor:` binding + `:fake`/`:shell` executors

## Context

Next-ten item 7 (camus C1-1, direction agreed 2026-07-02: "build the seam, not the pairing") opens one hard binding: `AgentRunner` always spawns an in-process `Jido.AI` worker from `Templates.get/1`, while Forge already holds the full session contract and runners. PR-1 of 4 lands the seam itself: a template-level `executor:` binding, an `AgentRunner` dispatch on it, and the two cheap executors (`:fake`, `:shell`) through **real minimal Forge sessions** — proving the bridge end-to-end and handing the eval harness deterministic fake-backed composer stages armed by app-env alone. PR-2 (consolidator-pattern provisioning: per-run MCP deposit endpoint + `submit_structured_output` through `Verdict.normalize/2`, `workspace:` knob, vendor creds), PR-3 (cross-vendor resolution), PR-4 (`needs_input` → gate case) are explicitly out of scope.

**Operator decisions (settled via Q&A):**
1. Real minimal Forge sessions in PR-1 — plain ephemeral (`claim: false`), no MCP endpoint / workspace / creds; `:shell` → existing `Runners.Shell`; `:fake` → a NEW generic runner (`Runners.Fake` is consolidator-MCP-specific, untouched).
2. Shell command is **template-declared operator config** (verify_cmd trust class); a command-less shell template fails closed. The stage task is never the command (AgentStep appends produces-instructions to tasks, `agent_step.ex:76`; and `Runners.Shell` silently defaults to `echo 'no command'` — exactly the silent-green the validation forecloses).
3. Fake outputs are **caller-armed app-env**, **validated against the template module's declared output schema** — invalid fixture ⇒ no `typed_output`, with live-faithful per-stage-kind consequences (§3; the invariant: never a fabricated verdict). Fixtures resolve `{:stage, template, step_name}` → `{:fragment, template, task-fragment}` → plain template — template-only keys are too coarse because real catalogs reuse one template across stages (`plan_drafter`/`plan_challenger`/`coder`/`reviewer` each appear multiple times in `route_composer/catalog.ex`), and the stage/fragment keys carry **distinct shapes** so one can never be mistaken for the other.
4. Registry validates the **full five-kind union**; dispatch refuses `:codex`/`:claude_code`/`:custom` with a clear "not implemented until PR-2" error (camus `review.sh` unknown-backend fail-closed discipline).

**Revised after operator plan review:** fixture-resolution granularity (P1), per-stage-kind validation consequences — the infra lane is lens-only (P2), `executor_config` map validation for every kind (P2), an AgentRunner-level forge envelope test (P3), test-path/wording corrections (P3).

**Verified seam geography** (all confirmed by direct reads):
```
WaveBuilder / IterativeStep / AgentStep(+cleanup)
  └─> AgentRunner.run/6 (agent_runner.ex:65)
        └─ Templates.get/1 → hydrated map   ← executor default + validation land in hydrate_template/1 (templates.ex:373)
        └─ [NEW] dispatch on template.executor
             ├─ :in_process → today's body, byte-identical (validate_sandbox_scope → spawn → attach → inject → correlate → run_registered_step)
             └─ {:forge, :fake|:shell} → ForgeExecutor: start_session_ready → run_iteration → StepResult → stop_session
Return contract everywhere: {:ok, %StepResult{}} | {:error, binary()}   (step_result.ex:20)
```

Load-bearing facts confirmed: `Forge.start_session_ready/3` returns `{:ok, session_id}` and needs `expected_backend:` (ReadyStart defaults to **Docker**, `ready_start.ex:50`; asserts `state: :ready` + `sandbox_status: :ready` + `:default in sandboxes` — so **no** `deferred_provision`); Harness `init` returning `:ok` sets `runner_state = runner_config` (`harness.ex:326-338`); `resolve_runner/1` passes module atoms through (`harness.ex:1289`) so the new fake runner goes straight into `spec.runner` — no `resolve_runner` edit; `resolve_client(:local)` → HostShell; `Jido.AI.Output.parse/2` accepts map AND binary (JSON-decode), returns `{:ok, map} | {:error, _}` (`deps/jido_ai/lib/jido_ai/output.ex:107-125`); `Reasoning.Output.extract_result/1` returns a binary as-is, prefers `:summary` on typed maps.

---

## Implementation

### 1. `lib/jido_claw/agent/templates.ex` — `:executor` + `:executor_config` keys

- New optional raw-entry keys: `executor:` (`:in_process | {:forge, :fake | :shell | :codex | :claude_code | :custom}`) and `executor_config:` (map; PR-1 uses only `%{command: String.t()}` for `{:forge, :shell}` — a **string**, Forge's existing `Sandbox.exec` shell contract; a map so PR-2 can add keys without a new top-level field).
- Append `ensure_executor/1` as the **last** clause of `hydrate_template/1` (templates.ex:373-380): default `:in_process`, `Map.put` onto the hydrated map.
- Validation **raises** `ArgumentError` on a malformed value (the `ensure_max_iterations` loud posture, templates.ex:382-385 — NOT the warn+fail-closed posture of fc/ra/sandbox, which only works when "closed" is a *tighter runnable* value; for executor the tight direction is *refuse to run*, and silently mapping a typo to `:in_process` would hand execution to the wrong executor — fatal to PR-3's cross-vendor invariant):
  - `:in_process` → ok
  - `{:forge, k}` for `k in [:fake, :codex, :claude_code, :custom]` → ok
  - `{:forge, :shell}` → requires `executor_config.command` to be a non-empty binary, else raise (hydration-time = earliest, loudest, before any Forge slot is consumed)
  - `{:forge, _}` additionally requires the template `:sandbox` policy to be absent/`:none` — the in-process VFS-jail axis is meaningless for a forge session; refusing the combo prevents a silently-dead policy field (PR-2's session-sandbox knob will live in `executor_config`, a different axis)
  - anything else → raise with the expected-union message
  - `executor_config` hydrates to `%{}` and must be a map for **every** executor kind — a non-map raises (PR-2 must not inherit ambiguous shapes)
- Safe for every surface: `list/0` hydrates only the repo-authored `@templates` (which stay clean — pinned by test); `names/0`/`spawnable_names/0`/`exists?/1` never hydrate, so the `jido_md`/`system_prompt` enumeration checks are untouched. Only `get/1` sees overrides, where a raise is the wanted loud failure.
- **Raw `@templates` literals are NOT edited** — untouched templates stay byte-identical at the source; hydrated maps gain `executor: :in_process` (no existing test asserts exact hydrated-map equality — verified).

### 2. `lib/jido_claw/skills/steps/agent_runner.ex` — dispatch + shared envelope

- `run/6` becomes: `case Templates.get(template_name)` → `{:error, reason}` keeps the exact `"Step #{name} setup failed: #{inspect(reason)}"` phrasing; `{:ok, template}` → `dispatch_executor/7`:
  - `%{executor: :in_process}` → `run_in_process/7` — the **verbatim** current body from `validate_sandbox_scope` onward (agent_runner.ex:67-120), same `else` branch, same strings, same ask forms (`ask_step/5` untouched). Byte-identical behavior.
  - `%{executor: {:forge, k}} when k in [:fake, :shell]` → `run_forge/5` (drops `catalog_stage_name`/`tier` with `_`-prefixed params — they steer persona injection and the per-turn transformer, neither of which exists on this path; documented in a comment).
  - `%{executor: {:forge, k}} when k in [:codex, :claude_code, :custom]` → `{:error, "Step #{name} failed: executor {:forge, #{inspect(k)}} is not implemented until PR-2"}`.
  - Clauses are exhaustive over the validated union (malformed raises at hydrate, never reaches dispatch).
- Extract one shared tool-context builder used by both arms (prevents drift, avoids a clone): tag mint (`"wf_#{template_name}_#{:erlang.unique_integer([:positive])}"`) + `stamp_sandbox(resolve_scope(context, tag), template)` + `apply_visibility` + `Map.put(..., :agent_template, template_name)`; in-process additionally applies `maybe_put_tier` (forge arm passes `[]` — no ask to tier). Transcript/correlation rows stay uniform across executors.
- Extract the record/never-crash envelope from `run_registered_step/7` (agent_runner.ex:217-240) into `run_recorded(tool_context, request_id, task, template_name, run_fun, cleanup_fun)`: `record_task` → `try` run → `record_step_terminal` → `rescue` (keep the inline `# reach:disable-next-line bare_rescue`; same `"[step crashed]"` transcript + `"Step #{name} crashed: #{msg}"` string) → `after cleanup_fun.()`. `run_registered_step/7` keeps its signature and passes closures (run_step / stop-agent-if-alive) — not a trivial forwarder. Confirmed `record_task`/`record_terminal` need only `tool_context` + `request_id` (no pid).
- `run_forge/5`: build tool_context → `JidoClaw.register_child_correlation(tool_context)` (same `{:error, ...} → "correlation failed"` phrasing; correlation happens BEFORE any Forge resource exists) → `run_recorded(..., fn -> ForgeExecutor.run(template_name, template, task, step_name, context) end, fn -> :ok end)` (the bridge owns Forge teardown).

### 3. NEW `lib/jido_claw/skills/steps/forge_executor.ex` — the bridge

`JidoClaw.Skills.Steps.ForgeExecutor.run(template_name, template, task, step_name, context) :: {:ok, StepResult.t()} | {:error, binary()}`. Real `@moduledoc` (subsystem seam). Calls `JidoClaw.Forge` **directly** — do NOT clone the `front_door.ex:506` `defp forge` app-env seam (tests run real sessions).

- **Spec build** (per kind; fail closed before any session starts):
  - `:shell` → `%{runner: :shell, runner_config: %{command: template.executor_config.command}, sandbox: :local, claim: false, tenant_id: ..., workspace_id: ...}` (tenant/workspace from context per `resolve_scope` precedence). Command reaches the runner via `runner_state` (= `runner_config`); the bridge's `run_iteration` opts carry only `timeout:` — never `:command` (Shell reads `opts[:command]` first).
  - `:fake` → same shape, `runner: JidoClaw.Forge.Runners.StaticFake` (module atom in `spec.runner`), `runner_config: %{fake_output: fixture}`. **Fixture resolution** from `Application.get_env(:jido_claw, :executor_fake_outputs, %{})` mirrors the StubWorker's loud deterministic lookup (`composer_stubs.ex:105-121`), extended with the step-name key the bridge (unlike the StubWorker, which only sees `tool_context.agent_template`) actually receives — and with **distinct key shapes** so a stage key can never double as a fragment for sibling stages: `{:stage, template_name, step_name}` (exact step match), `{:fragment, template_name, fragment}` (task-contains match), plain `template_name` (template-wide). Order: (1) exact `{:stage, template, step_name}` when present; (2) else, if any `{:fragment, template, _}` keys exist, exactly ONE fragment must `String.contains?`-match the task — zero or several ⇒ fail-closed step `{:error, ...}` (never an arbitrary pick; the lib-code analogue of the stub's raise); (3) else, **any tuple key for the template disables the plain fallback** — an unkeyed sibling stage of a stage-keyed template is a fixture-authoring oversight ⇒ fail-closed error (the StubWorker's own no-silent-fallback rule); (4) a template with NO tuple keys uses the plain `template_name` key; (5) else **missing fixture ⇒ `{:error, "Step #{name} failed: no fake output armed for '#{name}' (:executor_fake_outputs)"}`**. All resolved before provisioning — no session starts on a resolution failure.
  - `sandbox: :local` pinned for both (→ HostShell; a plain tmp-dir default sandbox — "plain ephemeral session"). This deliberately ignores a prod `FORGE_SANDBOX=docker` env: PR-1's executors must not spin a microVM per stage; the session-sandbox knob is PR-2.
- **Lifecycle**: mint `session_id = Ecto.UUID.generate()` → `Forge.start_session_ready(session_id, spec, expected_backend: JidoClaw.Forge.Runner.HostShell)` (ReadyStart tears down its own partial session on failure — no bridge cleanup needed there) → `try do Forge.run_iteration(session_id, timeout: @forge_step_timeout_ms) |> map_result(...) after Forge.stop_session(session_id, :normal) end`. Result captured before teardown (trust-boundary ordering; consolidator precedent `run_server.ex:463-471`). `@forge_step_timeout_ms 180_000` mirrors `@step_timeout_ms`. No rescue in the bridge (`try/after` only — facade returns tagged tuples; a genuine raise propagates to `run_recorded`'s boundary).
- **Result mapping** (`"Step #{name} failed: ..."` phrasing parity):

| `run_iteration` reply | mapping |
|---|---|
| `{:ok, %{status: :done, output: out}}` | build StepResult (§4) |
| `{:ok, %{status: :error, error: e}}` | `{:error, "Step #{name} failed: #{inspect(e)}"}` |
| `{:ok, %{status: :needs_input, question: q}}` | `{:error, "... needs input (gate mapping lands in PR-4): #{q}"}` |
| `{:ok, %{status: :blocked}}` / `%{status: :continue}` | `{:error, ...}` (single-shot in PR-1) |
| `{:error, reason}` | `{:error, "Step #{name} failed: #{inspect(reason)}"}` |

- **StepResult build**: `typed = parse output against the template module's schema` — `worker_output_schema(module)` reads `strategy_opts()[:output]` (a `%Jido.AI.Output{}`; `nil` when undeclared **or when the module doesn't export `strategy_opts/0`** — defensive `Code.ensure_loaded(module)` + `function_exported?` guard — an unloaded-but-valid worker must not read as schema-less — because test overrides can pair a non-worker module with an explicit `max_iterations` and the forge arm must stay as tolerant as hydration is) → `Jido.AI.Output.parse(schema, output)` → `{:ok, map}` ⇒ typed, anything else ⇒ `nil`. Soft validation is deliberately **live-faithful**, and its downstream consequence differs by stage kind: a **lens/reviewer** stage with `typed: nil` reaches `Verdict.normalize(:review, %{})` ⇒ the infra lane, signals+artifacts suppressed (`default_mapper.ex:76-91`) — never a fabricated verdict; a **producer** (non-lens) stage falls back to `StepResult.result` for its named artifact (`default_mapper.ex:230`) — the same behavior a live worker with failed output validation gets, so a fixture-authoring bug surfaces in eval assertions rather than masquerading as infra. **Validation applies uniformly to both arms** (fake fixture map AND shell stdout binary — parse JSON-decodes binaries; non-JSON stdout just yields `typed: nil`), a deliberate strictly-safer extension of decision 3. `result` text: `Reasoning.Output.extract_result(typed || output)` (typed ⇒ `:summary`; shell ⇒ stdout verbatim). `artifacts`: mirror `await_step`'s merge (agent_runner.ex:349-356) via one small shared helper extracted from `await_step` (public on AgentRunner, e.g. `step_artifacts(raw_text, typed)`) so the fenced-block + typed-artifacts merge stays single-sourced — both call sites migrate (reach trivial-forwarder rule: no delegate left behind).
- **Telemetry**: one house-style counter on the forge arm only — `:telemetry.execute([:jido_claw, :executor, :total], %{count: 1}, %{kind: :fake | :shell, outcome: :ok | :error})` (register beside `jido_claw.verify.total`'s metric declaration). The in-process arm gains no new side effects. Drop it at review if it doesn't earn its keep — the durable transcript envelope already covers auditing.

### 4. NEW `lib/jido_claw/forge/runners/static_fake.ex`

Generic deterministic runner, mirroring `Runners.Shell`'s stateless pattern (init → `:ok`, so `runner_state = runner_config`):

```elixir
@behaviour JidoClaw.Forge.Runner
def init(_client, _config), do: :ok
def run_iteration(_client, state, _opts), do: {:ok, Runner.done(Map.get(state, :fake_output))}
def apply_input(_client, _input, _state), do: :ok
```

Pure — the app-env read stays single-sited in the bridge; the runner is driveable with a plain config map. `Runners.*` is already reach-ignored for `behaviour_candidate` (`.reach.exs:120`). `Runners.Fake` (consolidator) untouched.

---

## Tests

- **`test/jido_claw/templates_test.exs`** (extend — the existing file; NOT under `agent/`): every `Templates.list/0` entry hydrates with `executor: :in_process` + `executor_config: %{}` (the repo-invariant + byte-identity guard, incl. `get("coder")`); via `:agent_templates_override` (with `on_exit` restore): `{:forge, :fake}` and `{:forge, :shell}` + command hydrate; shell w/o command raises; `{:forge, :fkae}` raises; `{:forge, :codex}` hydrates (full union); `{:forge, :fake}` + `sandbox: :prototype` raises (combo rule); non-map `executor_config` raises.
- **NEW `test/jido_claw/skills/steps/forge_executor_test.exs`** (`async: false`; disable Forge persistence via `Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)` — the `ready_start_test.exs:16-19` hermetic pattern; restore env in `on_exit`):
  - fake through a REAL session: arm `:executor_fake_outputs` with a `coder_result()`-valid map, template `module: JidoClaw.Agent.Workers.Coder` → assert `typed_output` validated, `result` = summary, session gone afterward.
  - invalid fixture ⇒ `typed_output == nil` (result still built); missing fixture ⇒ the armed-outputs error, no session started.
  - fixture resolution: `{:stage, template, step_name}` beats `{:fragment, template, frag}` beats plain key; zero/several fragment matches, or an unkeyed stage under a tuple-keyed template (tuple keys disable plain fallback), ⇒ fail-closed error, no session (mirrors `composer_stubs.ex:105-121`).
  - shell through HostShell: `printf`-class command (real-exec precedent: `host_shell_test.exs:29-31`) ⇒ `result` = stdout; nonzero-exit command ⇒ `{:error, "...exit code..."}`.
- **`test/jido_claw/skills/steps/agent_runner_test.exs`** (extend): dispatch refusal for `{:forge, :codex}` ("not implemented until PR-2"); existing in-process suites (EchoAskStub, sandbox-scope, correlation) stay green — they are the guard that the `run_in_process`/`run_recorded` extraction didn't drift.
- **AgentRunner-level forge envelope test** (same file, DB-backed via the shared-sandbox/`TenantCase` pattern the AgentRunner moduledoc requires for real UUIDs): `AgentRunner.run/6` on a `{:forge, :fake}` template with a real tenant/session context — assert a `RequestCorrelation` row plus the task + terminal transcript `Message` rows landed. This proves the shared `run_recorded`/correlation/transcript envelope on the forge arm, which the direct bridge tests alone don't.
- **Composer integration (the eval payoff)** — extend `test/jido_claw/eval/composer_case_test.exs` or a sibling: arm **only** `:agent_templates_override` (the `reviewer` **template** → `executor: {:forge, :fake}`, `module:` the real reviewer worker — the executor binding is template-level; per-**stage** output differences are expressed through the fixture keys, `{:stage, template, step_name}`/`{:fragment, template, fragment}`, never via per-stage template overrides) + `:executor_fake_outputs`; run a `:composer` eval case through `RouteComposer.run_sync/1`; assert the emission flows through `DefaultMapper`/`Verdict` (clean/findings signal) — proving the lib-blessed seam needs neither `:route_composer_stub_outputs` nor `:step_agent_server` (contrast `composer_case_test.exs:27-51`). Needs `TenantCase` (transcript rows hit the DB).

## Docs

- **AGENTS.md**: one compact Key Patterns bullet (house style): binding shape + hydration validation (raise posture), dispatch, the bridge lifecycle (`claim: false`, `sandbox: :local`/HostShell, `expected_backend:`), fake arming key + `{:stage, …}`/`{:fragment, …}`/plain resolution (tuple keys disable plain fallback) + schema validation (invalid ⇒ live-faithful: infra lane on lens stages, result-text artifact fallback on producers), shell command trust class (verify_cmd precedent), unbuilt-kind refusal, PR-2/3/4 deferrals, residuals (Manager per-runner caps — `shell: 20`, module-runners fall to `max_sessions: 50` — can `:runner_at_capacity` a wide parallel wave ⇒ per-step error, not a crash; forge arm runs no persona/tier/MCP attach by design).
- **No** camus Status line / next-ten README DONE marker (item 7 completes after PR-4). **No** `.jido/JIDO.md` / `system_prompt.md` impact (no new tool/template/skill names; both checks enumerate raw names — verified).

## Verification

1. Targeted: `mix test test/jido_claw/templates_test.exs test/jido_claw/skills/steps/forge_executor_test.exs test/jido_claw/skills/steps/agent_runner_test.exs` + the composer/eval file.
2. Full gate: `mix precommit` — run bare (never piped), report exit code + counts verbatim. Known: one unrelated rotating timing flake per full run (MemoryExport / collector / `:pg`) — re-run once, don't chase.
3. Nothing committed; all changes stay unstaged.

**Precommit risk register**: compile_check warnings-as-errors (`_`-prefix dropped params); credo `--strict` (moduledocs on both new modules, MaxLineLength 120, alias order); reach `--smells` (no trivial forwarders — closures/extractions carry real work; keep the existing `bare_rescue` pragmas on the moved rescue; single `get_env` in the bridge — no third contiguous clone; `fixed_shape_map` pragma only if the spec literal fires); dialyzer (`@spec` on bridge `run/5`; mapping total over documented shapes — no Zoi authored here).

## Non-goals (PR-1 boundary)

PR-2: MCP deposit endpoint + `submit_structured_output` → `Verdict.normalize/2`, `workspace:` knob, vendor creds/homes, `:codex`/`:claude_code`. PR-3: cross-vendor resolution + review persona. PR-4: `needs_input` → gate case. No per-stage executor override (template-level only; a later stage override coordinates with AR-9's conditionally-put shape). No `Harness.resolve_runner`/`resolve_client` edits. MC1-1's runner files (`claude_code.ex`/`codex.ex`) and the consolidator (`Runners.Fake`, `MCPEndpoint`) untouched.
