# Plan: Setup Doctor — Configuration Truth, Diagnostics, and the Provider Authority

*Umbrella direction + phased adoption — not one executable plan.*

Make `/setup` a state-derived doctor (pre-argus do-now **#17**, pad PD3-1) —
and land the runtime provider-settings authority that item turned out to
require. What began as one "S"-sized CLI item
([queue §17](../pre-argus-do-now/README.md)) grew, under two rounds of plan
drafting re-verified against HEAD `4cf076dc` (2026-07-12 and 2026-07-14, each
with multiple review rounds plus an integration stress-test), into work
spanning dotenv compatibility, an HTTP transport, Ecto migration
introspection, escript packaging, secret routing, human authorization, ReqLLM
integration, and concurrent runtime configuration. A build-order section
inside one plan cannot isolate those risks; this group splits them into six
independently shippable workstreams.

The superseded draft (`.claude/plans/…-generic-scone.md`, local) is **not**
lost: its binding operator decisions, review-hardened invariants, HEAD-drift
facts, and stress-test resolutions are preserved as the contract inventory in
[CONTRACTS.md](CONTRACTS.md), each entry tagged with the workstream that owns
it. The WS docs carry the mechanics; CONTRACTS.md is the review rubric.

---

## The load-bearing discovery: the doctor needs an authority first

The verified gap that blew the scope up: **generation never consumes the
configured provider endpoint or credential.**

- `config.yaml`'s `providers.<p>.base_url` (including the auto-cloud
  `https://ollama.com` write, `core/config.ex:94-111`) is read ONLY by the
  health probe today. Generation resolves through ReqLLM (per-request opt →
  `:req_llm` app env → provider default), and **nothing installs the config
  value into that chain** — no `lib/` call site passes `base_url:`, no
  `:req_llm` put exists anywhere.
- Likewise the configurable `api_key_env` is invisible to ReqLLM's
  `Keys.get/2` (per-request opt → app config → the provider's FIXED env
  var), and `Provider.Defaults` always requires a key — keyless local ollama
  fails generation despite a green probe.

