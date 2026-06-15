# Plan: V2-4 Replay Preflight Diagnostics

## Context

Source: `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md`.

The two high-value V2 borrows are already shipped and verified in the codebase:
**V2-1** (per-tool approval gate, commits `7fa6267` + `28a01ce`) and **V2-2**
(external MCP consumption, `3cde549` + `ce96f02`). Their remaining deferred
items are either explicitly *not load-bearing* for this threat model, *superseded*
by what shipped, or *fail-closed/safe*. The Tier-3 items (V2-3/5/6/7) are gated on
future pain or are watch-only.

**V2-4** is the one remaining item that is bounded, ungated, non-redundant, and
reachable to a clean ADOPTED state. Today, when a workflow replay is refused, the
operator/LLM gets only a bare string — `"the workflow definition changed since
this run"` — with no picture of *why* the recorded run is or isn't safe and
complete to reason about. jidoka answers this as pure data: a `diagnose/1` that
reports recorded-run health (`:complete | :waiting | :failed | :incomplete`) plus
detail buckets (failed/missing steps, pending reviews, warnings).

**Outcome**: a pure, data-only `JidoClaw.Orchestration.Replay.diagnose/2` that
composes entirely from data that already exists — `WorkflowRun`, `WorkflowStep`,
`WorkflowEvent`, `AgentCase`, `DefinitionFingerprint` — surfaced in the two places
the doc names: the `replay_workflow` MCP tool's refusal detail and the dashboard
replay panel. It never executes providers and never decrypts the inputs blob.

This is greenfield — no migration/back-compat concerns.

> Revised after review. Fixes folded in: honest replay-safety naming
> (`preflight_clear?` + `input_status`, never a false `replayable?`); bounded
> `to_mcp_map/1`; shared test fixtures extracted to support (the originals are
> private `defp`s); `irreversible_executed?` homed in `Replay.Safety` not
> `DefinitionResolver`; `unresolved_steps` defined against the projection;
> verification covers every touched file.

## Design decisions

### Two distinct axes (refinement over the raw jidoka port)

A run's **recorded health** and its **replay-safety** are genuinely different
questions: a run can be perfectly `:complete` (all steps finished, no failures)
yet un-replayable because its skill YAML changed on disk since. So the struct
reports both, separately:

- `status :: :complete | :waiting | :failed | :incomplete` — jidoka's enum, the
  recorded-run-health axis. A definition change does **not** make this `:failed`.
- `blockers :: [term()]` + `preflight_clear? :: boolean` — the replay-safety axis:
  the union of every refusal `Replay.replay/2` would raise (un-forced) **that
  diagnose can determine without decrypting**, and whether that set is empty.
  `preflight_clear?: true` asserts only that the checks diagnose *performed* found
  no blocker — it is **not** a guarantee replay succeeds, because input-blob
  integrity (`:corrupt_inputs`) is intentionally not decrypt-verified here. The
  separate `input_status :: :present_unverified | :missing` surfaces exactly that
  residual: a `:present_unverified` blob is the one gate left unchecked. This is
  the dashboard/MCP value-add: "can I replay this, and if not, why — all reasons,
  not just the first."

`status` precedence (first match wins, adapted from jidoka):
1. `pending_gates != []` → `:waiting`
2. `run.status == :failed` or `failed_steps != []` → `:failed`
3. `not terminal?` or `unresolved_steps != []` → `:incomplete`
4. else → `:complete`

### The diagnostics struct — `JidoClaw.Orchestration.Replay.Diagnostics`

Plain `defstruct` + precise `@type t` (the `WorkflowView` convention — **not** Zoi,
which is only a transitive dep; this struct is built from trusted internal reads,
not parsed from external input, so it needs no schema validation):

```elixir
defstruct run_id: nil,
          status: :complete,            # :complete | :waiting | :failed | :incomplete
          terminal?: false,
          preflight_clear?: false,      # blockers == [] — NOT a replay guarantee (see input_status)
          input_status: :missing,       # :present_unverified | :missing (encrypted-column presence; no decrypt)
          definition: %{kind: nil, status: :no_hash, stored_hash: nil,
                        current_hash: nil, detail: nil},
          irreversible_executed?: false,
          failed_steps: [],             # operator-scoped, redacted step views
          unresolved_steps: [],         # projected step rows still :pending/:running on a terminal run
          pending_gates: [],            # [%{id, step_name, kind, status}]
          blockers: [],                 # replay refusal terms diagnose can determine (the union)
          warnings: [],                 # [String.t()]
          generated_at: nil             # one captured DateTime
```

