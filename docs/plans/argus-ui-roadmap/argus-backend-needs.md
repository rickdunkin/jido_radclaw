# Argus backend needs — the design-phase ledger

*Created with the Approvals (2b) unit (roadmap step 6). This is the durable
record of what the design-phase screens' fixture seams FRONT that the backend
must grow before slice 1 can wire them. Fixture field comments in
`ui/src/lib/approvals-data.ts` point at entry numbers here. Each entry: what
the UI renders, what the backend has today (file:line), where the contract is
documented, and what slice 1 must add. Entries are appended by later screens
(4a, 2c, 2d, 3b…) — never renumbered.*

Verified against source 2026-07-14. The 2b fixture keys on the **real**
`AgentCase` kind enum: `JidoClaw.Orchestration.Gate.Kinds.all()` =
`tool_call · plan · irreversible_write · review_stall · needs_input`
(lib/jido_claw/orchestration/gate/kinds.ex:41) — all five have live producers,
all are `AgentCase` rows.

---

## 1. Presentation payload for `tool_call` cases

**UI**: 2b's `ToolCallPresentation` union — a whitespace-preserved command
well with a per-case risk annotation for shell commands, a bounded generic
invocation line for non-command gated tools, and a `complete: boolean` that
disables Approve when false. Both variants render an always-present
`authorization` context line (`requested by {template} · {target}`).

**Backend today**: one 3-field/40-char truncated summary string for
everything — `ToolTranscript.summarize_args/2`
(lib/jido_claw/conversations/tool_transcript.ex:29-42), written into
`AgentCase.details["arguments"]` by `ToolApprovals.details/3`
(lib/jido_claw/orchestration/tool_approvals.ex:256-267). The producer
deliberately redacts BEFORE summarizing (redact-before-truncate — preserve
that order). `ShellCommand.analyze/1` risk effects exist but never ride the
case.

**Documented**: nowhere — this is an undocumented gap.

**Slice 1 must add**: TWO wire shapes, since `kind: :tool_call` covers both
shell commands and non-command gated tools (`forget`, `replay_workflow`,
network mutations, …):

- a redacted, whitespace-preserved **command** preview + per-case **risk
  annotation** for shell-command cases;
- a bounded redacted **generic invocation** presentation for everything else.

Contract requirements, all load-bearing:

- **Completeness**: `run_command` input is unbounded and over-64KiB commands
  deliberately gate as `:opaque`, so a truncated preview can hide a dangerous
  suffix. The preview must be **exact and fingerprint-bound**, or the payload
  carries an explicit incomplete marker and the UI refuses approval until the
  full command is inspectable. Client-side refusal is not the fence:
  **`decideCase` must re-check server-owned completeness under the case
  lock** — a direct mutation caller never approves what the inbox couldn't
  show. For oversized commands, either define an authorized full-payload/ref
  retrieval path or declare incomplete cases permanently reject-only.
- **Redaction before bounding** (the producer's existing order): truncating
  first can split and leak secrets. Redacted spans use an **explicit
  redaction marker distinct from truncation** so `complete: true` never
  contains ambiguous elisions.
- **Display safety is server-owned**: ANSI-strip before secret matching
  (escape-split secrets must reassemble and match), detect bidi/nonprinting
  control characters, and set `complete: false` unless an explicit escaped
  representation bound to the original fingerprint can be rendered — a
  preview that can visually hide or reorder text must never report complete.
- **Printable whitespace is significant**: repeated spaces, tabs, and
  newlines are part of the fingerprinted representation in BOTH variants. The
  client renders both through a whitespace-preserving well that marks tabs
  and trailing runs visibly (a server-produced escaped display paired with an
  exact-copy channel is the acceptable alternative). A complete presentation
  must never let two fingerprints that differ only in whitespace render
  identically.
- **`complete` is defined against the ENTIRE fingerprinted params map, never
  the command string alone**: `run_command` carries effect-relevant
  `backend`/`server`/`workspace_id` params (lib/jido_claw/tools/run_command.ex:52,57,63)
  and the fingerprint covers the whole map plus the requesting
  `agent_template` (lib/jido_claw/orchestration/tool_approvals.ex:103-111) —
  identical command text on the local host and an SSH target, or from `main`
  vs `coder`, authorize different subjects. BOTH presentation variants
  therefore carry a shared structured `authorization` context: the requesting
  `template` (always present, always rendered — the current LiveView already
  displays it, approvals_live.ex) and the effective execution `target` (null
  only when the server proves every remaining dimension default/irrelevant to
  effect). A payload that can neither render nor exclude a dimension must set
  `complete: false`.
- **Display-safety rules apply to EVERY authorization field, not just the
  invocation**: template and target are fingerprint dimensions rendered for
  consent, and a configured server/workspace/worktree/datasource NAME
  containing bidi, zero-width, or ANSI sequences could make two distinct
  targets render identically or reordered. The same
  ANSI-strip/bidi-detect/whitespace-significance/escaped-representation-or-
  `complete: false` contract governs them, and an unrenderable template or
  target makes the presentation incomplete (the UI's existing incomplete
  fence then refuses approval).
- **Required backend tests**: escape-split secrets; bidi controls;
  whitespace-only-difference pairs; identical-command/different-target pairs;
  identical-argument/different-template pairs (distinct visible presentations
  or incomplete); malicious authorization-field names (bidi/zero-width/ANSI
  in template and target → escaped rendering or `complete: false`) — for
  BOTH presentation variants.

**Consumed by**: 2b's `ToolCallPresentation` union (`complete: boolean`
disables Approve when false; incomplete cases hide the scope group entirely).

