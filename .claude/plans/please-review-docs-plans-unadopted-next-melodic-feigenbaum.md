# Plan: Executor seam PR-3 — cross-vendor review configuration (next-ten #7, camus C1-1)

## Context

PR-1 (template `executor:` binding + `:fake`/`:shell`) and PR-2 (the Forge-backed vendor
path) shipped 2026-07-06. PR-3 is the seam's **first configuration**: cross-vendor review —
"no agent grades its own work" (camus C1-1's borrowable invariant). Today no production
template declares a vendor binding and nothing stops a reviewer from sharing the
implementer's vendor; camus enforces independence only structurally (hardcoded
Claude→Codex topology), which the agreed direction refuses to copy. PR-3 makes the pairing
operator-configurable and enforces the invariant at resolution.

Spec (docs/plans/unadopted-next-ten/README.md:673-680): the invariant enforced at
resolution — a review-lens stage whose resolved executor shares the implementer's vendor is
*held* (fail closed, mirroring `review.sh`'s unknown-backend refusal) unless the operator
opts into degraded independence in `.jido/config.yaml`; fresh session per re-review wave;
lift `review-prompt.md`'s adversarial persona + "correct but incomplete must NOT pass"
completeness clause for the review templates; outbound prompt assembly passes the redaction
root before egress to a second vendor.

**Done means**: `mix precommit` passes (run directly, never piped; exit code + counts
reported verbatim). Nothing committed — all changes stay unstaged. Greenfield — no
migration/compat concerns.

## Operator decisions (asked & answered 2026-07-07)

1. **Config shape**: new `review:` section in `.jido/config.yaml` — `executor:
   codex|claude_code`, optional `executor_config:` (validated by the PR-1 hydration
   validators), `independence: strict|degraded` (default strict). A template-name-keyed
   resolver (knob scoped to the `reviewer` template) is consulted by BOTH the composer at
   launch (invariant) and AgentRunner at dispatch. Absent section ⇒ byte-identical today.
2. **Hold point**: launch/recovery-time refusal — the run refuses loudly before any wave;
   mid-run config edits are a documented residual (camus C2-7 class, same as `verify_cmd`).
3. **Lane scope**: the executor knob binds only the `reviewer` template (the four
   code-route lens stages). The adversarial+completeness doctrine slice goes to all three
   reviewer-contract templates: `reviewer`, `sketch_reviewer`, `system_verifier`.
4. **Persona wording**: neutral adaptation (drop the "from a different vendor" claim so the
   slice is honest on same-vendor paths); deviation recorded in the PR-3 done-note.

## Source material (attribution: `mateodaza/camus @ 53da91b3, MIT`)

- Persona, `review-prompt.md:1-3`; completeness clause, `review-prompt.md:13-19` (adapt:
  priority 1 → severity `error`; "must not pass" → `overall: request_changes`).
- Refusal shape, `review.sh:26-58`: unknown backend fails CLOSED as an infra outcome —
  never a verdict, never a fallback. Camus has **no same-vendor runtime detection and no
  degraded mode** — both are jido-native additions (record in the done-note; full source
  reconciliation waits for PR-4 per PR-1/PR-2 precedent).
- Fresh session per round, `SKILL.md:110-111` + `codex_review.sh:207,431-433`; camus
  C3-1's intra-attempt resume probe is deliberately NOT ported.

## Design (verified against source 2026-07-07)

### New module: `JidoClaw.Orchestration.ReviewIndependence`

`lib/jido_claw/orchestration/review_independence.ex` — sibling of
`Orchestration.Verify.Config`, the direct precedent for a `.jido/config.yaml`-driven
resolve-then-refuse policy. **Placement checkpoint**: run `mix reach.check --arch` early;
if the `orchestration → route_composer` edge (Stage/Graph) creates a cycle, fall back to
`lib/jido_claw/route_composer/review_independence.ex` (CatalogValidator sibling) — a
rename, not a redesign; alternatively have the composer pass `Graph.producers/2` output
into `check_route` to drop the Graph edge.

Public API:

- `mode(project_dir) :: {:ok, :strict | :degraded} | {:error, reason}` — reads
  `review.independence`; absent → `:strict`; `"strict"`/`"degraded"` → as named; **any
  other value → loud `{:error, …}`** (never silently strict: a typo'd `degraded` must not
  produce a hold whose remedy says "set the thing you think you already set"; it also can
  never silently enable same-vendor review — the error refuses the run/step).
- `configured_reviewer_binding(project_dir) :: {:ok, :default | {kind, raw_config}} |
  {:error, reason}` — reads and shape-validates the `review:` section ONLY (no template
  knowledge): `{:ok, :default}` when the section/`executor` key is absent; `kind` parsed
  via a CLOSED parser (`"codex"` → `:codex`, `"claude_code"` → `:claude_code`, anything
  else → loud error — never `String.to_atom/1`); `raw_config` is the string-whitelisted,
  workspace-coerced `executor_config` map. Full PR-1 hydration validation happens at the
  call sites (`apply_executor`/`check_route`) via
  `Templates.hydrate_review_binding(kind, raw_config, base_template)` — they are where
  the resolved base template (override precedence decided) is known. The
  `{:ok, _} | {:error, _}` shape composes in `with`.
- `apply_executor(template, template_name, context) :: {:ok, template} | {:error, reason}`
  — the dispatch overlay: for `template_name == "reviewer"` with a configured knob,
  overlay `:executor`/`:executor_config`; every other template returns unchanged before
  any config read. Reads `context[:project_dir]` guarded
  (`is_binary(pd) and pd != ""` — the ToolContext present-nil trap, same pattern as
  `ForgeExecutor.resolve_workspace_dir/3`).
- `vendor_of(executor, tier) :: {:provider, String.t()} | :none | :indeterminate` —
  provider identity is EXPLICIT, not a closed atom set (so `ollama`/`openrouter`/etc. are
  determinate and non-colliding rather than falsely indeterminate):
  `{:forge, :codex}`→`{:provider, "openai"}`; `{:forge, :claude_code}`→
  `{:provider, "anthropic"}`; `{:forge, :shell | :fake | :custom}`→`:none` (non-LLM/test
  executors never match); `:in_process` → `{:provider, prefix}` from
  `Jido.AI.resolve_model(tier)`. `:indeterminate` on anything non-`"provider:model"`: a
  rescued `ArgumentError` (unknown alias) AND non-binary returns —
  `Jido.AI.resolve_model/1` returns tuples for tuple inputs and aliases can point at
  tuple/map/LLMDB specs; only a binary with a provider prefix resolves (document in the
  moduledoc, pin with a tuple-spec-alias test). Comparison is provider-identity equality.
- `check_route(catalog, project_dir) :: :ok | {:error, {:review_independence_held, details}}
  | {:error, config_reason}` — the invariant (below).

**Nil-safety (load-bearing — byte-identical guarantee)**: every config-reading entry point
(`mode/1`, `configured_reviewer_binding/1`, `apply_executor/3`, `check_route/2`) treats a
nil/blank/non-binary project dir as **"no config available"** — knob absent, mode
`:strict`, NO `JidoClaw.Config.load/1` call. `state.context` can be restored/fallback-empty
at launch (route_composer.ex:1127) and the verify precedent deliberately normalizes
blank/missing dirs to nil (`verify_project_dir/1` :1336-1343); `Config.load/1` does
`Path.join([project_dir, ".jido", "config.yaml"])` (config.ex:73), so a nil passed through
would crash the hook. Deliberately NOT a `File.cwd!()` fallback: cwd-dependent config would
break test determinism and the "absent section ⇒ byte-identical today" guarantee. The
invariant still evaluates template/override-resolved executors on such runs — only the
config knob read is skipped.

**Test-seam precedence (load-bearing)**: when `:agent_templates_override` (the documented
test-only seam) contains the template name, the knob does NOT overlay — the override map
is authoritative including its executor. Applies to both `apply_executor` and
`check_route`'s effective-executor resolution. This keeps an operator's local
`.jido/config.yaml` `review:` section from hijacking test determinism
(`composer_vendor_case_test` arms reviewer→`{:forge, :codex}` + a codex-only scripted
runner with `project_dir: File.cwd!()`; a local `review: executor: claude_code` would
otherwise dispatch an unscripted vendor).

### The invariant

Scope: **every review-lens worker-template stage** in the catalog (`is_binary(stage.lens)`
and `unit = {:worker_template, _}` — the `{:verify, _}` stage is deterministic, no vendor).
The knob stays reviewer-only, but the check is lens-scoped per the spec — a test/future
vendor binding on `sketch_reviewer`/`system_verifier` is caught too.

For each such stage:

1. **Activation is keyed on the executor KIND, not the vendor value**: the invariant is
   active iff the review stage's effective executor is `{:forge, k} when k in
   [:codex, :claude_code]` — else skip (default in-process routes and `{:forge, :fake}`
   test routes are untouched). When active, `rv = vendor_of(...)` is always a determinate
   `{:provider, _}` (from the tuple).
2. Producers: `stage.input.required ++ stage.input.optional` → `Graph.producers/2`
   (`graph.ex:49-57`; expose as public with `@doc`/`@spec` — do NOT reimplement, the
   ExSlop clone rule) → keep `{:worker_template, tname}` producer stages (for the code
   route: `diff`→`implementer`/coder, `fix`→`fixer`).
3. `pv = vendor_of(producer's effective executor, producer_tier)` where **`producer_tier`
   is the producer's OWN tier — `producer_stage.model || producer_template.model` — never
   the reviewer's** (the AR-9 stage tier can point a single stage at a different alias,
   e.g. a `model: :capable` producer resolving `openai:` while `:fast` is `ollama:`).
   **Collision** iff `pv == rv` (provider-identity equality) OR `pv == :indeterminate`
   (cannot prove independence — fail closed, the camus posture).
4. Any collision: `:strict` → `{:error, {:review_independence_held, %{scope: :catalog,
   violations: [...], remedy: …}}}`; `:degraded` → `:ok` + `Logger.warning` + telemetry
   (the honesty marker).

Whole-catalog view, deliberately: the check runs at launch where recovery cannot yet see
`live` routes (they rebuild in `do_rebuild`), and a globally-broken review knob surfacing
on the next launch of ANY route is a feature, not over-blocking. **Because that means a
talk/sketch/system request can be refused by a code-route pairing, the refusal must say
so**: `details.scope: :catalog` plus remedy wording like "catalog-level review-independence
config refusal — every route on this project is held until review: executor: points at a
different vendor than the implementing stages (or review: independence: degraded accepts
same-vendor review); this is not a failure of the requested route." Violation payload is
bounded (stage names + provider identities + the fixed remedy string — redaction posture:
no config values ride the durable terminal).

Telemetry: counter `jido_claw.review_independence.total` (tags `[:outcome]` —
`:held | :degraded_pass`), declared in `core/telemetry.ex`, with an
`emit_review_independence(outcome)` helper alongside the existing `emit_verify/1` /
`emit_executor/2` helpers (telemetry.ex:269-276), emitted from `check_route/2`. (Pre-loop,
so no `:composer` Trace event exists yet — the durable parent terminal + the `run_sync`
error envelope are the primary signals.)

### Launch/recovery hook

`RouteComposer.init/1`, immediately before `{:ok, state, {:continue, :rebuild}}`
(route_composer.ex:1201) — the single point both `start_composer/2` (front door, :684) and
`ensure_started/2 → start_supervised_composer` (recovery, :803) pass through, holding both
`state.catalog` and `state.context[:project_dir]` (in `@persisted_context_keys` :315-319,
so recovery restores it; `verify_project_dir/1` :1336-1343 is the read precedent).

```elixir
case ReviewIndependence.check_route(state.catalog, state.context[:project_dir]) do
  :ok -> {:ok, state, {:continue, :rebuild}}
  {:error, reason} -> {:stop, reason}
end
```

Verified failure path: front door matches `GenServer.start → {:error, reason}` →
`terminalize_parent(parent, {:composer_start_failed, reason}, …)` → `run_sync/1` surfaces
`{:error, {:start_failed, {:review_independence_held, details}}}`. The run refuses to
start loudly before any wave — never a verdict, mirroring `review.sh`. Boot recovery
leaves the parent `:running` for a later retry (identical to the existing invalid-catalog
residual — document). A config-shape error (`mode/1` / binding error) rides the same
refusal, distinct reason. `state.context[:project_dir]` may be nil here (restored/
fallback-empty context, route_composer.ex:1127) — `check_route/2` is nil-total per the
nil-safety rule above, so a project-dir-less launch is byte-identical to today.

### Dispatch integration

`AgentRunner.run/6` (agent_runner.ex:80-96): consult the resolver between `Templates.get/1`
and `dispatch_executor/7`:

```elixir
with {:ok, template} <- Templates.get(template_name),
     {:ok, template} <- ReviewIndependence.apply_executor(template, template_name, context) do
  dispatch_executor(template, template_name, task, step_name, context, catalog_stage_name, tier)
else
  {:error, reason} -> {:error, "Step #{template_name} setup failed: #{inspect(reason)}"}
end
```

The `{:forge, kind}` overlay flows into the existing `forge_step_opts/4` (P1a subagent
prompt for vendor kinds) and `ForgeExecutor` (reads `template.executor_config`). An
invalid/unreadable knob at dispatch → step error → a lens cohort rides Lane-B infra
(`:review_infra_failed`) — fail closed, never a silent fall-through to `:in_process`.
Pinned non-goal honored: template-name-keyed, never per-stage. Spawn/handoff surfaces
don't pass through `AgentRunner.run/6` — unaffected (state in AGENTS.md).

### Validator sharing (config → PR-1 validators)

`.jido/config.yaml` values arrive string-keyed; the PR-1 validators expect atom keys:

- `ReviewIndependence` owns the YAML boundary, strictly: a non-map `review:` section is a
  loud `{:error, …}`, **never treated as absent** (the Verify.Config non-map `verify:`
  refusal precedent); top-level `review:` keys are whitelisted to
  `~w(executor executor_config independence)` — an unknown key (e.g. the typo
  `executer:`) refuses loudly rather than silently doing nothing; **`executor_config`
  present without `executor` refuses loudly too** (almost certainly a typo — must not
  silently read as `:default`). The `executor` VALUE goes through the closed string
  parser (`"codex"`/`"claude_code"` only, loud error otherwise — no `String.to_atom/1`).
  Within `executor_config`, refuse any key outside the string whitelist
  `~w(workspace model max_turns timeout_ms thinking_effort)`, then **translate the
  allowed string keys to the closed atom keys via a literal map** (`"workspace"` →
  `:workspace`, `"model"` → `:model`, `"max_turns"` → `:max_turns`, `"timeout_ms"` →
  `:timeout_ms`, `"thinking_effort"` → `:thinking_effort`) — the PR-1 validators compare
  against the ATOM `@vendor_config_keys` (templates.ex:594), so string-keyed config
  handed to `hydrate_review_binding/3` untranslated would reject valid YAML like
  `model: …` as an unknown key. Also coerce the `workspace` VALUE
  `"repo"|"scratch"|"none"` → atom (unknown values left as-is so the PR-1 validator
  rejects them). Never `String.to_atom/1` on arbitrary input — both translations are
  closed literal maps.
- New public `Templates.hydrate_review_binding(kind, config, base_template)` for `kind in
  [:codex, :claude_code]` (anything else → `{:error, …}`): takes the ACTUAL resolved base
  template map (after override precedence is decided — the resolver passes the template
  it is about to overlay), so `refuse_forge_sandbox_combo!` (templates.ex:670-681) sees
  the real `:sandbox` value and genuinely refuses a future sandboxed reviewer template —
  a synthetic sandbox-less base would make that check vacuous. Calls the existing private
  `validate_executor_config!/2` + `normalize_executor_config!/3` (templates.ex:530-613 —
  `workspace: :repo` default, vendor-key validation), rescues the typed `ArgumentError`
  into `{:error, message}` (operator-facing refusal; `RescueWithoutReraise`
  disable-comment precedent: subagent_prompt.ex:104). Not a trivial forwarder (adds
  kind-gating + raise→tuple conversion); not a clone (calls the same private validators).
  Existing hydration pins (templates_test.exs:501-577) untouched.
- `JidoClaw.Config` (core/config.ex): add a `review/1` accessor (nil-safe, consistent
  with `verify_cmd/1`/`verify/1`).

## Implementation steps

### Step 1 — resolver + invariant module
- `lib/jido_claw/core/config.ex`: `review/1` accessor.
- `lib/jido_claw/agent/templates.ex`: public `hydrate_review_binding/3` (above — takes
  the resolved base template so the sandbox-combo check is real).
- `lib/jido_claw/route_composer/graph.ex`: make `producers/2` public (`@doc` + `@spec`).
- `lib/jido_claw/orchestration/review_independence.ex`: NEW — `mode/1`,
  `configured_reviewer_binding/1`, `apply_executor/3`, `vendor_of/2`, `check_route/2`,
  test-seam precedence rule, YAML-boundary parsing (closed executor parser, strict
  section shape).
- `lib/jido_claw/core/telemetry.ex`: declare `jido_claw.review_independence.total`
  counter + emitter.

### Step 2 — launch hook
- `lib/jido_claw/route_composer/route_composer.ex`: the `init/1` check before `:1201`'s
  `{:ok, state, {:continue, :rebuild}}`.

### Step 3 — dispatch overlay
- `lib/jido_claw/skills/steps/agent_runner.ex`: the `run/6` `with` chain (:80-96).

### Step 4 — doctrine slice `:reviewer_stance`
- NEW `priv/defaults/doctrine/reviewer_stance.md`, header:
  `<!-- Adapted from mateodaza/camus @ 53da91b3 (MIT) — review-prompt.md:1-3 (persona;
  vendor claim dropped) + :13-19 (completeness; severity/overall vocabulary adapted). -->`
  Body (near-verbatim, our vocabulary):

  ```
  ## Review stance

  You are an independent, adversarial code reviewer. Your job is to find what is
  wrong, not to praise what is right. You have no stake in the implementation and
  no reason to soften findings. Do not be agreeable.

  **Completeness.** If your task states what this change must accomplish, judge
  completeness, not only correctness: does the work actually DO what the task
  asked? A change that is clean and compiles but does NOT fulfill the stated task
  (e.g. it refactors but omits the required new behavior) is an incomplete
  implementation — report a finding with `severity` `error` naming what is
  missing, and set `overall` to `request_changes`. "Correct but incomplete" must
  NOT pass: never `approve` a change that leaves the stated task unfinished.
  ```

- `lib/jido_claw/doctrine.ex`: `@reviewer_stance_priv` via `Path.join` (never
  `Path.expand` — ExSlop ban), `@external_resource`, `@slices` entry; insert
  `:reviewer_stance` right after `:reviewer_min` in the three reviewer-contract lists
  (`"reviewer"` :188, `"sketch_reviewer"` :191, `"system_verifier"` :203 — before the
  output contract; order is cosmetic, tests anchor content). Keep the slice tight —
  stance + completeness judgment only, no schema re-teaching (the content-overlap smell
  the module comments flag).

### Step 5 — redaction root parity at prompt egress
- `lib/jido_claw/security/redaction/prompt_redaction.ex`: both clauses gain the ANSI
  pre-pass — `Patterns.redact(Ansi.strip(text))` (binary + per-message content). Blast
  radius: exactly the 4 vendor-runner egress sites (codex.ex:84,129;
  claude_code.ex:64,92) — all should strip. Runner egress stays the single enforcement
  point (no redundant assembly-site pass in `vendor_prompt/5`).
- `lib/jido_claw/skills/steps/forge_executor.ex`: truth-up the moduledoc claim (:78-83) —
  after this fix "passes the redaction root" is literally true.

### Step 6 — fresh-session pin + test-support extension
- `test/support/scripted_deposit_runner.ex`: add `:deposit_rounds` —
  `[[round1_outputs], [round2_outputs]]` consumed one list per `run_iteration` via a
  monotonic counter (`:counters` ref or Agent in the script map); flat `:deposits` form
  stays for existing tests.
- No-resume argv pins in `codex_test.exs` / `claude_code_test.exs` via
  `StubSandbox.last_run_args/1`: argv contains `--ephemeral` (codex) / `-p` (claude) and
  no `resume`/`--continue` token.

### Step 7 — docs + comment truth-ups
- `AGENTS.md` Executor Seam bullet: "PR-2 of 4 shipped" → "PR-3 of 4 shipped"; replace
  "No production template declares a vendor binding (PR-3's cross-vendor lane is the
  first declarer)" and "PR-3 (cross-vendor resolution) … deferred" with the shipped
  summary (the `review:` config section as the first production declarer — config, not a
  committed template; the launch-held invariant + degraded opt-in; `reviewer_stance`
  doctrine; PromptRedaction ANSI parity; test-seam precedence; residuals: mid-run config
  edits C2-7-class, boot-recovery loop on a deterministic violation). Keep "no per-stage
  executor override (template-level only)".