`definition.status :: :match | :changed | :unavailable | :no_hash`;
`definition.detail` carries the `:skill_unavailable | :no_definition_kind |
{:compile_failed, _} | {:disallowed_module, _} | :module_unavailable` reason when
`:unavailable`.

`unresolved_steps` is defined precisely against the data we have: `WorkflowStep`
is a *projection* of observed `step_*` events, **not** a complete expected-step
inventory — so this field means "projected step rows still `:pending`/`:running`
on a terminal run," never "steps absent from the definition" (a definition-DAG
diff is out of scope; documented in the moduledoc).

### Fingerprint recompute — best-effort, never crashes

To report `definition.status`, diagnose must recompute the *current* fingerprint
exactly the way the replay gate does (fresh from disk for skills, pure BEAM md5
for module reactors). This logic is currently private in `replay.ex`. Decision:
**extract the shared gates into two cohesive modules both call**, so the two paths
can never drift — `replay/2` folds them via `with` (short-circuit), `diagnose/2`
collects (never short-circuits):

- `Replay.DefinitionResolver` — definition resolution only (`definition_kind/1`,
  `resolve/2`).
- `Replay.Safety` — the non-definition gates (`terminal?/1`, `irreversible_executed?/1`).
  The irreversible check scans `WorkflowEvent` payloads, which is *not* definition
  resolution and must not live in `DefinitionResolver` (review [P3]).

Both extractions are pure code-moves; the existing `replay_test.exs` taxonomy is
the regression net. `diagnose/2`'s call to the resolver is wrapped so a
malformed-YAML-on-disk raise (outside `Skills.load_skill/2`'s typed error set)
maps to `definition.status: :unavailable` + a warning instead of crashing —
`replay.ex` keeps its current behavior untouched.

**`definition.status` precedence mirrors replay's kind-then-hash order**: no
`definition_kind` → `:unavailable` (detail `:no_definition_kind`) — replay refuses
`:no_definition_kind` *before* it reaches the hash gate, so diagnose reports the
same even when `definition_hash` is also nil; kind present + hash nil → `:no_hash`;
kind + hash present, resolve fails → `:unavailable`; resolve ok →
`:match`/`:changed`. `terminal?` is `Safety.terminal_status?(run.status)`.

### Encryption safety + the unverified-input residual (non-negotiable)

`diagnose/2` reads only: `WorkflowRun.by_id`, `WorkflowStep.for_run`,
`WorkflowEvent.for_run`, `AgentCase.pending_for_run`. It **never** calls
`Ash.load(run, :replay_inputs | :resume_checkpoint)` (no vault decrypt). It checks
*presence on the encrypted column* (the `GateResume` precedent, which checks
`encrypted_resume_checkpoint`) — confirm the exact attribute name
(`encrypted_replay_inputs`) against `workflow_run.ex` during implementation — and
maps it to `input_status`: `nil` column → `:missing` (+ blocker
`{:not_replayable, :no_inputs}`); present → `:present_unverified`.

Because the ciphertext is never decrypted, `:corrupt_inputs` is **not** diagnosable
— a present-but-corrupt blob diagnoses as `input_status: :present_unverified`,
`preflight_clear?: true`, and would still fail `replay/2` (review [P1]). This is
exactly why the convenience flag is `preflight_clear?`, not `replayable?`. The
limitation is documented in the moduledoc. All error/output snippets route through
`Visibility.*_view(_, :operator, now)`.

### Surfaces

- **MCP** (`replay_workflow.ex`): on the replay-relevant refusals
  (`{:definition_changed, _, _}`, `:irreversible_steps_executed`,
  `{:not_replayable, _}`), call `Replay.diagnose/2` and attach
  `Diagnostics.to_mcp_map/1` to a structured error. Verified safe: `Error.normalize/1`
  (`error.ex:119`) passes `%{code: atom, message: binary, details: map}` through
  verbatim, so returning `{:error, %{code: :replay_refused, message: <existing
  string>, details: %{diagnostics: <map>}}}` lands diagnostics at
  `details.diagnostics` and keeps the existing `{:error, %{message: message}}`
  assertions green. A `diagnose` failure degrades silently (omit the key) — never
  let diagnostics break a refusal. **Bounding is `to_mcp_map/1`'s own job**: that
  legacy `Error.normalize/1` clause passes `details` through *unsanitized*, and
  `OutputLimit` caps individual string/list leaves, not total serialized map size
  (`output_limit.ex:29`) — so without explicit caps a run with hundreds of failed
  steps/gates would emit an unbounded map (review [P2]). No standalone MCP tool
  (scope creep; the replay surface is deliberately tight + MCP-only per AGENTS.md).
  Success path (`summarize/1`) unchanged.
- **Dashboard** (`workflows_live.ex`): on a blocked replay click, stash the
  diagnostics struct in a **separate** `@replay_diagnostics` assign (a
  `%{run_id => Diagnostics.t()}` map) — *not* nested in `@replay_blocked`, whose
  exact `%{reason:, force:, allow_irreversible:}` shape is asserted by
  `replay_test.exs`. Render a compact, expandable detail (status badge, blockers
  list, warnings, failed/pending counts) in the existing expanded-steps row.
  diagnose runs only on a blocked click (not on the 30s list refresh).

### Out of scope

Telemetry/Trace events (diagnose is a pure read; consistent with `WorkflowView`).
`:corrupt_inputs` reporting (would require decrypt — see the residual above). A
definition-DAG step inventory. A standalone diagnose MCP tool.

## Files to change

**New — `lib/jido_claw/orchestration/replay/definition_resolver.ex`**
`JidoClaw.Orchestration.Replay.DefinitionResolver` (moduledoc). Pure code-move
from `replay.ex` of: `definition_kind/1`; `resolve/2` (was `resolve_definition/2`)
plus helpers `lookup_skill`, `skill_project_dir`, `compile_skill`,
`check_allowed_module`, `resolve_module`, `@allowed_module_prefix`. Public
functions get `@spec`s + docs. The `{:ok, %{kind, reactor, hash, deadline?}}` map
is the shared contract. Definition resolution only — no event scanning.

**New — `lib/jido_claw/orchestration/replay/safety.ex`**
`JidoClaw.Orchestration.Replay.Safety` (moduledoc). The non-definition replay
gates, shared so replay + diagnose can't drift: `terminal_statuses/0` (the
`@terminal` list, now homed here) + `terminal_status?/1` (takes a status atom —
explicit input, no `%WorkflowRun{}` ambiguity; can eventually replace the
duplicated terminal lists at `workflows_live.ex:15` / `workflow_view.ex:15`),
`irreversible_executed?/1` (pure code-move of `irreversible_step?/1` +
`@irreversible_kinds`, scanning `WorkflowEvent` payloads).

