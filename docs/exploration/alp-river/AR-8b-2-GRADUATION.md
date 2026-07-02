# AR-8b-2 — Sketch Graduation & Follow-ons (phased design)

*Architecture direction — the deferred half of AR-8b. Extends AR-8b / AR-2 §8. Not a commitment.*

**Status — SHIPPED in full (C1+C2+C3 `40383c2a` 2026-06-23, F1+F3 `d72b655d` 2026-06-24, F2
2026-06-24..25; reconciled 2026-07-02).** How each phase resolved against its forks:

- **C1** — as recommended: **reference + summary** (`premises["graduated_from"]` + an `intent`
  summary, stashed even when nil); the real run starts fresh, never auto-merges.
- **C2** — as recommended: **debounce**, off a bounded `metadata["path_transitions"]` log,
  fail-open, surfacing a "re-send to confirm" ack instead of a silent block.
- **C3** — as recommended: **never-GC default + opt-in TTL sweep** —
  `VFS.PrototypeRetentionSweeper` (`config :jido_claw, prototype_retention: [max_age_days: N]`,
  hourly, and the referenced-check is fail-safe via `Orchestration.PrototypeReference`).
- **F1** — shipped **report-only** (the recommended fork), with one design correction: this
  doc's `subscribes: ["prototype"]` names an *artifact*, which the validator rightly rejects
  (signals and artifacts are different namespaces) — the shipped `sketch-review` subscribes
  `request-received` and depends on the prototype via `input.required`.
- **F2** — shipped as its own plan ([`AR-8b-2-F2-EXEC-TIER.md`](AR-8b-2-F2-EXEC-TIER.md)):
  `sketch_build_exec` / `sandbox: :docker`, hard-fail (never host fallback), no-egress.
- **F3** — shipped as the **dedicated read-only tools** *alternative* (`read_real_file` /
  `search_real_code` / `list_real_directory`), not the read-only-mount recommendation; the
  invariant held (every write stays in `.prototypes/<id>/`).

*(Write-time status, kept for the record:)* AR-8b shipped the **sketch path itself** as a genuine
composer route with a real capability boundary: a `sketch` turn launches a `sketch-build` worker
in a hard-isolated, per-prototype `<project>/.prototypes/<uuid>/` sandbox (file tools only), and
the run **converges trivially** when the worker finishes. This doc designs the parts AR-8b
deferred — all **cross-run** or **richer-isolation** concerns that the in-run sketch path does
not need.

## What shipped in AR-8b (the substrate this builds on)

The pieces below are live and are the hooks every phase here rides:

- **`sandbox: :prototype` template policy** (`JidoClaw.Agent.Templates`). One fact drives four
  independent, structural enforcements — none relying on the LLM or a prompt:
  - no external MCP tools (`MCP.Consumer.modules_for_template/3` via `Templates.external_tools?/1`),
  - no remote file schemes (`VFS.Resolver` `local_only:` → `{:error, {:remote_forbidden_in_sandbox, _}}`),
  - a validated sandbox root (`VFS.Sandbox` — symlink-rejecting creation + realpath/shape
    `validate_root/1`),
  - composer-private instantiation (`AgentRunner.run/4` validates the scope + stamps the
    `tool_context[:sandbox]` capability from the template; `spawn_agent` / `send_to_agent` /
    `handoff` **and** the handoff **router** all refuse a `sandbox: :prototype` template).
- **The front-door sketch seam** (`FrontDoor.sketch_scope/2`). Creates the per-prototype sandbox via
  `VFS.Sandbox.create_prototype_dir/1`, reroots `project_dir` to `.prototypes/<id>/` and the
  `workspace_id` to `<ws>:proto:<id>`, and persists **`premises["prototype_id"]` /
  `premises["prototype_dir"]`** on the composer parent run. A sandbox failure is a bounded
  `{:error, {:sketch_sandbox_unavailable, _}}` ack — never a fall-through to the inline agent.
- **The `sketch-build` catalog stage** (`RouteComposer.Catalog`). `routes: ["sketch"]`,
  `subscribes: ["request-received"]`, publishes only the mandatory `scope-shift`. Its worker emits
  **no signals** (no `signals` output field → `DefaultMapper.explicit_signals/1` returns `[]`), so the
  route converges the moment it finishes. On a `code`/`system` run the route-filter (`Router`
  `on_live_path/3`) drops it `:off_path`.
- **Triage stickiness** (`FrontDoor.decide/2` + `persist_path/2`). Every turn is re-classified; the
  prior path is stored under `Session.metadata["last_triage_path"]` (observability/cold-start only,
  never read to decide). Graduation rides exactly this.

