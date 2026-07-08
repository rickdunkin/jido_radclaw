---
type: subsystem
description: The template executor binding — in-process vs Forge-backed vendor CLIs, the single-channel deposit, cross-vendor review independence, the per-stage override, and the needs-input answer loop.
sources:
  - lib/jido_claw/skills/steps/agent_runner.ex
  - lib/jido_claw/skills/steps/forge_executor.ex
  - lib/jido_claw/skills/steps/forge_executor/deposit.ex
  - lib/jido_claw/orchestration/review_independence.ex
  - lib/jido_claw/orchestration/needs_input.ex
  - lib/jido_claw/agent/templates.ex
  - lib/jido_claw/forge/sandbox/docker.ex
  - lib/jido_claw/route_composer/stage.ex
  - lib/jido_claw/route_composer/wave_builder.ex
  - lib/jido_claw/route_composer/catalog_validator.ex
verified: 2026-07-07
verified_sha: "91157b13"
---

# Executor Seam (template `executor:` binding)

## What & why

Next-ten item 7 (camus C1-1, "build the seam, not the pairing"): every worker template
declares *what executes it* — the in-process `Jido.AI` worker or a Forge-backed
session (fake fixture, shell command, or a vendor CLI: codex / claude_code) — so
orchestration can mix executors per stage without the composer knowing vendor
mechanics. **Item complete** (PRs 1–4 + the docker write build); the first production
declarer is the cross-vendor review configuration; PR-4 added the per-stage catalog
override, the `access`/`session_sandbox` knobs, and the `needs_input` answer-loop
gate case; the write build made `session_sandbox: :docker` dispatch real — a
write-capable vendor session runs inside an sbx microVM with a direct rw same-path
repo mount, and its edits land in the real working tree.

## Invariants & contracts

- Every hydrated template carries `executor:` (`:in_process` default — today's
  in-process `Jido.AI` worker, byte-identical — or
  `{:forge, :fake | :shell | :codex | :claude_code | :custom}`) + `executor_config:`
  (map, `%{}` default) — **operator-declared config in the `verify_cmd` trust class,
  never the stage task**.
- Hydration validation **raises** `ArgumentError` via normalizing validators that
  return the config they validated (the `:max_iterations` loud posture, NOT
  fc/ra/sandbox's warn+fail-closed — the tight direction here is *refuse to run*).
  `:custom` stays refused at dispatch (the camus unknown-backend fail-closed
  discipline).
- **Write is docker-bound, and the microVM is the boundary** (the docker write
  build, camus sketch (d)). `access: :write` requires `session_sandbox: :docker` at
  hydration (write+local raises — a write-capable vendor session must be
  docker-backed); a docker plan dispatches the vendor CLI into an sbx microVM via
  the `:executor_docker_backend` seam with the run's repo mounted **same-path**
  (`{project_dir, project_dir, "rw"|"ro"}` — mode from the plan's single resolved
  `access`), and the runner posture derives from that SAME access: `:write` ⇒ the
  runners' `:full` arms (codex `--dangerously-bypass-approvals-and-sandbox`, claude
  `--dangerously-skip-permissions` + `--strict-mcp-config`); `:read_only` keeps the
  restricted CLI flag sets AND a `:ro` mount (defense in depth). Local vendor plans
  are always `:read_only` by the hydration invariant.
- **Executor precedence (PR-4, both seams)**: test `:agent_templates_override` >
  `.jido/config.yaml` `review:` knob > per-stage catalog `executor:` override >
  template binding. The test seam is NAME-gated — an overridden template suppresses
  stage overrides on it by design.
- **Single-channel deposit** (camus OQ-1(c)): `typed_output` comes ONLY from a
  schema-valid `submit_structured_output` deposit; CLI stdout feeds `ARTIFACTS:`
  extraction and no-deposit fallback text, never typed. A deposit-less lens stage lands
  `normalize(:review, %{})` ⇒ the Verdict infra lane — never a fabricated verdict
  (`Verdict.normalize/2` stays at `DefaultMapper`, the fold backstop).
