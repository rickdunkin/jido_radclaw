# Executor Seam PR-2 — the Forge-backed path (next-ten item 7, camus C1-1)

## Context

PR-1 (shipped 2026-07-06, `85cbe9f2`) built the executor seam: every hydrated template
carries `executor:` + `executor_config:`, `AgentRunner.run/6` dispatches on it, and
`{:forge, :fake | :shell}` run through `JidoClaw.Skills.Steps.ForgeExecutor` as real
minimal Forge sessions. The vendor kinds — `{:forge, :codex}`, `{:forge, :claude_code}` —
are refused at dispatch ("not implemented until PR-2").

PR-2 makes them real (from `docs/plans/unadopted-next-ten/README.md` item 7):

> **PR-2 — the Forge-backed path (M):** session provisioning per the consolidator
> pattern; a `workspace: :repo | :scratch | :none` template knob; a scoped per-run MCP
> endpoint whose single deposit tool (`submit_structured_output`) validates against the
> template's output schema **through #4's normalizer** — schema drift is `{:infra, _}`,
> never a verdict. Read-only stages only in this wave.

The payoff (camus C1-1's thesis): a composer stage can run on a competing vendor's CLI —
the cross-vendor review lane PR-3 configures — with the engine owning both ends of the
result channel (an MCP callback) instead of camus's hallucination-prone stdout relay.
Trust-boundary laws 2 and 5 (`docs/TRUST-BOUNDARIES.md`) are the review rubric: the
deposit enters composer state only through `Verdict.normalize/2`, and the CLI's own
tools (which bypass our `Tools.Action` pipeline entirely) are compensated by hardwired
read-only CLI modes this wave.

## Operator decisions (ratified in planning Q&A, 2026-07-06)

1. **Sessions stay HostShell** (`sandbox: :local`, `claim: false`, PR-1 posture). NO
   session-sandbox knob in PR-2 — it lands with PR-4's write-capable work (the deposit
   endpoint is a loopback URL a microVM can't reach without a networking design). The
   three "PR-2's session-sandbox knob" comments get updated to say PR-4.
2. **Hardwired read-only CLI invocation** for every vendor executor session — codex
   `exec -s read-only` (never `--dangerously-bypass-approvals-and-sandbox`); claude
   restricted `--tools` read set + `--allowedTools` (read set + deposit tool) +
   `--permission-mode dontAsk` + `--strict-mcp-config` (never
   `--dangerously-skip-permissions`). No access knob. Executor codex sessions sync
   `auth.json` ONLY (host `config.toml` would carry host MCP servers past read-only
   intent); executor claude sessions get an **isolated per-run `CLAUDE_CONFIG_DIR`**
   with `credentials.json` only and a minimal (non-allow-all) `settings.json` — never
   the operator's real `~/.claude` (review finding P1b).
3. **Single-channel deposit** (camus OQ-1(c) resolved): `typed_output` comes ONLY from a
   schema-valid deposit. No deposit ⇒ `typed_output: nil` — a lens stage rides the
   Verdict infra lane, a producer falls back to result text (both live-faithful,
   matching PR-1). CLI stdout is kept for artifact extraction and as fallback result
   text, never parsed into typed.
4. **Vendor kinds only**: `:custom` stays refused at dispatch (reworded "not
   implemented" — no roadmap PR); no production template gains a vendor binding in PR-2
   (capability + tests only; PR-3's cross-vendor review config is the first declarer).
5. **Generalize + migrate**: extract the consolidator's per-run MCP endpoint machinery
   into shared modules and migrate the consolidator onto them, deleting the originals
   (no delegate shims — reach trivial-forwarder rule; sibling copies would risk the
   exslop clone gate).
6. **Vendor creds = reuse host-sync**: the runners' existing `~/.claude` / `~/.codex`
   sync + `{:error, :no_credentials}`, surfaced as a clean step error that rides the
   composer's Lane B infra for lens cohorts. Trust model documented (operator's own CLI
   auth — same class as running claude/codex by hand).
7. **`executor_config.workspace`**, vendor kinds only (refused at hydration elsewhere),
   **default `:repo`**: `:repo` = CLI pointed at the run's real `project_dir` (codex
   `-C`, claude `--add-dir` + path named in prompt) — `project_dir` required or the step
   fails loudly BEFORE any session. `:scratch`/`:none` = no repo exposure — the CLI runs
   from its per-session throwaway dir (codex explicitly via `-C forge_home`; claude from
   the HostShell sandbox dir — its cwd is not ours to set), and **this wave the two
   differ only in the prompt note** (meaningful writable `:scratch` arrives with PR-4
   writes; the enum ships now for knob stability). Repo materialization for sandboxed
   sessions stays PR-4 OQ-1(a).
8. **Deposit validation layering**: the deposit box Zoi-validates against the template
   module's `strategy_opts()[:output]` (a compile-time-normalized `%Jido.AI.Output{}` —
   `Jido.AI.Output.parse/2` handles maps AND binary JSON, and coerces string keys).
   Invalid ⇒ structured tool error (MCP `isError`, bounded detail) so the CLI retries
   in-session, nothing stored; valid ⇒ stored, last-valid-wins. `Verdict.normalize/2`
   stays at its existing site (`DefaultMapper` lens dispatch) — that is how "through
   #4's normalizer" holds end-to-end (normalize is total over arbitrary input as the
   backstop; producers have no normalize kind, so normalize-at-deposit is not
   well-defined). A no-deposit lens stage feeds `normalize(:review, %{})` ⇒ infra lane.