**Modify — `lib/jido_claw/orchestration/replay.ex`**
- `do_replay/5`'s `with` calls `DefinitionResolver.definition_kind/1` +
  `DefinitionResolver.resolve/2`; `ensure_terminal/1` uses
  `Safety.terminal_status?(status)`; `check_irreversible/4` calls
  `Safety.irreversible_executed?(events)`.
- Add facade `diagnose/2` delegating to `Diagnostics.diagnose/2`.
- Remove now-unused aliases / module attributes (`Skills`, `Skills.Compiler`,
  `DefinitionFingerprint` if fully moved; `@terminal`, `@irreversible_kinds`,
  `@allowed_module_prefix` once relocated) — **a leftover unused alias/attribute
  is a blocking `compile_check` warning.**

**New — `lib/jido_claw/orchestration/replay/diagnostics.ex`**
`JidoClaw.Orchestration.Replay.Diagnostics` (full moduledoc: the two axes, the
status precedence, the never-decrypt discipline + why `preflight_clear?` is not a
replay guarantee, the `:corrupt_inputs` / `unresolved_steps` limitations). The
struct + `@statuses` + `@type t` + `@type status`; `statuses/0`;
`@spec diagnose(String.t(), keyword()) :: {:ok, t()} | {:error, :missing_required_opt
| :not_found}` (a *findable* run with blockers is `{:ok, struct}`, not an error —
only a genuinely missing run / missing opt errors). Composes findings from
`DefinitionResolver` (definition status) and `Safety` (terminal?/irreversible) so
it shares the exact gates `replay/2` uses. `@spec to_mcp_map(t()) :: map()` —
**build a bounded plain map first, then `Core.JsonSafe.encode/1`** (bounding must
precede encode — review [P2]): truncate `failed_steps` / `unresolved_steps` /
`pending_gates` / `warnings` to the first N (e.g. 10) each with a companion
`*_omitted` count; normalize `blockers` tuples to `%{code:, detail:}` maps with
each `inspect`-ed detail byte-capped; and byte-cap `definition.detail` too (it can
carry a `{:compile_failed, _}` term or other large value). Split the builder into named private
steps (credo arity/length). Apply `# reach:disable-for-this-file fixed_shape_map`
(the `definition`/gate-summary shapes recur; precedented at `error.ex:4`); if
`behaviour_candidate` fires, add the module to the existing `.reach.exs` list
beside `WorkflowView` — but its `diagnose/2 + statuses/0 + to_mcp_map/1` surface
differs from the view triad, so it likely won't.