- `docs/plans/unadopted-next-ten/README.md` item 7: PR-3 DONE note (PR-1/PR-2 style) with
  deviations recorded: declarer-is-config-not-template, neutral persona adaptation, the
  invariant/degraded mode having no camus antecedent, loud-refusal on malformed
  `independence:`. Item-level Status + camus source reconciliation still wait for PR-4.
- `lib/jido_claw/forge/runners/claude_code.ex:46`: update the forward-looking
  "PR-3 … first production declarer" comment to the shipped truth.

## Test plan

- **`test/jido_claw/orchestration/review_independence_test.exs` (new)** — resolver:
  `mode/1` (strict/degraded/absent/typo → typo is a LOUD error); **config shape**: a
  non-map `review:` section → `{:error, …}` (never absent); an unknown top-level key
  (`executer: codex`) → `{:error, …}`; `executor_config` without `executor` →
  `{:error, …}`; `configured_reviewer_binding/1` (valid `"codex"`/`"claude_code"` strings
  parse via the closed parser; any other executor value — `"gpt"`, `"shell"`, a list —
  loud error; unknown config key, bad workspace — all `{:error, …}`);
  `vendor_of/2` (all executor kinds → `{:provider, _} | :none`; `:in_process` under
  stubbed `:jido_ai, :model_aliases` — put_env + on_exit restore — including an
  `ollama:` alias → `{:provider, "ollama"}` (determinate, NOT indeterminate);
  unresolvable alias → `:indeterminate`; an alias pointing at a TUPLE/non-binary model
  spec → `:indeterminate`); `check_route/2` fixtures: same-vendor held (assert
  `details.scope == :catalog`); cross-vendor ok (codex reviewer + `ollama:` in-process
  producer passes — provider-identity comparison); **producer-own tier**: a producer
  stage with `model: :capable` where `:capable → "openai:…"` and `:fast → "ollama:…"`
  collides with a codex reviewer (and the same catalog passes once the stage tier is
  removed) — proving the producer's tier, not the reviewer's, is resolved; degraded →
  ok + telemetry/warning; producer `:indeterminate` → held; in-process/fake reviewer →
  inactive; optional-input (fixer) collision → held; `:agent_templates_override`
  precedence over the knob; **nil-safety regression**: `check_route(catalog, nil)` and
  blank-string project_dir → no config read, byte-identical `:ok` on a default catalog
  (the `Config.load(nil)` Path.join crash guard). Config via the `Verify.Config`
  temp-dir `write_yaml!` pattern.