- **Cross-vendor review (PR-3)**: a `.jido/config.yaml` `review:` section binds ONLY
  the `reviewer` template and is consulted at BOTH seams by
  `JidoClaw.Orchestration.ReviewIndependence` — the composer **launch fence** (a
  strict-mode provider collision refuses the run BEFORE any wave) and the **dispatch
  overlay** (an invalid/unreadable knob is a step error, never a silent in-process
  fall-through). The YAML boundary is Verify.Config-strict: unknown keys, non-map
  sections, and present-nil values refuse LOUDLY — a typo can neither silently strict
  nor silently enable same-vendor review.

## Mechanics

### Template binding & hydration (PR-1 + PR-4 knobs)

- `{:forge, :shell}` uses `%{command: <binary>}`; a command-less shell template raises.
- Vendor kinds accept `workspace: :repo (default) | :scratch | :none`, `access:
  :read_only (default) | :write`, and `session_sandbox: :local (default) | :docker` —
  all three defaults written back into the hydrated config — plus optional
  `model`/`thinking_effort` (non-blank binaries) and `max_turns`/`timeout_ms`
  (positive ints); any other key is refused (the knob is `:session_sandbox`, NOT
  `:sandbox` — deliberately distinct from the template-policy VFS-jail axis), and a
  `workspace` key on any non-vendor kind refuses too. The write⇒docker invariant
  raises on write+local (including write with the defaulted local).
- A `{:forge, _}` executor also refuses a `:prototype`/`:docker` `:sandbox` policy —
  the in-process VFS-jail axis is dead on a forge session; the forge-session axis is
  `executor_config` `session_sandbox:`.
- `Templates.hydrate_executor_binding/3` (generalized from PR-3's
  `hydrate_review_binding/3`) is the shared config-sourced binding hydration:
  `:in_process` ⇒ `{:ok, {:in_process, %{}}}` (config dropped), `{:forge, _}` runs the
  same private validators with `ArgumentError` converted to an operator-facing
  `{:error, message}`, anything else refuses. Both the review knob and the per-stage
  override hydrate through it against the RESOLVED base template.

### Forge dispatch

