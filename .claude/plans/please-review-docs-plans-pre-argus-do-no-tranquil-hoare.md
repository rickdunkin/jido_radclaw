# Plan: pre-argus Wave E — contract, surface & enrollment (items #16–#21)

## Context

Executes Wave E of [the pre-argus do-now queue](../../docs/plans/pre-argus-do-now/README.md):
six standalone items closing contract/surface/enrollment gaps — **#16**
served-MCP error-code registry (pad PD1-2), **#17** setup-as-doctor (pad
PD3-1), **#18** `mix jidoclaw.api_key` (myrlin MY1-4a + t3code scopes rider),
**#19** `mix jidoclaw.reproject_steps` (orca OR2-4a), **#20** non-interactive
env floor (orca OR3-1), **#21** headless-contract fragment +
`JIDOCLAW_HEADLESS=1` (chorus CH2-5). All argus-independent and mutually
independent except #20→#21 (one headless authority). Greenfield — no compat
shims. **Nothing is committed by the agent**; work lands unstaged, ending
with files-to-stage + suggested commit slicing. Completion bar:
`mise exec -- mix precommit` green.

**Operator decisions (interview 2026-07-12) + two review rounds (same day):**

1. **#20 floor scope**: Forge sites + the OsCmd seam (default env + verify's
   explicit OsCmd env sites); review round 1 extended delivery in-VM via one
   explicit `headless` session property; round 2 made the marker RESERVED
   (forced, not merely defaulted) and added the git-editor chain to the floor.
2. **#16 stability sentence**: server-level (`server_instructions/0` +
   bootstrap `error_contract`). Reviews: errors must be machine-readable on
   the wire via an **additive** second content item (legacy inspect text
   preserved → honest 1.3); registry membership enforced at the boundary,
   scoped to the PUBLIC server only (the runtime patch also serves the
   consolidator + deposit servers — those stay byte-identical); the exact
   `Jido.Exec` wrapper shape is pinned below; AST sweep = supplemental lint.
3. **#17**: DB-migrated gap is print-only. Reviews: doctor runs on a
   **minimal boot** (no `app.start` — pending migrations must not crash the
   diagnosis; check-only truly read-only); tagged result threaded through
   all four callers; `:unsupported` vs `:unavailable` split; model check =
   per-provider **retrieve-by-id** on canonical ids (first-page listing
   proves nothing); ollama probes derive base URL + bearer from effective
   config (ollama_cloud); credential durability modeled explicitly
   (`:persisted | :ambient | :session | :missing`), wizard reuses the
   persist flow; ymlr + atomic writes replace the hand serializer.
4. **#20 askpass**: `/bin/false` (BEAM cannot express set-but-empty env).
5. **#19 (reviews)**: lock → read → fold → reconcile in ONE transaction
   (snapshot-before-lock is a race); real contention test via the
   `Sandbox.mode(:auto)` pattern; `WorkflowStep` becomes **wholly
   projection-owned** (its user-facing create/start/complete actions and
   `config` are a dead competing write model — zero lib/ callers, verified)
   so phantom removal is safe by construction.
6. **#21 (review)**: executor vendor stages get a `report_blocked` deposit
   tool mapping to the existing PR-4 `needs_input` machinery; the fragment
   never promises routing it can't deliver. #21 is S, not XS.
7. **Round 3 (2026-07-12)**: `--check` routes BEFORE the wizard (never
   prompts/writes); the migration probe is genuinely read-only
   (`Ecto.Migrator.migrations/1` DDLs a cold DB — existence-check first);
   a shared pure dotenv resolver keeps minimal boot from losing `.env`
   credentials (ambient wins persisted) and doubles as the durability
   source; OpenRouter's retrieve path special-cased (`/api/v1/model/…`);
   the wire envelope is JsonSafe-normalized before JSON encoding
   (totality); `report_blocked` gets real runtime validation + ingestion
   redaction; `WorkflowStep`'s write surface goes genuinely private;
   reconcile skips value-equal rows (no `updated_at` churn); runner
   headless reads from spec-derived state only; checks/results get typed
   homes for credential `source` + `repair_outcomes`.

**Hard gates:**

- **No PORT maps** (docs/exploration/README.md rule — all six are
  posture/contract lifts; chorus + myrlin are AGPL patterns-only). Same
  class as Wave A's no-map items.
- **Step 0**: materialize this plan as `docs/plans/pre-argus-wave-e/README.md`
  (Wave A shape; `## Deviations` maintained as work proceeds).
- **Queue discipline** per item: dated Status lines on every source entry,
  falsified claims corrected, cross-refs updated same session.
- Run mix via `mise exec -- mix`. Gates bare (never piped), background, read
  the tail. Known-flaky singleton suites verified in ISOLATION.

**Build order**: #20 → #21 → #18 → #19 → #16 → #17.

---

## Item #20 — OR3-1: non-interactive subprocess env floor

### `lib/jido_claw/security/redaction/env.ex`

- `@noninteractive_floor` (string-keyed, rationale comment): `CI=true`,
  `DEBIAN_FRONTEND=noninteractive`, `GIT_TERMINAL_PROMPT=0`,
  `GIT_ASKPASS=/bin/false`, `SSH_ASKPASS=/bin/false`,
  `GIT_EDITOR=/bin/false`, `GIT_SEQUENCE_EDITOR=/bin/false`,
  `EDITOR=/bin/false`, `VISUAL=/bin/false`, `PAGER=cat`, `GIT_PAGER=cat`,
  `NPM_CONFIG_YES=true`, `PIP_NO_INPUT=1`, `PYTHONUNBUFFERED=1`, plus the
  reserved marker `JIDOCLAW_HEADLESS=1`. Deviations from orca's list
  recorded in moduledoc + Status: `/bin/false` askpass (BEAM removes
  empty-string env — probe-verified), git-editor chain +
  editor/pager neutralization (review-directed; `GIT_EDITOR` beats
  `core.editor`, `GIT_SEQUENCE_EDITOR` covers rebase — `git var`
  precedence).
