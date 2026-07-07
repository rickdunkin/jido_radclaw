---
type: subsystem
description: The template executor binding — in-process vs Forge-backed vendor CLIs, the single-channel deposit, and cross-vendor review independence.
sources:
  - lib/jido_claw/skills/steps/agent_runner.ex
  - lib/jido_claw/skills/steps/forge_executor.ex
  - lib/jido_claw/skills/steps/forge_executor/deposit.ex
  - lib/jido_claw/orchestration/review_independence.ex
  - lib/jido_claw/agent/templates.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
---

# Executor Seam (template `executor:` binding)

## What & why

Next-ten item 7 (camus C1-1, "build the seam, not the pairing"): every worker template
declares *what executes it* — the in-process `Jido.AI` worker or a Forge-backed
session (fake fixture, shell command, or a vendor CLI: codex / claude_code) — so
orchestration can mix executors per stage without the composer knowing vendor
mechanics. PR-3 of 4 shipped; the first production declarer is the cross-vendor review
configuration.

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
- Vendor sessions are **HARDWIRED read-only + isolated** — no access knob this wave.
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

### Template binding & hydration (PR-1)

- `{:forge, :shell}` uses `%{command: <binary>}`; a command-less shell template raises.
- Vendor kinds accept `workspace: :repo (default, written back into the hydrated
  config) | :scratch | :none` plus optional `model`/`thinking_effort` (non-blank
  binaries) and `max_turns`/`timeout_ms` (positive ints); any other key is refused —
  deliberately NO `access`/`sandbox` keys this wave, and a `workspace` key on any
  non-vendor kind refuses too.
- A `{:forge, _}` executor also refuses a `:prototype`/`:docker` `:sandbox` policy —
  the in-process VFS-jail axis is dead on a forge session; PR-4's session-sandbox knob
  lives in `executor_config`.

### Forge dispatch

`AgentRunner.run/6` dispatches on the binding: `:fake`/`:shell`/`:codex`/`:claude_code`
route through `JidoClaw.Skills.Steps.ForgeExecutor` — a REAL minimal Forge session per
step (`Ecto.UUID` session id, `claim: false`, `sandbox: :local` ⇒ HostShell per-run tmp
dir even under a prod `FORGE_SANDBOX=docker`,
`start_session_ready(expected_backend: HostShell)`, one `run_iteration`, result
captured before the `try/after` `stop_session`; `:needs_input` maps to a step error
until PR-4's gate case, `:blocked`/`:continue` are single-shot errors). Both arms share
one tool-context builder + the `run_recorded` never-crash envelope (task/terminal
transcript rows + child correlation, uniform across executors); the forge arm
additionally **publishes the terminal signal itself** (`ai.request.completed`/`failed`
— no AgentServer runs on this path, and the Recorder's flush barrier + correlation
finalizer wait on it) and runs no stage tier / MCP attach.

### Vendor arm (PR-2, `{:forge, :codex | :claude_code}`)

- Per step: a linked `ForgeExecutor.Deposit` box (registered in `DepositRegistry`) + a
  `JidoClaw.MCP.ScopedEndpoint` (Bandit loopback fronting the always-on `DepositServer`
  through `DepositPlug`) + a host-side client config — acquired through a total
  unwinding reducer (box → endpoint → forge home → client config; a partial acquisition
  tears down exactly what it acquired), torn down on every path.
- Deposits are validated in the box against the template's `strategy_opts()[:output]`
  (`%Jido.AI.Output{}`; invalid ⇒ bounded `isError`, the CLI retries in-session;
  valid ⇒ last-valid-wins).
- **codex hardwiring**: `-s read-only` + auth.json-only sync (a refused `CODEX_HOME`
  inject fails init CLOSED).
- **claude hardwiring**: `--tools Read,Glob,Grep` + `--allowedTools`(+deposit tool) +
  `--permission-mode dontAsk` + `--strict-mcp-config` + credentials-only sync into an
  isolated per-run `CLAUDE_CONFIG_DIR` (exec-based writes; a refused env inject fails
  init CLOSED; isolation proven live — a fresh dir reads "Not logged in" on an
  authenticated host).
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
- Three load-bearing live-smoke fixes ride this wave: the shared client config writes
  `"type": "http"` (claude ≥2.x reads a bare `url` as legacy SSE);
  `HostShell.cli_exec_argv/2` always redirects CLI-runner stdin from `/dev/null`
  (OsCmd ports never deliver EOF and `codex exec` reads piped stdin TO EOF — every
  codex session hung); the codex `-c` override carries
  `default_tools_approval_mode="approve"` (codex ≥0.142 auto-cancels un-approved MCP
  tool calls headless).
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
  (run through the PR-1 hydration validators against the RESOLVED reviewer base
  template via `Templates.hydrate_review_binding/3`), `independence: strict | degraded`
  (default strict). Template-name-keyed — no per-stage override (the pinned non-goal).
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
- **Dispatch overlay**: `ReviewIndependence.apply_executor/3` between `Templates.get/1`
  and executor dispatch in `AgentRunner.run/6`.
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

## Config & telemetry

Config: `:executor_fake_outputs` + `:executor_vendor_runners` (both test-armed; the
scripted vendor double reads its script from its own key — no test keys in prod
runner_config). Telemetry counters `jido_claw.executor.total` (`kind`/`outcome`) and
`jido_claw.review_independence.total` (`:held`/`:degraded_pass`).

## Residuals & accepted risks

- Forge `Manager` per-runner caps (`shell: 20`, `codex`/`claude_code`: 10; module
  runners like `StaticFake` fall to `max_sessions: 50`) can `:runner_at_capacity` a
  wide parallel wave ⇒ a per-step error, not a crash.
- The codex runner's `gpt-5-codex` default model is rejected on ChatGPT-plan accounts
  (declare `model` in `executor_config`).
- Mid-run `.jido/config.yaml` edits are not re-checked (camus C2-7 class, the
  `verify_cmd` precedent); a deterministic violation loops boot recovery `:running`.
- Vendor identity is provider-prefix-approximate — a proxy provider like openrouter
  reads as its own vendor; the operator owns the knob.
- PR-4 (`needs_input` → gate case, session-sandbox knob, camus source reconciliation)
  deferred; no per-stage executor override (template-level only).

## Source map

- `lib/jido_claw/agent/templates.ex` — hydration validators,
  `hydrate_review_binding/3`
- `lib/jido_claw/skills/steps/agent_runner.ex` — dispatch on the binding, the
  independence overlay seam
- `lib/jido_claw/skills/steps/forge_executor.ex` — the forge arm: session lifecycle,
  unwinding reducer, terminal signal
- `lib/jido_claw/skills/steps/forge_executor/deposit.ex` — the deposit box,
  schema validation, last-valid-wins
- `lib/jido_claw/orchestration/review_independence.ex` — `check_route/2`,
  `apply_executor/3`, provider identity
- `lib/jido_claw/route_composer/route_composer.ex` — the launch fence call in `init/1`