---

## 2. Server-derived scope options + grant-aware `decideCase`

**UI**: 2b's scope chips (`scopeOptions` — a discriminated union of
`once`/`thread`/`project` options carrying structured context and NO copy)
and 4a's grants tab.

**Backend today**: decisions are strictly single-use `:consume`; no
standing-grant concept exists anywhere in `lib/`. The approval fingerprint is
the five-part template-scoped `:v2` term — tenant, session, agent template,
tool, canonical params (lib/jido_claw/orchestration/tool_approvals.ex:103-111)
— irreversibly hashed at case creation, with only redacted, truncated display
details persisted beside it.

**Documented**: FLOW.md:431-441 / DECISIONS.md:151-155 (approve dialog offers
*once / this thread / this project for N days*; grants visible + revocable;
hard-block class always asks). The located implementation seam is a
non-consuming grant checked in `ToolApprovals.classify/1`, keyed by a coarser
fingerprint variant (emdash OQ-1). Hard-block class: XA2-2.

**Slice 1 must add**:

- **Per-case offered scopes** where the one-shot option is ALWAYS present and
  hard-block cases offer only it — one-shot approval stays possible, standing
  grants don't (4a's "Approve this once" card).
- **A discriminated grant scope**, not the flat `(kind, project)` FLOW
  sketches — the offer includes "This thread", which `(kind, project)` cannot
  enforce without silently widening to the project. One-shot is never
  persisted; a thread grant carries the session/thread identifier; a project
  grant carries the project identifier + TTL; and every persisted grant names
  the authorization subject/pattern it permits — **including the
  agent-template identity**: today's fingerprints deliberately include
  `agent_template`, so an approval for `main` can never be reused by `coder`,
  and a grant subject of tool+args alone would silently widen that consent
  boundary (cross-template grants, if ever wanted, are an explicit design
  decision, not a default).
- **The mutation never trusts the client's scope**: `decideCase` accepts only
  an OFFERED option identifier, and the server transactionally re-derives the
  allowed scopes from the locked case + current policy — unknown, stale,
  cross-thread/project, or hard-block-standing inputs are rejected
  (forged-scope tests required).
- **The grant subject must be persisted server-side at case creation**:
  today's producer irreversibly hashes the session-scoped canonical term and
  stores only redacted, truncated display details — neither can yield a
  thread- or project-scoped subject at decide time (a project grant must drop
  the session dimension, which a hash cannot; the original arguments are
  unrecoverable from either representation), so a decide-time derivation
  would have to trust client material or silently widen consent. Case
  creation therefore persists a versioned, server-derived authorization
  subject (or per-scope digests) carrying the canonical arguments, the
  template identity, and the thread/project identities each offered scope
  would bind; the opaque option id resolves against that persisted material
  plus current policy under the case lock.
- **The persisted subject binds the EFFECTIVE execution target, not raw
  params**: `run_command` chooses the docker sandbox from `tool_context` and
  takes the effective workspace from context before parameters
  (lib/jido_claw/tools/run_command.ex:97,123), while today's fingerprint
  hashes session/template/tool/raw-params only — so a grant matched on
  arguments+template+project could execute against a different effective
  destination after runtime context shifts (mutable cwd, sandbox choice,
  project root, resolved workspace, backend, server). Case creation
  materializes a versioned effective execution target (stable
  sandbox/project/worktree/workspace/backend/server identity — and for
  data-touching commands the resolved, non-secret datasource/database
  identity, which config/env otherwise smuggle past a host-level subject)
  into the authorization subject, and BOTH the presentation's
  `authorization.target` and ALL approval matching bind to it.