The remaining work is **provenance** (carry the prototype into a graduating run), an **oscillation
guard** (cross-run thrash), **retention** (when a `.prototypes/<id>/` dir dies), and three richer
follow-ons (light review, code-exec tier, read-only real-tree access).

---

## Phase C1 — Prototype provenance into the graduating run

**Goal.** When triage re-classifies a later turn from `sketch` to `code`/`system`, carry the prior
prototype into the fresh composer seed so "throwaway becomes real" doesn't start from a blank slate.

**The hooks (already persisted).** The prior sketch run's parent carries
`config["premises"]["prototype_id"]` and `["prototype_dir"]`; the session carries
`metadata["last_triage_path"] == "sketch"`. The graduating turn is a *new* `decide/2` call, so C1
reads those hooks at the front door **before** building the new composer seed.

**Detection.** In `FrontDoor.decide/2`, when the fresh verdict is `code`/`system` **and** the
session's `last_triage_path` was `sketch`, look up the most-recent `sketch` composer run for the
session (the parent whose `premises["prototype_id"]` is set) and read its prototype dir. Keep this a
best-effort lookup: a missing/garbage-collected prototype just means a normal `code`/`system` launch
(zero behavior change), never a failure.

**The open form — how the prototype is carried.** Three options, in increasing coupling:

