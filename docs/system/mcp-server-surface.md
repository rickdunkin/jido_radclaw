---
type: surface
description: The served MCP surface — 26 tools, four jido:// resources, the surface-version stability contract, the closed error-code contract, and their golden guards.
sources:
  - lib/jido_claw/core/mcp_server.ex
  - lib/jido_claw/core/mcp_server/surface_version.ex
  - lib/jido_claw/core/mcp_server/error_codes.ex
  - lib/jido_claw/core/mcp_server/error_boundary.ex
  - lib/jido_claw/core/json_safe.ex
  - lib/jido_claw/core/jido_mcp_runtime_patch.ex
  - lib/jido_claw/core/jido_exec_patch.ex
  - lib/jido_claw/core/dependency_patches.ex
  - lib/mix/tasks/compile.jidoclaw_release_patches.ex
  - lib/mix/tasks/jidoclaw.compile_check.ex
  - mix.exs
  - lib/jido_claw/core/mcp_server/resources
  - lib/jido_claw/tools/search_code.ex
  - lib/jido_claw/tools/search_real_code.ex
  - lib/jido_claw/tools/file_payload_limit.ex
  - test/jido_claw/core/mcp_server/served_surface_golden_test.exs
  - test/jido_claw/core/mcp_server/error_boundary_test.exs
  - test/jido_claw/core/mcp_server/error_codes_sweep_test.exs
  - test/jido_claw/core/jido_exec_patch_test.exs
  - test/mix/tasks/jidoclaw_compile_check_test.exs
  - test/jido_claw/core/dependency_patches_test.exs
  - test/jido_claw/core/json_safe_test.exs
  - test/fixtures/mcp_surface/served_surface.json
verified: 2026-07-14
verified_sha: "fdf361b4"
---

# MCP Server Surface

## What & why

`JidoClaw.MCPServer` serves the platform over MCP stdio for Claude Code, Cursor, and
other MCP-compatible editors: 26 tools + four `jido://` resources. The `.mcp.json`
quickstart and the anubis patch notes stay in AGENTS.md (MCP Server Mode); this page is
the full surface: what is exposed, what is deliberately MCP-only, and the stability
contract clients pin against. The *consuming* direction is
[mcp-consumption](mcp-consumption.md).

## Invariants & contracts

- **MCP-only by design**: `inspect_workflow`, `workflow_events`, and `replay_workflow`
  are on no in-REPL agent's tool list; `replay_workflow` additionally exposes no
  `force`/`allow_irreversible` overrides — replay-gate overrides are dashboard-only.
- **Version facts are single-sourced**: `app_version` comes from
  `SurfaceVersion.app_version/0` over `Application.spec/2`, and `server_info/0` is
  hand-defined to carry the same — never a hand-rolled literal (the old "0.2.0" rot
  lesson).
- **The stability contract**: `JidoClaw.MCPServer.SurfaceVersion` is what clients pin
  against — bump rules + changelog live in its moduledoc, and the golden
  `served_surface_golden_test.exs` set-compares tool names / static resource URIs /
  template URIs / the version string per enumeration surface against the committed
  `test/fixtures/mcp_surface/served_surface.json`, so a surface change without a
  deliberate bump fails precommit.
- **Honesty over fabricated zeros**: an unresolved MCP scope reads
  `available: false` with a reason, and a failed read inside a resolved tenant flips
  that block's `*_available: false` flag — the deliberate inversion of the dashboard
  rollup's degrade-to-zero.
- **The closed error contract (PD1-2, v1.3)**: every machine-readable code a PUBLIC
  served tool-result error may carry is enumerated in
  `JidoClaw.MCPServer.ErrorCodes` (8 families, 51 codes, each with a one-line doc),
  enforced at the wire by `JidoClaw.MCPServer.ErrorBoundary`: an unregistered code is
  re-coded to `tool_error` with the typed `unregistered_code` field carrying the
  original (stringified via `inspect/1` BEFORE JsonSafe — module atoms as map values
  are otherwise dropped), the envelope's retry state retained, plus a drift log.
  Producer squatters are stripped at the build site, so the wire key is present
  EXACTLY when the fallback fired. The boundary fallback is
  the closure PROOF; the AST sweep (`error_codes_sweep_test.exs` — occurrence-
  provenance collection with count-pinned non-envelope exclusions) is supplemental
  lint. Registry change rules: additions = MINOR, removals/renames/refamilies =
  MAJOR, always with a golden-fixture regen (`error_codes_by_family`) in the same
  diff.