- **`templates_test.exs` (extend)** — `hydrate_review_binding/3` describe (valid →
  `{:ok, {{:forge, kind}, %{workspace: :repo}}}`; unknown key / bad workspace / bad kind
  → error messages; **a base template carrying a `:prototype`/`:docker` `:sandbox` →
  `{:error, …}`** — the combo check sees the real base, not a synthetic). Existing
  hydration pins stay green.
- **Launch-refusal integration (new)** — same-vendor config (temp project dir:
  `review: executor: codex` + `model: openai:…` aliases armed) with an in-process
  implementer → `run_sync` returns `{:error, {:start_failed,
  {:review_independence_held, _}}}` and the parent run is terminalized (assert the
  durable terminal). Degraded variant → composer starts and reaches a normal terminal.
- **Dispatch-time resolution (new)** — temp `.jido/config.yaml` with
  `review: executor: codex`, `:executor_vendor_runners` → ScriptedDepositRunner, run a
  `"reviewer"` step through `AgentRunner.run/6` with `context.project_dir` = temp dir:
  assert the scripted `:prompt`/`:config` captures fire (the static in-process reviewer
  template actually dispatched to the vendor); companion: invalid `executor_config` key
  → `{:error, "Step reviewer setup failed: …"}`. **Precedence at the live seam**: with
  `review: executor: claude_code` in the temp config AND `:agent_templates_override`
  binding `"reviewer"` to `{:forge, :codex}` (codex-only scripted runner armed), assert
  the CODEX runner fires — the override beats the knob at `AgentRunner.run/6`, not just
  in the resolver unit. **Nil-context**: a `"reviewer"` step whose context lacks
  `project_dir` (or carries present-nil) dispatches unchanged (`:in_process`), no config
  read.