- Public wrappers + `merge_floor/1` (normalize overrides to string keys,
  `Map.merge(@noninteractive_floor, normalized)` — caller wins — **then
  force the marker**: `Map.put("JIDOCLAW_HEADLESS", "1")`). The marker is
  the ONE documented carve-out from caller-wins: a non-interactive env is
  headless by definition, and env/prompt must never disagree (review F8).
  Shared `scrubbed_*_env` stay byte-identical (interactive paths:
  `shell/backend_host.ex:132`, `cli/commands.ex:1507`).

```elixir
@spec noninteractive_cmd_env(Enumerable.t()) :: [{String.t(), String.t() | nil}]
@spec noninteractive_port_env(Enumerable.t()) :: [{charlist(), charlist() | false}]
@spec noninteractive_floor() :: %{String.t() => String.t()}
```

- Precedence LAW (moduledoc + tests): **denylist > forced marker > caller
  override > floor > allowlist-survivor inheritance**. Scrub = leakage
  hygiene, floor = liveness hygiene; never interactive shells.

### Host-tier call-site flips

- `forge/runner/host_shell.ex` `:75, :116, :134` cmd + `:275` port;
  `forge/sandbox_init.ex` `:43, :63, :95, :110`;
  `forge/sandbox/docker.ex` host-side sbx `:108, :157, :352, :540` cmd +
  `:295` port; `core/os_cmd.ex:98` default env (+ check `:538` at build);
  `orchestration/verify/os_cmd_runner.ex:74`,
  `orchestration/verify/git.ex:511, :638`.
- NOT floored: shell BackendHost, `$EDITOR` spawn, git tools (System.cmd,
  non-OsCmd), MCP stdio children, setup probes, `cli/terminal.ex`.

### In-VM delivery — the `headless` session property