`AgentRunner.run/7` dispatches on the binding: `:fake`/`:shell`/`:codex`/`:claude_code`
route through `JidoClaw.Skills.Steps.ForgeExecutor` — a REAL minimal Forge session per
step (`Ecto.UUID` session id, `claim: false`; the `:shell`/`:fake` arms and LOCAL
vendor plans run `sandbox: :local` ⇒ HostShell per-run tmp dir even under a prod
`FORGE_SANDBOX=docker`, `start_session_ready(expected_backend: HostShell)`; a DOCKER
vendor plan sets `sandbox:` from the `:executor_docker_backend` seam and asserts the
seam-resolved MODULE — `ForgeExecutor.expected_backend/1` maps the `:docker_sandbox`
wire atom to `Forge.Sandbox.Docker` itself, because `ReadyStart.usable_status` compares
harness `sandbox_module` MODULES, so a raw atom would tear down every real docker
session as `{:wrong_backend, _}`. One `run_iteration`, result captured before the
`try/after` `stop_session`; `:blocked`/`:continue` are single-shot errors;
`:needs_input` is the PR-4 gate case below — still a step error). Both arms
share one tool-context builder + the `run_recorded` never-crash envelope
(task/terminal transcript rows + child correlation, uniform across executors); the
forge arm additionally **publishes the terminal signal itself**
(`ai.request.completed`/`failed` — no AgentServer runs on this path, and the
Recorder's flush barrier + correlation finalizer wait on it) and runs no stage tier /
MCP attach.

### The `needs_input` answer loop (PR-4, camus sketch (e))

A runner's `:needs_input` iteration maps to a **gate case + step error** — the
ToolApprovals model, not a composer park (the full park is deliberately unbuilt: no
production runner on the executor path emits `:needs_input`; the scripted test
runners are its first emitters):

- `JidoClaw.Orchestration.NeedsInput.raise_case/2` (best-effort — a DB fault
  Trace-warns and the step error still returns) maps a **question-agnostic stage
  identity** fingerprint (`{:needs_input_v1, tenant, identity_key, template,
  step_name-or-template}`) to a durable pending `AgentCase` (kind `:needs_input`,
  gate `JidoClaw.Gates.NeedsInputGate`) — run-bound for PROVENANCE only (no run
  status flip, no checkpoint) or run-less. `identity_key` is the session key
  (`session_uuid || session_id`) else the run id (run-scoped degradation); with
  NEITHER the producer refuses to open rather than share answers across unrelated
  same-tenant attempts. A raise while pending reuses the case — **first question
  wins** (retries rephrase; no per-retry detail updates). The question is redacted in
  BOTH sinks (case `details["question"]` and the step error text).
- The step error names the gate id: operators decide via REPL `/gates` / web
  `/approvals` — the ANSWER rides `decision_comment` (the kind-dispatched
  `Cases.decide/4` branch refuses a blank-answer approve with
  `{:error, :answer_required}`; reject needs no comment; `Cases.abandon/3` refuses
  the kind outright with `{:error, :not_abandonable}` — dispatched BEFORE the
  workflow-case guard, since the case may be run-less).
- `NeedsInput.claim_answer/1` (fail-open — the LoopGuard facade posture) runs in the
  stage's NEXT attempt: the vendor `build_spec` claims **LAST in its `with` chain**
  (after the docker refusal and workspace resolution — a refused dispatch never
  burns the answer) and injects the answer into the prompt between the workspace
  note and the deposit instruction (deposit stays LAST; nil ⇒ byte-identical
  prompt). Claims are single-use (`AgentCase.consume` under FOR UPDATE) and
  TTL-bounded (24h from `decided_at` — the bound on the question-agnostic cross-run
  replay window; stale approved cases stay inert). Session arms (`:fake`/`:shell`)
  raise but never claim, and `details["injectable"]` (vendor AND session-keyed) keys
  the surface copy so injection is never promised where it can't happen.

### Vendor arm (PR-2, `{:forge, :codex | :claude_code}`)

- Per step: a linked `ForgeExecutor.Deposit` box (registered in `DepositRegistry`) + a
  `JidoClaw.MCP.ScopedEndpoint` (Bandit loopback fronting the always-on `DepositServer`
  through `DepositPlug`) + the MCP client config — acquired through a total
  unwinding reducer (box → endpoint → forge home → client config; a partial acquisition
  tears down exactly what it acquired), torn down on every path. The client config is a
  host-tmp FILE for local plans only; a docker plan carries the SAME JSON body
  (`ScopedEndpoint.client_config_json/2`) as runner-config `mcp_config_json`, written
  in-VM at claude's runner init through the CHECKED `FileSync.write_checked/3` (a
  failed write fails init closed — no deposit server, no session); codex needs only the
  URL (its `-c` inline override).
- **Docker deposit reachability**: `ScopedEndpoint` keeps its `127.0.0.1` bind; a
  docker plan rewrites the URL host to `host.docker.internal` and the session spec
  carries `allow_network: ["host.docker.internal:<port>", "localhost:<port>"]` — the
  backend applies it post-create as a per-sandbox `sbx policy allow network` rule
  (both forms REQUIRED: the sbx proxy normalizes `host.docker.internal` to
  `localhost:<port>` in its allow matching — smoke-verified). Enforcement is a
  transparent proxy answering in-band HTTP 403 ("Blocked by network policy") rather
  than a transport denial; `sbx rm` removes per-sandbox rules (leak-check pinned in
  the `:docker_sandbox` tier).