- **Redaction (new + extend)** — `prompt_redaction_test.exs`: plain secret, ANSI-split
  secret (`"sk-ant-\e[0m…"`), message-list form, non-binary passthrough; runner-level:
  ANSI-split secret in the prompt → redacted placeholder in argv and `context.md`
  (`StubSandbox.file/2`).
- **Doctrine (extend)** — `doctrine_test.exs`: slice loop + `list/0` exact set gain
  `:reviewer_stance`; `for_template` anchors (`=~ "adversarial"`, `=~ "must NOT pass"`)
  for the three reviewer-contract templates; negative pins for `verifier`/`coder`. One
  targeted `subagent_prompt_test.exs` assertion that a built reviewer prompt carries the
  stance text.
- **Fresh-session two-round (new)** — composer eval mirroring `composer_vendor_case_test`:
  implementer + fixer on `{:forge, :fake}` fixtures, reviewer on scripted codex with
  `deposit_rounds` = [round 1 `request_changes` + one finding, round 2 `approve`]. Assert:
  terminal `:converged`; TWO `{:scripted_deposit_runner, :prompt, _}` captures (two fresh
  vendor sessions — the pin); fixer in `ran`.
- **Existing-test impact** — `composer_vendor_case_test` verified compatible unarmed: its
  coder is `{:forge, :fake}` (→ `:none`), reviewer `{:forge, :codex}` (→
  `{:provider, "openai"}`) — invariant active, no collision. Test-env aliases are
  `ollama:` (config.exs:161-166, no test override), so in-process producers resolve
  `{:provider, "ollama"}` — determinate, never colliding with openai/anthropic vendor
  CLIs.

