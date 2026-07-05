# Features Worth Borrowing from orca

Exploration notes — not a plan, not a commitment. Initial inventory **2026-07-04** (the
pms corpus's fourth dig, [DIG-BRIEFS.md](../DIG-BRIEFS.md) — scoped as a targeted read,
upgraded to a full dig when the readers kept finding scan corrections). Source:
`~/workspace/research/pms/orca` (andrewmcoupe/orca — "a desktop control plane for
turning software work into briefed, planned, implemented, audited tasks"; local-first
Tauri app driving Claude Code/Codex through a brief → plan → per-task phase pipeline →
gated land flow). Pinned: orca @ `2520b31` (2026-05-13, v0.1.13 — **zero drift from the
scan pin**; the repo has been quiet since), jido_radclaw @ `609350aa`. Cites are
firsthand reads of both trees, accurate to within a few lines. Shape: Rust Tauri 2
backend ~26k LOC + React 19/TS ~29k LOC (pnpm workspaces; `apps/web` is only a
marketing site); rusqlite event store, git2, portable-pty. Maturity: **95 commits, all
between 2026-05-02 and 2026-05-13** — the entire product is an eleven-day solo sprint
(Andy Coupe), with signed macOS releases and a Tauri updater but a self-described
"active early-stage project" README. License: MIT (clean). Nothing was built or
executed this review — all claims are code reads. In-repo doc/code drift is
substantial and recorded per entry (headliners: `docs/events.md` documents 43 of 55
event types and claims upcasters/caller-supplied idempotency keys that don't exist;
`docs/permission-modes.md` describes an auditor default the code bans; the rich
briefing prompt in `prompts/defaults/briefing.md` is dead code; the line-anchored
concern renderer was orphaned by the final commit) — calibrate trust accordingly, in
both directions: the *shipped mechanics* below were verified against code, not docs.