- **Docker session mechanics** (sbx 0.34.0): workspaces are `sbx create` POSITIONALS
  mounted in-VM at the SAME absolute host path (`path` rw / `path:ro`; no `--mount`,
  no path remapping — same-path + absolute validated up front, and
  `network:`/`allow_network` moved to post-create `sbx policy`). A vendor run is
  `sbx exec` into the harness sandbox wrapped in-VM as
  `sh -c 'exec "$0" "$@" </dev/null'` — the stdin redirect is load-bearing (the sbx
  client forwards its never-EOF piped stdin), and the same wrapper applies the
  workspace `.forge_env` with assignment-only exports (`sbx exec --env-file` is inert
  on 0.34.0; `-e` would put vault secrets on the host argv). Docker plans pin
  `forge_home` under `/tmp/jidoclaw_forge_exec/<session_id>` (in-VM user-writable;
  `/var/local/forge` may not be creatable in-VM).
- Deposits are validated in the box against the template's `strategy_opts()[:output]`
  (`%Jido.AI.Output{}`; invalid ⇒ bounded `isError`, the CLI retries in-session;
  valid ⇒ last-valid-wins).
- **codex hardwiring**: `access: :read_only` ⇒ `-s read-only`, `:full` (the write
  posture) ⇒ `--dangerously-bypass-approvals-and-sandbox`; auth.json-only sync (a
  refused `CODEX_HOME` inject fails init CLOSED).
- **claude hardwiring**: `access: :read_only` ⇒ `--tools Read,Glob,Grep` +
  `--allowedTools`(+deposit tool) + `--permission-mode dontAsk` +
  `--strict-mcp-config`; `:full` (the write posture) ⇒
  `--dangerously-skip-permissions`, plus `--strict-mcp-config` when the executor
  sets `strict_mcp: true` (docker plans — orthogonal to permissions). Credential-only
  sync into an isolated per-run `CLAUDE_CONFIG_DIR` (a refused env inject fails init
  CLOSED; isolation proven live — a fresh dir reads "Not logged in" on an
  authenticated host): the credential resolves content-based through the SHARED
  source — host `.credentials.json` → legacy `credentials.json` → macOS Keychain
  (`security find-generic-password -s "Claude Code-credentials" -w` behind the
  injectable `:claude_keychain_reader` seam; the blob never lands on host disk) —
  and is written in-sandbox to the DOTTED `.credentials.json` (what claude reads
  under `CLAUDE_CONFIG_DIR`) via the CHECKED `FileSync.write_checked/3` (write +
  `chmod 600` in one exit-status-verified exec; failure fails init CLOSED). This
  also fixed the latent macOS LOCAL vendor path: a Keychain-only host (no
  credential file) no longer fails `:no_credentials`.
- Vendor prompts carry the FULL subagent contract (`Startup.subagent_prompt/3`, same
  `:doctrine` master gate; `catalog_stage_name` threads down the forge arm so stage
  personas hold) + task + workspace note + deposit instruction LAST, redacted by the
  runners' argv `PromptRedaction` (which gained the ANSI pre-pass — `Ansi.strip` before
  `Patterns.redact`, both clauses — so vendor-CLI prompt egress passes the redaction
  root literally).
- `workspace: :repo` requires `project_dir` pre-flight (codex `-C`, claude
  `--add-dir`); `:scratch`/`:none` differ only in the prompt note this wave.
- Vendor `timeout_ms` defaults **240s** (clamped 30s–600s) — deliberately under the
  composer's 300s wave deadline; raising one means raising the other.
- Three load-bearing live-smoke fixes rode the PR-2 wave: the shared client config
  writes `"type": "http"` (claude ≥2.x reads a bare `url` as legacy SSE);
  `HostShell.cli_exec_argv/2` always redirects CLI-runner stdin from `/dev/null`
  (OsCmd ports never deliver EOF and `codex exec` reads piped stdin TO EOF — every
  codex session hung); the codex `-c` override carries
  `default_tools_approval_mode="approve"` (codex ≥0.142 auto-cancels un-approved MCP
  tool calls headless).