- **Every approved claim — one-shot included — recomputes the effective
  target immediately before claim/execution and must exactly match what the
  operator saw**: today approval merely flips the case and the agent later
  reissues the call, with consumption keyed on
  tenant/session/template/tool/raw arguments alone — so cwd, sandbox,
  workspace, or datasource can drift between decision and execution, and
  single-use limits frequency, never destination drift. A mismatch refuses
  the claim and re-pends. Where the target cannot be stabilized and
  revalidated, the case is **incomplete and reject-only** — one-shot approval
  is not the escape hatch for an unstabilizable destination.
- **The persisted subject is secret-safe by construction**: keyed per-scope
  digests (server-keyed HMAC over the canonical subject) when equality
  matching suffices, or an AshCloak-encrypted attribute when recovery is
  required — never plaintext canonical arguments in a durable row
  (`AgentCase.details` is deliberately public and uncloaked, and today's
  producer redacts arguments BEFORE writing anything operator-visible; the
  subject must not become a new durable secret store). Raw subjects are
  excluded from GraphQL, case events, logs, and public case details;
  retention follows the case/grant lifecycle (subject destroyed or expired
  with its owner), with tests covering every exposure surface and cleanup.
- **Required tests**: changed arguments, changed effective target (same
  args/template — including drift between approval and claim on a one-shot),
  or changed template never match a persisted grant or an approved claim.
- **Scope-option wire shape**: options carry a semantic kind PLUS the
  structured context each kind binds (thread identity; project identity +
  TTL) and NO copy — every operator-facing label derives client-side from
  that structure, so a forged or mislabeled wire label can never display
  one-shot consent while the option id binds a standing grant. The one-shot
  option is REQUIRED — the client initializes selection from it (never from a
  server default id), and a payload missing it renders reject-only. Option
  ids must be unique per case, exactly one `once` offered, and scope-bound
  display names (project/thread) must be display-safe under the same contract
  as entry #1's authorization fields — `Projects.Project` accepts arbitrary
  name strings today, so this is a real server obligation; the client
  independently normalizes and fails reject-only on violation.
- Plus: a durable grant resource (visible, revocable), enforcement in
  `ToolApprovals`, revocation.

**Consumed by**: 2b's scope chips; 4a's grants tab.

---

## 3. `decideCase` wire contract + async states