**Modify — `lib/jido_claw/tools/replay_workflow.ex`**
Restructure `run/2` so `tenant`/`actor` are bound before the `with` (so the error
branch can reuse them); on a replay-relevant refusal, build the structured error
with an attached `Diagnostics.to_mcp_map/1`. Keep the existing plain-English
`format_refusal/1` strings as the `message`.

**Modify — `lib/jido_claw/web/live/workflows_live.ex`**
Add `replay_diagnostics: %{}` to `mount/3`; in the two blocked branches of
`handle_event("replay", ...)` compute + stash the struct; clear the run's entry on
a successful replay; render the detail in the expanded-steps row guarded on
`@replay_diagnostics[run.id]`. **Once the template reads `@replay_diagnostics`,
every hand-built `render/1` assign map in the tests must include
`replay_diagnostics: %{}`** or the render raises `KeyError` — the assign maps at
`replay_test.exs:750` and `workflows_live_test.exs:89`.

## Test plan

**New — `test/support/replay_fixtures.ex`**
`JidoClaw.Test.ReplayFixtures` — extract the fixture + forged-row helpers as
**public functions** (`fixture_yaml/0` returning the raw YAML — a module attribute
is private and the disk-edit tests need the string; `tmp_project_dir!/0`,
`write_fixture!/1,2`, `launch_fixture!/2,3,4`, `forge_terminal_run!/2` — the
`(attrs, ctx)` corruption-sim builder over `WorkflowRun.create`) that today are
*private* `defp`s in `replay_test.exs` (and partly re-duplicated in
`replay_workflow_test.exs`), so the new diagnostics tests can call them (review
[P2]). Since a support module does not `use ExUnit.Case`, temp-dir cleanup calls
`ExUnit.Callbacks.on_exit/1` **fully qualified**. The new test uses this module;
refactoring the two existing test files onto it is optional follow-up — leave them
untouched to keep blast radius small.

**New — `test/jido_claw/orchestration/replay/diagnostics_test.exs`**
(`use JidoClaw.TenantCase, async: false`; uses `JidoClaw.Test.ReplayFixtures` +
the `EchoStub`/`CrashStub`/`SecretErrorStub` stubs). One test per axis:
- clean completed skill run → `status: :complete`, `definition.status: :match`,
  `preflight_clear?: true`, `input_status: :present_unverified`, empty blockers.
- disk-edited skill → `definition.status: :changed`, blocker
  `{:definition_changed, stored, current}`; assert the hashes equal what
  `Replay.replay/2` refuses with (the cross-check pin against drift).
- irreversible-executed run → `irreversible_executed?: true`, blocker
  `:irreversible_steps_executed`.
- gate-parked (non-terminal, `GatedTestReactor`) → `status: :waiting`,
  `terminal?: false`, `pending_gates` non-empty, blocker `{:not_replayable,
  :run_not_terminal}`.
- failed-step run (`CrashStub`/`ErrorStub`) → `failed_steps` non-empty,
  `status: :failed`.
- forged terminal run with a step row left `:running` → `unresolved_steps`
  non-empty, `status: :incomplete`.
- forged terminal run with a **valid `config` (definition_kind + reactor) but
  `definition_hash: nil`** → `definition.status: :no_hash`, blocker
  `{:not_replayable, :no_hash}`, `status: :complete` (a valid kind is required, or
  precedence reports `:no_definition_kind` first).
- forged run, hash but no inputs blob → `input_status: :missing`, blocker
  `{:not_replayable, :no_inputs}`, `preflight_clear?: false` via the
  encrypted-column presence check (assert `encrypted_replay_inputs == nil` first).
- `:no_definition_kind` / `{:disallowed_module, _}` forged configs →
  `definition.status: :unavailable` with the right detail, no crash. Forge a
  **non-nil `definition_hash`** on the `:no_definition_kind` case so the expected
  status is unambiguous (replay checks kind before hash).
- skill YAML deleted after launch → `:unavailable` (`:skill_unavailable`), no crash.
- **redaction pin**: a `SecretErrorStub`-failed run — secret appears raw on
  `run.error` but absent from `Jason.encode!(to_mcp_map(diag))` (the
  `workflow_view_test.exs` pattern).
- **bounding pin**: a run forged with > N failed steps → `to_mcp_map/1` truncates
  to N with the `*_omitted` count set (review [P2]).
- **error contract**: `:missing_required_opt` (no tenant/actor), `:not_found`
  (unknown id), cross-tenant id → `:not_found`.