Forge session specs gain `headless :: boolean()`, **default `true`**
(#22's Lane A will set `false`). `Harness.inject_spec_env/2`: when
headless — merge caller `spec.env` over `Env.noninteractive_floor()`
(caller wins on floor keys) **then force `JIDOCLAW_HEADLESS=1`** (reserved
— review F8); always inject, riding `.forge_env` into docker in-VM children
(verified: sbx exec forwards no host env) and `sandbox.env` locally
(harmless double-cover). When `headless: false` — spec env passes through
un-floored with the marker **explicitly removed** (`Map.delete`). Verify
at build: spec normalization site; `RecoveredSpec` handling (ABSENT key
decodes headless=true — fail-safe for recovered sessions); no test pins
"no inject on empty spec env". The same property gates #21's fragment —
env, marker, and prompt share one authority.

### Tests

- `env_test.exs`: floor pairs present; caller override wins (`CI=false`);
  nil unsets floor keys; **marker forced even against an override /
  explicit nil**; denylist beats floor; PATH survives; port variant
  mirrors.
- `host_shell_test.exs`: real-child observation — exec
  `printf %s "$GIT_TERMINAL_PROMPT"` → `"0"`; `inject_env(%{"CI" => "off"})`
  then `$CI` → `"off"`.
- Git-editor pin: real child with a temp `HOME` whose `.gitconfig` sets
  blocking `core.editor`/`sequence.editor` values → an editor-requiring git
  command fails fast (GIT_EDITOR=/bin/false wins), never hangs.
- Done-when demo: ~15-line `:gen_tcp` one-off replying `401` +
  `WWW-Authenticate: Basic`; `git ls-remote http://127.0.0.1:<port>/x.git`
  via HostShell → fast nonzero exit, `=~ "terminal prompts disabled"`;
  skip-tag when git missing.
- Harness (with #21): headless spec → full floor + forced marker in
  StubSandbox env, including against a spec-env `JIDOCLAW_HEADLESS`
  override; `headless: false` → no floor, marker absent.

### Docs + reconciliation

- `forge-session-resume.md` (sources: env.ex, os_cmd.ex, harness.ex): floor
  + headless-property + reserved-marker passage; bump. `executor-seam.md`
  (docker.ex): in-VM floor via `.forge_env`. `verify-authority.md`: check
  sources for os_cmd_runner/git; bump if listed.
- Status: OR-FIRST-WAVE item 2; orca FWB OR3-1; pre-argus README §20
  (deviations: `/bin/false`, editor/pager + git-editor extension, OsCmd
  widening, in-VM via `headless`, reserved marker).

---

## Item #21 — CH2-5: headless contract — fragment, marker, and a real blocked channel

### New `lib/jido_claw/forge/runners/headless_contract.ex`

```elixir
@spec fragment() :: String.t()
@spec fresh_prompt(map(), keyword()) :: String.t() | nil
# Keyword.get(opts, :prompt, state.prompt); when state.headless — set at
# INIT from the spec-derived config, default true; NEVER read from
# iteration opts, which control only the prompt text (review r3) —
# prepend fragment <> "\n\n"; nil passes through unchanged.
```

Fragment (~7 lines, OUR words — AGPL: contract reimplemented, never Chorus
text), honest: (a) running unattended, `JIDOCLAW_HEADLESS=1` marks it — no
human at this terminal; (b) never invoke interactive/blocking prompts,
editors, pagers, or ask-the-user tools; never wait for terminal input;
(c) if blocked on a decision only a human can make: use the platform's
blocked-reporting tool when one is offered in this prompt; otherwise state
the blocking question clearly as your final output and stop — **never
guess or fabricate completion**. (Prose-only sessions' detection is Wave C
#11's item — recorded residual.)

### Fragment + marker wiring

- `claude_code.ex` `:207, :250-253` / `codex.ex` `:211, :247` (fresh-turn
  prompt selection) → `HeadlessContract.fresh_prompt(state, opts)`;
  continuations untouched (resumed conversations retain it). Runners learn
  `headless` at INIT from the #20 spec property (absent ⇒ true);
  iteration opts cannot flip it — env, marker, and fragment share the one
  spec authority.
- Marker: floor (host tier) + headless `inject_spec_env` (in-VM), both
  forced-reserved — no separate injection.

### The `report_blocked` deposit lane (review F1, round 1)

A blocked vendor CLI exits 0 → `Runner.done` → success today. Executor
vendor stages get the explicit terminal signal:

- `forge_executor/deposit_plug.ex` (+ `Deposit` scope store +
  `deposit_server.ex`): second tool `report_blocked` on the `jido_deposit`
  scoped server — advertised schema `%{question: string}` plus **genuine
  runtime validation** (review r3: the existing deposit tool's JSON-Schema
  map is advertisement-only — `submit_structured_output.ex:7`): a
  validating Zoi schema or total guard (binary, trimmed nonempty, ≤ 2KB)
  refuses invalid calls in-session (`isError` retry). The question passes
  `NeedsInput.redact_question/1` at INGESTION — before storage or any
  logging.
- `forge_executor.ex`: `allowed_mcp_tools` gains it (claude arm; codex MCP
  override equivalently — verify both at build); `deposit_instruction/1`
  gains one sentence naming it for human-blocking questions (the executor
  KNOWS the endpoint exists; the runner fragment stays generic);
  `map_vendor_result/5`: blocked report with NO valid typed-output deposit
  → the existing `:needs_input` path → `NeedsInput.raise_case` (durable
  `AgentCase`, step errors, answer claimed single-use next attempt — all
  PR-4 machinery). Valid deposit alongside → deposit wins; the report is
  logged REDACTED (same ingestion redaction — review r3).
- Consolidator/`run_loop` sessions (no deposit endpoint) keep
  state-and-stop prose; residual recorded (rides #11).

### Tests

- Vendor runner suites: fresh prompt starts with
  `HeadlessContract.fragment()` (reference the function, never paste);
  ABSENT on continuations; ABSENT when `headless: false`. Mechanical
  exact-argv updates (claude `:289-291, :501, :596, :640`; codex `:175,
  :532, :608, :756, :804`); continuation refute-pins survive.
- New `headless_contract_test.exs` (async: true): names the marker +
  never-fabricate clause; precedence; nil/headless-false passthrough.
- Executor: scripted vendor session calls `report_blocked` → step errors,
  `:needs_input` AgentCase carries the question; blocked + valid deposit →
  deposit wins; answer-claim round-trip reuses the PR-4 test pattern.
  DepositPlug wire test for the new tool: oversize/blank/non-string
  questions refused in-session; a secret-bearing question is stored/logged
  redacted (the `redact_question/1` pin).

### Docs + reconciliation

- `forge-session-resume.md`: fragment on fresh turns only, one assembly
  point, headless authority; bump. `executor-seam.md`: `report_blocked`
  joins the deposit surface (typed_output still ONLY via
  `submit_structured_output`; blocked is a distinct lane) + the
  needs_input mapping; bump.
- Status: CH-FIRST-WAVE item 2 (+ wording correction: vendor CLIs cannot
  emit `:blocked` themselves — the deposit tool is the shipped channel;
  prose-only sessions are the residual riding #11); chorus FWB CH2-5;
  pre-argus README §21 (XS→S growth, review-directed).

---

## Item #18 — MY1-4a: `mix jidoclaw.api_key` + scopes rider

### Resource edits

- `accounts/api_key.ex`: real `@moduledoc` (records OQ-2: scopes are schema
  room; enforcement with the first scoped surface); attribute
  `scopes {:array, :string}`, `allow_nil? false`, `public?`,
  `default ["read", "operate"]` (`"terminal:operate"` NEVER in the
  default); `create` gains `accept([:scopes, :expires_at])` plus a
  **normalization change on the action** (trim, drop blanks, dedupe
  order-preserving — review F14: canonical for EVERY caller incl.
  AshAdmin, not just the task); `define(:by_id, action: :read, get_by:
  [:id])` on the primary read (the `WorkflowRun.by_id` idiom — no new
  action).
- `accounts/user.ex`: `define(:get_by_email, args: [:email])` for the
  existing read (user.ex is in NO docs-page sources — verified; re-check).
- **Migration**: `mise exec -- mix ash.codegen add_api_key_scopes`; the
  `test:` alias's `ash.setup --quiet` applies it.

### New `lib/mix/tasks/jidoclaw.api_key.ex`

One task, argv head-dispatch, exporter conventions (`use Mix.Task`,
`@shortdoc`, `## Usage` moduledoc, OptionParser `scope: :keep`,
`Mix.Task.run("app.start")`, `Mix.shell()`, `Mix.raise` on bad usage):

- `mint --email EMAIL [--scope S]... [--expires-in DAYS]` —
  `User.get_by_email(email, authorize?: false)`; `{:ok, nil}` → `Mix.raise`
  naming the user COUNT (never auto-create); `--expires-in` must be a
  positive integer. `ApiKey.create(user.id, attrs, authorize?: false)`;
  print plaintext from `Ash.Resource.get_metadata(record,
  :plaintext_api_key)` EXACTLY once + "store it now"; never `inspect` the
  record; print id/scopes/expires_at.
- `list` — `ApiKey.read(authorize?: false, load: [:user, :valid])`, one
  row-formatting helper.
- `revoke --id UUID` — `ApiKey.by_id(id, authorize?: false)` →
  `ApiKey.revoke(key, authorize?: false)`; unknown id raises.

### Tests

- New `test/mix/tasks/jidoclaw_api_key_test.exs` (async: false; shared
  sandbox owner; `Mix.shell(Mix.Shell.Process)` + restore in on_exit;
  re-enable between runs): default scopes exactly `["read","operate"]`, no
  `terminal:operate`; `--scope` repeatable verbatim (explicit grant
  allowed); blank/dup scopes normalized **at the resource** (assert via a
  direct `ApiKey.create` too); `--expires-in 30` ≈ now+30d, `0`/`-1`
  raises; unknown email raises with count; plaintext once with `jidoclaw_`
  prefix; list; revoke; bogus id raises.
- New `test/jido_claw/accounts/api_key_test.exs` (async: true): defaults;
  accept round-trip; normalization change; regression —
  `ApiKeyAuth.authenticate_api_key/1` still succeeds with a scoped key.
- Dialyzer: match both `{:ok, %User{}}` and `{:ok, nil}` arms.

### Docs + reconciliation

- No docs/system sources list api_key.ex; ApiKey absent from GraphQL — no
  SDL change. Status: myrlin FWB MY1-4 (**PARTIAL — the (a) slice**) +
  dated corrections to the stale claims ("headless client cannot open the
  WS with a key" — argus P4's ArgusSocket; "zero callers / no mix tasks");
  t3code FWB TC1-2 Status + **OQ-2 decision recorded** + gap text
  corrected; myrlin OQ-3 note; pre-argus README §18.

---

## Item #19 — OR2-4a: `mix jidoclaw.reproject_steps` (lock-fenced, authoritative)

### `WorkflowStep` becomes wholly projection-owned (review F2, round 2)

Verified: NO lib/ caller uses the user-facing `:create` (pending step +
`config`) or the `:start`/`:complete`-class updates — a dead competing
write model. Greenfield: remove those actions and the writer-less `config`
attribute (+ its migration, `mise exec -- mix ash.codegen
drop_workflow_step_config`); keep reads + `record_*` + a reprojector-scoped
destroy + identity — and make that write surface **genuinely private
(review r3)**: drop ALL write code-interface defines (the current block
exposes the `record_*` writers publicly, workflow_step.ex:26), mark the
write actions non-public / policy-pin them to system actors (exact Ash 3
mechanism verified at build — action-level visibility if available, else
an explicit write policy), and replace the default public destroy with the
explicit private one. A test asserts no public write interface remains.
**Build-time verify**: grep + LSP references for `:create` /
`.config` readers in lib/ AND test/ (tests seeding via `:create` re-seed
via events); `visibility.step_view` must not expose config. If a real
reader surfaces, fall back to the recorded alternative — no eventless-row
deletion + provenance note — instead of ownership conversion. With
ownership total, every legitimate row is event-derived and phantom
removal is safe by construction. Moduledoc states projection-ownership.

### Fold + reconcile — new `lib/jido_claw/orchestration/workflow_event/step_projection.ex`

Move VERBATIM from `changes/allocate.ex` (kind list, `step_action/1`,
`step_name/1`+fallback, `step_attrs/3`, `kind_attrs/2`,
`parse_sequence/1`, validity helpers, the bare write) so live projection
and replay share one fold. Allocate keeps the raw-payload stash,
SAVEPOINT bracketing + `reach:disable-next-line bare_rescue` + failure
logging — **live path byte-identical** (existing
`workflow_step_projection_test.exs` untouched = regression proof).

```elixir
@spec projection_kinds() :: [atom()]
@spec derive(WorkflowEvent.t(), map()) :: {:ok, atom(), map()} | :skip     # live path, unchanged semantics
@spec upsert(atom(), map(), keyword()) :: {:ok, WorkflowStep.t()} | {:error, term()}
@spec reproject(WorkflowRun.t() | binary(), keyword()) ::                  # the whole replay, ONE transaction
        {:ok, %{upserted: n, deleted: n, unchanged: n, skipped: n}} | {:error, term()}
```

**`reproject/2` (review F1, round 2 — no snapshot-before-lock): one
transaction doing lock → read → fold → reconcile**: take the parent run's
FOR-UPDATE lock (Allocate's `lock_run/3` shape,
`Query.lock("FOR UPDATE")`), THEN read `WorkflowEvent.for_run` (seq asc),
fold from empty into complete desired rows (every deterministic column
explicit, nils included — a started-less terminal yields
`started_at: nil, output: nil` rather than inheriting corruption), then
reconcile: rows whose name ∉ desired set → destroyed (phantom removal,
safe under total ownership); each desired row is COMPARED against the
locked existing row on the deterministic field set FIRST and value-equal
rows are **skipped entirely** (no Ash write, no `updated_at` churn, honest
`unchanged` counts — review r3); only differing/missing rows go through a
new internal `:reproject` upsert action on `WorkflowStep` (existing
identity; accepts the whole deterministic column set including explicit
nils; non-public like its siblings — live `record_*` keep partial
semantics). NO status writes (structural). A concurrent append blocks on
the same lock until the replay commits — stale-overwrite impossible.

### New `lib/mix/tasks/jidoclaw.reproject_steps.ex`

`mix jidoclaw.reproject_steps RUN_ID --tenant TENANT`: `Actor.system(tenant)`;
tenant-scoped `WorkflowRun.by_id` (NEVER `by_id_global`; missing/cross-tenant
→ `Mix.raise "workflow run not found for tenant …"`); thin call to
`StepProjection.reproject/2`; print upserted/deleted/unchanged/skipped;
failures print loudly then `Mix.raise` (idempotent, rerunnable). No
auto-trigger, no `--all-runs`.

### Tests — new `test/mix/tasks/jidoclaw_reproject_steps_test.exs`

`JidoClaw.TenantCase, async: false`; seed via direct `WorkflowLog.append`
(deterministic secret-free payloads → redaction identity → exactness
provable); Mix.Shell.Process hygiene. Cases: corrupt a row (`Repo.query!`
garbaging status/output/started_at) → deterministic field set (`name,
step_type, sequence, status, deadline, depends_on, started_at,
completed_at, output, error`) equals pre-corruption snapshot, same id;
**started-less terminal** (log = [step_failed] + corrupted stale
output/started_at → nils restored); **phantom row** (hand-INSERT eventless
row → deleted); hand-DELETE → recreated field-equal, fresh id/inserted_at
asserted; healthy run → value-identical, count unchanged, **`updated_at`
untouched** (equal rows are skipped, not rewritten); retry-shaped log
converges; `step_retried` ignored; tenant mismatch raises; no public write
interface on `WorkflowStep` (the privacy pin). **Contention test** (review F1): the
`Sandbox.mode(:auto)` pattern (`lock_owner_test.exs:23` precedent, real
cross-connection visibility, manual cleanup in on_exit): connection A
holds FOR UPDATE on the run row → `reproject` in task B blocks; A appends
a newer terminal event + releases; B's result reflects the NEWER event
(fold ran after the lock) — the stale-overwrite pin.

### Docs + reconciliation

- No docs/system page lists allocate.ex/workflow_step.ex — moduledoc
  rework IS the doc deliverable: cite the command; persisted-log fidelity
  (replay reads redacted+capped payloads vs the live raw stash — identical
  whenever nothing was redactable); projection ownership.
- Status: OR-FIRST-WAVE item 1 (honesty refinements: byte-equal =
  deterministic set modulo id/inserted_at/updated_at; review upgrades —
  in-transaction lock, ownership conversion, phantom delete, full-row
  reconcile); orca FWB OR2-4; pre-argus README §19.

---

## Item #16 — PD1-2: boundary error-code registry (wire-real, boundary-enforced)

### New `lib/jido_claw/core/mcp_server/error_codes.ex`

`JidoClaw.MCPServer.ErrorCodes` beside SurfaceVersion (served-MCP scope by
construction; interior stays open). Families as **code → one-line-doc
maps** (a code cannot join without its doc):

```elixir
@type family :: :pipeline | :normalization | :lua | :sandbox | :host_exec | :scope | :lookup | :workflow
@spec families() :: %{family() => %{atom() => String.t()}}
@spec all() :: MapSet.t(atom())
@spec member?(atom()) :: boolean()
@spec family(atom()) :: {:ok, family()} | :error
@spec stability_sentence() :: String.t()
```

Inventory ≈ 45 codes (spec said ~25 — pre-sweep estimate, flag in Status):
pipeline (approval trio + doom_loop; cites LoopGuard `@skip_codes`),
normalization (`Tools.Error` struct/legacy codes incl. `:tool_error`), lua
(11 + unknown_binding), sandbox (4), host_exec (the two non-literal
run_command codes), scope, lookup (incl. NEW `unknown_skill`, NEWLY-TYPED
glob codes, agent_view session codes), workflow (replay_refused,
event_feed_unavailable). Details-level sub-codes excluded (documented).
Moduledoc carries the **#4 kinship paragraph** (exit tiers 0–6 classify
via `RunFailure`; one family, two enforcement points) — NO run_command.ex
edit (ambiguity-clarify.md sources).

### The wire boundary (reviews F2/F3 r1, F3/F9/F12 r2)

Today `Jido.MCP.Server.Runtime.handle_tool_call/5` error arms emit
`Response.error(inspect(reason))`.

- New patch `lib/jido_claw/core/jido_mcp_runtime_patch.ex` (registered in
  `dependency_patches.ex`, documented like the anubis patch in AGENTS.md
  known-limitations + the docs page; drop-when-upstream note): redefines
  the runtime with ONLY the two `{:error, …}` arms changed to
  `ErrorBoundary.serialize(reason, server_module)` — the 5-arity already
  carries `server_module`.
- **Scoped, not global (F9)**: the runtime also serves the memory
  consolidator's MCP server and the executor's DepositServer. The boundary
  matches on `JidoClaw.MCPServer` → structured + registry-enforced; every
  OTHER server → the byte-identical legacy `Response.error(inspect/1)`
  arm. Tested for all three surfaces.
- **Additive wire shape (F12)**: `content[0]` keeps the legacy inspect
  text BYTE-IDENTICAL; a SECOND text content item carries the canonical
  JSON `{"code","message","details"}` (the LoopGuard appended-text-item
  precedent — no repurposing of `structuredContent`, which is owned by
  outputSchema). Genuinely additive → **1.3 MINOR is honest**; the
  bootstrap `error_contract` documents where the JSON lives.
- **Exact unwrap (F3)**: pinned shape — for our envelope `%{code, message,
  details}`, `Jido.Exec`'s `extract_error_fields` (binary-message clause)
  moves `message` onto the exception and sets `exception.details =
  %{code: code, details: inner}` (exec.ex `extract_error_fields` +
  `Error.execution_error(message, details)`). The boundary reconstructs
  `{details.code, exception.message, details.details}`; raw envelope maps
  and non-envelope reasons (→ `{"code":"tool_error","message":
  inspect-text,"details":{}}`) handled totally. **The entire canonical
  envelope is normalized through the total `JsonSafe.encode/1` BEFORE
  `Jason.encode!`** (review r3): inner details can carry tuples, PIDs,
  structs, refs, non-string keys — a raise here would convert the tool
  error into a JSON-RPC execution failure. Registry membership
  enforced on the reconstructed code — unknown/dynamic codes (e.g.
  network_share forwarding `:solution_not_found`) → fallback `:tool_error`
  + `details.unregistered_code` + a log line.
- **Wire test asserts EXACTNESS, not membership** (F3): drive the patched
  handler end-to-end — (a) a failing served tool → content[1] JSON decodes
  to the EXACT original code + message + inner details; (b) foreign atom →
  fallback + `unregistered_code` carrying the original; (c) content[0]
  bytes unchanged vs the unpatched arm; (d) consolidator + deposit servers
  byte-identical legacy behavior; (e) success responses untouched;
  (f) non-JSON-safe nested details (tuples, pids, non-string keys) still
  produce a decodable envelope.

### Hint fields + producers

- `Tools.Error`: `hint_available(names, details \\ %{})` (list, cap 25 +
  `available_truncated`), `hint_expected(expected, got, details \\ %{})`
  (2KB truncation reuse); an `Error.envelope/3` constructor if reach
  objects to new envelope literals.
- `run_skill.ex`: unknown skill → typed `:unknown_skill` +
  `hint_available(Skills.list())`. `list_directory.ex`: glob failures →
  typed codes + `hint_expected(...)`. `lua_docs.ex`: **untouched** (its
  `available` string is an existing served shape; unify at next MAJOR —
  residual noted).

### Version + server-level sentence

- `mcp_server.ex`: `server_instructions/0` → stability sentence.
  `resources/bootstrap.ex`: additive `"error_contract"` (sentence +
  family→codes map + "canonical JSON rides the final error content item").
- `surface_version.ex`: `@current "1.3"` + changelog (additive: second
  error content item, hints, new lookup codes, instructions, bootstrap
  field). Regen golden fixture (version field only); run `jido_md.check`,
  regenerate `.jido/JIDO.md` if it pins the version.

### The sweep test — supplemental lint

`error_codes_sweep_test.exs` (async: false, `Code.ensure_loaded` setup):
sources = `published_tool_modules()` compile-info paths + pinned
envelope-producer files (tool_approval, loop_guard, lua/runner,
forge_bridge, error.ex). Quoted-AST walker pruning pattern positions
(`->` LHS, def heads/guards, `<-` LHS, attributes); collects literal
`code:`-keyed envelope maps, first-arg atoms of local `envelope(...)`
calls, literal `{:error, atom}` tuples; non-literal `code:` values must
be declared in `@indirect_producers`; view-layer relays in
`@relayed_codes` (file:line). Assertions: collected ∪ declared ⊆ `all()`;
`all()` ⊆ collected ∪ declared ∪ normalization-family; collector
self-tests (map-path, envelope-call, bare-tuple each MUST collect).
Framed as **lint for the same-diff-docs discipline — closure PROOF is the
boundary fallback + wire test**. Plus `error_codes_test.exs` units,
hint-helper rows in `tools_wire_format_test.exs`, producer tests.

### Docs + reconciliation

- `mcp-server-surface.md`: closed-error-contract invariant (registry,
  boundary fallback, dual-content wire shape, scoping to the public
  server, hints); the runtime patch documented beside the anubis patch;
  `sources:` += error_codes.ex, error_boundary.ex, the patch, sweep test;
  `verified:` bump. AGENTS.md known-limitations gains the patch line
  (same commit).
- Status: PD-FIRST-WAVE item 2; pad FWB PD1-2 + **OQ-2 re-dated**
  (boundary enforcement beats static enumeration; lean single registry /
  per-surface subsets); pre-argus README §16 (deviations: server-level
  sentence, ~45 not ~25, wire adapter, dual-content shape) + **correct
  §16's stale "#4 consumes this registry" sentence + §4 Status addendum**.

---

## Item #17 — PD3-1: setup as a state-derived doctor

### Minimal doctor boot (review F4 — no `app.start`)

Both `mix jidoclaw --setup [--check]` and escript `--setup` currently boot
the FULL app (`Mix.Task.run("app.start")` / `ensure_all_started(:jido_claw)`)
— recovery barriers, initializers, gateway/Discord; pending migrations can
crash boot before the doctor speaks, and check-only isn't read-only.
Rework both arms: `app.config`-level load + targeted
`Application.ensure_all_started` (`:inets`, `:ssl` for probes; yaml apps
for config reads — pin the exact set at build) — the JidoClaw supervision
tree NEVER starts. `:first_run_setup_pending` stays for the REPL flow; on
the no-boot mix paths it's moot (note at build). The wizard path on these
arms uses the same minimal boot (nothing in it needs the app tree).

**Read-only DB probe (review r3)**: `Ecto.Migrator.migrations/1` calls
`migrated_versions`, which CREATES `schema_migrations` on a cold DB —
DDL during `--check`. `Doctor.migration_status(repo)` therefore probes in
order: a read-only existence check (`to_regclass('schema_migrations')`
class query) — absent → report ALL local migrations pending (file count
from the migrations path); present →
`Ecto.Migrator.migrations(repo, paths, skip_table_creation: true)`
(exact option verified at build), under `with_repo` (temporary repo
start; tolerates already-started, so the same probe works from the live
REPL).

**Credentials must survive minimal boot (review r3)**: full boot loads
dotenv into System env (application.ex:57) before provider resolution —
skipping it would misdiagnose a healthy persisted-only setup. New shared
pure resolver `JidoClaw.Config.EnvResolver` (reusing the existing dotenv
parse logic — locate at build):
`resolve(project_dir, names) :: %{name => %{value: String.t() | nil,
source: :ambient | :persisted | :missing}}` — snapshots ambient env,
parses `.env` WITHOUT `System.put_env` (derive stays read-only), **ambient
wins persisted**. The provider-key + voyage checks read it, and
`ProviderProbe` receives the credential VALUE explicitly — it never reads
System env internally. The resolver is also the credential-durability
source (`source` rides the check).

### New `lib/jido_claw/cli/setup/doctor.ex` — pure derivation

```elixir
@type step :: :config | :provider_key | :voyage_key | :model | :database
@type status :: :ok | :gap | :error | :unsupported | :unavailable
@type source :: :persisted | :ambient | :session | :missing | nil   # credential steps only
@type check :: %{step: step(), status: status(), detail: String.t(), source: source()}
@spec derive(String.t(), keyword()) :: {map(), [check()]}   # probes injected via opts
@spec repairs([check()]) :: [step()]                        # :gap/:error; :database excluded (print-only)
@spec healthy?([check()]) :: boolean()                      # :ok/:unsupported pass; :unavailable FAILS
@spec print([check()]) :: :ok
```

`:unsupported` = expected-absent capability (healthy); `:unavailable` =
indeterminate (fails `--check`). Checks: `:config` — dispatch wizard-vs-
doctor on **`File.exists?`** of `.jido/config.yaml` (review F7:
`read_user_config` maps missing AND empty to `{:ok, %{}}`), then
`read_user_config` for parse/provider-presence (broken YAML = `:error`,
provider/model skipped); `:provider_key` + `:model` — ONE
`ProviderProbe.probe` call feeds both, credential from `EnvResolver`;
`:voyage_key` — `EnvResolver` presence + `source`; `:database` —
`migration_status/1` (N pending → `:gap` "run `mix ecto.migrate`";
unreadable → `:unavailable`).

### New `JidoClaw.Config.ProviderProbe` (reviews F10 r1; F5/F6/F7 r2)

```elixir
@spec probe(map(), keyword()) :: %{reachable: boolean(), auth: :ok | :invalid | :unknown,
                                    model: :present | :absent | :unknown | :unsupported,
                                    detail: String.t()}
```

- **Retrieve-by-id, not first-page listing (F6)**: the model check GETs the
  provider's model-retrieve endpoint for the CONFIGURED model — anthropic
  `GET /v1/models/{id}` (`x-api-key` + `anthropic-version`), openai/groq/
  xai `GET /v1/models/{id}` (Bearer), openrouter
  **`GET /api/v1/model/{author}/{slug}`** (singular `model` — review r3;
  its ids always carry the author/slug slash, so the generic path would
  falsely report valid models absent; tested with aliases and `:free`
  variants), google `GET /v1beta/models/{name}` with **`x-goog-api-key`
  header** (never query-string creds). 200 → auth ok + `:present`; 404 →
  auth ok +
  `:absent`; 401/403 → `:invalid`; other statuses → `:unknown` (detail
  carries the status — never conflated with unreachable); transport →
  `reachable: false`. One request answers BOTH checks; an incomplete
  search can only yield `:unknown`/`:unavailable`, never a repairable
  `:gap`.
- **Canonical id contract (F5)**: config stores `provider:model`
  (`openai:gpt-4.1`); the probe derives the provider-native id (strip our
  prefix; google's `models/…` resource naming normalized) and reports in
  canonical form. Per-provider unit rows.
- **Effective-config derivation (F7)**: base URL + auth come from the same
  config resolution the runtime uses — ollama vs ollama_cloud
  (`config.ex:307/:323`: base_url override + bearer when configured;
  `/api/tags` membership for the model, tags listed once for the gap
  detail). Total unknown-provider fallback clause (no function-clause
  crash) → `:unavailable` detail.
- HTTP via an injectable request fun (default `:httpc`) — mapping
  unit-tested on canned `{status, body}` tuples for EVERY provider clause.
  The credential arrives explicitly (from `EnvResolver`); the probe never
  reads System env.
- `Config.check_provider/1` becomes a thin wrapper deriving today's
  `:ok | {:error, :unauthorized | :unreachable}`; its two callers (REPL
  banner, wizard `test_connection`) unchanged.

### `cli/setup.ex` rework

- `run/1` → `run(project_dir, opts \\ [])` returning a **tagged result**:
  `{:ok, %{config: map(), checks: [Doctor.check()], disposition:
  :wizard_completed | :healthy | :repaired | :gaps_remaining |
  :check_only, repair_outcomes: %{Doctor.step() => :persisted |
  :session_only | :declined}}}` — the typed home (review r3) for repair
  state the re-derive cannot honestly recompute. **All four callers
  updated + tested (review F10 r2)**: `repl.ex` `ensure_config`
  (first-run unwrap), `commands.ex` `/setup` + `/config` (unwrap →
  `Config.model/1`), the mix task, `cli/main.ex`.
- Dispatch — **`check_only` routes FIRST (review r3)**: derive + print +
  report only — a missing config file is a `:config` gap (provider/model
  skipped), NEVER a wizard launch; zero prompts, zero writes, zero env
  mutations. Otherwise: config file ABSENT → today's full wizard
  (`:wizard_completed`); present → doctor: derive → print → repair
  `repairs/1` only, re-derive, closing summary.
- **Credential durability modeled, not inferred (F11)**: the provider-key
  and voyage checks carry `source: :persisted` (var present in `.env`) `|
  :ambient` (process env at start) `| :session | :missing`. Repairs prompt
  for the key then **offer persistence via the existing 0600 atomic
  `persist_env_var/3`**: accept → `repair_outcomes[step] = :persisted`;
  decline → `System.put_env` + `repair_outcomes[step] = :session_only`
  (carried in the RESULT — the re-probe would now succeed and lie) →
  disposition `:gaps_remaining`, summary flags it, standalone exits 1.
  The first-run wizard's `configure_api_key` **reuses the same
  persist-offer flow** (its session-only posture goes away — deviation
  recorded). Voyage keeps prompt+persist; **no `System.halt(1)` in doctor
  mode** (declined ⇒ unresolved + BootGuard consequence printed; the
  true-first-run wizard keeps its halt).
- Other repairs: `:model` — `pick_model` + merged write; `:config`
  (present-but-no-provider) — provider-subset interview + merged write;
  `:database` — print-only.
- **YAML writing (F9 r1)**: promote `{:ymlr, "~> 5.1"}` to a direct dep
  (already in mix.lock transitively); `write_config/2` + new
  `write_config_merged/2` emit via `Ymlr.document!/1`, written atomically
  (tmp + rename, the `persist_env_var` pattern); DELETE the hand-rolled
  `map_to_yaml/2`. Merged write: `read_user_config` → `Config.deep_merge`
  → encode → atomic write; **refuses** when the existing file is
  unparseable. Round-trip tests cover YAML-hostile strings: `"true"`,
  `"001"`, `"2026-07-12"`, leading whitespace, quotes, backslashes,
  multiline, `:`/`#`, list-of-maps.

### `--check` plumbing + exits

`mix jidoclaw --setup --check`: exit 0 iff `Doctor.healthy?/1`, else 1;
plain `--setup`: 0 unless `:gaps_remaining`. Escript twin (`--check` must
NOT set `:force_setup`). REPL `/setup check` + `/setup --check` heads
above `"/setup"` (never exits); `/config` alias unchanged. Moduledocs
document flags + exits (they ARE the help). Exit mapping pinned by testing
the disposition→code function (System.halt untestable directly).

### Tests

- `doctor_test.exs` (async: true; tmp dirs; injected probes — never live
  network): healthy → all `:ok`/`:unsupported`, `repairs == []`,
  `healthy?`; single-gap rows; broken YAML → `:config` `:error` + skips;
  pending migrations → gap NOT in repairs; `:unavailable` fails
  `healthy?`; derive performs zero writes/env mutations; **no-config
  check-only regression (review r3)**: fresh tmp dir + `check_only` →
  `:config` gap reported, zero prompts consumed, directory bytes
  untouched — the wizard never launches.
- **Cold-DB probe test (review r3, async: false)**: `storage_up` a scratch
  database, point a dynamic repo at it, run `migration_status/1` → all
  local migrations reported pending AND `schema_migrations` REMAINS
  ABSENT (`to_regclass` still null — the probe performed no DDL);
  `storage_down` in on_exit. The injected-probe unit rows are not
  sufficient for this pin.
- `env_resolver_test.exs` (async: true; tmp `.env` files): persisted-only
  key found with `source: :persisted`; ambient WINS persisted; missing;
  no `System.put_env` side effects.
- `provider_probe_test.exs` (async: true): per-provider request shapes
  (anthropic x-api-key, google x-goog-api-key + `models/` normalization,
  Bearer for openai-compat, **openrouter `/api/v1/model/{author}/{slug}`
  incl. alias + `:free` variant ids**, ollama_cloud bearer + base_url);
  canned-status table incl. 404→`:absent`, 405→`:unknown` (never
  unreachable); unknown provider total fallback; canonical-id round-trips
  for every provider; explicit-credential arg (no System env reads).
- `setup_test.exs` additions: merged write preserves operator keys
  (verify_cmd list, mcp_servers list-of-maps, nested providers — semantic
  equality via YamlElixir); refuses on unparseable; ymlr round-trip table;
  atomicity (tmp cleaned on rename failure).
- Caller-threading tests (F10): `/setup`/`/config`/first-run unwrap the
  tagged result (commands/repl level where feasible); disposition→exit
  mapping rows incl. session-only-repair ⇒ `:gaps_remaining`.
- Interactive prompt bodies stay untested (status quo); `migration_status`
  exercised only via the injected probe (sandbox constraint).

### Docs + reconciliation

- No docs/system page covers cli/setup.ex — none created. mix.exs dep
  promotion noted in the commit body.
- Status: PD-FIRST-WAVE item 3 (deviations: DB print-only, minimal-boot
  doctor, voyage-halt narrowing, `:unsupported`/`:unavailable` split,
  ymlr swap, retrieve-by-id probes, durability modeling, wizard
  persist-offer — review-directed); pad FWB PD3-1; pre-argus README §17;
  XA2-3 entry cross-ref re-date (manual surface landed; scheduled canary —
  pre-argus #6 — separately tracked; note #6 should consume
  `ProviderProbe`).

---

## Verification

Per item, immediately after building: run its test files (`mise exec --
mix test test/...`) plus named regression proofs (#19:
`workflow_step_projection_test.exs` untouched-green + WorkflowsLive step
detail still renders; #21: both vendor runner suites + executor suite;
#18: `api_key_auth_test.exs`; #16: golden + wire tests + `jido_md.check`;
#17: existing `setup_test.exs` + REPL banner path). End-to-end spot
drives: `mise exec -- mix jidoclaw.api_key mint/list` on dev DB;
`reproject_steps` on a dev run (corrupt → repair); `mix jidoclaw --setup
--check` on this checkout (must not start the app tree); a served-MCP
failing tool call showing content[0] legacy text + content[1] JSON.

**Final bar**: `mise exec -- mix precommit` bare in background; iterate to
green. Known-flaky singleton suites verified in isolation. Docs gates
re-run as edited (`system_docs.check`, `jido_md.check`,
`graphql.schema.check` — expected no-op).

## Suggested commit slicing (operator commits; nothing staged by the agent)

1. `docs: pre-argus wave E plan` — the materialized plan doc.
2. `feat: non-interactive env floor + headless session property (OR3-1)` — #20.
3. `feat: headless contract fragment, marker, report_blocked lane (CH2-5)` — #21.
4. `feat: mix jidoclaw.api_key + ApiKey scopes room (MY1-4a, TC1-2 rider)` — #18.
5. `feat: mix jidoclaw.reproject_steps — projection-owned steps, lock-fenced rebuild (OR2-4a)` — #19 (incl. the WorkflowStep write-model removal + config-drop migration).
6. `feat: served-MCP structured error contract + code registry (PD1-2)` — #16.
7. `feat: setup doctor with --check, provider probes, ymlr config writes (PD3-1)` — #17.

Each item's reconciliation/Status edits ride its own commit.
