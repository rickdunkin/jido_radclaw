# Features Worth Borrowing from pad

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-04** (the
pms corpus's sixth dig, [DIG-BRIEFS.md](../DIG-BRIEFS.md) — scoped there as "pattern
notes, at API-surface freeze"; run early as a full dig because argus implementation is
beginning and pad's headline material feeds the surfaces argus builds first). Source:
`~/workspace/research/pms/pad` (PerpetualSoftware/pad — "Project management for the
agent era": a single-binary PM substrate that external agents drive via CLI, a
natural-language `/pad` skill, and MCP; it deliberately has **no run engine** — the
agent executes procedures itself). Pinned: pad @ `bcc4a69` (2026-07-04 — **15 commits
past the scan pin `4429af5`**, an email-verification + restricted-owner/auth-perimeter
sprint; repo refreshed pre-dig), jido_radclaw @ `609350aa`. Cites are firsthand reads
of both trees, accurate to within a few lines. Shape: Go 1.26 ~195k LOC across 553
files (`internal/server` 74k, `store` 42k, `mcp` 26k) + SvelteKit/Svelte 5 ~89k;
chi + modernc-SQLite/pgx dual backend (71 SQLite migrations vs 49 squashed-baseline
Postgres — Postgres is second-class), mcp-go, ory/fosite, gorilla/websocket. Maturity:
**915 commits in ~3.5 months** (2026-03-22 → 2026-07-04, active the day of the dig),
solo (xarmian 886/915 + dependabot), GitHub releases (v0.8.0 scan-era; no in-repo
CHANGELOG), real CI matrix (SQLite+Postgres+race, govulncheck, golangci-lint,
svelte-check). License: Apache-2.0 (clean for code lifts). Nothing was built or
executed this review — all claims are code reads. The repo is heavily dogfooded
(commits and regression tests are named by its own refs: `TASK-1932`, `bug985_test.go`;
CLAUDE.md cites `PLAN-…` items as design history), and in-repo drift was found while
reading — headliner: the MCP handshake `instructions.md` still describes the **v0.4**
tool surface while the code serves **v0.7** (three stale sites), the exact rot its own
version-constant discipline exists to prevent. Calibrate trust accordingly, both ways:
shipped mechanics below were verified against code, not docs.

Companion docs: [../README.md](../README.md) (the pms scan this corrects — five
claims), [../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) +
[../../argus/FLOW.md](../../argus/FLOW.md) (the seam map every entry lands on),
[../../ades/traycer/FEATURES-WORTH-BORROWING.md](../../ades/traycer/FEATURES-WORTH-BORROWING.md)
(TR1-1/TR1-2 — the *enforcement* half of the surface-versioning story; pad supplies
the *advertisement* half, and PD1-1 merges with the queued TR1-2a golden test),
[../multica/FEATURES-WORTH-BORROWING.md](../multica/FEATURES-WORTH-BORROWING.md) +
[../bosun/FEATURES-WORTH-BORROWING.md](../bosun/FEATURES-WORTH-BORROWING.md) (MC1-2 +
BO1-4 — the FLOW §7 task-schema reading list PD1-3 joins), and
[../../camus/FEATURES-WORTH-BORROWING.md](../../camus/FEATURES-WORTH-BORROWING.md)
(C1-3 — the boundary-normalization posture PD1-2 is the tool-surface sibling of).
Threat-model weighting as always: personal tailnet — LLM-misbehavior containment and
leakage hygiene over external-attacker hardening.

**Structure note**: like the sibling digs, this doc adds a **"Dig-brief dispositions"**
section after the tiers (explicit answered/contradicted/absent per standing question)
plus the scan-corrections block mirrored into the corpus README.

## Determination (TL;DR)

**The complement, not a competitor — nothing to adopt as a dependency, and the field's
best agent-surface contract-discipline donor.** The scan's framing survives the dig:
pad is what a PM substrate looks like when agents are the primary users and the
product refuses to run them. Its whole execution layer is one HTTP handler that binds
arguments and returns a markdown body for the agent to execute — so runs, gates,
leases, and event-sourcing (everything argus keeps) are exactly what pad lacks, and
what pad has instead is discipline at the agent-facing boundary that we measurably
lack: a **versioned tool-surface stability contract** advertised in the MCP handshake
(with a paid-for lesson — enforcement is manual, and their own handshake instructions
rotted three versions behind the constant), a **closed-at-the-boundary error-code
taxonomy** with typed self-correction hints, a **bounded one-round-trip bootstrap**
payload with overflow counts, and a shipped **import-copy definition store** (library →
activate-copies → frozen snapshot; the auto-upgrade hook was built and then *removed*)
that field-validates FLOW §13 open item 1's leading candidate almost clause by clause.
The task-schema material is a strong slice-3 reference (workspace-global computed refs
so moves preserve numbers; a binary terminal classification whose poverty argues *for*
our seven kinds; an advisory-locked open-children completion guard) with one more
negative datapoint for the corpus: the `blocks` link type is completely inert. The §5
sweep closes at **subject 22 in its strongest form: pad contains no LLM integration at
all** — no generation layer exists, so no edit-gate could. Our-side embarrassment
surfaced by the seams pass: our MCP server advertises a hardcoded `version: "0.2.0"`
while the app is at `0.6.4` — we are already living pad's rot lesson, which makes
PD1-1 a do-today fix, not just an argus item.

| Part of pad | As a dependency | What to take |
| --- | --- | --- |
| MCP/CLI/cmdhelp contract layer | No | **The stability contract** (PD1-1): version constants + 4 advertisement surfaces + bump-rules-as-doc-comment + the enforcement-is-manual lesson; merges with traycer TR1-2a |
| MCP error layer | No | **Closed-at-the-boundary code set** + typed hint fields + versioned stderr marker (PD1-2) |
| Items/refs/status core | No — argus tasks are native Ash (FLOW §7) | **Task-schema reference** (PD1-3): computed workspace-global refs, terminal classification, open-children guard, inert-`blocks` negative |
| Playbooks/library/artifact | No | **Import-copy seam validation** (PD1-4): activate-copies, frozen snapshots, removed auto-upgrade, portable artifact format with provenance |
| Bootstrap + skill conventions | No | Bounded bootstrap w/ overflow counts, metadata-not-bodies, `needs_onboarding` offer-not-auto-run (PD2-1); curation rubric (PD2-4) |
| SSE/collab live layer | No | Catch-up + leakage-hygiene deltas for argus slices 1/3 (PD2-2); collab machinery TRACKed (PD3-2) |
| Auth perimeter | No | The wreck-survey checklist — third negative reference for argus §4.4 (PD2-3) |
| Go store / web UI / cloud tier | No | Nothing structural |

## Why not adopt as a dependency

1. **The task-layer decision is already made, natively.** FLOW §7 (answering pms
   observation 6) makes tasks a first-class Ash resource with argus as source of
   truth, bound to threads/worktrees/gates/audit. Running pad as the board would put
   the central PM entity outside tenancy, `AgentCase`, and the event-sourced spine —
   the exact two-sources-of-truth trap the corpus documented (bosun's deleted sync
   engine, BO1-4).
2. **Wrong persistence and authz plane.** pad brings its own users, sessions, RBAC,
   and SQLite-first store (Postgres second-class: 49 squashed migrations vs 71;
   store-layer quirks like the ref-uniqueness index created in Go, not a migration —
   `internal/store/store.go:897`). Integrating means bridging identity and audit
   twice across systems that each assume they own both.
3. **Its multi-node story is behind ours on the one axis argus exists for.** Yjs
   collab is single-instance by design (`MemoryOpBus` hardcoded, RedisOpBus an
   explicitly deferred IDEA — `cmd/pad/main.go:831-836`, `internal/collab/bus.go:78-86`)
   while the shipped k8s manifests advertise 2–10 replicas with no sticky routing;
   SSE caps and replay buffers are per-pod under Redis (`redis_bus.go:95-97`).
4. **No engine, by design.** Everything argus needs beyond the board — runs, gates,
   leases, durable events, placement — is deliberately absent here.

The honest inverse: as an **external tool over MCP**, pad works today config-only (an
`mcp_servers:` entry; the coderunner trial precedent). That is OQ-1's named trigger,
not a plan.

## How to read this document

Recommendation vocabulary per the corpus conventions (`docs/exploration/README.md`):
**BORROW-PATTERN**, **BORROW-REFERENCE**, **BORROW-RUBRIC**, **FOLD-IN**,
**INDEPENDENT**, **ALREADY-COVERED**, **TRACK**, **SKIP**. Initial inventory — no
Status lines. Tiers scoped to this codebase: **Tier 1** = clear gap, high leverage,
buildable against a shipped seam or a decided argus slice. **Tier 2** = valuable,
lands with a specific argus slice or an already-queued item. **Tier 3** = garnish or
tracked. IDs `PD<tier>-<seq>`; `S-n` skips; `OQ-n` open questions. Every Gap claim
verified against jido_radclaw @ `609350aa` on 2026-07-04.

---

## Tier 1 — High Impact

### PD1-1. The served-surface stability contract — advertised versions, bump rules, and the rot lesson

**Recommendation**: BORROW-PATTERN, with a **do-today slice** that merges with the
queued traycer TR1-2a golden test (next-ten #6 rider). Pad supplies the
*advertisement* half of surface versioning; traycer supplies the *enforcement* half;
each is incomplete alone — and both trees prove it (see the rot evidence on both
sides below).

> **Status: ✅ ADOPTED 2026-07-06** (folded into next-ten #6 per the
> superseded TR1-2a rider — the fused advertisement+enforcement PR, exactly
> this entry's do-today slice). Sketch items (a)–(e) shipped whole:
> `JidoClaw.MCPServer.SurfaceVersion` (`current/0` = `"1.0"`, bump rules +
> in-file changelog in the moduledoc — the doctrine line (e); also the
> single-sourced `app_version/0` accessor); `server_info/0` hand-defined
> over `Application.spec(:jido_claw, :vsn)`, killing the stale `"0.2.0"`
> (the `use`-opt version demoted to an inert non-nil `"0"` — anubis's
> `maybe_define_server_info` force-generates a duplicate def on a nil); the
> `jido://_meta/version` resource
> (`{app_version, surface_version, tool_count}`); `app_version` on
> `project_info`; and the golden — `served_surface_golden_test.exs` +
> committed `test/fixtures/mcp_surface/served_surface.json`, set-comparing
> tool names, static resource URIs, template URIs, and the version string
> **per enumeration surface** (never counts), with the ready-to-commit regen
> JSON printed on mismatch — so a surface change without a deliberate bump
> fails precommit, closing the enforcement hole pad left open. The PD2-1
> slim bootstrap rode the same plumbing (see PD2-1's Status).

**Where in pad**: `internal/mcp/version.go:41,139` — two decoupled constants
(`CmdhelpVersion = "0.1"` for the CLI help-tree contract, `ToolSurfaceVersion = "0.7"`
for the MCP catalog contract; "two contracts, two version constants", `:35`), each
with bump rules and a **full v0.1→v0.7 changelog as doc comments** (`:50-139` — v0.2
retired the auto-generated ~85-tool cmdhelp leaf-walker for a hand-curated catalog;
v0.4 was a 40% bootstrap-payload trim whose one breaking type change is called out;
v0.7 is current). Advertised on **four surfaces**: the MCP initialize handshake under
`capabilities.experimental.padCmdhelp/.padToolSurface` (`meta.go:131-142`, wired
`server.go:65`), a `pad://_meta/version` resource (`meta.go:54-65` —
`{pad_version, cmdhelp_version, tool_surface_version, tool_surface_stable,
mcp_protocol_version}`), a `pad_meta` tool action (`catalog_meta.go:105,152`), and
REST `GET /api/v1/mcp/tool-surface` (`tool_surface.go:198,218`). **Enforcement is
manual and it shows**: the only test is self-referential (emitted string == constant,
`tool_surface_test.go:47-51`; no golden fixture anywhere), and the handshake
`instructions.md` served to every client still describes the **v0.4** surface — eight
tools, `pad_library` omitted entirely — against a v0.7 code reality (`instructions.md:9-11`,
plus stale copies at `cmd/pad/mcp.go:225-230` and `catalog_meta.go:60,66,132`);
`tool_surface_stable` is hardcoded `true` (`meta.go:62`).

**What**: declare the agent-facing surface a versioned contract; advertise the
version where consumers already look (handshake + a meta resource); document bump
rules and history *next to the constant*; and — the lesson pad paid for — make the
bump mechanical, because a version constant without a golden pin rots, and prose
descriptions of the surface kept far from the bump site rot faster.

**Gap in jido_radclaw** (verified 2026-07-04): we are the rot lesson already. The
served MCP surface advertises a hardcoded `version: "0.2.0"`
(`lib/jido_claw/core/mcp_server.ex:14`) while the app is at `0.6.4` (`mix.exs:4`) —
stale and decoupled, and asymmetric: the MCP *client* side advertises the real vsn
(`lib/jido_claw/mcp/endpoint_config.ex:264-266`). No version rides the catalog or
per-stage resource payloads (`workflow_catalog.ex:45`, `workflow_stage.ex:40`; the
`%Stage{}` struct has no version field) and `project_info` returns no version at all
(`tools/project_info.ex:33-42`). A tool-**count**+presence guard exists
(`test/jido_claw/mcp_server_test.exs:69,72-131`) but the version assertion is
`is_binary` only (`:49-53`) and nothing freezes the name set or resource URIs —
TR1-2a remains queued, unbuilt. *(Connective note, 2026-07-04 pass: the rot lesson
got its same-day second instance — myrlin's QR-pairing endpoint ships 429-broken at
HEAD with the asserting test present but not gating releases
([myrlin dig](../myrlin-workbook/FEATURES-WORTH-BORROWING.md)); enforcement, not
advertisement, is the load-bearing half. README observation 13 makes it law (a).)*

**Why it matters**: editor MCP clients already consume this surface (the
MCP-only-by-design tools, the `jido://workflows/*` resources), and argus multiplies
deployed-contract surfaces (GraphQL, Channels, the sandbox MCP endpoint of FLOW §4)
consumed by clients we don't redeploy in lockstep. Our house fingerprint idiom
(`orchestration/definition_fingerprint.ex:78-106`) already encodes the right style
for "what changed" honesty; this extends it to the served surface.

**Adoption sketch** (one PR, ~2h, no argus dependency — supersedes the standalone
TR1-2a rider): (a) derive `serverInfo.version` from `Application.spec(:jido_claw,
:vsn)` — kill the hardcoded `"0.2.0"`; (b) add a `SurfaceVersion` constant (start
`"1.0"`) with pad-style bump-rules + changelog doc comment; (c) publish a
`jido://_meta/version` resource (`{app_version, surface_version, tool_count}` — the
house resource machinery makes this ~20 lines) and add `app_version` to
`project_info`; (d) the golden test: a committed fixture holding the sorted tool-name
list + resource URIs **+ the surface-version string** — any catalog change forces a
fixture regen, and the regen diff shows whether the version moved with it (closing
the enforcement hole pad left open); (e) doctrine line in the module doc: prose
descriptions of the surface live next to the constant, never in distant docs (the
`instructions.md` lesson).

### PD1-2. Closed-at-the-boundary error codes + typed self-correction hints

**Recommendation**: BORROW-PATTERN — scoped to the served surface; not a global
registry. The tool-surface sibling of camus C1-3's judge-boundary normalization
(same move: an open interior, a closed contract at the trust boundary).

**Status (2026-07-12): ✅ ADOPTED** — pre-argus Wave E #16
([plan](../../../plans/pre-argus-wave-e-16/README.md); done-when in
[PD-FIRST-WAVE item 2](PD-FIRST-WAVE.md)). Sketch (a)–(d) shipped with the
build's sharpenings: 51 registered codes (8 families,
`JidoClaw.MCPServer.ErrorCodes` — the "~25 atoms" estimate undercounted HEAD's
48 literals), boundary ENFORCEMENT (the pad two-classifier funnel became
`ErrorBoundary`'s unregistered-code → `tool_error` + `details.unregistered_code`
fallback on an additive `content[1]` JSON envelope, surface v1.3) with the AST
sweep demoted to supplemental lint, `hint_available`/`hint_expected` typed
details, and the stability sentence on `server_instructions` +
`jido://bootstrap`. The versioned-stderr-marker leg was NOT taken (our
subprocess boundary is jido_mcp stdio, not a CLI relay). →
[docs/system/mcp-server-surface.md](../../../system/mcp-server-surface.md)

*Amendment (2026-07-13)*: a post-review round corrected the boundary's tier-1
provenance — "the exact `Jido.Exec` wrap of a canonical envelope" was inferred
from a forgeable native-error SHAPE (the wrap is lossy; a hand-built
`ExecutionFailureError` carrying `:code`+`:details` mis-tiered into tier 1 and
reported the nested code as the domain code). Now WITNESSED through a
compile-time-generated fork of jido_action 2.3.1's `Jido.Exec`: the map-wrap
arms stamp an opt-gated per-call ref (only for pre-wrap canonical envelopes),
the boundary detaches it on exact ref identity, and tier 1 requires the
witness. Semantics map, signed before code:
[PORT-PD1-2-EXEC.md](PORT-PD1-2-EXEC.md).

**Where in pad**: `internal/mcp/errors.go:43` — `ErrorCode` is a **closed set of 15**
(`no_workspace, unknown_workspace, auth_required, permission_denied, item_not_found,
not_found, validation_failed, conflict, workspace_required, backend_unreachable,
upstream_error, server_error, open_children, rate_limited, plan_limit_exceeded`,
`:45-152`), documented "do not introduce a new code without updating the docs" and
"stable across versions" (`:166`). The interior is open — the HTTP layer has 40+
free-string codes and the CLI passes them through verbatim
(`internal/cli/client.go:993-997`) — closure happens **at the MCP boundary** via two
classifiers (`classifyExecError` `:424`, `classifyHTTPStatus`) that funnel everything
into the 15, plus a two-code whitelist (`allowedStructuredErrorCodes :359-362` =
`open_children, plan_limit_exceeded`) for structured pass-through, enforced
identically on both transports ("keeps the ErrorCode enum's closed-contract honest…
a TWO-WAY change", `:339-354`). The envelope carries **typed hint fields** —
`hint`, `available_workspaces`, `field/expected/got`, `required_role/current_role`
(`:158-204`) — machine-usable self-correction data, not prose. Structured errors
cross the subprocess boundary on a **versioned stderr marker line**
(`pad-structured-error/v1: `, `client.go:1056`, lockstep-comment `:1052`;
last-marker-wins extraction `errors.go:380`).

**Gap in jido_radclaw** (verified 2026-07-04): the envelope is normalized
(`tools/error.ex:80-88`, `%{code, message, details}`) but the code set is **open** —
any atom a tool invents becomes a code (`error.ex:173-179,119-122`); the only closed
mappings are local (`struct_code/1 :191-202`, `code_from_value/1 :397-403`), and the
nearest thing to an enumeration is LoopGuard's skip list
(`agent/loop_guard.ex:140`). No stability promise anywhere; hints are prose
(`message`) — the LoopGuard recovery directives are our only machine-shaped
self-correction channel.

**Why it matters**: MCP clients pattern-match our codes today (the house memory about
`Error.normalize_result` turning `{:ok, %{status: "failed"}}` into an error exists
*because* a consumer tripped on envelope semantics), and both retry layers key on
code identity. An enumerated served-surface set with a subset test makes those
contracts checkable; typed hint fields give the LLM caller a self-correction path
that doesn't require parsing prose.

**Adoption sketch**: (a) enumerate the served-surface code families in one module
attribute (approval, doom_loop, lua_*, sandbox_*, tenant_required, replay/workflow,
plus the normalizer's struct codes — ~25 atoms); (b) a test sweeping tool modules
(or observed test-run envelopes) asserting emitted codes ⊆ the registry — new codes
join deliberately, in the same diff as their docs; (c) stability sentence in the
served tool descriptions; (d) adopt the typed-hints shape inside `details` for the
common cases (`expected/got` on validation, `available` on unknown-name lookups) —
generalizing the LoopGuard-directive precedent. Scope: served MCP first (OQ-2 for
the REST surface); interior atoms stay open — this is a boundary contract, not an
internal enum.

### PD1-3. Task-schema reference: computed global refs, terminal classification, and the open-children guard

**Recommendation**: BORROW-REFERENCE for FLOW §7's slice-3 schema review — joins
multica MC1-2 (field mechanics) and bosun BO1-4 (task-store lessons) on that reading
list, adding the ref mechanics and completion-guard shapes neither had.

**Where in pad**: refs are **computed, never stored** — `Ref =
fmt.Sprintf("%s-%d", CollectionPrefix, ItemNumber)` (`internal/models/item.go:87-91`,
`:24`), with the counter **workspace-global, not per-collection**: allocation is a
`MAX(item_number)+1` subquery inside the INSERT (`internal/store/items.go:205`),
retried ≤10× on unique-violation (`:63,141-151`), serialized by a Postgres advisory
lock keyed on workspace (`:172`) / SQLite `BEGIN IMMEDIATE` (`store.go:84-108`).
The global space is deliberate: **a collection move preserves the number and changes
only the prefix** ("IDEA-42 → BUG-42", `items.go:3173-3176`) — refs survive
reclassification. Status semantics are two-level: per-collection custom statuses
(options of a `status` select field) plus a system **terminal classification** —
per-field `TerminalOptions` with fallback `DefaultTerminalStatuses` (`done, completed,
resolved, cancelled, rejected, wontfix, fixed, implemented, archived, disabled,
deprecated`, `models/terminal.go:21-24`; done-field resolution `:49`,
`multi_select` explicitly rejected `:38-44`) — and system behavior binds to the
classification, not the status: reports, transition seeding, and the **open-children
completion guard** (IDEA-1494): a non-terminal→terminal transition is prechecked
against non-terminal children (`parent`/`implements` links, `items.go:18`) inside the
write tx under a per-parent advisory lock (`:1609,1658`), with an explicit `Force`
override (`models/item.go:593`). Parent links are cycle-checked (`items.go:2519`).
The negatives are as instructive: `blocks` is **inert** — no computed blocked state,
no release semantics, nothing consumes it (`item_lineage.go` ignores it; grep-clean);
and the `status_transitions` table (`migrations/063`, seq tiebreak `065`, written in
the same tx as the item write) carries **no actor columns** — provenance lives on the
item (`created_by`, `last_modified_by`, `source`) and the `activities` feed, not the
transition row.

**Gap in jido_radclaw** (verified 2026-07-04): no task resource exists
(`Projects.Project` is metadata-only, `projects/project.ex:72-102`, and deliberately
global/no-tenant `:58-70`); the only ref minting is random
(`refs.ex:21-24` — 12 random bytes, unguessable by design, the opposite goal); the
house allocator idiom for a future sequential ref is already shipped —
`Conversations.Message`'s `AllocateSequence` (`UPDATE … SET next_sequence =
next_sequence + 1 … RETURNING`, row-locked on the parent,
`conversations/resources/message.ex:517-560`) — a cleaner shape than pad's
MAX+1-with-retries.

**Why it matters**: FLOW §7 committed to tasks with per-project statuses + semantic
kinds + computed blocked. Pad adds to that design's evidence base: (a) the
ref-mechanics reference, including the move-survival argument for counter scope;
(b) the binary-terminal counterexample — pad's single terminal/non-terminal axis
forces literal coupling downstream (standup hardcodes the string `in-progress`,
`handlers_project_intel.go`), which is precisely the failure our seven-kind enum
avoids; (c) a shipped completion-guard shape (kind-transition precheck + explicit
force) for §7's completion detection and §10's landing checklist; (d) the corpus's
**third** dead-dependency datapoint (multica's dead `issue_dependency` table, pad's
inert `blocks`, vs orca's real queue-then-release) — dependencies that only display
never get wired; if argus ships task dependencies, ship the release semantics with
them or not at all.

**Adoption sketch** (at slice 3, with MC1-2/BO1-4 open): refs = per-project prefix +
project-scoped counter via the `AllocateSequence` idiom, computed on read (never
stored); numbering scope is OQ-3 (pad's global-space motive — cross-collection moves
— maps weakly to cross-project moves we'll likely forbid); the open-children guard
becomes a kind-transition precheck (a `done`-kind move with non-terminal children
requires explicit force) implemented as an Ash change on the transition action;
provenance goes **on the transition row** (actor kind + surface), not beside it —
pad splits fact from actor across two tables and the scan mis-read it as one; our
`Audit.Event` vocabulary (`user/agent/system`, `audit/resources/event.ex:37`) plus a
`workflow` value is the starting enum.

### PD1-4. The import-copy definition store, frozen snapshots, and the portable artifact format

**Recommendation**: BORROW-PATTERN — and immediate validation for FLOW §13 open
item 1 (the workflow YAML seam), whose leading candidate pad ships nearly clause by
clause. Hardens this session; build lands with the argus workflow store (FLOW §9).

**Where in pad**: the canonical library is **compiled into the binary and read-only**
(`internal/collections/playbook_library.go:37-76`; retired entries stay compiled but
unsurfaced, `playbook_library_archive.go`); **activate = import-copy** — `pad library
activate` POSTs the *current* library body as a **new workspace item**
(`dispatch_http_library.go:71-91`); workspace copies are **snapshots frozen at
creation** — the startup auto-upgrade/backfill hook was built and then **removed**
(IDEA-1479: "incompatible with templates that intentionally diverge…future changes…
should be implemented as explicit migrations", `cmd/pad/main.go:397-402`), so
canonical improvements never overwrite local adaptations and drift is an accepted,
documented state closed by explicit re-import. Seeding is idempotent by title, at
workspace creation only (`store/collections.go:496-501,586-588,640-645`). The
adaptation posture is doctrine in the shipped onboard playbook: "**ADAPT, DON'T
CURATE** … every library entry … is a STARTING POINT" (`playbook_library_onboard.go:57`).
Cross-workspace portability is a versioned **artifact format** — `FormatVersion = 1`,
YAML frontmatter + markdown body, kinds `playbook | convention`, frontmatter carrying
status/trigger/scope/args plus a **provenance block** (`internal/artifact/artifact.go:1-24,
56-59`, golden files in `testdata/`); export is per-item-visibility-gated, import is
editor-gated with a 1 MiB cap (`server.go:1365,1255,158-164`). One wart worth
avoiding: the artifact vocabulary drifted from the live collection schema
(`trigger: on-intent` / `scope: workspace` in goldens vs `manual`/`all` in the
schema) — their portability layer grew its own dialect.

Contrast inside the same subsystem: the playbook "lifecycle" is **not** a lifecycle
machine — `draft/active/deprecated` is a plain status select field, mutable in place,
no versioning, no transition rules (`templates.go:370-377`; slug routing dispatches
only `status=active`, SKILL.md:185). That is safe for pad **because nothing executes
playbooks** — the moment an engine consumes definitions (replay, pinned runs), you
need immutability. The asymmetry is the insight, not a contradiction.

**Gap in jido_radclaw** (verified 2026-07-04): FLOW §13 item 1 is exactly this seam,
explicitly undecided ("decide by slice 3 or slice 7"); our definition stores are
file-based with no lifecycle (`.jido/skills|strategies|pipelines/*.yaml` via
`YamlStore`, `reasoning/yaml_store.ex`); FLOW §9 already commits to immutable-append
versions — the right call, and pad's mutable-in-place model is the confirming
counter-datapoint per the asymmetry above (our replay gates assume pinned
definitions: `definition_fingerprint.ex:78-106`, `replay.ex:205-219`). Our nearest
canonical-vs-local mechanism is the `system_prompt.md` manual-sync chore, which
already grew a drift-marker + advisory check task
(`agent/subagent_prompt.ex:13-15,31-36`; `mix jidoclaw.system_prompt.check`) — a
mid-spectrum answer between pad's frozen-snapshot and CC2-2's managed blocks.

**Why it matters**: FLOW §13-1's leading candidate ("read-only + one-click
import-copy, provenance recorded, independent thereafter, export = YAML download,
argus never writes into repos") now has a shipped implementation *and* the negative
result for its main alternative (auto-sync was built, hurt, and was removed). The
open item can harden to "decided, pending build" this session.

**Adoption sketch**: at the FLOW §9 store build — import = copy with provenance
recorded (source identity + content hash at import time; our `DefinitionFingerprint`
is the hash), never auto-synced, re-import explicit; export = the artifact shape
(format_version + provenance frontmatter over the YAML body), with the vocabulary
**single-sourced from the live schema** to dodge pad's dialect drift; a
`draft/active` status governs *binding eligibility* (automations only fire active
versions — pad's slug-routing-requires-active, transplanted) and composes with, not
replaces, immutable versioning.

---

## Tier 2 — Valuable, lands with a named slice or queued item

### PD2-1. The bounded bootstrap: one round-trip of agent context, with overflow honesty

**Recommendation**: BORROW-PATTERN — lands with the served-surface work or FLOW
slice 6's sandbox MCP endpoint, whichever comes first.

> **Status: ✅ ADOPTED 2026-07-06 — the slim cut, riding PD1-1's plumbing**
> (next-ten #6; the served-surface work came first, as this entry predicted).
> `jido://bootstrap` serves app+surface versions, sorted tool names + count,
> and a tenant block: identity (tenant/workspace/session/project_dir),
> pending-gates count, and `active_runs`/`recent_completions` **capped at 5
> with `*_overflow_count` fields from a cap+1 read** (documented "≥1 means
> more exist, not a total" — the overflow-honesty rule, bounded to one extra
> row rather than a COUNT query). Two honesty postures beyond pad's shape:
> an unresolvable MCP scope reads `available: false` with a reason (never a
> fabricated empty snapshot), and a failed read inside a resolved tenant
> flips that block's `*_available: false` flag — never a zero (the
> deliberate inversion of the dashboard rollup's degrade-to-zero). Run rows
> are `Visibility.run_view` projections, so completions carry the #6
> `disposition` automatically. The slice-6 extension (per-token tool
> allowlist view) stays queued, as does `needs_onboarding` (no onboarding
> concept here yet).

**Where in pad**: one payload (`GET /api/v1/workspaces/{ws}/agent/bootstrap` ≡ the
`pad://workspace/{ws}/bootstrap` resource ≡ embedded in the `pad_set_workspace`
response) returns workspace + user + collections + always-on conventions + roles +
playbook **metadata** + dashboard + `needs_onboarding`
(`handlers_bootstrap.go:283-298`). The discipline is what to leave out: playbook
bodies are excluded (5-10KB each; the agent fetches on invoke — `:277-279`),
projections are slimmed (v0.4 dropped UUIDs/timestamps/settings for ~40% off), and
the dashboard sub-arrays are **capped at 5 with parallel `*_overflow_count` fields**
— bounded payloads that still say what they dropped. `needs_onboarding` is an
EXISTS-backed predicate (any item with `source != 'template'`,
`store/items.go::WorkspaceHasUserCreatedItems`) rendered as an **offer, not an
auto-run** (SKILL.md:39).

**Gap in jido_radclaw** (verified 2026-07-04): no bootstrap surface — an MCP client
orients by composing `project_info` (thin: cwd/branch/dirty,
`tools/project_info.ex:33-42`) + `workflow_status` + resource reads across
round-trips; nothing reports capabilities/version/identity in one read (PD1-1's
`_meta/version` is the first sliver). The no-silent-caps rule already exists here as
Workflow-tool doctrine ("if a workflow bounds coverage, log what was dropped") — pad
applies the same rule to payload shaping.

**Why it matters**: FLOW §4/slice 6 mints per-thread sandbox MCP tokens; a session's
first read should be one bootstrap (identity, allowed tools, workspace context,
pending-gate count, capped recent activity). Editor clients get the same win today.
The metadata-not-bodies split maps directly onto skills/strategies (names +
descriptions in bootstrap; bodies on use).

**Adoption sketch**: a `jido://bootstrap` resource (tenant-scoped; app+surface
version, tool names, workspace identity, pending gates count, recent runs capped
with overflow counts). Ride PD1-1's PR for the resource plumbing; extend at slice 6
with the per-token tool allowlist view.

### PD2-2. Live-layer deltas: gap signals, mid-stream re-authz, and broadcast leakage hygiene

**Recommendation**: BORROW-REFERENCE for argus slices 1/3 (Channels layer). Our
durable spine supersets pad's catch-up; four delivery-layer details are worth
carrying anyway.

**Where in pad**: two-tier catch-up — an ephemeral per-workspace replay ring
(1024 events / 5 min, `events/bus.go:50-51`) behind `Last-Event-ID`, with an explicit
**`sync_required`** control event when the cursor predates the ring
(`handlers_events.go:169-201`), layered over a **durable** per-workspace monotonic
`seq` cursor + `/items-changes` delta endpoint (`053_items_seq.sql`; bumped on every
mutation). Events are fat metadata (ids + type + actor + seq), never full resources.
The hygiene details: **bulk events deliberately carry no per-item IDs** — a broadcast
bus can't apply per-grant visibility filtering, so IDs would leak hidden items;
clients reconcile through the visibility-filtered delta endpoint instead
(`bus.go:79-92`); **per-connection authz is re-validated every 60s mid-stream**
(fresh user fetch + visibility recompute — demotion/revocation closes or narrows the
stream within a tick, `handlers_events.go:272-306,384-513`); and the keepalive
interval is a **process-start invariant** against the HTTP idle timeout
(`3 × keepalive < idle_timeout`, `handlers_events.go:29-36`).

**Gap in jido_radclaw** (verified 2026-07-04): argus §4.2 already specifies durable
catch-up (`workflowEvents(afterSeq:)` over the append-only log — stronger than pad's
ring) and minimal channel payloads; what's unbuilt is the Channels layer itself
(PubSub is LiveView-consumed only, `run_pubsub.ex:17-27`; the only SSE is chat
streaming, `chat_controller.ex:83`). Nothing today re-checks authz on a long-lived
subscription (LiveView sessions are operator-only, low stakes — argus channels and
the operator terminal raise them).

**Why it matters / take**: (a) an explicit `sync_required`-style resync signal for
any ring-buffered or retention-bounded topic — never let a client believe a silent
gap; (b) mid-stream re-authz as a rule for argus channel joins and the FLOW §11
terminal; (c) the no-IDs-on-mixed-visibility-broadcast rule — our single-operator
tenancy lowers the stakes, but the composer's multi-session topics should inherit it;
(d) the keepalive-vs-idle-timeout boot invariant, verbatim.

### PD2-3. The auth-perimeter wreck survey — argus §4.4's third negative reference

**Recommendation**: BORROW-RUBRIC (checklist, not code). Joins CCC's CSRF≠auth and
Xantham's model-inside-the-TCB as the third shape of the same lesson: single-author
perimeters fail on the dimension nobody re-checks.

**Where in pad**: two documented families, all fixed reactively within the drift
window this dig covers. The **restricted-owner family** (BUG-1920/1921/1922/1923/
1925/1928/1945): workspace role and collection-visibility are orthogonal dimensions,
and seven handlers gated on `requireRole("owner")` alone — letting a
visibility-restricted owner mint share links on hidden items, mutate hidden
collections, revoke grants by guessed ID, **escalate their own access mode**
(BUG-1925, "defeating the entire family in one request"), and exfiltrate via two
different export routes. The **B6–B9 audit** (commit `d36f27c`): a blanket CSRF
exemption on the entire `/auth/*` prefix silently covering authenticated mutations
(fixed to an exact-path allowlist); an OAuth login minting 30-day sessions vs 7-day
web TTL; a deploy-time security contract (`PAD_CLOUD` without secure cookies)
promoted to a **startup error** (`config.go:334`); an error-swallow leaving orphaned
workspaces. Plus one positive pattern: **bearer-admin suppression** — platform-admin
authority works over cookie sessions only; every bearer credential class (PAT, OAuth,
CLI token) is attenuated to plain membership (`middleware_auth.go:485,616-621`), so a
leaked admin token never widens to every workspace.

**Gap / our side** (verified 2026-07-04): the structural answer is the one we
already have — centralized Ash policies rather than per-handler checks
(`project.ex:66-70`, tenant-match policies on audit/messages), and single-operator
tenancy keeps the orthogonal-dimension count low. The checklist still binds argus:
(a) when a second authz dimension appears (per-device keys, per-thread sandbox
tokens — FLOW §4), it enters the policy layer, never per-resolver checks; (b)
security exemptions are exact-path allowlists, never prefixes; (c) deploy-time
security contracts fail the boot, not the incident review (our config validation at
startup is the seam); (d) privilege attenuates by credential class — the FLOW §11
operator-terminal short-lived tokens and the standing API key should not be
interchangeable, which is exactly how FLOW already specifies them.

### PD2-4. The curation rubric and the one-dispatch-spine rule

**Recommendation**: BORROW-RUBRIC — thin, mostly confirming our shape; take the
prose and one consolidation datapoint.

**Where in pad**: the v0.1→v0.2 history is the datapoint — an auto-generated
~85-flat-tool surface walked from the CLI help tree was **retired** for a
hand-curated catalog (9 resource tools × 52 `action` enums + `pad_set_workspace`;
`registry.go:14-18`), and TASK-1916 later deleted the last parallel reimplementation
("three reproductions" → "**CLI + REST, MCP proxies to REST**" — MCP handlers became
validate-then-forward proxies, `dispatch_http_project.go:94-158`). The exposure
rubric is one sentence worth lifting near-verbatim (CLAUDE.md): *don't expose
interactive (prompts the user), destructive (mutates auth/filesystem state),
long-running (streaming watcher), or recursive (would spawn another MCP server)
commands.* All three agent surfaces (skill→CLI→REST, stdio-MCP→CLI, remote
MCP→in-process REST) converge on one handler chain.

**Gap / our side** (verified 2026-07-04): we already conform structurally — the 26
served tools are hand-enumerated (`mcp_server.ex:16-66`), the MCP-only-by-design
trio shows the same curation instinct, and served tools share the `Tools.Action`
pipeline (one spine). The external-MCP proxy layer is the surface that *bypasses*
curation by design (remote `inputSchema` pass-through) — its guardrails are the
approval gate + templates allowlist, a deliberate trade already documented in
AGENTS.md. Take: the rubric sentence into the MCP server module doc for the next
tool addition; the resource×action consolidation as the known answer if the flat
list ever pressures client tool budgets (pad went 85→9; we're at 26).

---

## Tier 3 — Garnish and tracked

### PD3-1. `init` as a state-derived doctor, not a wizard

**Recommendation**: INDEPENDENT (S). `pad init` re-derives each of its six steps
from live state (configured? server up? admin exists? authed? workspace linked?
skills installed?) and acts only on what's missing, printing a status summary when
nothing is (`cmd/pad/init.go:83-320`, "safe to re-run anytime" `:44`) — no marker
files. Our setup is a first-run wizard gated by `needed?/1` whose re-run **replaces
`config.yaml` wholesale** (`cli/setup.ex:16-34,66-68`). Adoption: teach `/setup` the
doctor posture — per-step live checks (config, provider key via the shipped
`Config.check_provider/1` — the XA2-3 canary — voyage key, DB migrated), act only on
gaps, `--check` prints the derivation. Pairs naturally with FLOW §5's provisioning
lifecycle, which already commits to idempotent steps for worktrees.

### PD3-2. Collab machinery: schema-version fencing, force-refresh, designated applier

**Recommendation**: TRACK — named trigger: argus editors ever becoming
collaborative/CRDT-backed (deliberately not planned; §5.4's `expectedSeq` +
single-operator revisions is the chosen shape, with CC1-3's recovery-UX acceptance
criteria). When the trigger fires, pad is the reference stack: client announces a
schema version on every connect, mismatch = HTTP 400 + whole-op-log prune
(`handlers_collab.go:135-143`; ops are causally linked — never prefix-prune,
`manager.go:389-399`); a `force_refresh` control frame when a resume cursor predates
retention (`manager.go:220-238`) — the same "reconnect on major skew, never bridge"
rule traycer TR1-1 ships for streams, independently converged at the CRDT layer; the
**designated-applier** protocol routing REST writes through the longest-connected
tab during live co-edit (`applier.go`); and the exact-pin lockstep rule for the three
Tiptap packages whose minor drift silently forks the persisted doc shape
(CLAUDE.md). One line of it applies today: canonical content (`items.content`)
stays authoritative; the op-log is disposable — keep that split if we ever persist
editor-local state.

### PD3-3. Derived-closure lineage badges

**Recommendation**: FOLD-IN to the disposition-vocabulary conversation (next-ten #6
step 6, where traycer TR3-2's `superseded` already sits). Pad computes display-only
closure: an item pointed at by a terminal `supersedes`/`implements` link renders
closed-as-`superseded_by`/`implemented_by`, while `split_from` deliberately does
**not** auto-close (`internal/server/item_lineage.go:121-194`) — a small, shipped
vocabulary for "closed by relation, not by status" that the argus task layer's
kind/disposition design should at least name.

> **Status: ✅ FOLDED IN 2026-07-06 (named, as prescribed)** — next-ten #6
> shipped the `review_stall` kind, and the `Gate.Kinds` moduledoc now carries
> the disposition-vocabulary note naming this entry's lineage badges beside
> traycer TR3-2's `superseded` and bosun BO2-6's retry vocabulary, so the
> argus task-layer design inherits the reference. Machinery stays unbuilt by
> design (display-only closure needs the argus task layer to exist).

## Skip / Already Covered

- **S-1 Go store/dialect dual-backend** — SKIP; we are Ash+Postgres natively; pad's
  Postgres is the second-class citizen here (49 squashed vs 71 migrations).
- **S-2 FTS5/tsvector search** — SKIP; Postgres-native search lands when a consumer
  exists; nothing transferable in the wiring.
- **S-3 SvelteKit board UI / web components** — SKIP; argus is React+Apollo by
  decision (OVERVIEW §2.6).
- **S-4 Cloud tier (billing, Maileroo email, 2FA, OIDC sidecar)** — SKIP; no cloud
  tier planned; auth is AshAuthentication + tailnet (OVERVIEW §4.4).
- **S-5 Outbound webhooks** — SKIP (no consumer); its SSRF guard
  (resolve-then-reject private/metadata ranges) is ALREADY-COVERED by
  `Security.DestinationPolicy` (`destination_policy.ex:8-12,345` — resolver-injected
  `:inet.getaddrs`, private/v6/metadata blocks; verified 2026-07-04).
- **S-6 urlimport** — SKIP; `browse_web` + OutputShaper cover the fetch-and-bound
  path; the two converters are trivial.
- **S-7 Content-addressed attachments + orphan GC** — SKIP; `ToolOutput`/
  `ComposerArtifact` refs are our blob idiom; the grace-period orphan GC is noted in
  the teardown disposition below.
- **S-8 Conventions runtime injection** — ALREADY-COVERED for our topology: doctrine
  slices (11, compile-time, per-template — `doctrine.ex:108-196`),
  `.jido/system_prompt.md` (per-project, drift-marked), and the AGENTS.md ecosystem
  convention cover native agents with repo access. Pad's distinctive case —
  trigger-scoped rules served *through the tool surface* to pure-MCP agents with no
  filesystem — becomes relevant only if we serve third-party agents that way (same
  trigger as OQ-1's inverse).
- **S-9 Agent roles** — SKIP; descriptive-only ((user, role) labels, session-local,
  no enforcement); our worker templates + tenancy occupy this ground with actual
  semantics.
- **S-10 GitHub PR↔item link CLI** — SKIP; manual link storage + status display;
  FLOW §10 builds the real path (webhook auto-advance off task links) and the pms
  seams pass already flagged `PullRequestCoordinator` as scaffolding to build real.
- **S-11 documents-v1 API** — SKIP; their own legacy ("will be replaced by items in
  Phase 2", `server.go:1267`).

## Dig-brief dispositions

The standing questions from [DIG-BRIEFS.md](../DIG-BRIEFS.md) (pad section + the six
cross-cutting), each with a verdict:

1. **`tool_surface_version` + closed error-code taxonomy** — **ANSWERED** (PD1-1,
   PD1-2), with two sharpenings the brief didn't predict: enforcement of the version
   discipline is entirely manual and pad's own handshake instructions rotted to
   v0.4-vs-v0.7 (the lesson *is* the entry); the "closed" taxonomy is a
   boundary-classification layer over an open interior, not a global enum — which is
   exactly the right shape to copy.
2. **Playbooks-as-data lifecycle vs FLOW §9 immutable-append** — **ANSWERED,
   CORRECTED** (PD1-4): "draft/active/deprecated lifecycle" is a plain mutable status
   field, no versioning, no state machine. The real versioning story is the
   import-copy library with frozen snapshots and the *removed* auto-upgrade hook.
   Verdict for §9: keep immutable-append — pad's mutability is safe only because
   nothing executes playbooks; the asymmetry (version what engines consume) is the
   transferable rule.
3. **Stable item refs (`TASK-5`)** — **ANSWERED** (PD1-3): computed prefix+number,
   workspace-global counter (move-survival is the design motive), MAX+1 allocation
   under advisory lock with retries; resolution by prefix+number join with
   bare-number fallback. OQ-3 carries the scope decision to slice 3.
4. **Yjs + SSE multi-node bridge** — **ANSWERED, CORRECTED** (PD2-2, PD3-2): the
   Redis bridge is **SSE-only**; collab has no cross-instance fan-out (MemoryOpBus
   hardcoded, RedisOpBus a deferred IDEA) while shipped k8s manifests advertise 2–10
   replicas — the corpus's cleanest example of a scaling story the code can't cash.
5. **§5 edit-and-resume sweep** — **STRUCTURALLY ABSENT, subject 22**, the strongest
   form yet: pad contains **no LLM integration at all** (grep-verified across
   `internal/` + `cmd/` — no client, no generation, only install-target aliases and
   an output-format name). No generation layer ⇒ no draft→approve→materialize flow
   anywhere; the nearest shapes (urlimport preview, onboard's propose-confirm) are
   deterministic conversion and conversation convention respectively. The streak
   holds: 22 subjects, zero execution-layer edit-and-resume.
6. **Provisioning lifecycles (FLOW §5)** — **PARTIAL datapoints**: `pad init`'s
   state-derivation idempotence (PD3-1) and title-keyed idempotent seeding; no
   worktrees, no setup-status tracking (n/a by product shape).
7. **Branch/directory naming (FLOW §4)** — **ABSENT**: pad performs no git
   operations (the GitHub feature stores PR links); no naming-template evidence.
8. **Status/attention taxonomies (FLOW §7/§12)** — **ANSWERED**: per-collection
   custom statuses + binary terminal classification (PD1-3 — its poverty is
   pro-seven-kinds evidence); attention is a computed, capped dashboard array
   (`attention`, `plan_completion` nudges, blockers) — **pull-only; no notification,
   inbox, watch, or push model exists** (client toasts are local history; no service
   worker). Argus §12's differentiators survive another subject.
9. **Teardown + stranded-work (FLOW §5/§12)** — soft-delete everywhere with **no
   cascades** (deleting a collection silently orphans its items — hidden, not
   surfaced); the one disciplined path is attachments' grace-period orphan GC
   (`attachments.go:523,579`); account deletion is atomic mixed hard/soft. Mild
   negative reference: soft-delete without stranded-state surfacing accumulates
   invisible debt — FLOW §5's phased+dirty-checked deletion plus §12 attention items
   remain the stronger design.
10. **Placement/multi-machine (FLOW §2)** — **ABSENT, confirmed**: no node, host, or
    device concept; hub-only topology; multi-instance = shared Postgres + Redis SSE
    fan-out, and collab breaks it (disposition 4).

## Scan corrections (mirrored into [../README.md](../README.md))

1. **Attribution**: the scan's "per-transition `StatusTransition` audit rows … full
   attribution (`created_by`, `source = cli|web|mcp`)" conflates two tables —
   `status_transitions` rows carry **no actor columns** (fact only:
   field/from/to/when); attribution lives on items (`created_by`,
   `last_modified_by`, `source`) and the `activities` feed (`actor ∈ user|agent`,
   `source ∈ cli|web|skill`). And item-level `source` is **never `mcp`** — MCP
   writes stamp `cli`; the `mcp` value exists only on workspace-creation provenance.
2. **"Yjs CRDT collab editing + SSE with a Redis multi-node bridge"**: the Redis
   bridge serves **SSE only**; Yjs collab is single-instance by design (MemoryOpBus;
   RedisOpBus an explicitly deferred IDEA) — and the shipped k8s manifests
   (2–10 replicas, no sticky routing) oversell what the collab layer supports.
3. **"PWA manifest present"**: installable-only — no service worker, no offline, no
   Web Push; a second, conflicting manifest sits unreferenced in `web/static/`.
4. **"playbooks-as-data … draft/active/deprecated lifecycle"**: a plain mutable
   status select field — no state machine, no versioning; bodies are edited in
   place. The durable-discipline story is the import-copy library + frozen
   snapshots + the removed auto-upgrade hook (IDEA-1479).
5. **"kanban + blocks/blocked-by"**: the `blocks` link type exists but is **inert**
   — no blocked_by inverse row, no computed blocked state, no release semantics,
   no consumer (display-only). The scan's surface-versioning claim, by contrast,
   verified *stronger* than scanned: two constants, four advertisement surfaces, an
   in-file changelog — with the manual-enforcement caveat (and their own v0.4-stale
   handshake instructions) as the working lesson.

## Open questions

- **OQ-1 — pad as the interim board.** Named trigger: argus slice 3 (board &
  automations) slipping badly while day-to-day work wants a tracker now. It's
  config-only (`mcp_servers:` entry; coderunner trial precedent) and the surface is
  good. Costs that keep this parked: the board would sit outside tenancy, audit, and
  the gate family, and it mints the second source of truth the corpus keeps finding
  wrecked. Decide only if the trigger fires.
- **OQ-2 — error-contract scope.** PD1-2 scopes the enumerated code registry to the
  served MCP surface. Does `/v1/chat/completions` (and later the argus GraphQL
  error extensions) adopt the same registry or per-surface sets? Decide when PD1-2
  lands; lean single registry, per-surface subsets. **Re-dated 2026-07-12
  (PD1-2 landed)**: still open, with one lesson folded in — boundary
  ENFORCEMENT beat static enumeration (the interior set is formally open;
  the sweep alone would have false-greened), so a future REST/GraphQL
  adoption should plan its own enforcement seam per surface, consuming the
  one registry (`JidoClaw.MCPServer.ErrorCodes` families are already
  family-keyed for per-surface subsetting).
- **OQ-3 — task-ref numbering scope.** Pad's workspace-global counter exists so
  cross-collection moves preserve refs. Argus tasks live under projects; if
  cross-project moves are forbidden (likely), per-project counters + project
  prefixes read better and shard naturally. Joins MC OQ-1/2/3 in the slice-3 schema
  review (PD1-3).

## Cross-references and dependencies

```
PD1-1 stability contract ──merges──► traycer TR1-2a (next-ten #6 rider) ──do today
  │                                        PD1-2 error contract (S, independent)
  └─► PD2-1 bootstrap resource (rides PD1-1 plumbing; extends at FLOW slice 6)

PD1-4 import-copy validation ──hardens──► FLOW §13 open item 1 (doc edit, this session)
                                └─build──► FLOW §9 workflow store (argus slice 3/7)

PD1-3 task-schema reference ──joins──► MC1-2 + BO1-4 reading list (argus slice 3)
                                └─► OQ-3 numbering scope

PD2-2 live-layer deltas ──► argus slices 1/3 (Channels build)
PD2-3 perimeter checklist ──► argus §4.4 (joins CC2-4 + XA1-1 as negative ref #3)
PD2-4 curation rubric ──► next served-tool addition (module doc)
PD3-1 init doctor ──► anytime (S, independent)
PD3-2 collab stack ──TRACK──► trigger: collaborative editors (not planned)
PD3-3 lineage badges ──FOLD-IN──► next-ten #6 step 6 disposition vocabulary
```

**Suggested first wave** (extracted 2026-07-04 to
[PD-FIRST-WAVE.md](PD-FIRST-WAVE.md), the adoptable-now queue): PD1-1 (+the
PD2-1 resource riding its plumbing) as the do-today PR — it fixes a live defect (the `0.2.0` advertisement), lands the queued
TR1-2a in stronger form, and costs ~2h. PD1-2 second (S). The FLOW §13/§7 doc
hardening from PD1-4/PD1-3 happens with this dig's corpus updates. Everything else
rides its named slice. Collision notes: next-ten #6 carries the TR1-2a rider —
building PD1-1 satisfies and supersedes it (note that in the queue doc when it
lands); CC2-2 (managed-block prompt sync) gains pad's frozen-snapshot model as its
counter-datapoint — cite PD1-4 in that conversation; camus C1-3's boundary
normalization is PD1-2's design kin, not a collision.

## Bottom line

1. **Fix our own rot today** (PD1-1): the served MCP surface says `0.2.0` on an
   `0.6.4` app — adopt pad's advertisement shape (constant + bump rules + `_meta`
   resource) fused with traycer's golden-test enforcement, one small PR, and the
   queued TR1-2a is superseded in the same motion.
2. **Close the error contract at the boundary** (PD1-2): enumerate the served code
   set, test the subset relation, add typed hints — camus C1-3's posture applied to
   the tool surface.
3. **Harden two FLOW decisions with shipped evidence now** (PD1-4, PD1-3): §13's
   import-copy seam is field-validated (including the removed-auto-upgrade negative
   result), and §7's task schema gains the ref mechanics, the completion guard, the
   pro-seven-kinds counterexample, and the corpus's third dead-dependency datapoint.
4. **The differentiators survive subject 22**: no gates, no push, no notification
   model, no placement, no execution layer at all — and the §5 edit-and-resume slot
   stays empty in its strongest form yet (nothing generates, so nothing could
   resume).