- Two more rode the write-build smoke, both in the Forge harness: `Harness.init`
  now TRAPS EXITS so `terminate/2` — and with it `Sandbox.destroy` — actually runs
  on `Manager.stop_session`'s `:shutdown` delivery (latent forever: invisible for
  HostShell whose linked sandbox Agents die with the harness, a leaked microVM +
  secret-bearing workspace per session on docker; pinned by
  `harness_teardown_test.exs`), with the destroys themselves DETACHED under the
  app TaskSupervisor (a real `sbx rm` is multi-second — inline it would block
  `stop_session` callers past their 5s deadlines and serialize wave teardowns
  through the singleton Manager; a killed/failed rm is the boot reaper's job);
  and the harness `persist/1` guard catches EXITS too, not just raises — a
  DBConnection checkout fault inside `terminate/2` must not replace the
  session's real exit reason.
- Fresh-session-per-re-review-round is pinned (two vendor sessions across a findings →
  fix → approve loop; no-resume argv pins on both runners — camus C3-1's resume
  machinery unported).

### The fake executor

`{:forge, :fake}` serves caller-armed fixtures from `:executor_fake_outputs` through
the generic `Forge.Runners.StaticFake`: resolution is `{:stage, template, step_name}`
(exact) → `{:fragment, template, fragment}` (exactly ONE must contain-match the task;
zero/several fail closed) → plain `template` — **any tuple key for a template disables
its plain fallback** (the composer StubWorker's no-silent-fallback rule), and
resolution happens before provisioning so no session starts on a miss. Fixture/stdout
output is soft-validated against the template module's `strategy_opts()[:output]`
schema (binaries JSON-decode): invalid ⇒ `typed_output: nil` with **live-faithful**
consequences — a lens stage rides the Verdict infra lane (never a fabricated verdict),
a producer falls back to its result text for the named artifact.

### Cross-vendor review configuration (PR-3)

Camus C1-1's "no agent grades its own work", enforced at RESOLUTION rather than
camus's hardcoded topology — the first production declarer is operator CONFIG, not a
committed template:

- The `review:` section: `executor: codex | claude_code`, optional `executor_config:`
  (run through the hydration validators against the RESOLVED reviewer base template
  via `Templates.hydrate_executor_binding/3`; PR-4 added `access`/`session_sandbox`
  to the translated key set, so a write+local knob surfaces the hydration invariant
  loudly at both seams), `independence: strict | degraded` (default strict). The KNOB
  stays template-name-keyed; per-stage steering is the separate catalog override
  below — knob beats stage.
- **Launch fence**: `check_route/2` in `RouteComposer.init/1` (front door AND boot
  recovery pass through it) walks every review-lens `{:worker_template, _}` stage;
  when its effective executor is a vendor CLI kind, every `{:worker_template, _}`
  producer of its required+optional inputs must differ in provider identity
  (`{:forge, :codex}` → openai, `{:forge, :claude_code}` → anthropic,
  `:shell`/`:fake`/`:custom` → `:none`; `:in_process` resolves the producer's OWN
  tier — `stage.model || template.model` — through `Jido.AI.resolve_model/1`, with
  unknown aliases / non-binary alias specs `:indeterminate` = collision, fail closed).
- A strict-mode collision refuses the run BEFORE any wave — `run_sync` surfaces
  `{:error, {:start_failed, {:review_independence_held, %{scope: :catalog, …}}}}`, the
  front door terminalizes the parent, boot recovery leaves it `:running` for retry
  (the invalid-catalog precedent). The whole-catalog scope is deliberate — a
  talk/sketch request can be refused by a code-route pairing (the remedy says so).
  `independence: degraded` passes with a warning + telemetry, no new terminal.
- **Dispatch overlay**: `ReviewIndependence.apply_executor/4` between `Templates.get/1`
  and executor dispatch in `AgentRunner.run/7` — resolves the full precedence chain
  (test override > knob > stage override > template); a stage override that fails
  hydration (e.g. `{:forge, :shell}` over a command-less config) is a step error,
  never a silent fall-through.
- YAML boundary details: closed executor parser + literal key translation — never
  `String.to_atom/1`; non-map section / unknown keys / `executor_config`-without-
  `executor` / malformed `independence:` all refuse LOUDLY. Strict at the FILE level
  too — reads go through the fail-closed `Config.read_user_config/1`, so an
  unreadable/unparseable `.jido/config.yaml` refuses loudly (absent file stays absent;
  `Config.load/1` keeps the tolerant collapse for boot/wizard surfaces). Present-null
  keys (`review:` / `executor:` / `executor_config:` / `independence:` left blank
  parse present-nil; `Map.fetch` semantics at all four sites) refuse loudly as well
  (present-nil ≠ absent), and every config read is nil-total (nil/blank `project_dir`
  ⇒ no config read, byte-identical launch — never a `File.cwd!()` fallback).
- Test-seam precedence: an `:agent_templates_override` template is authoritative at
  both seams — the knob never overlays it.
- The camus review-prompt persona landed as the `:reviewer_stance` doctrine slice
  (adversarial stance + the "correct but incomplete must NOT pass" completeness
  clause) on the three reviewer-contract templates, with the "from a different vendor"
  claim deliberately dropped (honest on same-vendor paths).

### Per-stage executor override (PR-4, camus OQ-1(b))

The AR-9 tier seam's shape, exactly ("one shape" — `plan-arbiter` is the tier
declarer precedent; the shipped catalog declares NO executor overrides, pinned):

- `Stage.executor` (`:in_process | {:forge, kind} | nil`, nil default) serializes as
  `nil | "in_process" | "forge:<kind>"` through `Stage.to_map/from_map` (closed decode
  map — an unknown string fails the whole stage decode; never `String.to_atom`);
  `Catalog.to_map/from_map` (the durable launch catalog in
  `WorkflowRun.config["catalog"]`) delegates per stage. The `jido://workflows/*` MCP
  resources render stages via `Stage.to_map`, so the `"executor"` key was an additive
  served-output field — SurfaceVersion MINOR bump to 1.1.
- `CatalogValidator` group 0: nil everywhere; a non-nil override must be a closed
  executor term AND on a `{:worker_template, _}` stage (gate/verify/seed stages
  carrying one are rejected at load — nothing would read it).
- `WaveBuilder.executor_opts/1` (beside `tier_opts/1`, the conditionally-put shape —
  never a present-nil key) carries a declared override into the stage step options;
  `AgentStep` forwards it as `AgentRunner.run/7`'s trailing argument (skill-YAML steps
  and the saga cleanup naturally pass nil).
