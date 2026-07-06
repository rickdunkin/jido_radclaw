# PD first wave — the adoptable-now queue

*A sequenced grab-list, not new design. Extracted 2026-07-04 from the
[pad inventory](FEATURES-WORTH-BORROWING.md)'s "suggested first wave" — the
three entries whose trigger is satisfied by the act of deciding to work (no
argus slice required). Everything else in the inventory is argus-slice-bound
and stays there (PD1-3 → slice 3's schema review, PD1-4's build → the FLOW §9
store, PD2-2 → slices 1/3, PD2-3 → the §4.4 build, PD2-4 → the next served-tool
addition); the doc-hardening halves of PD1-3/PD1-4 already landed with the dig
itself. Refs inherited from the inventory (verified there 2026-07-04 @
jido_radclaw `609350aa`, pad `bcc4a69`); re-verify at build time.*

**Queue discipline** (the next-five/next-ten habit): each item ends by
reconciling its source entry — add the dated Status line (the inventory carries
none yet; this queue is pad's first adoption pass), correct any claims the
implementation falsified, and update cross-refs the same session. Item 1
additionally reconciles **two other docs' entries** (it supersedes a queued
rider — see its Done-when).

**Effort legend**: XS ≤ 2h · S ≤ 1 day · M 2–4 days.