**Modify — `test/jido_claw/tools/replay_workflow_test.exs`**
Extend the definition-change test to also assert the error carries the diagnostics;
add one for the irreversible refusal. Mind the key-type boundary: the error
envelope keys we build are atoms (`err.details.diagnostics`), but everything
*inside* `to_mcp_map/1` is string-keyed after `JsonSafe.encode/1` — so assert
`err.details.diagnostics["definition"]["status"] == "changed"`. Keep the existing
`{:error, %{message: message}}` assertions (the extra key is additive). If this
file is refactored onto `ReplayFixtures`, do it as separate optional cleanup.

**Modify — `test/jido_claw/orchestration/replay_test.exs`**
The `@replay_blocked` exact-equality assertions stay valid (diagnostics live in
the separate `@replay_diagnostics` assign). Add: after a blocked click,
`socket.assigns.replay_diagnostics[run_id]` is a `%Diagnostics{}`; a LiveView
render assertion (reusing `render_workflows/2`) that the diagnostics detail HTML
appears for a blocked run and is absent otherwise.

## Verification

Run via `mise exec -- mix` (project toolchain = mise latest, OTP 29 / Elixir 1.20).

1. Immediately after the `DefinitionResolver` + `Safety` extraction (before writing
   diagnose), run the regression net:
   `mise exec -- mix test test/jido_claw/orchestration/replay_test.exs test/jido_claw/tools/replay_workflow_test.exs`
   — proves the pure code-move changed no behavior.
2. New + touched suites (every file this change modifies — review [P2]):
   `mise exec -- mix test test/jido_claw/orchestration/replay/ test/jido_claw/orchestration/replay_test.exs test/jido_claw/tools/replay_workflow_test.exs test/jido_claw/web/live/workflows_live_test.exs`
3. Manual smoke (Tidewave `project_eval` or IEx): launch a fixture skill, edit its
   YAML on disk, call `JidoClaw.Orchestration.Replay.diagnose(run_id, tenant:,
   actor:)`, confirm `definition.status == :changed`, `preflight_clear? == false`,
   the right blocker, and that `to_mcp_map/1` Jason-encodes with no leaked payloads
   and bounded lists.
4. **The gate (definition of done):** `mise exec -- mix precommit` run **bare**
   (never piped — `| tail` masks the exit code) in the background, then read the
   output tail. It runs `jidoclaw.compile_check` (the warnings gate — tolerates
   only the 2 documented pull_request_coordinator warnings, so watch for unused
   aliases in `replay.ex`), `format --check-formatted`, `reach.check --smells
   --strict` (the `fixed_shape_map` / `behaviour_candidate` mitigations above),
   `credo --strict` (moduledocs + `@spec`s on every public fn), `dialyzer` (precise
   `@type t`, including the `definition` sub-map and `blockers :: [term()]`), and
   `test`. The plan is **not complete until `mix precommit` passes.**

Note: the Stop hook's `compile --warnings-as-errors` always fails on the 2
intentional pull_request_coordinator warnings — that is expected and is **not** a
signal from this change; trust `jidoclaw.compile_check`/`precommit`, which tolerate
exactly those two.

## Risks / call-outs

- **`DefinitionResolver` + `Safety` extraction blast radius** — pure moves, but
  they touch the working replay path. Mitigation: step-1 regression run (above).
  Fallback if either gets noisy: make the needed `replay.ex` functions `@doc false`
  public instead of extracting — smaller change, but pollutes Replay's surface;
  prefer the extraction.
- **Honest naming** — `preflight_clear?` (not `replayable?`) + `input_status` keep
  diagnose from promising an outcome it can't verify without decrypting (review
  [P1]); a consumer wanting certainty must attempt the replay.
- **Status-precedence judgment calls** (definition-changed kept *out* of `:failed`;
  `:no_hash` → `:complete`-but-not-`preflight_clear?`) are documented in the
  moduledoc and pinned per-axis; a different severity is a one-line change.
- **`encrypted_replay_inputs` attribute name** — verify against `workflow_run.ex`
  before relying on the presence check (GateResume precedent: `encrypted_resume_checkpoint`).

## Suggested commit (do not run — leave unstaged)

After `mix precommit` passes, stage the six `lib/` + support files + three test files:

```
feat: V2-4 replay preflight diagnostics

Add Replay.diagnose/2 — a pure, never-decrypting projection reporting recorded-run
health (:complete/:waiting/:failed/:incomplete) plus the union of determinable
replay blockers (preflight_clear? + input_status, honest about the unverified
input blob), surfaced in the replay_workflow MCP refusal detail (bounded
to_mcp_map) and the dashboard replay panel. Extract the shared definition
re-resolution (DefinitionResolver) and non-definition gates (Safety) so the replay
gate and diagnose can't drift.
```