| Option | Carries | Pro | Con |
| --- | --- | --- | --- |
| **By-ref** | the `.prototypes/<id>/` path in the seed `premises` | cheap; the real run can read it on demand | the real run is sandbox-isolated from `.prototypes/` (it runs against the real tree), so a raw path is unreadable without the F3 read-only view |
| **Re-read** | the prototype files inlined into the seed `request` artifact | self-contained; survives GC | can blow the seed size; pulls throwaway code verbatim into a reviewed run |
| **Summary** *(recommended)* | an `intent`/`request` summary of what the prototype established | small, durable, decoupled; the real run starts clean against the real tree | a summarization step (cheap; the verdict's `intent` already distills the turn) |

**Recommendation.** A **reference + summary**: seed the new run's `intent` with a short summary of
the prototype ("a tracer-bullet rate-limiter using a token bucket in `lib/…`") and stash the
`prototype_dir` in `premises["graduated_from"]` for provenance/observability. **The real run starts
fresh against the real tree — the prototype *informs*, it does not auto-merge.** Auto-merging a
throwaway prototype into the real tree would defeat the entire isolation boundary AR-8b built.

**Why not just hand the prototype files to the implementer.** Because the prototype was built with
*no real-tree context* (full isolation, F3) — it is a sketch, not a patch. Merging it would import
code that never saw the real surrounding modules. The summary is the honest contract: "here's what
the exploration found; now build it for real."

**Surface.** A new `premises["graduated_from"]` key (the prior `prototype_id`/`dir`) + an `intent`
seed derived from the prototype. No new persisted-context keys; rides the existing seed path.

---

## Phase C2 — Oscillation guard (cross-run)

**Goal.** Stop a `sketch ⇄ code` flip-flop from thrashing brand-new composer runs.

**Why AR-2's guard doesn't cover it.** AR-2 §4's oscillation guard is **within-loop** — it bounds a
single composer run's wave count and re-trigger churn. Graduation (C1) and its inverse ("actually,
just sketch it") are **cross-run**: each is a *new* `decide/2` → new parent run. Nothing today
bounds how often the front door can mint a new run for the same session as triage flips the path.

**Where the guard belongs.** At the **front-door / triage level**, keyed on `(session, recent path
history)`. The session already records `last_triage_path`; extend that to a short bounded
**path-transition log** (e.g. the last N `{path, run_id, at}` entries in `Session.metadata`, N≈6,
absolute timestamps). The guard reads it before launching a graduating run.

**Guard shape (design options).**

- **Debounce** — refuse to mint a new run if the *same* `sketch→code` (or `code→sketch`) transition
  fired within a short window (e.g. 2 transitions in 60s ⇒ ask the user to confirm rather than
  auto-launch). Cheap; catches accidental thrash.
- **Hysteresis** — once a session has graduated `sketch→code`, require an explicit
  sketch-again signal (not mere ambiguity) to flip back. Biases toward "forward progress".
- **Budget** — cap composer runs per session per window; beyond it, the front door returns a bounded
  ack ("you've started several runs quickly — continue the existing one?") instead of launching.

**Recommendation.** Start with **debounce** (simplest, observable, no new durable state beyond the
transition log) and treat hysteresis/budget as escalations if telemetry shows real thrash. The guard
must **fail open to today's behavior** (launch the run) when the transition log is missing/unreadable
— never block a legitimate first graduation.

**Telemetry.** Emit a `:triage` / front-door trace event on every guard *intervention* (what it
suppressed and why), so a suppressed run is never invisible (mirrors the "no silent caps" rule).

---

## Phase C3 — Retention / cleanup of `.prototypes/<id>/`

**Goal.** Decide when (if ever) a per-prototype sandbox dir is garbage-collected.

**Current behavior (AR-8b).** **Never auto-GC.** `.prototypes/` is `.gitignore`d, so prototypes
accumulate on disk but never pollute the repo or a commit. This is the safe default — no data is
ever lost out from under a graduation that might still want C1 provenance.

**The decision (explicit options).**

| Policy | GC when | Pro | Con |
| --- | --- | --- | --- |
| **Never** *(current)* | — | simplest; C1 can always re-read; zero risk of yanking a live prototype | unbounded disk growth over a long-lived project |
| **On graduation** | a `sketch→code`/`system` run starts from this prototype | tidy; the prototype's job is done once it informs a real run | loses the prototype if the real run is abandoned and the user wants to re-sketch |
| **On session end** | the owning session closes | bounded by session lifetime | a prototype referenced cross-session (rare) is lost |
| **TTL sweep** | dir mtime older than N days | bounded growth, survivable | a background sweeper + the usual "is it still referenced?" race |

**Recommendation.** Keep **never** as the default (matches the `ComposerArtifact` retention posture —
durability over tidiness) and add an **opt-in TTL sweep** as the bounded-growth escape hatch: a
periodic task that removes `.prototypes/<id>/` dirs whose mtime exceeds a configured age **and** whose
`prototype_id` is not referenced by any non-terminal run. Single-source the "is it referenced?" check
so the sweeper can't race a graduating run. Document the chosen default the same way the
`ComposerArtifact` retention note does.

**Non-goal.** Auto-GC on graduation — too easy to yank a prototype a user still wants (the real run
can be abandoned; the user may re-sketch). Make deletion conservative and observable.

---

## Follow-on F1 — Light-lens `sketch-review`

**Goal.** Catch a genuinely-broken prototype without the full code-only review ceremony.

**Today.** The sketch route is **minimal**: `sketch-build` runs, emits no signals, the route
converges. The four reviewers + `fixer` are `routes: ["code"]`, so the route-filter drops them on a
sketch run automatically — there is no review at all.

**Design.** Add a `sketch-review` catalog stage: `unit: {:worker_template, "reviewer"}`,
`routes: ["sketch"]`, `lens: "correctness"` (and/or `"security"`), `subscribes: ["prototype"]` (the
artifact `sketch-build` outputs), `input: %{required: ["prototype"], optional: []}`.

**Validator obligations (the gotchas).** A `lens`-carrying `emit: :default` stage **must** declare
**both** `clean:<lens>` and `findings:<lens>` in `publishes` (`CatalogValidator` invariant 8), and
its worker must emit the reviewer `overall` shape (`DefaultMapper.reviewer_verdict/3` —
`approve`/`request_changes`/`comment` + optional `findings`). Then `clean:<lens>` gates convergence
exactly as it does on the code path, and a broken prototype surfaces `findings:<lens>` instead of
silently converging.

**Convergence interaction.** With a lens present, the loop's `lenses_clean?` is no longer trivially
true — convergence now requires `clean:<lens>`. Keep the lens set **minimal** (correctness, maybe
security) so a sketch stays light; the full quality/architecture band remains `code`-only.

**Open.** Whether `sketch-review` should be able to loop back into `sketch-build` on findings (a
fix→re-review mini-loop) or just report. Recommendation: **report only** for the first cut — a sketch
that needs fixing is a signal to graduate to `code`, not to perfect in the sandbox.

---

## Follow-on F2 — Code-execution sketch tier (`sandbox: :docker`)

**Goal.** Let a sketch that must *run* a tracer-bullet do so with real OS isolation.

**Why a new tier.** `sketch-build` is **file tools only** — deliberately, because `RunCommand`
shells to the **host** and escapes the VFS jail entirely (the jail only constrains file-tool paths).
A sketch that needs to execute code therefore needs OS-level isolation (filesystem, process,
network), which the VFS jail does not provide.

**The hook.** The `sandbox` template policy was designed to anticipate exactly this: `:prototype`
means the file jail; **`:docker`** would mean Forge Docker isolation (`forge/sandbox/docker.ex`).
The enforcement table generalizes — `:docker` is "the file jail **plus** an OS sandbox for
`RunCommand`", and `external_tools?/1` would still be false (a sandboxed tier never gets external MCP
tools). `validate_sandbox_scope` / `stamp_sandbox` already key on the policy value, so adding a tier
is a new policy branch, not a new mechanism.