| # | Item | Source | Effort | Shape |
| --- | --- | --- | --- | --- |
| 1 | Served-surface stability contract (version fix + golden + `_meta` resource) — ✅ DONE 2026-07-06 (inside next-ten #6, bootstrap rider included) | [PD1-1](FEATURES-WORTH-BORROWING.md#pd1-1-the-served-surface-stability-contract--advertised-versions-bump-rules-and-the-rot-lesson) | S | One PR: constant + resource + golden test (+ bootstrap rider) |
| 2 | Closed-at-the-boundary error-code contract | [PD1-2](FEATURES-WORTH-BORROWING.md#pd1-2-closed-at-the-boundary-error-codes--typed-self-correction-hints) | S | One registry module + subset test + hint fields |
| 3 | `/setup` as a state-derived doctor | [PD3-1](FEATURES-WORTH-BORROWING.md#pd3-1-init-as-a-state-derived-doctor-not-a-wizard) | S | One command rework + `--check` mode |

All three are independent — no load-bearing sequencing. Item 1 goes first
anyway: it fixes a live defect (the `0.2.0` advertisement) and supersedes a
rider already queued elsewhere, so landing it early keeps two queues honest.

---

## 1. PD1-1 — Served-surface stability contract (S) — ✅ DONE 2026-07-06

> **Done 2026-07-06, inside next-ten #6** (the cross-queue supersession
> executed as written). Sketch items (a)–(e) shipped whole, the PD2-1 slim
> rider included; every Done-when clause holds (real versions on handshake +
> `jido://_meta/version`; the golden fails un-bumped surface changes; Status
> lines landed on PD1-1, PD2-1, traycer TR1-2(a) = PARTIAL, and the next-ten
> #6 entry). One shape note: `app_version/0` single-sources on the
> `SurfaceVersion` module (four consumers — `server_info`, `_meta/version`,
> `bootstrap`, `project_info`) rather than a private helper per module.

**What**: the pad-advertisement half fused with the traycer-enforcement half,
one PR (the inventory's sketch, verbatim scope): (a) derive `serverInfo.version`
from `Application.spec(:jido_claw, :vsn)` — kill the hardcoded `"0.2.0"`
(`core/mcp_server.ex:14` vs `mix.exs:4`); (b) a `SurfaceVersion` constant
(start `"1.0"`) with pad-style bump-rules + changelog doc comment
(`internal/mcp/version.go:50-139` is the reference shape); (c) a
`jido://_meta/version` resource (`{app_version, surface_version, tool_count}` —
house resource machinery, ~20 lines) and `app_version` added to `project_info`;
(d) **the golden test**: a committed fixture holding the sorted tool-name list +
resource URIs **+ the surface-version string**, so any catalog change forces a
fixture regen and the regen diff shows whether the version moved with it —
closing the enforcement hole pad demonstrated (their handshake instructions
rotted three versions behind their constant); (e) the doctrine line in the
module doc: prose descriptions of the surface live next to the constant.

**Rider — PD2-1's slim cut**: the same PR's resource plumbing cheaply carries a
first `jido://bootstrap` resource (tenant-scoped: app+surface version, tool
names, workspace identity, pending-gates count, recent runs capped with
`*_overflow_count` fields — pad's bounded-payload discipline,
`handlers_bootstrap.go:283-298`). Optional scope: cut it if the PR grows; the
full version (per-token tool-allowlist view) is slice-6-bound either way.

**Done when**: the served surface advertises real versions on handshake +
resource; the golden test fails on any un-bumped catalog change; PD1-1 (and
PD2-1 if the rider shipped) get Status lines. **Cross-queue reconciliation**:
this build satisfies and supersedes the TR1-2a rider queued under
[next-ten #6 step 6](../../../plans/unadopted-next-ten/README.md) — note it
there — and the (a) slice of
[traycer TR1-2](../../ades/traycer/FEATURES-WORTH-BORROWING.md#tr1-2-released-surface-golden-test--new-capabilities-ride-existing-names)
gets its dated Status line (PARTIAL: the MCP surface; SDL/Channels goldens stay
argus-bound).

## 2. PD1-2 — Closed-at-the-boundary error-code contract (S)

**What**: camus C1-3's boundary posture applied to the tool surface — the
interior stays open (any atom), the served contract closes. (a) Enumerate the
served-surface code families in one module attribute (~25 atoms: approval,
doom_loop, lua_*, sandbox_*, tenant_required, replay/workflow families, plus
`Error.normalize`'s struct codes — `tools/error.ex:191-202,397-403`); (b) a
test sweeping observed envelopes asserting emitted codes ⊆ the registry — a new
code joins deliberately, in the same diff as its docs (pad's "a TWO-WAY
change", `errors.go:354`); (c) a stability sentence in the served tool
descriptions; (d) typed hint fields inside `details` for the common
self-correction cases (`expected/got` on validation, `available` on
unknown-name lookups — pad's `ErrorPayload` shape, `errors.go:158-204`),
generalizing the LoopGuard-directive precedent.

**Scope guard**: served MCP only — OQ-2 (REST/GraphQL adoption) stays open; do
not build a global internal enum.

**Done when**: registry + subset test green; hint fields on the two named
cases; the stability sentence ships; PD1-2 gets its Status line and OQ-2 is
re-dated with whatever the build taught.

## 3. PD3-1 — `/setup` as a state-derived doctor (S)

**What**: teach setup the `pad init` posture (`cmd/pad/init.go:83-320` — six
steps, each re-derived from live state, act-only-on-missing, status summary
when nothing to do, no marker files). Ours today is a first-run wizard whose
re-run **replaces `config.yaml` wholesale** (`cli/setup.ex:16-34,66-68`).
Rework: per-step live checks — config present, provider key valid (via the
shipped `Config.check_provider/1` — the XA2-3 canary probe, here given a manual
invocation surface), voyage key, model reachable, DB migrated — with a
`--check` mode that prints the derivation and changes nothing, and a default
mode that acts only on gaps.

**Done when**: re-running setup on a healthy install is a no-op that prints
status; a single missing piece is repaired without touching the rest;
`--check` exists; PD3-1 gets its Status line (and the XA2-3 entry gains a
cross-ref note — the *scheduled* canary remains unbuilt and separately
tracked).

---

**Collision notes**: item 1 supersedes next-ten #6's TR1-2a rider (reconcile
both queue docs when it lands — the note above); nothing here touches the
next-ten composer/judgment items 4–10. Kinship, not collision: item 2's
registry is the same boundary-vocabulary conversation as camus C1-3's
`Verdict` (design them to read as one family), and if
[MC-FIRST-WAVE item 3](../multica/MC-FIRST-WAVE.md) (exit-code tiering for
`mix jidoclaw run`, XS, still queued) lands, its tier mapping should consume
item 2's registry rather than re-sniffing envelopes — whichever lands second
adds the cross-ref. Items 1+2 together are the inventory's "fix our own rot +
close the contract" bottom line; item 3 is a standalone day.