**UI**: 2b's decision-state union (`submitting | resolved | error{code,
action, disposition, allowedActions}`), the reconcile-locked card, the
resolved-decision projection copy, and versioned optimistic-delta
acknowledgement.

**Backend today**: `Cases.decide/4` (lib/jido_claw/orchestration/cases.ex) is
fully built server-side with the taxonomy `not_pending` (concurrent-loser
included), `not_yet_resumable`, `parent_terminal`, `parent_state_unknown`,
`answer_required`, `incomplete_waiver`, `not_found` — surfaced distinctly by
the current LiveView. `AgentCase` records only `decision` +
`decision_comment` (lib/jido_claw/orchestration/agent_case.ex); a one-shot
approval creates no grant row. No GraphQL mutation exists.

**Documented**: `decideCase` is named in argus-ui-bootstrap decision 7 and
sketched in docs/exploration/argus/OVERVIEW.md §4.1.

**Slice 1 must add**:

- The mutation wrapping `Cases.decide/4`, its input (decision, comment,
  offered-scope id), and **stable error codes with dispositions** — the
  taxonomy above is not closed (resume-claim and infrastructure failures
  exist beyond it; unknowns map to a retryable infra code).
- **Dispositions are per attempted action, not case-wide**: `parent_terminal`
  blocks *approval* only — reject/abandon remain valid convergence paths, so
  one failed approve must never strand a pending case. The payload carries
  the attempted action and server-authoritative allowed actions.
- **`not_pending` reconciles from server truth**: since the pending-inbox
  read filters decided rows out, the mutation result must be a normalized
  payload carrying the authoritative case (plus any created/renewed grant AND
  the refreshed authoritative pending summary — the client rebases counts
  from the payload without waiting for a refetch), with a by-id case read
  available for the conflict path (`not_pending` reconciliation needs the
  decided case a pending-only query can no longer return — this is what
  unlocks a `reconcile`-locked card).
- **The accepted semantic scope persists in the decision artifact**: a
  conflict loser's by-id read would otherwise have no authoritative scope to
  render (`Approved — just once` vs `— this thread` would be unknowable or
  stale client-selected copy). The accepted scope kind, TTL, and any grant
  identity persist transactionally on the case or its decision
  `AgentCaseEvent`, and BOTH the mutation payload and the by-id read expose
  one normalized **authoritative decision projection** (decision, the
  structured scope context — kind plus thread/project identity and TTL, from
  which ALL resolution copy derives client-side — grant id when standing,
  decided-by/at, **and the decision's commit version**). Reconciled cards
  render from that projection, never from the local draft, and the by-id
  conflict read returns the projection **paired with a baseline guaranteed to
  include that decision, accepted atomically**: reconciliation stamps the
  winner's commit version, so against an older retained baseline the
  resolution is born-unacknowledged (it subtracts correctly until the newer
  baseline arrives) and against a newer already-accepted baseline it is
  born-acknowledged (never double-subtracted). Required test: by-id
  reconciliation under both baseline orderings.
- **Acceptance is atomic and version-matched**: the pending-summary and
  grants payloads are VERSIONED (monotonic), the mutation returns the
  post-decision version, and one client-side operation installs the
  authoritative case + decision projection + summary + grants baseline,
  acknowledges every local optimistic delta whose decision committed at ≤
  that version, AND removes the decided row from the exact cached pending
  connection — Apollo does not remove changed objects from filtered lists on
  its own, and row absence is NEVER treated as aggregate absorption (the
  summary and inbox are independent operations that refresh in either order).
  Required tests: an advanced summary accepted while the old row is still
  cached; BOTH orderings of independent inbox/summary refreshes (inbox-first
  must not bounce the badge back up; summary-first must not double-subtract
  past acknowledgement); a route exit (the badge holds its decremented value
  with the rich inbox unmounted); concurrent-winner by-id reconciliation
  where the winner chose a DIFFERENT scope (one-shot vs standing — the
  loser's card reconciles to the winner's actual scope); an advanced grants
  baseline meeting a stored created-effect.
- **Transient/infra codes stay retryable ONLY when proven safe**: for
  workflow approvals the decision COMMITS before finalize/resume runs, so a
  resume/claim failure can error AFTER the case is approved. The mutation
  wrapper must re-read authoritative case state after every error and return
  a discriminated `committed | still_pending | indeterminate`, and only
  `still_pending` re-enables the original action (a post-commit resume
  failure is the required test). The UI models the committed-with-error arm
  as `followUpFailure` on a resolved decision.
- The mutation result also returns an **authoritative grants summary** that
  atomically replaces the client baseline (optimistic `grantEffect` deltas
  clear when the baseline observes the grant — never double-counted; renewals
  are zero delta).
- The needs_input deny affordance (entry #7) rides this contract.

**Consumed by**: 2b's local decision-state union (modeled today, producers
widen in slice 1).

---

## 4. `AgentCase` GraphQL read + gates channel proxy

**UI**: the 2b pending inbox (total over all five live kinds), the shell
approvals badge, the priority-aware card order, and live updates.

**Backend today**: `AgentCase` has no `graphql` block; the schema is
query-only over Project + WorkflowRun. `pending_for_tenant` is currently
unbounded and sorts bare `inserted_at asc`. The PubSub seam already exists:
`RunPubSub.broadcast_gate_requested/3` fires on every case open,
`broadcast_gate_resolved/4` on every decide/abandon
(lib/jido_claw/orchestration/run_pubsub.ex); bootstrap P4 deliberately
deferred the `gates:user:<id>` topic.

**Documented**: slice 1 scope in argus-ui-bootstrap.

**Slice 1 must add**:

- A **bounded, paginated** pending-inbox query (the surface's existing reads
  cap at 200/default 50) **plus an authoritative, VERSIONED server summary**
  (total pending count, per-kind counts, oldest `insertedAt`, and a monotonic
  version/`asOf` the client uses to retire optimistic deltas — entry #3) —
  client-side derivation over one page silently undercounts the badge once a
  tenant exceeds a page, so the aggregate endpoint is required, with coverage
  for >200 pending cases of mixed kinds.
- **Shell chrome consumes ONLY the summary operation**: persistent navigation
  queries the aggregate on every route, while the paginated RICH inbox
  operation mounts only on `/approvals` — a badge must never fetch/cache up
  to 200 command presentations (cost AND sensitive-surface narrowing). On
  non-approvals routes, local optimistic deltas derive from overlay snapshots
  (the snapshot carries the case kind, so `decisionBucket` needs no page
  rows). A required test proves a non-approvals route never executes the
  inbox operation.
- **The inbox sort is a priority-aware TOTAL order** — `(kind_rank,
  inserted_at ASC, id)`, kind_rank `tool_call`/`irreversible_write` = 0 ·
  `needs_input` = 1 · `plan`/`review_stall` = 2 (one-tap decisions first,
  replies second, gate deep-links last — this reproduces the approved 2b mock
  card order, where today's bare `inserted_at asc` would put the 12m question
  above the 4m command and reshuffle the design). Slice 1 implements the
  ranked sort server-side; id is the unique tie-breaker. The client mirror is
  `pendingOrder` in `ui/src/lib/approvals-data.ts`.
- **Inbox totality**: `pending_for_tenant` returns all five live kinds — the
  inbox payload must be **total**: every live kind gets at least a
  lightweight generic representation (title/kind/age/context) so it renders
  and counts even before its rich card exists (the 2b union models this via
  `GenericPendingCase`; `irreversible_write`'s rich card joins with 4a,
  `review_stall`'s with the gate screens; both count in the `decide` bucket).
  The plan-gate card counts as "decide" while its affordance lives on the
  gate screen (3b) — the 2b card is deliberately inert and chevron-less until
  then.
- The **`gates:user:<id>` channel proxy** over the existing PubSub seam.
- **Pagination cache contract — ONE merge authority**: all cursor merging
  happens in the generation-aware `fetchMore({ updateQuery })` closure
  (delegating to `acceptInboxConnection`; stale generations return `previous`
  verbatim), and the inbox field policy is `keyArgs` by tenant/filter plus
  REPLACEMENT-ONLY merge — Apollo still runs field merge functions on
  updateQuery results, so a concat-style policy would re-merge the
  already-merged output; replacement semantics make the policy a passthrough
  for updateQuery writes while initial-page and refetch writes REPLACE the
  list (concat-only retains rows another operator already resolved and
  duplicates survivors). The cursor is a KEYSET key over the total order, so
  pagination needs no snapshot token — out-of-order delivery of concurrent
  refetches is a recorded transport residual (Apollo's own request ordering
  governs it), deliberately preferred over inventing a snapshot token the
  server cannot honor. `deriveOldestShown`'s row-driven header polish
  additionally needs the page's summary-version certificate
  (`snapshotVersion`) before rows may outrank the server aggregate — until
  that certificate ships, live pages set it null and the server value stands.
- **Required tests**: external resolution followed by a first-page refetch;
  the generation fence through the REAL cache path
  (`MockedProvider`/`InMemoryCache`: an unresolved fetch-more, a replacement,
  a successful new-generation load-more, then the late stale completion
  discarded — the request-start generation token must reach the merge before
  Apollo writes it). The 2b design phase proves the helpers
  (`acceptInboxConnection`, `createFetchMoreGuard`) directly; the cache-path
  proof cannot exist until the inbox operation does.

**Consumed by**: 2b's inbox seam + shell badges; every later approvals
surface.

---

## 5. Case display context

**UI**: `caseMeta()` segments (`threadRef`, project, worktree, node, taskRef)
and the plan-gate card's human title + artifact format.

**Backend today**: cases carry `session_id`, but workflow-case creation
doesn't accept one and conversation producers deliberately resolve missing
sessions to nil — so the resolved thread/session display name is NULLABLE
with defined fallback copy ("An agent…" / "Decide agent"). Project /
worktree / node / task-ref context fields have no documented wire source. The
real `gate_title` is the static `"Approve plan"` and the reactor adds only
`%{summary: "Approve the implementation plan before execution"}`.

**Documented**: nowhere — gap.

**Slice 1 must add**: the joins that make cases presentable — resolved
thread/session display name; project / worktree / node / task-ref context
(the joins from session/run to each, and the fallback label when absent, need
defining). Also the **plan-gate display projection**: the human title ("Plan
review — export pipeline") and artifact format ("markdown") the mock renders
need a defined joined source.

**Consumed by**: 2b's `caseMeta` line + card titles; 3b's gate header.

---

## 6. Pending-case TTL

**UI**: 4a's expired-request card ("Allow `rm -rf node_modules` — expired").

**Backend today**: no TTL on pending cases; queued as XA2-1.

**Documented**: XA2-1 (queued).

**Slice 1 must add**: expiry semantics (undecided) — what expires a pending
case, what the expired disposition looks like on the wire, and how expiry
interacts with the needs_input 24h single-use answer claim.

**Consumed by**: 4a.

---

## 7. `needs_input` deny affordance

**UI**: 2b's question composer carries a quiet Reject beside Send (a
deliberate addition over the mock's reply-only row) rendering
`Rejected — no answer given`.

**Backend today**: the reject path ("no answer will be given") exists and the
current LiveView offers it — 2b preserves it so the SPA never regresses an
existing operator capability.

**Documented**: current LiveView behavior.

**Slice 1 must add**: the wire mapping rides the `decideCase` contract
(entry #3) — no separate endpoint.

**Consumed by**: 2b's QuestionCard.