**Design sketch.**

- A `sketch_build_exec` worker template with `sandbox: :docker`, carrying `RunCommand` **bound to a
  Forge Docker runner** (not the host shell), plus the file tools jailed to the prototype dir.
- A `sketch-build-exec` catalog stage (`routes: ["sketch"]`), selected when triage's early signals
  indicate the sketch must execute (e.g. a `significant-build` signal on a sketch, or an explicit
  "run it" intent). Otherwise the file-only `sketch-build` stays the default — Docker is heavier.
- `AgentRunner` gains a `:docker` branch in `validate_sandbox_scope`: the launch scope must be a
  Forge sandbox session, not just a `.prototypes/` dir.

**Open — does a code-executing sandboxed sketch need a gate?** Throwaway argues *no ceremony*, but a
sketch that can reach the **network** inside a sandbox might still warrant a safety check (data
exfiltration from a sandbox is still exfiltration). Likely **no gate** if the Docker sandbox is
network-isolated by default; revisit if a network-reachable sandboxed sketch is allowed. This is the
one place a sketch tier might earn a gate.

**Prerequisites.** The `sbx` CLI / Docker Desktop (or equivalent) must be available;
`FORGE_SANDBOX=docker`. The default `HostShell` backend is explicitly **not** isolated, so the tier
must hard-fail (not silently fall back to host) if Docker is unavailable — failing to a tool-less
file-only sketch is acceptable; failing *open* to host execution is not.

---

## Follow-on F3 — Read-only access to the real project

**Goal.** Let a prototype be *informed* by the real tree without being able to *mutate* it.

**Today (the deliberate first-cut limitation).** The sketch sandbox is **fully isolated** — the
worker cannot read the real project at all (`project_dir` is rerooted to `.prototypes/<id>/`; remote
schemes are forbidden). This keeps the boundary dead simple ("writes land in `.prototypes/`, full
stop") but limits prototype quality: a sketch can't see the real modules it's prototyping against.

**Design options (all writes still stay in `.prototypes/<id>/`).**

- **Read-only mount of the real tree.** Mount the real `project_dir` into the sandbox workspace as a
  **read-only** VFS mount (`Jido.Shell.VFS` mount table) at a distinct path (e.g. `/real`). The
  Resolver would route reads there but reject writes (a new `read_only:` mount flag, enforced at
  `parse_path` like `local_only`). Cleanest if the VFS mount layer can express read-only.
- **Bounded summaries.** A pre-sketch step that summarizes the relevant slice of the real tree into
  the seed `request` (the C1 summary pattern, inverted). No live reads; bounded; but stale and lossy.
- **Dedicated read-only tools.** A `read_real_file` / `search_real_code` tool pair, available only to
  the sketch worker, that read the real tree through the jail with writes structurally impossible (no
  write counterpart exists). Most explicit; smallest blast radius; but a new tool surface.

**Recommendation.** The **read-only mount** if the VFS layer supports a read-only flag cleanly —
it's the least new surface and composes with the existing Resolver jail (add a `read_only` violation
alongside `local_only`). Otherwise the **dedicated read-only tools** (explicit, auditable). In all
cases the invariant is unchanged: **every write lands in `.prototypes/<id>/`; the real tree is
read-only, period.** This is what makes F3 safe to add without re-opening the AR-8b boundary.

**Interaction with C1.** F3 is what makes by-ref provenance (C1) actually useful — with a read-only
view of `.prototypes/`, a graduating run could read the prototype directly rather than relying solely
on a summary. So F3 and C1 reinforce each other; ship F3 to unlock by-ref graduation.

---

## Dependency / sequencing notes

- **C1 → C2.** Ship provenance (C1) and the oscillation guard (C2) together — graduation that thrashes
  is worse than no graduation. C2 fails open, so it's safe to land incrementally.
- **C3** is independent (a retention concern off the routing path); the **never** default is already
  live, so C3 is "add the opt-in TTL sweep when disk growth becomes real".
- **F1 / F2 / F3** are independent of C1–C3 and of each other. F3 unlocks richer C1 (by-ref); F2 is
  the heaviest (new isolation backend) and gated on Forge Docker availability.
- Everything here is **cross-run or richer-isolation** — none of it changes the in-run sketch path
  AR-8b shipped, which stays the minimal, file-only, trivially-converging default.