- Both seams resolve it below the knob: the dispatch overlay hydrates the override
  against the template's own `executor_config` (identity comes from the stage; config
  stays operator-declared), and the launch fence's `resolve_executor/4` takes the
  stage branch ONLY when `stage.executor` is non-nil — an unconditional stage read
  would mask template bindings for every all-nil production catalog and manufacture
  false holds. A producer stage's own override feeds implementer-vendor identity.
- Run-level force-`:in_process` (OQ-1(b)'s other half) is design-pinned, unbuilt — no
  declarer.

## Config & telemetry

Config: `:executor_fake_outputs` + `:executor_vendor_runners` (both test-armed; the
scripted vendor double reads its script from its own key — no test keys in prod
runner_config). Telemetry counters `jido_claw.executor.total` (`kind`/`outcome`),
`jido_claw.review_independence.total` (`:held`/`:degraded_pass`), and
`jido_claw.needs_input.total` (`event` `:raise`/`:claim` × `outcome`
`:opened`/`:reused`/`:consumed`/`:error`).

## Residuals & accepted risks

- Forge `Manager` per-runner caps (`shell: 20`, `codex`/`claude_code`: 10; module
  runners like `StaticFake` fall to `max_sessions: 50`) can `:runner_at_capacity` a
  wide parallel wave ⇒ a per-step error, not a crash.
- Both vendors' runner-default models can be account/era-stale — codex's
  `gpt-5-codex` is rejected on ChatGPT-plan accounts, and claude's
  `claude-sonnet-4-20250514` is retired (`model_not_found`, write-build smoke).
  Declare `model` in `executor_config`; the defaults are deliberately left
  (consolidator byte-identical discipline — any default goes stale again).
- Mid-run `.jido/config.yaml` edits are not re-checked (camus C2-7 class, the
  `verify_cmd` precedent); a deterministic violation loops boot recovery `:running`.
- Vendor identity is provider-prefix-approximate — a proxy provider like openrouter
  reads as its own vendor; the operator owns the knob.
- The full `needs_input` composer park stays gated on an interactive-runner producer
  (today every executor-path runner is single-shot; the answer-loop gate case covers
  the seam).
- A stale approved needs-input answer (past the 24h TTL) is left inert — visible in
  case history, never consumed, never garbage-collected.
- **Answer-burn on docker infra failure**: the vendor `build_spec` claims the
  operator answer LAST (after every refusal), but a docker infra failure AFTER the
  claim (backend create, policy rule, runner init) still burns the single-use answer
  — the same pre-existing class as a local `:no_credentials` at init; accepted, not
  new machinery.
- **Claude credential source residuals**: an in-VM token refresh can rotate the
  refresh token while the host Keychain copy goes stale (same class as the existing
  Linux file sync), and the first Keychain extraction may pop a one-time macOS
  approval prompt (attended runs OK; unattended runs need pre-authorization). The
  `FileSync` base64-argv exposure class (the credential rides an exec argv
  base64-encoded — `Patterns`' `sk-ant-` rule covers plaintext, not the base64 form)
  is pre-existing and shared with the `:full` auth sync; the checked write drops the
  shell's error output from its error tuple so a failure can't echo the argv into
  logs/transcripts.
- The repo-`.mcp.json` concern in write mode is **CLOSED by `strict_mcp`** (claude's
  write arm appends `--strict-mcp-config`; the flag+bypass combination is
  smoke-verified against the installed CLI), not an accepted residual.
- sbx `secret`/`serviceAuth` proxy-injected credentials remain the documented
  alternative to file-sync auth; a vendor-image pinning knob (`sbx create -t`) stays
  unbuilt — the smoke didn't force either.

## Source map

- `lib/jido_claw/agent/templates.ex` — hydration validators (incl. the write⇒docker
  invariant), `hydrate_executor_binding/3`
- `lib/jido_claw/skills/steps/agent_runner.ex` — `run/7` dispatch on the binding, the
  independence/override overlay seam
- `lib/jido_claw/skills/steps/forge_executor.ex` — the forge arm: session lifecycle,
  unwinding reducer, terminal signal, docker dispatch (session spec, backend seam,
  URL translation, access mapping), needs-input raise/claim/injection
- `lib/jido_claw/forge/sandbox/docker.ex` — the sbx 0.34.0 backend: same-path
  workspace positionals, post-create policy rules, the in-VM exec wrapper
  (stdin `</dev/null` + `.forge_env` export loop), `allow_network` validation
- `lib/jido_claw/skills/steps/forge_executor/deposit.ex` — the deposit box,
  schema validation, last-valid-wins
- `lib/jido_claw/orchestration/review_independence.ex` — `check_route/2`,
  `apply_executor/4`, provider identity, the stage-override branch
- `lib/jido_claw/orchestration/needs_input.ex` — the needs-input producer:
  fingerprint, raise/reuse, TTL-bounded single-use claims
- `lib/jido_claw/route_composer/stage.ex` — the `executor` field + closed
  serialization
- `lib/jido_claw/route_composer/wave_builder.ex` — `executor_opts/1` (the
  conditionally-put carrier)
- `lib/jido_claw/route_composer/catalog_validator.ex` — the worker-stage-only
  structural check
- `lib/jido_claw/route_composer/route_composer.ex` — the launch fence call in `init/1`