- **Typed reserved wire state vs the open extension bag**: the boundary's internal
  `WireError` split — reserved wire state (`retry`, `truncated`, `unregistered_code`)
  rides typed struct fields overlaid authoritatively POST-encode onto string keys,
  while `extra_details` stays the producers' open extension bag, reserved-key-free
  by construction. One build site serves every tier: boolean-only extraction lifts
  `retry` and `truncated` atom-form-first with both key forms always dropped
  (non-boolean junk ⇒ the wire key is ABSENT — the boundary abstains; `truncated`
  lifts the legitimate `Tools.Error.sanitize_details/1` producer boolean, and the
  boundary's reduction tiers OR their own `true` over it — a producer `false` can
  never mask a real reduction); boundary-owned keys (`unregistered_code`,
  `original_byte_size`, `observed_at_least` — both key forms) are stripped from
  producer details so boundary measurements can't be counterfeited; hint +
  `value`/`timeout` twins canonicalize atom-first by fixed direct lookups, never a
  key sweep. Reduced/minimal tiers read the typed fields; reserved keys never hit
  the walker's collision sentinel and never flip values between tiers. NON-reserved
  twins keep the walker's sentinel — a documented bounded-work residual (no
  contract key lives outside the reserved list).
- **Dual-content error wire shape**: a failing public tool call carries `content[0]`
  = the byte-identical legacy inspect text (rendered via `JsonSafe.safe_inspect/1` —
  same bytes whenever `inspect/1` succeeds with valid UTF-8) and `content[1]` — the
  SECOND content item of the raw error response, never "the final item" (downstream
  relays such as the external-MCP proxy → LoopGuard path may APPEND items) — the
  canonical JSON envelope `{"code","message","details"}`. Every OTHER server riding
  the patched runtime (memory consolidator, Forge deposit server) keeps the
  byte-identical legacy single-item arm, raw-inspect escape path included.
- **Never escalates, bounded machinery**: the entire structured-item production
  sits in one rescue+catch guarded region (throw/exit escape a bare `rescue`); any
  escape yields a fully static ASCII envelope carrying `"retry": false` — a
  serializer bug can never convert a tool error into a JSON-RPC failure. The region
  is provable end-to-end via the test-compiled `:error_boundary_chaos` app-env seam
  (all three escape kinds driven through the real runtime); production builds carry
  a constant no-op, structurally unable to trip the fallback on configuration junk. The
  extension bag normalizes through the budgeted `JsonSafe.encode_bounded/2`
  (node/depth/key/byte budgets with O(1) container preflights), and the encoded
  item — reserved fields overlaid, the item as shipped — is capped at 16 KiB:
  over-cap or budget-tripped envelopes reduce to the fixed hint allowlist
  (`field`, `expected`, `got`, `available`, `available_truncated` — atom and
  string key forms), each value re-bounded (2 KB string truncator; per-field small
  bounded pass whose own trip yields the constant `"[truncated]"`); a reduction
  still over the cap falls to the minimal envelope. Machine-readable code and the
  reserved wire state survive every tier via the typed overlay. The boundary's own
  machinery never renders an unbounded-width value uncharged: out-of-int64
  integers charge `2 × max(external_size − 8, 0)` in the walker — a provable
  LOWER bound of the decimal render preserving `observed_at_least`'s contract,
  tight enough that a single huge integer trips before Jason and admitted
  bignums render within 2.625× of their charge (total bignum materialization
  ≤ 2.625× the byte budget; finite-width numerics keep the documented
  node-bounded undercount); the calendar leaf conversions run only behind an
  ISO-only, in-int64-temporal-fields fast-path gate (anything else takes the
  generic budgeted struct walk — non-ISO calendar callbacks never dispatch; a
  documented `encode_bounded`-vs-`encode/1` divergence); and tier 4's message
  reuses the single `content[0]` legacy render.