## Precommit gates & risks

- Gates: `format`; `compile_check` (no new warnings); `credo --strict` + ExSlop
  (`PathExpandPriv` — Path.join; `RescueWithoutReraise` — one disable-comment on the
  typed rescue; no duplicate-clone — reuse `Graph.producers/2` and the private
  validators); `reach --arch/--smells` (the module-placement checkpoint above; no
  trivial-forwarder — `hydrate_review_binding` adds real behavior); dialyzer (exact
  return unions; no Ash.transact error channel involved); full suite (doctrine slice-list
  pin is the guaranteed tripwire if wiring is incomplete); `jido_md.check` /
  `system_prompt.check` do NOT trip (no new template — they compare name sets).
- Known full-suite rotating flakes (MemoryExport / collector recovery / :pg): re-run
  once, don't treat as regression (project memory).
- Residuals to document (AGENTS.md + done-note): mid-run `.jido/config.yaml` edits not
  re-checked (C2-7 class); boot recovery of a deterministic violation loops `:running`
  (existing invalid-catalog behavior); vendor identity is provider-prefix-approximate
  (a proxy provider like openrouter reads as its own vendor — operator owns the knob).

## Verification

1. Targeted: the new/extended test files above, run per-file.
2. Full gate: `mix precommit` run directly (never piped — house rule); report exact exit
   code and test counts verbatim; failures shown, never claimed green without output.
3. Offered, not unattended: an operator-assisted live smoke (the PR-2 habit that surfaced
   3 real fixes) — a real `review: executor:` against an authenticated vendor CLI, one
   composer run.

## Deliberate non-goals (scope fences)

- No per-STAGE executor override (pinned non-goal; template-name-keyed only).
- No `needs_input` gate case, no session-sandbox knob, no camus C1-1 source-entry
  Status reconciliation (all PR-4).
- camus `review-prompt.md`'s GROUND-every-deviation discipline clause: available, not in
  PR-3's named scope — not ported.
- No disposition/vocabulary changes: degraded independence is observable via telemetry +
  warning, not a new terminal.
- camus C3-1 resume-recovery machinery: explicitly not ported.