**Plan-review findings folded in (2026-07-06):** (P1a) vendor prompts carry the full
subagent contract — `SubagentPrompt.build/3` output (role/doctrine/persona/blocks/
JIDO.md) prepended, `catalog_stage_name` no longer dropped on the forge arm, same
`doctrine_enabled?` master gate as in-process; (P1b) claude config isolation via per-run
`CLAUDE_CONFIG_DIR` + exec-based file writes (never jailed `Sandbox.write_file` absolute
paths), env/argv test-asserted; (P2a) hydration validators refactored to a normalizing
return path so the `workspace: :repo` default is actually written back; (P2b) vendor
resource acquisition unwinds on partial failure (no unbound-var cleanup, box never
leaks); (P3a) `StepResult.result` prefers the typed deposit over raw stream-json (the
PR-1/in-process projection); (P3b) `LoopbackClient` echoes `mcp-session-id`.

## Design

### A. Shared scoped-MCP machinery (+ consolidator migration)

**New `lib/jido_claw/mcp/scoped_endpoint.ex`** — `JidoClaw.MCP.ScopedEndpoint`,
generalizing `Consolidator.MCPEndpoint`: `start_link(plug:, scope_id:, path_prefix:)` →
Bandit on `127.0.0.1:0` → `{:ok, %{pid, port, url: "http://127.0.0.1:<port><prefix>/<id>"}}`
**or `{:error, term}`** (surface Bandit's error tuple, don't crash-match — the executor's
acquisition unwind needs the tuple). If Bandit starts but the port read
(`ThousandIsland.listener_info`) fails, `start_link` **stops the listener itself** before
returning `{:error, _}` — the caller never received the pid, so no outer unwind could.
`stop/1` (catch-safe `Supervisor.stop`). Also
`write_client_config(server_name, url, basename) :: {:ok, path} | {:error, term}` —
host-side tmp JSON `{"mcpServers": {<name>: {"url": url}}}` via non-bang `File.write/2`
(single-sources the consolidator's `write_mcp_config/2`; the consolidator call site
matches `{:ok, path} =` — same crash-on-failure semantics it has today. HostShell's
`Sandbox.write_file` jails absolute paths, so client-config files are always host-side).

**New `lib/jido_claw/mcp/scoped_forward.ex`** — `JidoClaw.MCP.ScopedForward`,
generalizing `Consolidator.Plug.RunForward`: `call(conn, server:, assign_key:, path_param:)`
stamps `conn.assigns[assign_key]` from `conn.path_params[path_param]` then delegates to
`Anubis.Server.Transport.StreamableHTTP.Plug` with **lazy request-time init** (anubis
reads server session config from `:persistent_term` — preserve this property). Also
hosts `scope_id(ctx, key)` — the both-key-shapes (atom/string assigns) reader both
lanes' tools use.