Companion docs: [../README.md](../README.md) (the pms scan this corrects — six claims),
[../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) +
[../../argus/FLOW.md](../../argus/FLOW.md) (the seam map every entry lands on),
[../../camus/FEATURES-WORTH-BORROWING.md](../../camus/FEATURES-WORTH-BORROWING.md)
(C1-3 verdict normalizer orca's parse discipline confirms; C1-2 verify — orca's gates
are its shipped shape),
[../multica/FEATURES-WORTH-BORROWING.md](../multica/FEATURES-WORTH-BORROWING.md)
(MC1-1 resume stack orca's no-resume contrasts; MC1-4 failure taxonomy OR3-2 rides),
[../chorus/FEATURES-WORTH-BORROWING.md](../chorus/FEATURES-WORTH-BORROWING.md) (CH1-1 —
orca is the second plan-layer promote-the-edit and the **third** missing-approve-fence
datapoint), and
[../../ades/traycer/FEATURES-WORTH-BORROWING.md](../../ades/traycer/FEATURES-WORTH-BORROWING.md)
(TR1-3 setup-status split, which orca independently ships). Threat-model weighting as
always: personal tailnet — LLM-misbehavior containment and leakage hygiene over
external-attacker hardening.

**Structure note**: like the sibling digs, this doc adds a **"Dig-brief dispositions"**
section after the tiers (the umbrella deliverable requires an explicit
answered/contradicted/absent verdict per standing question), plus the scan-corrections
block mirrored into the corpus README.

## Determination (TL;DR)

**Nothing to adopt as a dependency; the corpus's best reference-schema donor per line
read.** The scan's "sharpest pattern-per-line ratio" verdict survives the dig, with
corrections. orca is a single-user, single-machine Tauri app — the opposite topology
from argus — but it shipped, in eleven days, working versions of four things argus is
about to design: a structured review-verdict payload (with the anchor-fidelity and
schema-drift lessons already paid for), a landing-staleness model
(`none|clean|dirty|colliding` + approval-goes-stale doctrine + agent-generated
resolution proposals), queue-then-release dependency semantics (with FLOW §7's
canceled-doesn't-release policy independently validated), and a worktree provisioning
lifecycle (init-status split + a toolchain detection table worth lifting verbatim).
Its briefing loop **corrects the scan and observation 1(b)**: Accept *promotes* the
operator's draft edits verbatim (the model is never re-invoked) — orca joins Chorus as
the field's second plan-layer promote-the-edit — while per-assumption pushback is
refine-only and never touches the accepted artifact. The §5 execution-layer sweep
stays empty (subject 20): the review surface is read-only by design, and the operator's
options are approve / pass-back-with-notes / reject / land / catch-up / re-run. The
negative datapoints are as useful as the borrows: teardown force-deletes unmerged work
(the weak end of the spectrum argus's phased+dirty-checked design avoids), the event
store's `correlation_id`/`causation_id` are dead columns and its idempotency key is
server-minted (weaker than scanned), and the approve path has no concurrency fence —
the third tracker in this corpus missing it, hardening the §5.4 acceptance criteria.

*(Connective note, 2026-07-04 pass: the later digs completed both negative lines —
teardown: myrlin's record-delete-strands is the paired leak-pole anti-reference to
this destroy pole, and symphony's [SY2-4](../symphony/FEATURES-WORTH-BORROWING.md)
`before_remove` PR sweep is the positive counter-reference the weak end lacks
(README observation 11 assembles the spectrum); fence: README observation 9 rolls
the double-accept race into the full §5.4 defect list beside Chorus's two missing
fences and bosun's resumed-gates-reopen-approved.)*

| Part of orca | As a dependency | What to take |
| --- | --- | --- |
| Tauri desktop app | No — single-user, single-machine, Tauri IPC only; argus is server+multi-device | Nothing structural |
| Auditor phase + verdict | No | **The review-payload reference** (OR1-1): verdict/severity/anchor/criterion-mapping schema + the anchor-fidelity taxonomy + parse-fail-is-infra confirmation |
| Catch-up / land flow | No | Staleness enum + stale-approval doctrine + resolution-as-proposal (OR1-2); re-validate-inside-execute discipline |
| Task DAG + queue manager | No | Queue-then-release semantics, canceled-keeps-blocked, cycle-check UX (OR1-3); the shipped file-overlap advisory |
| Worktree + init layer | No | Toolchain detection table verbatim; init-status-distinct-from-lifecycle; hard-stop/retry/skip with recorded skips (OR1-4). Teardown is the anti-reference |
| Event store | No — ours supersets it (tenancy, leases, FOR-UPDATE, durable feed) | The step-projection **rebuild command we claim but never built** (OR2-4); `recent_events` summary feed garnish; dead-column cautionary tale |
| Briefing subsystem | No | Ambiguity ledger + readiness gate rubric (OR2-5); the promote-on-accept evidence; the double-accept race as fence datapoint #3 |
| UI copy doctrine | n/a (a doc) | `GIT_IS_IMPLEMENTATION.md` nearly wholesale as the argus vocabulary rubric (OR2-1) |

## Why not adopt as a dependency

1. **Wrong topology, deliberately.** orca is local-first single-user: Tauri IPC only,
   no server, no API surface, no auth, per-machine SQLite. Argus exists precisely to be
   the multi-node, multi-device, phone-reachable version of this product category.
2. **Runtime mismatch.** Rust + React vs OTP + Ash + Phoenix. Every borrow is a
   translation; MIT makes even verbatim lifts legal, but nothing here is worth
   operating as a second binary.
3. **The execution substrate is thinner than ours where it matters.** No tenancy, no
   leases (a per-process mutex + optimistic seq), no durable catch-up feed, post-commit
   orchestration hooks that are best-effort `tokio::spawn` (`runtime.rs:190-209` — a
   panic silently stalls auto-progression). The things argus needs from a substrate are
   exactly what we already have and orca doesn't.
4. **Eleven days old, solo, quiet since May.** Impressive density, but the in-repo
   drift inventory above says the docs already lag the code at commit 95.

## How to read this document

Recommendation vocabulary per the corpus conventions (`docs/exploration/README.md`):
**BORROW-PATTERN**, **BORROW-REFERENCE**, **BORROW-RUBRIC**, **FOLD-IN**,
**INDEPENDENT**, **ALREADY-COVERED**, **TRACK**, **SKIP**. Initial inventory — no
Status lines. Tiers scoped to this codebase: **Tier 1** = clear gap, high leverage,
buildable against a shipped seam or a decided argus slice. **Tier 2** = valuable, lands
with a specific argus slice or an already-queued work item. **Tier 3** = garnish. IDs
`OR<tier>-<seq>`; `S-n` skips; `OQ-n` open questions. Every Gap claim verified against
jido_radclaw @ `609350aa` on 2026-07-04.

---

## Tier 1 — High Impact

### OR1-1. The review-verdict payload reference — schema, anchors, and the anchor-fidelity taxonomy

**Recommendation**: BORROW-REFERENCE (the schema and its two paid-for lessons), the
dig brief's headline question answered.

**Where in orca**: `phases/auditor.rs:63-74` (the verdict struct: `verdict`,
`confidence: f64`, `summary` required; `concerns`/`criterion_mappings`/`unmapped_hunks`
optional), `:543-602` (the JSON schema: `verdict ∈ approve|revise|reject`, confidence
0–1, concerns `{category, severity ∈ blocking|advisory, rationale}`,
`criterion_mappings[{criterion_id, hunks[{file, hunk_index}], satisfied, notes}]`,
`unmapped_hunks[{file, hunk_index, category ∈ dependency|config|refactor|unknown}]`);
`prompts/defaults/auditor.md:20-46` (the prompt half — which *additionally* requires
per-concern `anchor: {path, line} | null`, verdict definitions "approve = ship it,
revise = implementer can fix and try again, reject = fundamentally wrong approach",
and "Be specific. 'This is fine' is not a useful concern… Cite the diff");
`BRIEF.md:30-58` (the criterion-mapping design rationale: per-criterion `satisfied` is
a verdict *distinct from the overall verdict*; non-empty `unmapped_hunks` "is itself a
signal worth surfacing"; hunk-level with file-level fallback and graceful degradation).
The **anchor-fidelity taxonomy**: `diff.rs:541-602` classifies every LLM-supplied
anchor when mapping it onto the real diff — `on_diff_line | on_unchanged_line |
file_not_in_diff | unmapped` — so a hallucinated anchor degrades visibly instead of
lying. Parse discipline: three parse strategies then **one** clarifying retry ("Reply
with the JSON verdict object only", `auditor.rs:202-206`), then `PhaseRunFailed` with
`error_kind="auditor_parse_error"` — **no fabricated verdict, no progression**
(`auditor.rs:226-249`). The two paid-for lessons: (1) **schema/prompt drift** — the
JSON schema omits `anchor`, so the structured-output path (Codex `--output-schema`)
silently produces anchor-less verdicts while prompt-following providers include them
(`auditor.rs:369-381` vs `auditor.md:28-33`); (2) **untyped pass-through** — concerns
are `Vec<Value>` with no server-side shape validation, so malformed-but-JSON concerns
flow onto events and projections unchecked.

**Gap in jido_radclaw** (verified 2026-07-04): our shipped Verdict normalizer (camus
C1-3) is routing-critical-only by design — `Verdict.Review` validates `overall`,
findings list-ness, and per-finding `severity ∈ info|warning|error`
(`orchestration/verdict/review.ex:35-36, 87-96`), with **no blocking/advisory split
(all findings force revise — stated in the moduledoc)** and `clean? = approve AND zero
findings` (`review.ex:24`). Reviewer findings carry a **freeform `location` string** —
no `{file, line}` structure, no anchor validation
(`agent/workers/output_schema.ex:128-145`); `DefaultMapper` coerces findings raw into
the findings artifact (`route_composer/emit/default_mapper.ex:133-134`). The gate/case
layer has **no severity or payload typing at all** (`AgentCase.details` is an untyped
map; gate DSL fields are operator-input types only). And the argus `:review` gate kind
does not exist yet (`orchestration/gate/kinds.ex:15` — three kinds, all with live
producers); next-ten **item 6** plans `review_stall` joining the same list, with an
explicit co-design note (`docs/plans/unadopted-next-ten/README.md:406-409`).

**Why it matters**: OVERVIEW §5.3's editor payloads, FLOW §10's landing review gate,
and item 6's `review_stall` disposition vocabulary all need a review-payload shape;
orca is the only corpus subject that shipped one, and its two drift bugs are exactly
the ones our trust-boundary doctrine exists to prevent (schema is the contract — if
anchors matter, the schema carries them; validate shape at the boundary, which our
Zoi/normalizer stack already does better than their `Vec<Value>`).

**Adoption sketch**: when the `:review` gate payload gets its design pass (argus §5 /
item 6 co-design): adopt `approve|revise|reject`-class verdict verbs at the gate layer
(distinct from finding severity); give findings a **nullable structured anchor**
`{path, line}` validated by the normalizer (extend `Verdict.Review`'s routing-critical
set only if anchors become routing-critical — else typed-but-passthrough); adopt the
anchor-fidelity classification (`on_diff_line`/`on_unchanged_line`/`file_not_in_diff`/
`unmapped`) wherever we render or act on LLM anchors — it composes with `git_diff`'s
parsed per-file structure (`tools/output_shaper/git_diff.ex:40-73`); keep
criterion-mapping (per-criterion `satisfied` + categorized `unmapped_hunks`) as the
payload's stretch shape, gated on OQ-2 (acceptance criteria as first-class premises).
Their parse discipline needs no adoption — it independently confirms shipped C1-3
(garbled verdict → infra lane, never a verdict; their evaluator-only retry is our
`infra_retries`).

### OR1-2. Catch-up staleness + resolution-as-proposal — the landing trust model

**Recommendation**: BORROW-PATTERN (the staleness enum + stale-approval doctrine) and
BORROW-REFERENCE (the resolution flow), feeding FLOW §10 and validating FLOW §6.

**Where in orca**: `BRIEF-2.md:17-20` — the trust model, worth quoting: approval is
stale the moment the parent moves; "After any catch-up (clean or resolved), the
auditor pipeline re-runs. The previous verdict was given against the old parent and
does not carry over"; with agent-assisted resolution "the auditor is the only
automated gate between 'agent modified your files during rebase' and 'you landed
it'" — treat its verdict as a hard requirement. The staleness enum:
`catch_up_state ∈ none|clean|dirty|colliding` (`BRIEF-2.md:34-42`) — `clean` = rebase
changes nothing, `dirty` = rebase *succeeds mechanically but the resulting diff's
meaning changed*, `colliding` = conflicts; v1 treats clean/dirty identically but
data-models the distinction. Shipped mechanics: the six catch-up events
(`CatchUpStateChecked/Started/Succeeded/Cancelled`, `CollisionsDetected`,
`ResolutionRequested` — `events/projections.rs:1231-1307`);
`request_collision_resolution` (`commands.rs:2690-2747`) dispatches an **implementer
phase in "Collision Resolution Mode"** with the three-way contents + intervening-diff
context (`prepare_collision_resolution_context`, `commands.rs:3227-3294`) — FLOW §6's
"merge-back is agent work" doctrine, shipped, with the standing instruction
`BRIEF-2.md:98`: "preserve the original acceptance criteria while integrating cleanly
with the current parent; prefer the parent's approach unless it breaks the original
acceptance criteria" (their own open question calls this "the most important sentence
in this whole flow"). Merge hygiene worth noting: `execute` **re-validates every
precondition instead of trusting the analyze pass** (`merge.rs:189-219` — clean
primary worktree, not detached, not already-merged via `graph_descendant_of`
`:108-126`, no conflicts), and the merge is computed in-memory (`merge_commits`) and
committed directly to the ref — the working tree is never a scratchpad
(`merge.rs:214-253`). Two warts, theirs: the resolution-context builder shells out to
raw `git` in violation of their own git2-only doctrine (`commands.rs:3233-3318`), and
the land dialog hardcodes squash (`merge-dialog.tsx:75`) with the **commit message as
the one editable artifact at the landing gate** (`merge-dialog.tsx:366-372`) — a
small, real convergence with FLOW §10's editable-PR-metadata landing gate.

**Gap in jido_radclaw** (verified 2026-07-04): no worktree, merge, or landing code
exists (grep: one `--worktree` flag token in `security/shell_command/git.ex`);
`PullRequestCoordinator.submit_pr` fabricates a URL and its caller chain is orphaned
(`github/agents/pull_request_coordinator.ex:87-94`, confirmed again this dig). FLOW
§10 has landing paths and §6 has the merge-back doctrine, but neither has a staleness
model — nothing in FLOW says *when a review gate's approval expires*.

**Why it matters**: argus §5's whole premise is reviewed-then-acted artifacts; orca's
doctrine names the failure mode (an approval detached from the state it approved) and
the answer (staleness is computed continuously, catch-up is explicit, the judge
re-runs after any rebase — especially an *agent-performed* one). The
`clean|dirty|colliding` distinction is sharper than "conflicts?": `dirty` catches the
semantic-drift case a boolean misses.

**Adoption sketch**: slice 4 (landing) — worktree rows (or their PR-gate cases) carry
`staleness ∈ current|clean|dirty|colliding` computed against primary via
`git merge-tree` dry-runs (their brief's own performance recommendation; pairs with
XA3-2's merge-base three-dot rule); a `Needs catch-up`-class state suppresses Land and
the §5 review gate's approval; catch-up is operator-initiated; post-catch-up the
review re-runs (in our terms: the gate case is re-opened, never auto-promoted). Slice
5 (fan-out): `merge_child` conflicts spawn a resolution turn for the parent thread's
agent carrying orca's context bundle (three-way + intervening diffs + the
preserve-ACs-prefer-parent instruction as a tunable project setting), and the
resolution lands as reviewable work — never a silent mechanical merge. Adopt
re-validate-inside-execute for every landing action (our TOCTOU discipline, applied to
git state).

### OR1-3. Queue-then-release dependency semantics — the shipped `done`-kind release, sharpened

**Recommendation**: BORROW-PATTERN + the validation FLOW §7 was waiting for.

**Where in orca**: release fires only when the **last** dependency merges:
`find_newly_unblocked` returns a task iff it depends on the merged task AND every dep
is `merged` AND it isn't terminal (`dependencies.rs:276-332`). The sharpening the scan
missed: **auto-start is armed by the human** — only tasks the operator queued while
blocked (`is_queued`, set by clicking Run → `TaskQueued`, `pipeline.rs:396-443`)
auto-start on release (`pipeline.rs:517-528`, `start_task(force_run=true)` → worktree
create + init + first phase); unqueued tasks merely flip `is_blocked` and wait. The
policy detail FLOW §7 already decided, independently shipped: **`cancelled`/`archived`
dependencies keep dependents blocked** — only `merged` releases
(`compute_is_blocked`, `dependencies.rs:236-266`, test `:630-637`). Guard rails:
DFS cycle detection *with the exact cycle path returned for the UI*, self-dep and
duplicate rejection, same-plan-only edges (`dependencies.rs:106-233`); a visible
**"Run anyway (ignore dependencies)"** override in the overflow menu
(`task-action-toolbar.tsx:765-872`); and `TaskUnblocked` events recording
`unblocking_task_id` (actor `system:queue_manager`, `pipeline.rs:494-512`) — the
"why did this start?" lookup FLOW §8 wants. Adjacent and shipped: the **file-overlap
advisory** (`detect_file_overlap`, `dependencies.rs:348-419`) — real-time
`relevant_files` intersection against in-flight tasks, warning-only, never blocking —
the corpus's second `fileConflicts` datapoint after myrlin, this one code-verified.

**Gap in jido_radclaw** (verified 2026-07-04): no task layer (MC1-2's gap); on the
workflow axis the composer's Kahn waves release mechanically within one route
(`route_composer/router.ex:209-218`) and skills compile `depends_on ∪ consumes` into
Reactor edges with cycle detection (`skills/compiler.ex:281-293, 403-424`) — but there
is **no cross-run, event-triggered release anywhere**: run terminals broadcast to UI
subscribers only (`orchestration/run_pubsub.ex:70-71`), the GitHub webhook broadcasts
to a topic nothing subscribes to (`github/webhook_pipeline.ex:39`, grep-confirmed
void), and cron is time-based only (`platform/cron/dispatcher.ex:35-85`).

**Why it matters**: FLOW §7's "done-kind releases dependents" now has its shipped
reference with two refinements worth stealing: (1) release ≠ start — the arming bit
(their `is_queued`, our `ready`-kind + a per-task run intent) keeps automation
consentful, exactly the posture our approval-fatigue design wants; (2) the release
event carries provenance (`unblocking_task_id`), making every automation fire
explainable (FLOW §8's rule).

**Adoption sketch**: slice 3 — the Task resource's system behavior on `done`-kind
transitions implements last-dep-release with orca's semantics: only `done`-kind
releases; `canceled`-kind holds dependents blocked (already decided, now evidenced);
release emits a durable event with the releasing task id; auto-*start* additionally
requires the task's own arming state (OQ-3 decides whether `ready`-kind status *is*
the arming bit or a separate queued flag); cycle validation returns the path. The
file-overlap advisory lands with §12's `fileConflicts` trigger — compute
`relevant_files`/changed-file intersection across a project's active worktrees,
surface as attention, never block.

### OR1-4. Worktree provisioning — init-status split, the toolchain table, hard-stop/retry/skip

**Recommendation**: BORROW-REFERENCE for FLOW §5 (which cites "orca's auto-detect" by
name — this entry is that citation, cashed out).

**Where in orca**: two projection fields, not one enum — `worktree_status`
(NULL→`active`→`removed`) tracked separately from `worktree_init_status`
(NULL→`running`→`initialized`|`failed`) (`events/projections.rs:1329-1410`) — the
traycer TR1-3 lifecycle/setup split, independently shipped. The detection table
(`worktree_init.rs:100-139` detect, `:73-93` commands), first-match-wins, verbatim:

| Marker(s) | Command |
| --- | --- |
| `package.json` + `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `package.json` + `yarn.lock` | `yarn install --frozen-lockfile` |
| `package.json` (+ `package-lock.json`?) | `npm ci`, else `npm install` |
| `pyproject.toml` + `uv.lock` | `uv sync` |
| `pyproject.toml` + `poetry.lock` | `poetry install` |
| `requirements.txt` | `pip install -r requirements.txt` |
| `Cargo.toml` | `cargo fetch` |
| `go.mod` | `go mod download` |

— lockfile-specific commands, and it **refuses to guess** (`pyproject.toml` with no
recognized lock → no init rather than a wrong one, `worktree_init.rs:122-125`).
Resolution precedence: disabled → operator `user_command` override (recorded as
`detection_kind="user_configured"`) → detection (`:168-187`). Timeout doctrine: 600s
wall-clock, **deliberately no silence timeout** — "installs go quiet during downloads"
(`:207-212`). Failure is a **hard stop**: `WorktreeInitializationFailed`, no
`PhaseRunStarted`, the pipeline does not progress; the operator retries or skips, and
a skip is recorded as a synthetic `WorktreeInitialized` with
`detection_kind="user_skipped"` (`:381-461`) — provenance for "this workdir was never
initialized". Crash hygiene: `cleanup_orphan_for_task` before every create
(`worktree.rs:147-170`, the crash-window between `git worktree add` and the committed
event), and activation-time `reconcile_worktrees` (projection-vs-disk: prunes
dir-gone rows with `reason:"cleanup_orphan"`, logs-but-never-deletes untracked dirs —
"could be the user investigating", `commands.rs:1119-1209`). Naming: branch
`orca/{task_id}`, dir `~/.orca/workspaces/<key>/worktrees/<task_id>` — **outside the
repo**; collisions are a hard `BranchExists` error, no counter (`worktree.rs:59-67,
102-120`). The anti-reference: **teardown force-deletes everywhere** — merge, cancel,
reject, and delete all run `force=true`, bypassing the dirty check and deleting the
branch, so rejected work is unrecoverable (`commands.rs:4330-4363`,
`worktree.rs:181-246`; `reject_task` is literally `cancel_task`, `commands.rs:3796`).

**Gap in jido_radclaw** (verified 2026-07-04): zero toolchain provisioning — grep for
pnpm/uv/cargo/poetry install automation is empty; the only hook is Forge's declarative
`bootstrap_steps` (`forge/bootstrap.ex:21-30`, arbitrary exec/file steps a spec must
hand-write). No worktree code at all. FLOW §5 specifies create→setup→ready with
idempotent per-project steps and names orca's auto-detect as the toolchain-init
reference.

**Why it matters**: this is the FLOW §5 provisioning slice's parts list, verified
against code rather than the scan's one-liner — including the three judgment calls a
from-scratch build gets wrong (no silence timeout on installs; refuse-to-guess over
best-effort; skip-is-recorded-provenance rather than silent bypass).

**Adoption sketch**: slice 2 — `setup_status` on the Worktree resource per TR1-3, with
orca's state values as the floor; a per-project setup-step list seeded by this
detection table (detection at provision time, operator override in project settings,
`mix`/`_build`-aware entries added for our stacks); init failure holds the worktree
out of `ready` and raises an attention item (never offered to a thread — FLOW §5
already says this); skips recorded with provenance. Keep our teardown the
dirty-checked, phased one (TR2-1/MX2-2) — orca is the datapoint for why: their
reject/cancel destroys unmerged agent work with no recovery, indefensible once
worktrees are durable residents rather than task-scoped disposables.

---

## Tier 2 — Valuable, lands with a specific slice or queued item

### OR2-1. "Git is an implementation detail" — the vocabulary doctrine, nearly wholesale

**Recommendation**: BORROW-RUBRIC (a document, not code — MIT even makes it quotable).

**Where in orca**: `apps/desktop/GIT_IS_IMPLEMENTATION.md` — the complete doctrine:
intent-named verbs over mechanism names (the mapping table: **Proposal** = branch diff
against merge base, **Land** = squash merge, **Catch up** = rebase onto parent,
**Collision** = conflict, **Revision** = commit); a verb-agreeing state ladder
(`Drafting → Under review → Approved → Ready to land → Landing → Landed`, plus
`Needs catch-up → Catching up → Has collisions`); a banned-terms list for all
user-facing strings (branch/HEAD/merge/rebase/conflict/diff/commit-as-noun…); **the
terminal as the one sanctioned language boundary** ("that's Git's world, not ours —
we do not wrap git in aliases or retranslate its output"); and the implementation
rules — git speaks only inside dedicated modules, **DB columns use domain vocabulary**
(`tasks.land_strategy` not `merge_strategy`), **audit events are domain events**
(`TaskLanded`, never `BranchMerged`), errors translated at the boundary ("Collision in
src/foo.ts while catching up", never "merge conflict"). The enforcement lesson rides
along: the land dialog complies fully (`merge-dialog.tsx:61-66, 502-503` — even
`GitError` renders as "Version-control error") but the dependency UI leaks "merged"
and "cycle" (`dependencies-section.tsx:185-186, 353`) — vigilance doesn't hold the
line; a copy-lint or review-gate rule does.

**Gap in jido_radclaw** (verified 2026-07-04): no equivalent doctrine anywhere; argus
FLOW already uses intent vocabulary informally (threads, landing, quick-merge,
catch-up never named) but nothing binds UI copy, column names, or event names to it.
The audit-events-are-domain-events rule matters *now* — slice 2/3 name the Worktree
and Task resources' columns and events, which are forever.

**Why it matters**: argus's operator is on a phone approving agent work; every Git
mechanism word in that UI is translation burden at the worst moment. And our own
review muscle (ExSlop-style copy lint) makes the enforcement half cheap where orca's
vigilance failed.

**Adoption sketch**: adapt the doc as `docs/argus-vocabulary.md` when slice 1 starts
the client: keep their verbs where they fit (Land, Catch up, Collision), extend for
our nouns (threads, gates, attention); apply the DB-naming and domain-event rules to
the slice-2/3 resources; add the banned-list to the client's lint/review checklist.
The terminal-boundary exception maps exactly to FLOW §11's operator terminal.

### OR2-2. Deterministic gates between phases — the shipped shape of next-ten #5

**Recommendation**: FOLD-IN → `docs/plans/unadopted-next-ten` item 5 (deterministic
verify authority). Not a standalone adoption.

> **Status: ✅ FOLDED IN 2026-07-05** (next-ten #5 shipped). What landed of
> this entry: the **named-check registry** (`verify:` `checks:` in
> `.jido/config.yaml` — ordered `{name, cmd, env?, timeout_ms?}` list, or the
> scalar `verify_cmd:` ≡ one named check) with a **per-run override**
> persisted in the composer parent config, and the inverted wart — an
> override naming an unknown check **refuses loudly**
> (`{:unknown_check, name, known}`), never a silent skip. Deviations, per the
> item-5 design: checks run sequentially but **collect-all into ONE camus
> envelope** (no per-check `GateRan` event kinds — the envelope's `checks[]`
> carries name/cmd/exit, and the composer's existing wave events carry
> provenance, so `triggering_phase_run_id` has no separate analogue);
> **camus wins over orca on timeout** (timeout ⇒ inconclusive on the infra
> lane, never a red verdict); first-fail-stops-progression is inherent
> rather than wired (a red verify blocks convergence via `findings:verify`).
> Commands are argv lists via `Core.OsCmd` — never a shell string.

**Where in orca**: a gate is a named shell command with a timeout
(`GateConfig {command, timeout_seconds}`, `settings.rs:180-184`), registered
workspace-wide (`gates: {name → config}`) and attached per phase
(`phase_gates: {phase → [names]}`, `:298-303`) with per-task override resolution
(`pipeline.rs:72-100`); run sequentially after a phase completes, **exit code is the
only truth** (0 = pass), output opaque and 64 KiB-truncated, timeout ⇒ failed
(`gates.rs:1-7, 32-44, 62-168`); emits `GateStarted`/`GateRan {gate_name, passed,
output, duration_ms, triggering_phase_run_id}`; **first failure stops
auto-progression** (`pipeline.rs:945-949, 1151-1156`). One wart to not copy: unknown
gate names silently skip (`pipeline.rs:72-100`) — a typo'd gate is a gate that never
runs.

**Gap in jido_radclaw** (verified 2026-07-04): item 5 (`README.md:326-362`) plans
exactly this — `JidoClaw.Orchestration.Verify` running a `verify_cmd` as "a composer
stage that is not an agent", exit-code classification, envelope landing in a
WorkflowEvent — and is NOT started; `Verdict`'s `:inconclusive` lane is reserved for
it (`orchestration/verdict.ex:14-16`).

**Why it matters**: orca proves the shape at product scale-1: deterministic checks
interposed between LLM phases, first-class in the event log and the pipeline UI. The
details worth folding into item 5's design: the named-registry + per-phase-attach +
per-unit-override resolution order; `triggering_phase_run_id` provenance on the gate
event; and fail-loud-on-unknown-name (their silent skip inverted).

### OR2-3. Pass-back precedence — the human-overrides-judge retry rubric

**Recommendation**: BORROW-RUBRIC (prompt text + context shape), landing with the §5
review gates (and reusable in the composer's fix lane today).

**Where in orca**: `pass_back_to_implementer` builds `retry_context =
{auditor_summary, auditor_concerns, user_feedback}` and chains `is_retry_of` to the
prior run (`commands.rs:3746-3793`); the implementer renders each concern as
`- [{severity}] {category} ({path}:{line}): {rationale}` (`implementer.rs:511-541`)
under "Address each concern directly. If you disagree with one, leave a brief note in
your summary explaining why", and the user's note lands under the load-bearing line
(`prompts/defaults/implementer.md:68`): **"Treat the user feedback above as
authoritative: if it conflicts with the auditor's concerns, follow the user."** The
dialog copy states the same contract to the operator (`pass-back-dialog.tsx:58-62`).
Uncapped, human-triggered, each pass-back a fresh run — the pipeline never auto-loops
on `revise` (`pipeline.rs:971-1011`: the auditor hook stops regardless of verdict; a
human always takes the next action).

**Gap in jido_radclaw** (verified 2026-07-04): our fix lane feeds raw verdict findings
to the fixer via the findings artifact with no human-note channel and no stated
precedence rule; gate decisions carry only `decision_comment`, which **never flows
into the resumed reactor** (`orchestration/cases.ex:106`,
`gate_resume.ex:160-167` — the decision atom is all that's seeded, re-confirmed this
dig). When argus §5 adds operator notes at review gates, the precedence question
(judge findings vs operator note) arrives immediately.

**Why it matters**: the authoritative-on-conflict line is field-tested language for
the exact ambiguity our fixer prompts will hit the day a human note joins the loop —
and the address-or-explain-disagreement instruction is a cheap honesty lever for fix
attempts (composes with camus C1-4's honest-status doctrine).

**Adoption sketch**: when review-gate notes exist (argus §5.4 / item 6): thread
`{verdict_summary, findings, operator_note}` as the fixer/successor context with
orca's bullet format (anchors included when OR1-1 lands them) and the two prompt
lines nearly verbatim. Until then, keep as the reference shape for
`pass back with notes` in FLOW §10's gate UX copy.

### OR2-4. Event-store deltas — the rebuild command we claim, the summary feed, the stranded-run sweep

**Recommendation**: INDEPENDENT (a) — fix an our-side documented-but-unbuilt claim;
BORROW-PATTERN garnishes (b, c).

**Where in orca**: (a) `rebuild_projections` — DROP all projection tables and replay
the full event log per aggregate (`commands.rs:4640-4784`), manual/dev-only (no auto
trigger, no UI caller — an honest maintenance tool). (b) `recent_events` — a bounded
(200-row, INSERT-OR-REPLACE + trim) projection holding **one human-readable summary
line per event**, populated in the same append tx, with a per-type `summarize` match
(`recent_events.rs:9-186`) — the cheapest possible activity feed. (c) the
activation-time sweep: rows left `is_generating`/`running` by a dead process get
synthetic `BriefingGenerationFailed{reason:"interrupted by app restart"}` /
`PhaseRunFailed` events (`commands.rs:900-940`, `commands_briefing.rs:1561-1597`) —
terminal-status honesty for in-flight state that died with its process.

**Gap in jido_radclaw** (verified 2026-07-04): (a) `WorkflowStep` rows are projected
best-effort in a savepoint, and the moduledoc says failures "are repairable by
replaying the run's `step_*` events" (`workflow_event/changes/allocate.ex:50-51`) —
**no such replay exists** (grep empty; `Replay` is inputs-re-run, `replay.ex:95`;
`Projection.project_status/1` is a test-only prover, `projection.ex:285-300`). The
composer already proves the fold pattern (`route_composer/projection.ex:68-90`,
`workflow_recovery.ex:373-376`) — the step read-model is the one projection with a
promised, missing repair path. (b) our Trace/audit events have no bounded
human-summary projection; the CC1-2 attention-feed gap cites exactly this absence.
(c) our runs have lease-based reclaim (strictly stronger), but Forge sessions carry no
DB lease (MC2-1 noted the asymmetry) and briefing-style in-flight state doesn't exist
yet.

**Why it matters**: (a) is a small integrity IOU in our own spine — a maintenance
command makes the moduledoc true and gives operators a repair path when a savepoint
swallow ever fires. (b) is the thinnest useful slice of the argus attention feed.

**Adoption sketch**: (a) a `mix jidoclaw.reproject_steps <run_id>` (or MCP-side
maintenance action) folding `step_*` events into `WorkflowStep` upserts — reuse the
applier logic, idempotent by construction; adoptable now (OR-FIRST-WAVE item 1).
(b) fold into the CC1-2 attention-feed design: per-kind one-line summarizers over
`WorkflowEvent`/Trace, bounded projection, no new event source. (c) fold into MC2-1's
Forge-session lease work as the recovery-side rule: reclaimed ≠ silently reset —
synthesize the terminal event.

### OR2-5. Briefing judgment layer — ambiguity ledger, readiness gate, and the promote-on-accept evidence

**Recommendation**: BORROW-RUBRIC (the ledger/readiness shapes, riding next-ten items
8–9) + the corpus evidence entry for §5 plan-layer semantics.

**Where in orca**: instead of conversational questions, personas must encode
uncertainty as **ambiguity-ledger items** `{question, why_it_matters,
risk_if_unanswered, recommended_default_assumption, user_input_required, status,
user_answer}` (`briefing.rs:153-170`, prompt rule `briefing.rs:921-926`), and the
synthesis declares `readiness_status ∈ ready_for_tasks | ready_with_assumptions |
blocked_needs_user_input` (`briefing.rs:1001-1011`); Accept is **gated**: unresolved
`user_input_required` items block unless the operator explicitly accepts the
recommended assumptions (checkbox → `accept_assumptions`,
`commands_briefing.rs:1258-1273`). Depth-tiered personas
(quick/guided/thorough/adversarial, `briefing.rs:872-894`) with per-persona artifacts
persisted incrementally and **reused on retry** (crash after N personas resumes at
N+1, `commands_briefing.rs:763-795`); a deterministic quality gate on the draft
(≥1 task, meaningful specs, relevant-files present) with one repair re-prompt
(`briefing.rs:552-617, 1094`). The §5 evidence (scan correction): **Accept promotes
the operator's edits verbatim** — `apply_edits_to_draft` is a pure merge
(title/spec/file/task add-remove, dangling-dep scrub) applied at materialization with
the model never re-invoked (`commands_briefing.rs:1132-1186, 1251-1254`); **Refine
re-prompts** (edits ride as `user_feedback_json`); **pushback never promotes** — a
pushback accepted without an intervening refine is audit-trail-only, asserted by
their own test ("pushbacks become input to the next refinement, not draft state",
`commands_briefing.rs:1744-1760`). Their fences, absent: no whole-command lock on
accept — two concurrent accepts can both pass the `status=="active"` check and
double-materialize plans (`commands_briefing.rs:1236, 1281-1328`; deliberate
per-aggregate transactions), and the human **cannot edit the task DAG** (no
`depends_on`/reorder UI; the TS type omits the field, `types.ts:9-14`).

**Gap in jido_radclaw** (verified 2026-07-04): the persona-panel half is
ALREADY-COVERED (FrontDoor multi-plan arming: 3 lens planners → 3 challengers →
arbiter); what we lack is the *structured uncertainty* half — next-ten **item 8**
(ouroboros ambiguity clarify loop) and **item 9** (structured premises with
`acceptance_criteria`) are queued and unstarted; nothing shaped like a readiness
declaration or an explicit accept-assumptions gate exists on the plan gate
(`reactors/plan_gate.ex` re-emits the original plan byte-identical).

**Why it matters**: orca supplies shipped field shapes for both queued items (the
ledger item schema for #8; per-task `spec_markdown` + relevant-files-with-certainty +
the quality gate for #9), and its readiness enum is a plan-gate payload candidate —
"ready_with_assumptions" is precisely the honest middle state our plan gate
flattens today. The promote/pushback asymmetry and the missing accept fence harden
CH1-1's §5.4 acceptance criteria with a third datapoint: **promote semantics must be
explicit per channel** (which operator inputs become the artifact vs steer the next
generation), and **approve/accept must be idempotent** — orca and Chorus both shipped
without it.

**Adoption sketch**: fold the ledger item schema and readiness enum into item 8's
design; fold the per-task quality gate (deterministic, with one repair re-prompt —
their `validate_task_quality`) into item 9's premises lint; when argus §5.4 lands,
its editor spec states per-field promote-vs-reprompt semantics explicitly, and
`decideCase`/accept paths get the concurrency fence all three trackers lack (ours:
the FOR-UPDATE + single-use `:consume` machinery already exists — the criterion is
"keep it").

---

## Tier 3 — Garnish

### OR3-1. Non-interactive subprocess env baseline

**Recommendation**: BORROW-REFERENCE, small. `subprocess.rs:207-213` injects a
force-non-interactive floor under every child: `CI=true`,
`DEBIAN_FRONTEND=noninteractive`, `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=""`,
`SSH_ASKPASS=""`, `NPM_CONFIG_YES`, `PIP_NO_INPUT`, `PYTHONUNBUFFERED` (caller env
wins). **Gap** (verified 2026-07-04): our spawn hygiene is the *allowlist scrub*
(`security/redaction/env.ex:36-41, 169-175` — secrets can't leak in) but nothing
*injects* the never-prompt floor; a git/pip invocation inside a Forge sandbox that
decides to prompt hangs against its timeout instead of failing fast. Adopt as a
constant merged into `scrubbed_cmd_env`/Forge spawn for runner/gate/init-class
children — composes with, doesn't replace, the allowlist.

### OR3-2. Subprocess failure-kind + dual-timeout split — rider on MC1-4

**Recommendation**: FOLD-IN → MC1-4's `RunFailure` taxonomy. orca's contribution:
the **silence-vs-wall-clock timeout split** (`silence_timeout` 300s default,
`wall_clock_timeout` 1800s, `settings.rs:276-280`) surfacing as distinct kinds
(`stalled_no_output` vs `stalled_wall_clock`, `subprocess.rs:407-416`) — plus
`user_cancelled` as a first-class non-failure kind, `setsid` process-group SIGKILL
(catches shell-spawned grandchildren, `subprocess.rs:195-205`), and a `ChildTracker`
killing everything at app shutdown (`:94-102`). Our Forge/Lua watchdogs have the
wall-clock half; the silence-kind distinction and group-kill discipline join MC1-4's
enum when it lands. (Note their worktree-init deliberately *disables* the silence
timeout — the two knobs must stay per-workload.)

### OR3-3. Review-surface UX pack — AC-driven review, opacity rendering, reviewed-tracking, degraded modes

**Recommendation**: TRACK — trigger: the argus review/diff client build (slices 2–4,
the §5.3 `code_diff` editor). `BRIEF.md` is the spec and most of it shipped in #22
(`proposal-review-surface.tsx`): review organized **by acceptance criterion** with a
by-file escape valve; full files rendered with unchanged code faded (~35% opacity)
rather than diff-with-context; per-criterion reviewed-tracking with the land audit
event recording *which criteria were reviewed and which were not*; **degraded modes
as doctrine** ("structured output is a precondition for the *best* experience, not
*any* experience" — file-level fallback, no-mapping fallback, each with an honest
notice); keyboard-native throughout. Two riders: the maturity caveat — #22 orphaned
the line-anchored concern renderer (`DiffModal` unmounted, concern `path:line` clicks
no longer navigate; the anchor plumbing survives only in dead code) — and the
typography garnish (`AGENTS.md`: serif reserved exclusively for the auditor's prose
verdict, "to mark the auditor's voice as distinct from app chrome and from code" — a
one-line design idea for argus verdict cards). Their preview server
(`preview_server.rs`: single instance, health-gate readiness, worktree cwd,
default-disabled) is a second, smaller reference beside termic TM1-3 for the
preview-worktree story.

---

## Skip / Already Covered

- **S-1. The product as our control plane** — SKIP. Single-user, single-machine,
  Tauri-IPC-only; argus exists to be the opposite (OVERVIEW §2). Nothing to run.
- **S-2. Optimistic `expected_seq` appends + per-process write mutex**
  (`append.rs:95-101`, `write_lock.rs:31-59`) — ALREADY-COVERED, ours stronger where
  it counts: FOR-UPDATE seq allocation inside the append tx
  (`workflow_event/changes/allocate.ex:174-195`) plus DB leases/token fencing make us
  safe across *processes and nodes*; orca's mutex is per-process and two app instances
  contend at SQLITE_BUSY (their own docs note the write_lock exists because of a real
  "database is locked" race, `write_lock.rs:6-13`).
- **S-3. Id-only `projection_updated` invalidation nudge + client refetch**
  (`commands.rs:30-39`, `hooks.ts:12-75`) — ALREADY-COVERED: argus §4.2 already
  specifies minimal-payload channel events + GraphQL refetch; orca is an independent
  arrival at the same contract (a validation cite, not a borrow).
- **S-4. `correlation_id`/`causation_id` columns** — SKIP as schema, keep as the
  cautionary tale: documented, typed, and **never populated** (always `None`,
  `commands.rs:56-63`; docs claim semantics that don't exist). The lesson our
  centralize-aggregate-writers habit already encodes: don't ship contract surface
  without a producer. (Our `WorkflowEvent` deliberately has neither field; if argus
  ever wants cross-run causality, add it with its first real producer.)
- **S-5. Operator terminal (PTY into the worktree)** (`terminal.rs`) —
  ALREADY-COVERED by FLOW §11's operator-terminal plan (broker on owning node, authed
  WS, strictest tier). One garnish: their foreground-process labeler (poll
  `ps -o comm=` → live tab label, `terminal.rs:498-524`).
- **S-6. XState/TanStack client architecture, Tauri updater, marketing site** — SKIP;
  wrong stack, no lessons argus's React client doesn't already have closer references
  for.

## Open questions

- **OQ-1 — Does finding severity grow a release-semantics axis?** orca's
  `blocking|advisory` encodes "does this finding block landing" *in the verdict*; our
  `info|warning|error` deliberately doesn't (all findings force revise,
  `verdict/review.ex` moduledoc). When the `:review` gate and item 6's `review_stall`
  dispositions are co-designed, decide: extend the severity enum, or keep severity
  descriptive and put the release decision on the gate (a per-finding waive/ack at
  decision time). The second preserves C1-3's findings-win conservatism; the first is
  what orca ships. Decide at item 6 / argus §5 design.
- **OQ-2 — Acceptance criteria as first-class premises?** `criterion_mappings` only
  works because tasks carry structured ACs. Next-ten item 9 (structured premises with
  `acceptance_criteria`) is the producer; OR1-1's criterion-mapping is its natural
  review-side consumer. Decide whether item 9's schema reserves the AC-id linkage when
  it lands — one field now vs a migration later.
- **OQ-3 — Is `ready`-kind the arming bit, or is arming per-task?** orca separates
  `is_blocked` (computed) from `is_queued` (explicit human intent per task); FLOW §7
  has `ready`-kind = automation-eligible as a *status*. A status can be moved by
  automation; orca's per-task queue bit can't. Decide at slice 3 whether
  automation-eligibility needs the second, per-task consent bit for auto-*start* (the
  approval-fatigue posture suggests yes for agent-created tasks at minimum).

## Dig-brief dispositions

Per [DIG-BRIEFS.md](../DIG-BRIEFS.md) (orca section + the cross-cutting six):

1. **Auditor verdict schema** — ANSWERED (OR1-1): `approve|revise|reject` +
   `confidence` + `blocking|advisory` concerns + nullable `{path,line}` anchors +
   `criterion_mappings`/`unmapped_hunks`; **with corrections** — anchors are
   prompt-only (absent from the structured-output JSON schema, so Codex-path verdicts
   lack them), concerns are unvalidated `Vec<Value>` pass-through, and at HEAD the
   line-anchored rendering is dead code (#22 regression).
2. **Briefing-loop event vocabulary** — ANSWERED (OR2-5, reader-verified 12-event
   vocabulary) and **scan-contradicted**: the loop is not re-prompt-only. Accept
   promotes edits verbatim (`apply_edits_to_draft`, model never re-invoked); Refine
   re-prompts; per-assumption pushback (`BriefingPushedBack`) is refine-only and never
   affects the accepted artifact. The rich pushback-reconciliation prompt the scan's
   framing implied lives in a **dead** code path (`briefing.md` + `#[allow(dead_code)]`
   single-shot generator); the live persona prompts pass one generic
   `user_feedback_json` blob.
3. **DAG auto-queue-on-merge** — ANSWERED (OR1-3), sharpened: last-dep-merge release,
   auto-start only for human-queued tasks, cancelled/archived deps keep dependents
   blocked, full-pipeline start (worktree+init+phase), DFS cycle check with exact
   path, same-plan-only edges.
4. **Worktree auto-init** — ANSWERED (OR1-4): the 8-row lockfile-specific table,
   refuse-to-guess, disabled→override→detect precedence, 600s wall / no-silence
   timeout, hard-stop with retry/skip-recorded.
5. **Event-store conventions** — ANSWERED with corrections (OR2-4, S-2, S-4):
   `command_id` is a server-minted ULID checked by pre-query (guards internal retries,
   not UI double-submits — the scan's "command_id idempotency" overstated it);
   `correlation_id`/`causation_id` are dead columns; docs' upcasters don't exist
   (tolerant serde defaults; `version` written — TaskCreated v4 — never read);
   projections rebuild via a manual dev command; the store moved from repo-local
   `.orca/` to `$HOME/.orca/workspaces/<key>/` (repo-local is copy-migrated legacy).
6. **CLI-driving gotchas** — ANSWERED (dispositions feed MC1-1's list): the plan-mode
   deadlock is the `ExitPlanMode` tool awaiting an approval that closed stdin can
   never deliver — orca's fix is banning `plan` for Claude on every phase (Codex
   `plan` = `--sandbox read-only`, exempt); the auditor is clamped off
   `bypassPermissions` *and* `plan` at four defense-in-depth sites;
   `docs/permission-modes.md` contradicts the code (stale "auditor defaults to plan");
   **no session resume anywhere** — every phase is a fresh spawn, continuity via
   shared worktree + per-phase auto-commits + a `prior_phase_commits` prompt map.

Cross-cutting: **§5 edit-and-resume** — execution layer verified EMPTY (subject 20):
read-only review surface, options approve/pass-back/reject/land/catch-up/re-run; the
editable-at-the-gate artifacts are the *landing* commit message and next-run config,
not step outputs. Plan layer: promote-on-accept exists (correction above).
**Provisioning lifecycles** — answered, OR1-4. **Naming** — branch `orca/{task_id}`,
dir outside the repo, hard error on collision (no counter; FLOW §4's `-{n}` remains
the better UX). **Status/attention taxonomies** — the GIT_IS_IMPLEMENTATION state
ladder (OR2-1) + a task-level rollup enum (`Idle|Running|Blocked|Failed|
AwaitingReview|Complete`, `pipeline.rs:148-157`); the pipeline **always halts for a
human after the auditor** (`pipeline.rs:971-1011`); no push/notifications of any kind
(single-user desktop — honest absent). **Teardown/stranded work** — force-delete on
every teardown path (branch included; the corpus's weak end), with a three-mechanism
orphan-detection story (pre-create cleanup, activation reconcile, orphan-list command
with `has_uncommitted_changes`) and one incidental branch-survival case
(`DiffSource::BranchOnly`). **Placement/multi-machine** — ABSENT by design
(single-machine; nothing to learn, honestly recorded).

## Scan corrections (mirrored into [../README.md](../README.md))

1. **Observation 1(b) + the orca row**: orca's briefing loop is NOT
   "re-prompt-not-promote" — Accept **promotes** the operator's draft edits verbatim
   (model never re-invoked); only Refine re-prompts, and pushback never promotes.
   Plan-layer promote-the-edit therefore exists in the field **twice** (Chorus,
   orca); argus's novelty claim stays execution-layer head-promotion (now verified
   empty across 20 subjects).
2. **"Structured auditor verdicts (severity-tagged, line-anchored)"**: severity
   confirmed (`blocking|advisory`); line anchors are prompt-instructed but **absent
   from the structured-output schema** (Codex verdicts lack them) and the anchored
   rendering is dead code at HEAD (#22 orphaned `DiffModal`; concern `path:line`
   clicks no longer navigate).
3. **"command_id idempotency, correlation_id/causation_id"**: `command_id` is
   server-minted (not caller-supplied — guards internal retries only);
   `correlation_id`/`causation_id` are never populated (dead columns); docs claim
   upcasters that don't exist.
4. **"per-repo SQLite event store (`.orca/events.sqlite`)"**: relocated — now
   `$HOME/.orca/workspaces/<key>/events.sqlite`; the repo-local path is copy-migrated
   legacy.
5. **"per-task phase pipeline (test-author → implementer → auditor)"**: the bundled
   default chain is **implementer → auditor**; test_author is supported but opt-in
   via workspace config. And "auto-queue-on-merge" auto-starts **only human-queued
   tasks** (release ≠ start).
6. **"bans even the words branch/merge/diff from UI copy and column names"**: the
   doctrine doc is real and the land flow complies (including error copy), but
   enforcement leaks — the dependency UI surfaces "merged" and "cycle"
   (`dependencies-section.tsx:185-186, 353`).

## Cross-references and dependencies

```
OR1-1 verdict payload ──┬─→ argus §5.3 / FLOW §10 gate payloads
      (anchors, AC map) ├─→ next-ten #6 review_stall (co-design; OQ-1)
                        └─→ next-ten #9 acceptance_criteria (OQ-2 producer)
OR1-2 staleness/resolution ─→ FLOW §10 landing + §6 merge_child (validates doctrine)
OR1-3 queue-then-release ──→ FLOW §7 task layer (slice 3; OQ-3) + §12 fileConflicts
OR1-4 provisioning ────────→ FLOW §5 (slice 2), composes with TR1-3 + EM1-1/-2
OR2-1 vocabulary ──────────→ argus client copy + slice-2/3 schema naming
OR2-2 gates ───────────────→ FOLD-IN next-ten #5 (verify authority)
OR2-3 pass-back rubric ────→ §5.4 notes channel + composer fix lane
OR2-4a step reprojection ──→ INDEPENDENT, adoptable now (first wave)
OR2-5 ledger/readiness ────→ next-ten #8/#9 + CH1-1 fence criteria (3rd datapoint)
OR3-1 env baseline ────────→ INDEPENDENT, adoptable now (first wave)
OR3-2 timeout/kill kinds ──→ FOLD-IN MC1-4
OR3-3 review UX ───────────→ TRACK: argus review client build
```

**Suggested first wave**: [OR-FIRST-WAVE.md](OR-FIRST-WAVE.md) — the two items
adoptable without any argus slice (OR2-4a step reprojection; OR3-1 env baseline) plus
the fold-in riders on already-queued work (#5, #6, #8/#9, MC1-4) recorded so they
don't slip. Collision note: nothing here conflicts with the in-flight queues — the
riders *land inside* next-ten items 5/6/8/9, which are exactly the items the seams
pass confirmed unstarted.

## Bottom line

1. **OR1-1** — argus's review-gate payload should start from orca's verdict schema,
   with anchors in the schema (not just the prompt), boundary validation (not
   `Vec<Value>`), and the anchor-fidelity taxonomy for every LLM-supplied `path:line`.
2. **OR1-2** — approvals go stale when the parent moves: adopt
   `clean|dirty|colliding` staleness, re-open the review after any catch-up, and make
   conflict resolution reviewable agent work (FLOW §6's doctrine, now with a shipped
   precedent).
3. **OR1-3 / OR1-4** — the task and worktree slices have their field references:
   queue-then-release with canceled-keeps-blocked, and the toolchain table with
   init-status-split + hard-stop/retry/recorded-skip.
4. The §5 sweep closes its 20th subject still empty at the execution layer — and the
   scan's last "everyone re-prompts" holdout corrected: the field promotes plan-layer
   edits twice over, so argus's remaining novelty is precisely the head-promotion
   *at gates during execution*, plus the fences (approve idempotency, revision
   history) all three trackers shipped without.