So a doctor that probes the configured endpoint would **certify settings
generation never uses**. The 2026-07-14 operator interview bound the outcome
(Branch A: wire it — [CONTRACTS OD-1](CONTRACTS.md)), and the draft built it
as an `Application.put_env(:req_llm, …)` bridge. Architecture review rejected
that mechanism: mutable application env as a runtime control plane is global,
unfenced, torn-write-prone between the endpoint and credential legs,
load-order-sensitive, and entangled with test save/restore. The redesign — one
atomic endpoint-and-credential snapshot consumed at the Jido/ReqLLM request
seam — is **SD5**, its own architecture/security item
([queue #17b](../pre-argus-do-now/README.md)), no longer part of "make
`/setup` a doctor."

A second load-bearing fact anchors SD1: **ReqLLM and LLMDB each auto-load cwd
`.env` into System env at their app start**, before `JidoClaw.Application`
runs — so with `project_dir ≠ cwd` the doctor and full boot can resolve
*different* credentials. One dotenv authority is a prerequisite for every
diagnostic above it.

---

## Background — what ships today

| Area | Status | Where |
|---|---|---|
| `/setup` wizard — replaces `config.yaml` wholesale, session-only credentials | shipped (the behavior #17 exists to fix) | `cli/setup.ex` |
| `check_api_key` — sends Bearer to ALL providers (wrong for anthropic/google), 5s `:httpc` | shipped, scheme-wrong | `core/config.ex:362-379` |
| `check_ollama` — status-only, never parses `/api/tags` | shipped | `core/config.ex:348-360` |
| Dotenv boot loader — four-path first-wins chain, parse entangled in `application.ex` | shipped | `application.ex:639-699` |
| Dep dotenv auto-load (ReqLLM + LLMDB, cwd `.env`, default ON) | shipped hazard | deps' `application.ex` / `dotenv.ex` |
| Escript `--setup` arm — full boot via `start_app_or_halt!()`, bundles no `priv/` | shipped (#16 rewrote it) | `cli/main.ex:75-87`, `:42-44` |
| `:force_setup` | dead code at HEAD | `main.ex:82`, `setup.ex:22` |
| Generation-env consumption of configured `base_url`/`api_key_env` | **does not exist** — the SD5 gap | (verified absent) |

## Workstream summary

```
SD1   Configuration foundation    EnvResolver, one dotenv codec, dep-loader policy,     [keystone]
                                  pure effective-provider derivation, EndpointTrust read-side
SD2   Provider diagnostics        ProviderProbe, bounded Mint adapter, per-provider     (needs SD1)
                                  auth/model semantics, endpoint verdict
SD3   Migration diagnostics       MigrationManifest, bounded DB probe, ScratchRepo      (independent)
SD4   Read-only doctor  (#17a)    Doctor.derive/2, report, minimal boot, --check,       (needs SD1–3)
                                  REPL check, exit codes — zero mutation
SD5   Runtime provider authority  atomic settings snapshot + ReqLLM consumption seam,   (needs SD1)
                                  refusal, fencing, operator authorization  [own queue item #17b]
SD6   Repair & reconfigure        repair loop, persist offers, merged YAML writes,      (needs SD4, SD5)
                                  /setup reconfigure — completes PD3-1
```

| SD | Doc | Size | Depends on |
|---|---|---|---|
| SD1 | [SD1-configuration-foundation.md](SD1-configuration-foundation.md) | M | — |
| SD2 | [SD2-provider-diagnostics.md](SD2-provider-diagnostics.md) | M | SD1 |
| SD3 | [SD3-migration-diagnostics.md](SD3-migration-diagnostics.md) | S–M | — |
| SD4 | [SD4-read-only-doctor.md](SD4-read-only-doctor.md) | M | SD1, SD2, SD3 |
| SD5 | [SD5-runtime-provider-authority.md](SD5-runtime-provider-authority.md) | M–L | SD1 |
| SD6 | [SD6-repair-and-reconfigure.md](SD6-repair-and-reconfigure.md) | M–L | SD4, SD5 |

**Recommended sequence:** SD1 first (the keystone — SD2 consumes its
derivation and trust classification). SD3 is fully independent and can run
any time. SD4 ships once SD1–SD3 land — it is **#17a, the first user-facing
deliverable**: an honest `--check` and `/setup check` beside today's
untouched wizard. SD5 can start any time after SD1 and should be interviewed
early (it carries the open control-plane decisions). SD6 goes last — its
repairs must reconcile through SD5's authority so `:repaired` is never
reported while generation still resolves old state.

**Shipping rules carried from the draft (now per-workstream):**

- **Docs and queue reconciliation land with each workstream**, not in one
  final sweep — each WS doc has its own "Docs & reconciliation" section with
  the exact Status lines it owes.
- Each WS maintains its own `## Deviations` log as it is implemented (the
  house planning convention).
- No PORT map required (posture/contract lift — `docs/exploration/README.md`
  rule), re-affirmed per WS.

## Coverage map — the superseded draft's sections → workstreams

Nothing from the draft falls through. (Contract-level coverage is the
per-entry WS tags in [CONTRACTS.md](CONTRACTS.md).)

| Draft section | Covered by |
|---|---|
| §1 minimal boot + entry-point rework (check lane) | **SD4** |
| §1 read-only bounded DB probe | **SD3** |
| §2 `EnvResolver` + one dotenv codec + dep-loader policy | **SD1** |
| §3 effective-provider derivation | **SD1** |
| §3 `apply_generation_env` (Branch A bridge) | **SD5** — mechanism redesigned, outcome binding (OD-1) |
| §3 `EndpointTrust` (CB1-1 boundary) | **SD1** (read-side) + SD4 (gating) + SD5 (enforcement) + SD6 (interactive confirm) |
| §4 `Doctor` pure derivation | **SD4** |
| §5 `ProviderProbe` + Mint adapter + endpoint verdict | **SD2** |
| §6 `cli/setup.ex` rework (repairs, persistence, wizard integration) | **SD6** |
| §7 `--check` plumbing + exits | **SD4** (check subset) + **SD6** (full map) |
| §8 tests | distributed into each WS's test plan |
| §9 docs + reconciliation | distributed into each WS's "Docs & reconciliation" |

## Queue linkage

- [pre-argus do-now §17](../pre-argus-do-now/README.md) — SPLIT into this
  group (Status recorded there, 2026-07-14). **#17a** = SD4. PD-FIRST-WAVE
  item 3's done-when completes at **SD6**.
- **#17b** (new queue entry) = SD5, the runtime provider-settings authority.
- Cross-refs owed along the way: ades **XA2-3** (SD2 — #6's canary should
  consume `ProviderProbe`), crabbox **CB1-1** partial (SD5 — the
  endpoint/credential-egress slice; queue #15(a) generalizes from the
  `EndpointTrust` precedent).

## Related docs

- [CONTRACTS.md](CONTRACTS.md) — the preserved contract inventory: binding
  operator decisions (OD), review-hardened invariants (INV), HEAD-drift facts
  (HD), stress-test resolutions (ST). **Read before implementing any WS.**
- `docs/exploration/pms/pad/PD-FIRST-WAVE.md` item 3 — PD3-1's done-when.
- `docs/exploration/pms/pad/FEATURES-WORTH-BORROWING.md` PD3-1 (`:577`).
- `docs/exploration/sandboxes/crabbox/FEATURES-WORTH-BORROWING.md:129` —
  CB1-1, the credential-redirection shape SD5's trust boundary closes a
  slice of.
- `docs/exploration/ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md:100`
  — XA2-3, the manual provider-check surface SD2 provides.
- [../pre-argus-wave-e-16/README.md](../pre-argus-wave-e-16/README.md) — the
  #16 build that rewrote `cli/main.ex` (HD-1) and set the plan-doc shape.
- [../clustering/README.md](../clustering/README.md) — the umbrella-group
  precedent this group mirrors.