- **Tier-1 wrap provenance is WITNESSED, never shape-inferred (PORT-PD1-2-EXEC)**:
  the exec map-wrap is lossy — post-wrap, the wrap of a canonical envelope and a
  hand-built native error whose details carry `:code`+`:details` are byte-identical
  — so the forked `Jido.Exec` (generated at compile time by
  `lib/jido_claw/core/jido_exec_patch.ex`) stamps a per-call reference into the
  wrap's details: opt `:jido_claw_wrap_provenance` (passed ONLY by the public
  runtime path — `ErrorBoundary.mint_wrap_token/1` returns a ref for the public
  server, `nil` → `[]` opts everywhere else; unconditional minting would put
  marker keys into the consolidator/deposit servers' byte-pinned legacy arms),
  marker key `:__jido_claw_exec_wrapped__` (BOTH key forms boundary-owned —
  wire-stripped on every tier). The stamp condition is the RAW canonical-envelope
  contract on the PRE-wrap reason (non-struct map, atom `code`, binary `message`,
  map `details` — exactly tier 2's guard): the witness attests "exec wrapped a
  canonical envelope", never merely "exec wrapped a map" — colliding non-exception
  structs and near-envelope maps (non-binary/absent `message`) extract to the same
  details shape and wrap UNSTAMPED → native tier (`execution_error`, authoritative
  retry; junk-input-only deltas, all mis-tiering DOWN). `Map.put_new`, never
  `Map.put`: a producer squatting the key keeps its junk, the delivered term stays
  byte-identical to the unpatched world, and the identity check refuses. The
  boundary detaches the marker BEFORE the legacy render, ONLY on exact `===` ref
  identity (forged/stale refs stay in the term for `content[0]` fidelity and fail
  tier 1); tier 1 REQUIRES the witness. The marker is inert to the exec retry
  gate (`retryable?/1` walks only `retry`/`reason` keys) and to no-opt callers
  (byte-identical by construction — every exec caller outside the public runtime
  path passes no opt).
- **Unwrap tiers pinned**: (1) the WITNESSED exact `Jido.Exec` wrap of a canonical
  envelope (`ExecutionFailureError` whose details carry `:code` + `:details` AND
  the detached per-call marker — shape alone no longer selects this tier); (2) a raw
  envelope map — token-free by design (a raw map cannot be a native error); (3) the
  six native jido_action typed errors via
  `Jido.Action.Error.to_map/1`, with `details.retry` set from
  `Jido.Action.Error.retryable?/1` on the original error — **retry-policy
  ELIGIBILITY**, the class component the exec gate ANDs with its attempt budget
  (cap-first, so the boundary only sees finally-refused errors); producer hints
  are honored inside the predicate's own hint-folding, and `false` means "not
  eligible for the immediate automatic retry under the current classification —
  do not blindly repeat without intervention", never a determinism claim and
  never a record of in-call retry execution. The definition is SERVED, not
  repo-docs-only: bootstrap `error_contract.retry_semantics` + the
  `server_instructions` stability sentence (`ErrorCodes.retry_semantics/0`,
  single-sourced). `to_map/1`'s own `retryable?` field is not used (it diverges
  from the gate's predicate); non-binary/non-atom native messages project to a
  static placeholder before `to_map/1` (its message fallback inspects at
  `limit: :infinity`); `:configuration_error` translates to `:config_error`; (4)
  everything else → `tool_error`, message reusing the `content[0]` legacy render
  (computed once). (1) before (3) or our envelopes would collapse to a generic
  `execution_error`.
- **New producer envelopes are non-retryable in-call**: `run_skill`'s
  `unknown_skill`/`skill_cancelled`/`skill_run_failed`, `list_directory`'s typed
  glob envelopes, and `network_share`'s producer-normalized `not_found` all pin
  `details.retry: false` — `Jido.Exec` defaults unflagged error maps retryable with
  one retry, and `run_skill` mints a fresh WorkflowRun per call.
- **Contract scope is TOOL-RESULT errors only**: unknown tools, authorization
  refusals, and escaped runtime failures remain plain JSON-RPC protocol errors with
  no `content[1]`. The stability sentence (served as `server_instructions` and in
  `jido://bootstrap`'s `error_contract` block) says exactly this.
- **Typed hint details**: `Tools.Error.hint_available/2` (stringify → dedupe → sort
  → cap 25, `available_truncated` from the pre-cap count) and `hint_expected/3`
  (bounded `expected`/`got` strings) generalize the LoopGuard-directive precedent.

## Mechanics

**Exposed tools** (26): `read_file`, `write_file`, `edit_file`, `list_directory`,
`search_code`, `run_command`, `fetch_output`, `git_status`, `git_diff`, `git_commit`,
`project_info`, `run_skill`, `store_solution`, `find_solution`, `network_share`,
`network_status`, `agent_status`, `inspect_agent`, `swarm_status`, `forge_status`,
`workflow_status`, `inspect_workflow`, `replay_workflow`, `workflow_events`,
`lua_query`, `lua_docs`. `workflow_events` returns a run's raw, byte-paginated
`WorkflowEvent` feed (G2-1a). `inspect_workflow` reads a single composer run's live
route / waves / held / dropped / live signals + gate-block state; `workflow_status` is
the tenant rollup.

`search_code`/`search_real_code` share a bounded VFS traversal core: per-file
pre/post read caps plus hard directory-depth, entry, file, aggregate-byte, match,
and retained-output ceilings. Each regex match has explicit PCRE work/recursion
limits; regex/glob sources are capped at 8 KiB/4 KiB, and both compilers run in
supervised unlinked tasks that are killed and drained at the scan deadline (covering
GlobEx range expansion as well as PCRE compilation). The whole scan uses the tighter
of Jido's absolute action deadline or a five-second direct-call default.
`max_results` can narrow output but cannot raise the hard 1,000-line retention
ceiling; a scan that exceeds a safety budget fails loudly instead of materializing
an unbounded tree or match list. Locally resolved reads additionally require a
regular file before `File.read/1`, rejecting FIFOs/sockets/devices so a special file
cannot consume an unbounded blocking read.

**Exposed resources** (AR-2 Phase 5, §10.2):

- `jido://workflows/catalog` — the deterministic route-composer catalog (every
  composable stage: unit, routes, inputs/outputs, subscribes/publishes, locks) as
  `application/json`, so a client can *discover* the composable surface, not just
  trigger it.
- `jido://workflows/<stage>` (G2-1b) — the per-stage drill-down: an anubis `component`
  template resource (`jido://workflows/{name}`, listed under
  `resources/templates/list`, single-sourcing `Stage.to_map/1` so a stage read is
  byte-identical to the catalog's entry; unknown stage ⇒ resource not-found).
- Both workflow payloads gained the additive stage `"executor"` field in **v1.1**
  (`null | "in_process" | "forge:<kind>"` — the item 7 PR-4 per-stage executor
  override; every shipped stage serves `null`). Additive served-output field ⇒ a
  MINOR bump per the `SurfaceVersion` rules.
- `jido://_meta/version` (pad PD1-1, next-ten #6) — the served-surface version facts:
  `app_version`, `surface_version`, and `tool_count`.
- `jido://bootstrap` (PD2-1, slim) — one-read client orientation: versions + sorted
  tool names + a bounded tenant snapshot (identity, pending-gates count,
  `active_runs`/`recent_completions` as `Visibility.run_view` rows capped at 5 with
  `*_overflow_count` from a cap+1 read — ≥1 means "more exist", never a total).
- Run views served by `workflow_status`, `jido.runs`, `jido://bootstrap`, and
  `inspect_workflow` gained the additive `claimed_by` + `claim_expires_at` ownership
  fields in **v1.2** (WS6 lease observability, via `Visibility.run_view/3`). Both are
  raw/frozen claim columns — on a terminal run, the last-claim value, never live
  lease state; pair with `status`. Additive served-output fields ⇒ MINOR.

## Config & telemetry

Served when `:serve_mode` is `:mcp` (`mix jidoclaw --mcp`; Gateway and Discord are
skipped in this mode). Requires PostgreSQL running and `mix ecto.setup` run at least
once. The golden test + `SurfaceVersion` bump rules are the change-control mechanism.

## Residuals & accepted risks

The anubis_mcp 1.6.2 runtime patch (Peri validation rescue + argument atomization)
remains documented in AGENTS.md's Known limitations — it is a dependency workaround,
not a surface property; remove once `jido_mcp` emits Peri-compatible schemas or stops
routing those descriptors through Anubis's pre-dispatch validation.

**The jido_mcp runtime patch** (`lib/jido_claw/core/jido_mcp_runtime_patch.ex`,
registered beside the anubis patch in `DependencyPatches.patched_modules/0`): a
verbatim copy of `Jido.MCP.Server.Runtime` with EXACTLY two surgical changes — the
two `handle_tool_call/5` error arms route through
`ErrorBoundary.error_response/3`, and the exec call mints + threads the per-call
wrap-provenance token (`mint_wrap_token/1` + `exec_opts/1`; policy lives in the
boundary, the patch just threads). Its staleness is now guarded like the exec
fork's: a jido_mcp package pin (mix.lock version + outer checksum), the upstream
`runtime.ex` sha anchor, and a parity-reconstruction test that rebuilds the
committed file from upstream + the enumerated transformations (format-normalized)
— an accidental edit anywhere else in the ~300-line copy fails that row. Drop once
jido_mcp offers an error-rendering seam (a per-server error formatter callback)
that lets the boundary hook in without redefining the runtime.

**The jido_action exec fork** (`lib/jido_claw/core/jido_exec_patch.ex`, port map
`docs/exploration/pms/pad/PORT-PD1-2-EXEC.md` — signed 2026-07-13): NOT a committed
copy — a compile-time GENERATOR that reads the pinned upstream
`deps/jido_action/lib/jido_action/exec.ex` (sha256 compile-gated via
`@external_resource`; a jido_action bump fails COMPILATION with the re-port
message), applies two exact-string line-count-preserving hunks (the map-wrap arms)
plus an appended helper block (`maybe_mark_wrap/3`, `canonical_envelope?/1`,
`__jido_claw_patch_info__/0`), and compiles under the dep's own recorded file
string — so `handle_action_exception/4`'s embedded `__STACKTRACE__` frames render
byte-identical to the unpatched world on the no-opt raise path, and off-hunk drift
is structurally impossible. The produced BEAM's durable incremental-build owner is
`Mix.Tasks.Compile.JidoclawReleasePatches`: on EVERY compile it verifies the
app-side BEAM's persisted marker against BOTH pins (upstream sha + patch revision
— the digest of the hunks/helper, so hunk edits at an unchanged jido_action
version also regenerate) and regenerates otherwise; boot force-load + prod
relocation read `{Jido.Exec, :jido_action}` from `DependencyPatches`. One caller
sits OUTSIDE the mix.exs `compilers/0` chain: the warnings gate
(`mix jidoclaw.compile_check`) hand-sequences its compile tasks, and its original
`clean` → `compile.elixir` → `compile.app` run deleted the app-side fork BEAM
without ever rerunning the custom compiler (`compile.elixir` never runs custom
compilers; `compile.app` derives `:modules` from an ebin beam scan) — a post-gate
no-recompile boot silently fell back to the upstream dep BEAM. The gate therefore
now reruns `compile.jidoclaw_release_patches` between `compile.elixir` and
`compile.app` and SELF-ASSERTS at the end of its sequence
(`CompileCheck.assert_exec_fork!/2`): the marker-current BEAM plus `.app`-modules
membership at the env's owner — the app ebin in dev/test; in prod the relocated
`jido_action` ebin plus the single-owner invariant (no lingering app-side BEAM or
`jido_claw.app` entry). The fork's own `Code.compile_string` warnings also no
longer vanish: `JidoExecPatch.compile_with_diagnostics/2` captures them via
`Code.with_diagnostics/2`, `generate!/2` returns them, and the compiler task
converts them to `Mix.Task.Compiler.Diagnostic` structs on its
`{:ok | :noop, diagnostics}` return — which the gate runs through the SAME strict
allowlist split as compile.elixir's diagnostics (and shell-prints on a plain
`mix compile`, since capture suppresses the default print). Licensing
(Apache-2.0 §4): `priv/licenses/jido_action-APACHE-2.0.txt` (byte copy of the
dep's LICENSE, test-pinned) + `jido_action-NOTICE.txt` ride every
`priv/`-bundling artifact; `JidoClaw.Core.ThirdPartyLicenses` embeds both for the
escript (which bundles no `priv/`), served by the pre-boot
`jidoclaw --third-party-licenses` flag. Remove once jido_action stamps wrap
provenance natively or exposes a result-normalization seam (2.3.1's
`:error_normalization` opt is accepted-and-ignored).

Wrap-provenance residuals: enabled Jido compensation would nest a marked error
inside a NEW unmarked `ExecutionFailureError` beyond detach's reach — unreachable
today because compensation is opt-in ACTION METADATA (`use Jido.Action` defines a
default `on_error/4` for every action, so `Jido.Exec.Compensation.enabled?/1`'s
metadata read is the real gate) and no published tool enables it, pinned by the
served-inventory guard test; re-derive before enabling compensation on any served
tool. The opt/marker literals are duplicated between the boundary and the fork's
helper block by necessity (two module trees) — the end-to-end tier-1 rows pin the
coupling.

Accepted error-contract residuals: `lua_docs` keeps its pre-existing string
`available` detail shape (unify at the next MAJOR); proxied served errors reaching a
consuming JidoClaw's LoopGuard hash BOTH content items' text — signature drift for
that relay path is a documented effect of the additive shape; `Error.normalize`'s
legacy funnel keeps the emitted-code set formally open (any atom under
`code:`/`status:` keys), which is exactly why the boundary fallback — not the sweep —
is the closure proof. A raising `Inspect` impl never escapes `inspect/1` on modern
Elixir (it yields the `#Inspect.Error<…>` diagnostic); the guarded regions' raise arm
protects against OTHER raise sources, and throw/exit are the escape kinds the static
fallbacks actually serve.

**The served error call is NOT end-to-end resource-bounded** (declared, deliberately
narrow): `content[0]`'s pinned byte-identical legacy inspect renders hostile terms
in full, once per call (shared by tier 4's message — the structured machinery adds
only budgeted work, and the single-render pin is scoped to boundary CONTENT
PRODUCTION); the dep's default `:full`-telemetry span runs `Error.to_map/1`'s
unbounded transport sanitizer on every error result upstream; with error logging
enabled the dep's per-attempt `cond_log_error` renders `safe_inspect(error)` with
unbounded inspect options on EVERY failed attempt (a retried hostile error renders
once per attempt before the boundary ever runs); and tier 3's dep-parity adaptation
runs the same `to_map/1` — an unbounded traversal that ALSO renders at
`limit: :infinity` twice over: detail KEYS as transient sort keys (discarded — a
bignum key reaches the walker intact and takes its constant `<<key:bigint>>`
marker) and UNSUPPORTED detail values via the sanitizer's `safe_inspect` (the
walker then byte-charges the resulting string) — plus `retryable?/1`'s single-path
nested-reason hint walk (dominated by the former). All inherent to jido_action on
this path; a boundary-side replacement was drafted and reverted (it cannot change
path complexity, and it broke to_map parity — message projection is the one arm
the boundary CAN bound without parity loss). The promptness tests are therefore
boundary-scoped (direct `error_response/2`) by design and say so.

The scan deadline directly bounds traversal, compilation, and local regular-file
processing. Remote and mount-backed `Resolver` reads still rely on each backend's own
I/O timeout/cancellation contract; they are post-read byte-capped but are not made
interruptible by the traversal loop itself.

## Source map

- `lib/jido_claw/core/mcp_server.ex` — the served tool set, `server_info/0`,
  `server_instructions/0` (the error-contract stability sentence)
- `lib/jido_claw/core/mcp_server/surface_version.ex` — the stability contract,
  `app_version/0`, bump rules
- `lib/jido_claw/core/mcp_server/error_codes.ex` — the closed code registry
  (families, docs, stability sentence)
- `lib/jido_claw/core/mcp_server/error_boundary.ex` — unwrap tiers, the typed
  `WireError` split + reserved overlay, registry enforcement, reduction tiers,
  the guarded region
- `lib/jido_claw/core/json_safe.ex` — the budgeted walkers backing the boundary
  (bignum width charge, calendar fast-path gate, key-prefix clamps, option
  normalization)
- `lib/jido_claw/core/jido_mcp_runtime_patch.ex` — the runtime copy routing the two
  error arms through the boundary + minting/threading the wrap-provenance token
- `lib/jido_claw/core/jido_exec_patch.ex` — the compile-time `Jido.Exec` fork
  generator (pins, hunks, helper block, verify/regenerate core)
- `lib/jido_claw/core/dependency_patches.ex` — the fork's install authority
  (boot force-load inventory, `{Jido.Exec, :jido_action}`; escript archives —
  where `File.exists?` cannot see — fall back to the archive-aware code
  server, sound because prod relocation leaves exactly one, patched, copy)
- `lib/mix/tasks/compile.jidoclaw_release_patches.ex` + `mix.exs` (`compilers/0`
  ordering, `escript/0` `app: nil`) — the every-compile verification/regeneration
  owner that determines which `Jido.Exec` BEAM actually ships, and prod relocation;
  its `run/1` returns the fork compile's converted diagnostics
- `lib/mix/tasks/jidoclaw.compile_check.ex` — the hand-sequenced warnings gate:
  reruns the release-patches compiler before `compile.app`, routes both diagnostic
  sources through one allowlist split, and self-asserts the fork artifact
  (`assert_exec_fork!/2`)
- `lib/jido_claw/core/mcp_server/resources/` — catalog, per-stage template,
  meta-version, bootstrap resources (incl. the `error_contract` block)
- `lib/jido_claw/tools/search_code.ex` — bounded traversal, compile tasks, match limits
- `lib/jido_claw/tools/file_payload_limit.ex` — regular-file + byte preflight
- `test/jido_claw/core/mcp_server/served_surface_golden_test.exs` — the golden guard
  (incl. `error_codes_by_family`)
- `test/jido_claw/core/mcp_server/error_boundary_test.exs` — the wire exactness suite
- `test/jido_claw/core/mcp_server/error_codes_sweep_test.exs` — the supplemental
  AST lint
- `test/jido_claw/core/jido_exec_patch_test.exs` — both packages' drift pins, the
  runtime-fork parity reconstruction, fork marking semantics, raise-path frame
  fidelity, the incremental-build ownership rows (incl. the diagnostics-capture
  red path and the `compilers/0`-chain pin), the license/CLI/escript pins
- `test/mix/tasks/jidoclaw_compile_check_test.exs` — `assert_exec_fork!/2`
  fixture rows at both env owners (tmp lib dirs only, never the live build), the
  captured-map → `Diagnostic` conversion, the allowlist split
- `test/jido_claw/core/dependency_patches_test.exs` — the patch-inventory
  membership pins
- `test/jido_claw/core/json_safe_test.exs` — the budget-contract rows (clamps,
  bignum charge, calendar gate)
- `test/fixtures/mcp_surface/served_surface.json` — the committed surface