**New `lib/jido_claw/mcp/loopback_client.ex`** — `JidoClaw.MCP.LoopbackClient`: the
~100-line MCP-JSON-RPC-over-`:httpc` client extracted from `Runners.Fake`
(`initialize/1 → {:ok, client}` where `client = %{url:, session_id: sid | nil}`;
`call_tool(client, name, args)` **echoes the `mcp-session-id` header** captured at
initialize — session-aware, closer to real clients, not dependent on anubis auto-init).
`Runners.Fake` migrates to it (best-effort posture preserved); the scripted test runner
uses it too — one implementation, no clone-gate hit. (Supersedes PR-1's "Runners.Fake
untouched" claim — record as a correction in the done-note.)

**Consolidator migration** (behavior pinned by `run_server_test.exs`, which drives the
full fake harness through the real endpoint):
- Delete `lib/jido_claw/memory/consolidator/mcp_endpoint.ex` and
  `lib/jido_claw/memory/consolidator/plug/run_forward.ex`.
- `consolidator/plug.ex`: both match bodies → `ScopedForward.call(conn, server:
  Consolidator.MCPServer, assign_key: :consolidator_run_id, path_param: "run_id")`.
- `consolidator/run_server.ex`: `ScopedEndpoint.start_link(plug: Consolidator.Plug,
  scope_id: state.run_id, path_prefix: "/run")` (~line 369); `ScopedEndpoint.stop` in
  `cleanup/1`; `write_mcp_config/2` body → `ScopedEndpoint.write_client_config`.
- `consolidator/tools/helpers.ex`: `run_id_from/1` body →
  `ScopedForward.scope_id(ctx, :consolidator_run_id)` (partial application, not a
  trivial forwarder).

### B. The deposit lane (new files under `lib/jido_claw/skills/steps/forge_executor/`)

**`deposit.ex`** — `ForgeExecutor.Deposit`, a per-step GenServer registered
`{:via, Registry, {ForgeExecutor.DepositRegistry, ref}}`, started (linked) by the step
process. State: `%{output: %Jido.AI.Output{} | nil, last_valid: map | nil, deposits: n,
invalids: n}`. `submit(ref, payload)`: with a schema — `Jido.AI.Output.parse(output,
payload)`; `{:ok, typed}` ⇒ store (last-valid-wins), reply `{:ok, %{status: :accepted}}`;
`{:error, e}` ⇒ reply `{:error, "output failed schema validation: " <> bounded(e)}`
(bounded like `Verdict.format_reason` — ~240 graphemes, so garbage never becomes a huge
isError string). With NO schema (degenerate — all 16 real workers declare one) —
accept-and-store the raw map (test-pinned; an explicit structured submission has nothing
to drift from). `take(ref)` → `last_valid | nil` (read-only); `stop(ref)` graceful.
Handlers are total over model input (never raise), so the link can't realistically fault
the step.

**Registry**: `{Registry, keys: :unique, name:
JidoClaw.Skills.Steps.ForgeExecutor.DepositRegistry}` in `application.ex` beside
`Consolidator.RunRegistry` (~line 141).

**`deposit_server.ex`** — `ForgeExecutor.DepositServer`: `use Jido.MCP.Server, name:
"jido_deposit", version: "1.0.0", publish: %{tools: [SubmitStructuredOutput]}`. Started
always-on in `application.ex` beside the consolidator's server (~line 268):
`{DepositServer, transport: {:streamable_http, [start: true]}}` (transport-internal
`start: true` is load-bearing). Internal server — NOT part of the served-surface golden
(which enumerates `JidoClaw.MCPServer` only; the consolidator server sets the precedent).

**`deposit_plug.ex`** — `ForgeExecutor.DepositPlug`, a `Plug.Router` matching
`/deposit/:ref` + `/deposit/:ref/*_rest` → `ScopedForward.call(conn, server:
DepositServer, assign_key: :executor_deposit_ref, path_param: "ref")`; 404 otherwise.

**`tools/submit_structured_output.ex`** — `use Jido.Action, name:
"submit_structured_output", schema: [output: [type: :map, required: true, doc: …]]`
(a `:map` arg advertises `{"type": "object"}` — the real per-template schema rides the
prompt + box validation, forced by the single-static-server model, exactly the
consolidator's constraint). `run/2`: `ScopedForward.scope_id(ctx, :executor_deposit_ref)`
→ `Deposit.submit(ref, payload)`; no/unknown ref → `{:error, "no active deposit …"}`.
jido_mcp maps `{:error, reason}` → an `isError` tool result the CLI can read and retry —
the in-session repair loop that is our structural advantage over camus's stdout relay.

### C. Vendor runner knobs (defaults preserve the consolidator byte-for-byte)

**`forge/runners/codex.ex`**: parametrize the hardcoded `@consolidator_server_name` —
the `-c mcp_servers.<name>={url=…}` override uses `state[:mcp_server_name] ||
"consolidator"`. New `config_sync: :full (default) | :auth_only` — `:auth_only` syncs
`auth.json` only (no host `config.toml` ⇒ no host MCP servers ride into a read-only
session). New `access: :full (default) | :read_only` — `:read_only` replaces
`--dangerously-bypass-approvals-and-sandbox` with `["-s", "read-only"]`. `-C` uses
`state[:cwd] || state.forge_home`.

**`forge/runners/claude_code.ex`** — config isolation is explicit (review finding P1b:
HostShell inherits allowlisted `HOME`, so without an override claude reads the
operator's REAL `~/.claude`; the existing `forge_home/.claude` writes are decorative on
`:local` — `Sandbox.write_file` jails absolute paths):
- `config_sync: :auth_only` ⇒ build a per-run config dir `#{forge_home}/.claude`:
  sync `credentials.json` only (via `FileSync.sync_file` — exec-based base64 writes,
  which DO land on HostShell), write a minimal non-allow-all `settings.json` through the
  same exec-based mechanism (never `Sandbox.write_file` with an absolute path), and
  `Sandbox.inject_env(client, %{"CLAUDE_CONFIG_DIR" => that_dir})` (the codex
  `CODEX_HOME` precedent) so claude's config universe is the per-run dir — host
  settings/skills/CLAUDE.md/plugins cannot bleed in. `:full` (default) keeps today's
  behavior byte-identical (no env injection — consolidator unchanged).
- `access: :read_only` drops `--dangerously-skip-permissions` and adds `--tools
  <read set>`, `--allowedTools <read set + mcp__jido_deposit__submit_structured_output>`,
  `--permission-mode dontAsk` (auto-deny instead of prompt-hang in headless `-p`),
  `--strict-mcp-config`. New `add_dirs: [dir]` → repeated `--add-dir`. Exact built-in
  read-tool names + the `CLAUDE_CONFIG_DIR` var name pinned at build time (see
  Build-time verification).

### D. `ForgeExecutor` vendor arm (`lib/jido_claw/skills/steps/forge_executor.ex`)

**Signature**: `run/5` gains an options tail — `run(template_name, template, task,
step_name, context, opts \\ [])` (PR-1 call sites unchanged). `opts` carries
`system_prompt:` (P1a) from `run_forge`.

`build_spec` return values gain a tag so `run` dispatches cleanly: existing kinds wrap
as `{:ok, {:session, spec}}` (behavior unchanged); vendor kinds build
`{:ok, {:vendor, plan}}` where `plan = %{kind: kind, output: output, workspace:
workspace, config: executor_config, context: context, prompt: prompt}` — **fail-closed
pre-flight before any session/box/endpoint**:
- `workspace` read from hydrated `executor_config` (hydration wrote the default);
  `:repo` requires `context[:project_dir]` present-non-blank (ToolContext present-nil
  coercion) else `{:error, "… workspace: :repo requires a project_dir in the run
  context"}`.
- `output` = the template module's `strategy_opts()[:output]` (`%Jido.AI.Output{}` or
  nil — reuse PR-1's tolerant extractor).
- `prompt` assembled here (P1a order): **subagent system prompt** (when provided —
  role/doctrine/persona/memory blocks/JIDO.md, the same contract in-process workers
  get) + stage task + workspace note (`:repo` names the path; `:scratch`/`:none`
  minimal) + deposit instruction LAST (nearest to action), rendering the expected shape
  via `Zoi.to_json_schema(output.schema)` (schema_kind `:zoi`; embed `:json_schema`
  maps directly; schema-less gets a plain "call submit_structured_output" line). The
  instruction states: the tool call is the ONLY accepted channel; on validation error,
  fix the object and call again. Redaction happens in the runners
  (`PromptRedaction.redact` on the full argv prompt — verified both runners), so
  doctrine/JIDO.md text passes the redaction root before egress (camus sketch (d)).

**Resource acquisition with unwind** (P2b): a private `acquire_vendor_resources(ref,
plan, forge_home)` implemented as an **explicit accumulator/reducer, not `try`-scope
rebindings** (a rebound var inside `try` is not reliably visible to `rescue`): the
acquisition steps — Deposit box → `ScopedEndpoint.start_link` →
`File.mkdir_p(forge_home)` → `write_client_config` — form a list of step functions
`(acc :: res_map) -> {:ok, acc'} | {:error, msg}`, **each individually wrapped** in a
`safe_step` `try/rescue/catch` that converts any raise/exit to `{:error, msg}` (so
every step is a non-bang tuple step by construction — `GenServer.start_link` /
`ScopedEndpoint.start_link` error tuples, `File.mkdir_p/1`, tuple-returning
`write_client_config`). `Enum.reduce_while` threads the acc; the first `{:error, _}`
calls `teardown(acc)` (what was acquired so far — the acc IS the teardown manifest)
and halts with the error. **Total: no raise escapes, no unbound-var cleanup, the box
never leaks past a partial acquisition.** Returns `{:ok, res}` — a map
`%{box_ref, endpoint, cfg_path, forge_home}` consumed by the same idempotent
`teardown(res)` in `run_vendor`'s `after`.

`run_vendor(plan, template, template_name, step_name)` — **`plan` carries `context`**
(the vendor `build_spec` stores it, per the plan-map sketch above), so `session_spec`
reads `plan.context`:
1. `ref`/`session_id` = fresh UUIDs; `forge_home = <:forge_home base>/<session_id>`
   (host-side — the consolidator precedent; test env already redirects `:forge_home` to
   a writable partition-aware tmp base), `codex_home` inside it.
2. `acquire_vendor_resources(...)` (above) — `{:error, _}` returns the step error with
   nothing leaked.
3. `try`: build `runner_config` → `session_spec(plan.context, vendor_runner(kind), config)`
   (PR-1's spec builder: `sandbox: :local`, `claim: false`, tenant + `workspace_uuid`) →
   `Forge.start_session_ready(session_id, spec, expected_backend: HostShell)` → inner
   `try`: one `Forge.run_iteration(session_id, timeout:)` then `deposit =
   Deposit.take(ref)` then `map_vendor_result(iter, deposit, …)`; inner `after`:
   `Forge.stop_session`. `start_session_ready` errors (incl. `{:runner_init_failed,
   :no_credentials}`) → `{:error, "Step … failed: …"}`.
4. Outer `after` (every path incl. session-start failure): `teardown(res)` —
   `ScopedEndpoint.stop`, `File.rm(cfg_path)`, `File.rm_rf(forge_home)`,
   `Deposit.stop(ref)` — all idempotent/tolerant.

`build_runner_config`: `prompt`, `forge_home`, `codex_home`, `mcp_config_path`,
`mcp_server_url`, `mcp_server_name: "jido_deposit"`, hardwired `access: :read_only` +
`config_sync: :auth_only`, `cwd` (`:repo` → project_dir, else forge_home), `add_dirs`
(`:repo` → [project_dir]), `max_turns` (executor_config override, default 40),
`timeout_ms` (executor_config override clamped 30_000..600_000, **default 240_000** —
deliberately under the composer's `@default_wave_timeout_ms 300_000` so a default vendor
step never races the wave kill; the AGENTS.md note records that raising one means
raising the other), optional `model`/`thinking_effort` from executor_config.

`vendor_runner(kind)`: `Application.get_env(:jido_claw, :executor_vendor_runners,
%{})[kind] || kind` — prod resolves `:codex`/`:claude_code` atoms (harness
`resolve_runner`, per-runner cap 10); tests arm a module (the `:executor_fake_outputs`
pattern). The scripted double reads its deposit script from its OWN app-env key — no
test-only keys in prod runner_config.

`map_vendor_result` (P3a — the PR-1/in-process typed projection): `:done` →
`raw_text = Output.extract_result(cli_out)`; `text = if is_map(deposit), do:
Output.extract_result(deposit), else: raw_text` — transcripts show the typed summary,
not raw stream-json; `%StepResult{result: text, typed_output: deposit, artifacts:
AgentRunner.step_artifacts(raw_text, deposit)}` (raw text still feeds `ARTIFACTS:`
block extraction). `:error` / `:needs_input` ("gate mapping lands in PR-4") /
`:blocked` / `:continue` / `{:error, _}` → step errors (PR-1 shapes). Telemetry
`emit_executor(:codex | :claude_code, outcome)` flows through the existing
unconditional call.

### E. `AgentRunner` dispatch + prompt parity (`lib/jido_claw/skills/steps/agent_runner.ex` + `lib/jido_claw/startup.ex`)

- `run_forge` guard extends to `kind in [:fake, :shell, :codex, :claude_code]`; the
  refusal clause narrows to `:custom` ("executor {:forge, :custom} is not implemented").
- **P1a — `catalog_stage_name` is no longer dropped on the forge arm**: the forge
  dispatch clause passes it into `run_forge/6`. For VENDOR kinds only, `run_forge`
  computes `system_prompt = Startup.subagent_prompt(template_name, tool_context,
  catalog_stage_name)` — a new small PUBLIC function on `JidoClaw.Startup` that applies
  the SAME `doctrine_enabled?()` master gate and returns the `SubagentPrompt.build/3`
  string or `nil` (gate off ⇒ nil ⇒ vendor prompt = task+…, byte-consistent with the
  in-process doctrine-off behavior; total/never-raises, the existing best-effort
  posture). `:fake`/`:shell` never compute it (no prompt surface — avoids Memory/DB
  reads on those steps). `tier` stays dropped on the whole forge arm (model/effort come
  from `executor_config` on this path — documented).
- Vendor steps inherit the whole `run_forge` envelope: correlation BEFORE Forge
  resources, task/terminal transcript rows, `publish_forge_terminal` flush-barrier
  signal.

### F. Hydration validation (`lib/jido_claw/agent/templates.ex`)

**P2a — normalizing return path**: `ensure_executor/1` currently calls validators for
side effects and writes the ORIGINAL config back. Refactor: `config =
normalize_executor_config!(executor, config, template)` — validators return the
(possibly normalized) config, and `ensure_executor` puts THAT back. Vendor kinds:
`Map.put_new(config, :workspace, :repo)` (self-describing hydrated map, PR-1's
ensure-default pattern) then validate; all other kinds validate and return the config
unchanged (byte-identity preserved).

Validation (raise posture): vendor kinds get `refuse_forge_sandbox_combo!` +
`workspace ∈ [:repo, :scratch, :none]`; optional `model`/`thinking_effort` non-blank
binaries, `max_turns`/`timeout_ms` positive integers; **strict unknown-key refusal**
(anything ∉ `[:workspace, :model, :max_turns, :timeout_ms, :thinking_effort]` raises —
deliberately NO `access`/`sandbox` keys this wave). `:fake`/`:custom` keep the
combo-only check; a present `workspace` key on ANY non-vendor kind (`:in_process`,
`{:forge, :shell | :fake | :custom}`) raises "workspace is only valid on {:forge,
:codex | :claude_code}". Existing templates + PR-1 shapes stay byte-identical (guard
test at templates_test.exs:502 keeps holding). Moduledoc updated; the two "PR-2's
session-sandbox knob" comments (~:102, ~:565) → PR-4; ForgeExecutor moduledoc rewritten
for the shipped shape (session-sandbox knob → PR-4).

### G. Files summary

New: `lib/jido_claw/mcp/{scoped_endpoint,scoped_forward,loopback_client}.ex`;
`lib/jido_claw/skills/steps/forge_executor/{deposit,deposit_server,deposit_plug}.ex`;
`lib/jido_claw/skills/steps/forge_executor/tools/submit_structured_output.ex`;
`test/support/scripted_deposit_runner.ex`; 3 new test files (below).
Modified: `forge_executor.ex`, `agent_runner.ex`, `startup.ex` (public gated
`subagent_prompt/3`), `templates.ex`, `forge/runners/{codex,claude_code,fake}.ex`,
`memory/consolidator/{plug.ex, run_server.ex, tools/helpers.ex}`, `application.ex`,
AGENTS.md, `docs/plans/unadopted-next-ten/README.md`, 5 existing test files.
Deleted: `memory/consolidator/mcp_endpoint.ex`, `memory/consolidator/plug/run_forward.ex`.

## Test plan

House rules: `assert match?(pat, x), "msg"`; shared SQL sandbox where AgentRunner writes
transcripts; test/support stays reach-clean; no piping the gate.

1. **Hydration** (`templates_test.exs`, extend the :501 describe): vendor kinds with
   `%{}` hydrate with `workspace: :repo` **written into the hydrated config** (P2a);
   each enum value accepted; bad workspace / bad optional types / unknown key / `access`
   key / workspace-on-non-vendor all raise; static templates + `:fake`/`:shell`
   byte-identity guard stays green.
2. **Deposit box** (new `forge_executor/deposit_test.exs`): valid → accepted + `take`
   typed (atom-keyed); invalid → bounded error, `take` nil, `invalids` bumped; binary
   JSON payload validates; second valid → last-wins; no-schema → accept-and-store;
   `take` empty → nil.
3. **Deposit tool** (new `tools/submit_structured_output_test.exs`): registered box +
   atom-key AND string-key assigns resolve; no ref / unknown ref / invalid payload →
   `{:error, _}` (isError contract).
4. **Vendor arm E2E, hermetic** (extend `forge_executor_test.exs`): armed
   `:executor_vendor_runners` → `ScriptedDepositRunner` (a real `@behaviour
   Forge.Runner` in test/support that reads the MCP config file and drives
   `LoopbackClient` initialize + `tools/call submit_structured_output` — proving
   endpoint → plug → anubis → tool → registry → box with zero CLIs): valid deposit →
   `typed_output` set AND `result` text is the typed projection, not raw runner output
   (P3a); invalid-only → typed nil; no deposit → typed nil; `workspace: :repo` without
   project_dir → loud error BEFORE any session; **cleanup on failure paths** (P2b):
   session-start failure (scripted runner init `{:error, :no_credentials}`) and
   runner-cap style start errors leave no leaked session, no registered box, no
   listening endpoint, no tmp files; acquisition-unwind unit for
   `acquire_vendor_resources` with an injected failing acquire step if practical.
5. **Prompt parity** (P1a — PromptCapture-style scripted runner, the consolidator
   precedent): a vendor step's runner-received prompt CONTAINS the
   `SubagentPrompt.build/3` sections (role/doctrine) and the deposit instruction LAST
   when the doctrine gate is on; gate off ⇒ prompt starts at the task (byte-consistent
   with in-process doctrine-off); `catalog_stage_name` steers the persona section.
6. **Runner argv/env units** (extend `runners/codex_test.exs`, `claude_code_test.exs`
   via `StubSandbox`): read-only flag sets present and bypass flags absent;
   `mcp_server_name` override lands in the codex `-c` line / claude `--allowedTools`;
   `cwd`/`add_dirs` reach `-C`/`--add-dir`; codex `config_sync: :auth_only` syncs only
   auth.json; claude `config_sync: :auth_only` asserts the **`CLAUDE_CONFIG_DIR`
   inject_env event**, credentials-only sync, minimal settings.json via exec-based
   write, and NO allow-all settings (P1b — assert env/argv, not just copied files);
   existing `:full` tests stay green.
7. **Dispatch flip** (`agent_runner_test.exs` :268 describe): `{:forge, :codex}` routes
   through `run_forge` (correlation + transcript rows + flush-barrier signal, like the
   `:fake` envelope test); `{:forge, :custom}` still refused.
8. **Composer eval** (new `eval/composer_vendor_case_test.exs`, modeled on
   `composer_forge_fake_case_test.exs`): reviewer-lens stage on `{:forge, :codex}` via
   the scripted runner — clean deposit converges through real `DefaultMapper`/`Verdict`;
   drifted deposit (out-of-enum `overall`) is rejected by the box ⇒ typed nil ⇒
   `normalize(:review, %{})` ⇒ `{:infra, _}` ⇒ composer infra lane — never a verdict.
9. **Consolidator regression**: `run_server_test.exs` (full fake harness through the
   now-shared, session-aware endpoint/client) stays green.

## Implementation order (one PR)

1. Shared modules (`ScopedEndpoint` + `write_client_config`, `ScopedForward` +
   `scope_id/2`, session-aware `LoopbackClient`) + consolidator migration + delete
   originals → consolidator tests green.
2. Deposit lane (box + registry + server + plug + tool + application children) →
   red/green units (2)(3).
3. Runner knobs incl. claude `CLAUDE_CONFIG_DIR` isolation → red/green argv/env units (6).
4. ForgeExecutor vendor arm (`acquire_vendor_resources` unwind, prompt assembly,
   `run_vendor`, result projection) + `ScriptedDepositRunner` → red/green E2E (4).
5. AgentRunner dispatch + `Startup.subagent_prompt/3` → red/green (5)(7).
6. Hydration normalization + validation + comment/moduledoc updates → red/green (1).
7. Composer eval case (8).
8. Docs: AGENTS.md executor paragraph; next-ten README item 7 PR-2 done-note with
   corrections-to-claims (Output struct not raw schema; box validates + normalize stays
   at DefaultMapper as backstop; LoopbackClient touched Runners.Fake, superseding PR-1's
   "untouched"; `:scratch`/`:none` differ only in prompt note this wave; timeout default
   240s under the 300s wave deadline; vendor prompts carry the subagent contract —
   `catalog_stage_name` now threads to the forge arm). Item-level Status + camus C1-1
   reconciliation still wait for PR-4.
9. `mix precommit` — full gate, zero findings, exact exit code + counts reported
   verbatim (never piped).

## Build-time verification (live smoke, before calling the runners done)

- **claude**: confirm exact built-in read-tool names for `--tools`; confirm the read
  set + `--allowedTools` + `--permission-mode dontAsk` combination neither prompts nor
  hangs in `-p` mode and the MCP deposit tool is callable. **HARD PR GATE — config
  isolation**: prove `CLAUDE_CONFIG_DIR` is honored (credentials read from the per-run
  dir, host `~/.claude` settings NOT consulted) with one live run; this is the one
  speculative piece (HostShell really does inherit `HOME`, and the pre-existing
  `forge_home/.claude` write path is decorative without the env override). **Named
  fallback if the CLI ignores it**: inject `HOME=<forge_home>` for executor sessions
  instead (the Env allowlist's explicit-override-always-wins path, verified), with
  `credentials.json` synced under `<forge_home>/.claude` — coarser but fully effective
  isolation on HostShell; flags unchanged. The PR does not ship with an unverified
  isolation story.
- **codex**: confirm `-s read-only` doesn't block the streamable-HTTP MCP connection to
  127.0.0.1 (the MCP client runs in the codex process, not the sandboxed child — should
  hold; if not, a `-c` network override is the fallback).
- These are manual one-shot checks against the operator-installed CLIs; the committed
  test suite stays hermetic (scripted runner).

## Risks / residuals (documented, not built)

- `:scratch` vs `:none` are near-identical in a read-only wave (prompt note only);
  the enum ships now for knob stability, meaningful `:scratch` arrives with PR-4 writes.
- Deposit box is linked to the step process; handlers are total, and a pathological box
  fault surfaces as a step crash → the composer's existing wave-error/Lane-B handling.
  (Acquisition itself cannot leak on failure — every step is a tuple step and the
  rescue-backed unwind is total, per Design D.)
- Vendor sessions are per-runner capped at 10 by `Forge.Manager` — a wide parallel wave
  can hit `:runner_at_capacity` (a per-step error, the PR-1 residual class).
- Producer templates on vendor executors work but are untested against real CLIs this
  wave (read-only lens stages are the target cohort; PR-3 declares the first real one).

## Verification

- `mix precommit` passes (the plan's completion bar) — run directly, exit code + test
  counts reported verbatim.
- Hermetic E2E proves the full MCP loop (endpoint → deposit → StepResult) with no
  vendor CLIs; composer eval proves verdict + infra lanes end-to-end; prompt-parity
  test proves the subagent contract survives the executor swap.
- Consolidator regression suite green post-migration.
- Nothing committed — all changes stay unstaged.
