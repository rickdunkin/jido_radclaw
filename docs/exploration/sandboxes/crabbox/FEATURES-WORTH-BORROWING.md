# Features Worth Borrowing from crabbox

Exploration notes — not a plan, not a commitment. Deep-dive **2026-07-03**, fulfilling the
crabbox next-step of the [sandbox landscape scan](../README.md). Source:
`~/workspace/research/sandboxes/crabbox` (openclaw/crabbox, HEAD `62831c89`, v0.34.x-dev).
Self-description: *"Crabbox is a generic remote software testing and execution control
plane … Warm a box, sync the diff, run the suite."* Shape: a Go CLI (~381k LOC, 855 `.go`
files under `cmd/` + `internal/`) plus an optional TypeScript coordinator (`worker/src`)
that runs as either a Cloudflare Worker + Durable Object **or** Node.js + PostgreSQL.
Maturity: 1,668 commits in ~9 weeks (first commit 2026-04-30), 34 tagged releases
(0.14→0.34), two dominant authors (683 + 646 commits) with a real ~10-contributor tail,
active the day of this review, **MIT**, pre-1.0. Everything below is from reading docs +
source; **crabbox was not installed, built, or executed during this review** — runtime
claims are per-docs/per-code until a spike, and its coordinator was read but not deployed.

crabbox is, by its own front-matter, **explicitly not a sandbox**: *"Do not use it as a
replacement for CI, a hostile multi-tenant sandbox, a secrets scrubber, or an isolation
boundary between mutually untrusted users"* (`README.md:46-47`). It sits on the
**scale-out / evidence axis**, orthogonal to the isolation axis the rest of this corpus
studies — which is exactly why the scan parked it. This dig confirms that placement and
harvests the discipline, not the machine.

Companion docs: the [sandbox landscape scan](../README.md) (this doc answers its crabbox
park-item); [nono](../nono/FEATURES-WORTH-BORROWING.md) and
[openshell](../openshell/FEATURES-WORTH-BORROWING.md) (the scan's "coordinator-owned
credentials worth studying" pointer resolves to their phantom-token / placeholder-resolver
brokering — N2-2, OSH1-1 — **already covered**; crabbox's *distinct* credential borrow is
the provenance guard CB1-1, which neither has); [pi-sbx-llamacpp](../pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md)
(crabbox's shipped `sbx` adapter is third-party evidence for its OQ-1 — see CB-note-1);
`docs/exploration/camus/FEATURES-WORTH-BORROWING.md` (C1-3 verdict-normalizer converges
with crabbox's capsule-replay outcome taxonomy — CB2-2); and the
[argus overview](../../argus/OVERVIEW.md) (the tailnet-cluster future that gates CB2-2/CB3-1).
Threat-model weighting as ever: personal, single-operator, tailnet-only — LLM-misbehavior
containment and leakage hygiene over external-attacker or multi-tenant hardening. That
weighting *raises* crabbox's value on one axis: it is an unusually rigorous codebase on
**credential-destination and destructive-op safety**, which is precisely our axis.

## Determination (TL;DR)

**SKIP as a dependency; borrow the security discipline.** crabbox is a 381k-LOC remote
execution *control plane* with a two-runtime coordinator, 70 provider adapters, spend
caps, and a fleet portal — the machinery of a cooperative team sharing cloud capacity
without sharing cloud keys. A single-operator tailnet with no team, no shared cloud
credentials, and no fleet has nothing to custody, so the whole raison d'être evaporates on
contact. Where crabbox overlaps something we have (SSH remote command execution), it is a
far heavier machine than our shipped `run_command backend:ssh` path. **But** it earns its
place as a concept donor the way agentos did: its *patterns* are sharp on our exact threat
axis. Two are present-day defects on our side (a config-injection credential leak and an
ownership-blind sandbox reaper); the rest are triggered follow-ups.

| Part of crabbox | As a dependency | What to take |
| --- | --- | --- |
| Credential-destination provenance guard (`credential_provenance.go`) | **No** | **The pattern** — refuse an inherited secret bound to an agent-writable destination (CB1-1, a live gap) |
| Ownership-proof before destructive ops (`isCrabboxAWSLease` + second guard; VISION.md) | No | The pattern for our name-prefix sandbox reaper (CB1-2, a live gap) |
| Capsule replay: signature-gated repro + 4-outcome verdict taxonomy | No | Fold the outcome vocabulary into the eval harness / regression triage (CB2-1) |
| Tree-sync remote execution on leased/static capacity | No (build thin) | The reference for "sync my tree to the tailnet box and run the suite" (CB2-2) |
| External-provider JSON-stdio protocol | No | The integration shape *if* remote cloud leasing is ever wanted (CB3-1, TRACK) |
| Coordinator credential custody, spend caps, 70 providers, checkpoints/forks, pond, desktop-proof, Actions hydration | No | Nothing — wrong scale, or already covered (nono N2-2, openshell OSH1-1) |
| Provider-neutral core/adapter split; CI needle-scan tests; env-forwarding honesty | No | Already covered (Forge Behaviour + VFS adapters; agentos AO2-1; OutputRedaction) — at most a garnish |

## Why not adopt as a dependency

1. **It solves a problem we don't have.** crabbox's core value proposition —
   *"Maintainers and agents share infra without sharing provider tokens"* (`README.md:293`)
   — is a *team* credential-custody play. A coordinator holds the cloud keys; teammates get
   a broker token that can only *request* leases inside spend caps. A single operator on a
   personal tailnet has no team to share with and (today) no fleet of cloud provider keys to
   custody. The coordinator, GitHub-team allowlists, per-owner/per-org spend caps, admin-vs-
   user privilege split, and 70 provider adapters are all machinery for the multi-operator
   case (`docs/security.md:147-163`, `docs/cost-usage.md:88-104`).
2. **The overlap is already ours, thinner.** crabbox and JidoClaw both run commands on a
   remote SSH host. JidoClaw ships this today: `run_command backend:ssh server:<name>` →
   `Shell.SessionManager` → `Jido.Shell.Backend.SSH` over Erlang `:ssh`, with static hosts
   declared in `.jido/config.yaml` under `servers:` (`lib/jido_claw/shell/session_manager.ex`,
   `server_registry.ex`). What crabbox *adds* over that — working-tree rsync, cloud VM
   leasing, and durable run evidence — is either build-thin (CB2-2) or coupled to the
   coordinator we're rejecting.
3. **Not the isolation axis.** Every other subject in `sandboxes/` is evaluated as a
   `Forge.Sandbox.Behaviour` backend. crabbox explicitly is not one — *"not an isolation
   boundary"* (`README.md:46`). Its runners are dumb throwaway machines whose security is
   *repository-config-is-trusted* (`SECURITY.md:10-14`), the opposite of our LLM-misbehavior
   containment stance. It cannot be a second Forge backend.
4. **Wrong language, wrong grain, wrong maturity for a dep.** 381k LOC of Go + a TS
   coordinator, pre-1.0, two-author-dominated, with a Node runtime the docs say must not
   scale past one replica yet (`docs/portable-coordinator.md:96-98`). Even the tool-wrap
   route (à la nono) is unattractive: crabbox has **no MCP server** (unlike coderunner), so
   integration would be shelling to the binary, and durable evidence would land in crabbox's
   store, not ours.
5. **ADOPT-AS-TOOL considered and rejected.** The one tempting tool-wrap is "run my suite on
   the beefy tailnet desktop." crabbox's static-SSH provider + `--network tailscale` does
   exactly that today (`docs/providers/ssh.md:114-171`, `docs/features/tailscale.md:238-246`).
   But without a coordinator you get only local `.crabbox/` evidence, the tree-sync +
   ssh-exec it wraps is a few hundred lines we could own natively, and it pulls a large
   external binary into the agent's `run_command` surface for one capability. BUILD-ON beats
   ADOPT-AS-TOOL here (CB2-2).

## How to read this document

Recommendations: **BORROW-PATTERN** (translate the contract into our idioms — OTP/Ash/Jido),
**BUILD-ON** (ours to design; crabbox is the reference), **FOLD-IN** (absorb into a planned
item), **TRACK** (parked on a named trigger), **ALREADY-COVERED** (cite the local
equivalent), **SKIP**. Tiers are scoped to *this* project: **Tier 1** = a present-day defect
on our exact threat axis, cheap to fix; **Tier 2** = a real borrow gated on a design
decision or trigger; **Tier 3** = parked/garnish. Per-entry fields: **Where in crabbox**
(file:line — "start here," not gospel), **What**, **Gap in jido_radclaw** (verified against
our source 2026-07-03), **Why it matters**, **Adoption sketch**. IDs are `CB<tier>-<seq>`;
`S-n` for skips, `OQ-n` for open questions, `CB-note-n` for corpus-wiring findings.

---

## Tier 1 — Present-day defects on our threat axis

### CB1-1 — Credential-destination provenance: refuse an inherited secret bound to an agent-chosen destination

- **Recommendation**: BORROW-PATTERN.
- **Where in crabbox**: `internal/cli/credential_provenance.go` — a `credentialValueSource`
  enum tiers every credential *and every endpoint URL* by origin: `TrustedFile`,
  `Repository`, `Environment`, `Flag` (`:9-16`). `validateProviderCredentialDestination`
  (`:193-302`) walks each provider and, when the endpoint URL's source is
  `credentialSourceRepository` **and** the matching API key is `inheritedCredential(...)`
  (env/flag/trusted-file), returns `repositoryCredentialDestinationError` — refusing to send
  a higher-trust secret to a destination chosen by lower-trust repo config unless the
  operator re-declares the destination at the same trust tier. The sibling
  `validateCoordinatorCredentialDestination` (`:171-191`) does the same for the broker URL.
  The doctrine is written down: SECURITY.md lists *"Crabbox silently sending a trusted
  credential to a destination selected by a different, lower-trust configuration source"* as
  **in-scope vulnerability** (`SECURITY.md:44`), and the login flow carries the same guard
  for OAuth callback origins (`internal/cli/auth.go:102-131`).
- **Gap in jido_radclaw** (verified 2026-07-03): we have **no credential-destination
  provenance** anywhere. The concrete live instance: `Shell.ServerRegistry.resolve_secrets/1`
  reads an SSH password from the host env var named by `password_env`
  (`server_registry.ex:189-194`) and `build_ssh_config` hands it straight to `entry.host`
  (`:216-218`) — where `entry.host` is loaded from `project_dir/.jido/config.yaml`
  (`server_registry.ex` `config_path/1`), a file the agent's own `write_file`/`edit_file`
  tools can rewrite. So an LLM that edits `.jido/config.yaml` to point an existing `server:`
  entry's `host:` at a machine it controls — while keeping `auth_kind: password`,
  `password_env: SOME_SECRET` — causes the next `run_command backend:ssh server:that`
  to send the host-env password to the attacker's box. The same shape is latent on the MCP
  endpoint `env:` override map (`mcp/endpoint_config.ex`) and would activate on
  `providers.*.base_url` the day it stops being decorative (pi-sbx **PS2-2**). Nothing
  compares the trust tier of the *destination* against the trust tier of the *secret*.
- **Why it matters**: this is the single sharpest crabbox borrow *because* it targets our
  threat model dead-center. The house model is LLM-misbehavior + leakage hygiene, and
  `.jido/config.yaml` is the one high-trust control surface sitting inside the agent's own
  write radius. crabbox learned this axis the hard way (it's an entire hardening theme across
  its CHANGELOG) and distilled it into a reusable tier-comparison. We have the redaction and
  the default-deny env scrub, but not the "who chose this destination vs. who owns this
  secret" check — the exact gap that scrub can't close, because the secret is *supposed* to
  flow to a legitimately-configured host.
- **Adoption sketch**: introduce a small provenance tag on config-sourced values — at
  minimum a boolean "this field came from agent-writable `.jido/config.yaml` vs. host
  env/`.env`/an operator-only file." Then, at the two credential-bearing spawn sites, refuse
  the combination *destination-from-agent-writable-config* × *secret-from-higher-trust-source*
  unless the operator has opted in: (1) `ServerRegistry.build_ssh_config` for
  `auth_kind: :password` (the live case — `key_path`/`:default` are lower-risk since the key
  itself isn't transmitted); (2) the MCP `endpoint_config` env-override path as a follow-up.
  This composes with the existing `Env.scrubbed_port_env` default-deny (that stops
  *accidental* inheritance; this stops *directed* exfiltration to a chosen host). Fail-closed
  with an approvable error, mirroring crabbox's "set the destination env var to explicitly
  approve" escape hatch. Small, self-contained, and it can ride the same ToolApproval seam
  (`Security.ToolApproval`) so the operator can bless a genuinely-new host once.

---

### CB1-2 — Ownership proof before destroying an external resource (harden the sandbox reaper)

- **Recommendation**: BORROW-PATTERN.
- **Where in crabbox**: the load-bearing doctrine is one sentence in VISION.md — *"Labels,
  names, and IDs alone are not ownership proof"* (`VISION.md` Lifecycle Safety). Enforced:
  `isCrabboxAWSLease` requires the *full* canonical tag-set (`crabbox=true`,
  `created_by=crabbox`, `provider=aws`, canonical lease-ID, non-empty slug) before any
  destructive path (`internal/providers/aws/backend.go:173-181`); `ReleaseLease` adds an
  *exact* lease-ID match (`:213-216`); and `deleteServer` re-checks ownership a **second
  time at the destructive boundary** (`:367-370`). For fleet-wide orphan sweeps, coordinator
  lease state is the authority and *"provider tags discover candidates … but do not
  authorize a destructive action"* (`docs/security.md:431-438`); the local audit script
  *"intentionally refuses `--terminate`"* because it can't atomically prove ownership
  (`docs/operations.md:559-565`).
- **Gap in jido_radclaw** (verified 2026-07-03): our boot-time sandbox reaper matches on a
  **name prefix only**. `Forge.SandboxInit.do_cleanup_orphaned_sandboxes` filters
  `sbx ls --json` by `String.starts_with?(name, "forge-")` and `sbx rm --force`s each
  (`sandbox_init.ex:73-84`); `reap_orphaned_workspace_dirs` deletes any `/tmp/jidoclaw_forge/
  forge-*` host dir — which hold live `.forge_env` secret files — on the same prefix
  (`:153-155`). There is no owner-PID, instance-ID, or creation-token check. Two JidoClaw
  instances sharing one Docker daemon (dev + prod on one box; a test run beside a real one)
  means one instance's boot reaps the *other's in-flight* sandboxes and secret dirs mid-run.
- **Why it matters**: it's a present-day correctness/safety bug on the containment subsystem,
  and crabbox is the precedent for exactly why prefix-matching is unsafe. It's the *softer* of
  the two Tier-1 defects — the reaper code is wrong now, but the observable bite is
  concurrency-gated (single-instance dev Mac is fine, and per the argus design each tailnet
  *node* runs its own Docker so the prefix doesn't collide across devices —
  `argus/OVERVIEW.md`), where CB1-1 is exploitable in the common single-instance case. The fix
  is cheap and unconditional; the failure it prevents is silent data loss.
- **Adoption sketch**: stamp each sandbox with an owner token at create time — either an
  `sbx` label carrying this node's boot-unique instance ID, or (simpler) fold the instance ID
  into the sandbox name (`forge-<instance>-<n>`) and reap only names matching *this*
  instance. The workspace-dir reap already lstat-guards against symlinks (`:153-155`); extend
  the same "prove it's mine" predicate to the name. Trigger: satisfied now (the fix is
  unconditional hardening); the *observable* bite is gated on "run two JidoClaw instances
  against one Docker host."

## Tier 2 — Real borrows gated on a decision or trigger

### CB2-1 — Capsule replay: signature-gated reproduction + a 4-outcome verdict taxonomy

- **Recommendation**: FOLD-IN (the eval harness) + BORROW-PATTERN (the taxonomy).
- **Where in crabbox**: `internal/cli/capsule.go`. A capsule is a portable YAML manifest
  (`capsule.yaml`) pinning a *failure*: source identity (repo/run/sha), the exact replay
  command, bounded failed-step logs, and a **derived `oracle.failure_signature`** — the log
  scanned bottom-up for `fail/error/panic/exit status`, truncated to 240 chars
  (`capsuleFailureSignature` `:785-825`). `capsule replay` reruns the command and classifies
  the result into exactly four outcomes (`capsuleReplayFailureOutcome` `:962-972`): `pass`
  (exit 0 → *not reproduced* → CLI exits **1**); `fail_reproduced` (non-zero **and** the last
  256 KiB of output contains the signature → exits **0**, the only success path — so a repro
  script *gates on the failure still happening*); `fail_new` (non-zero, signature absent →
  exits 1); `inconclusive_env_error` (lease/sync/tooling failure → propagates, *not* a test
  verdict). The signature match is what separates "same bug" from "different failure."
- **Gap in jido_radclaw** (verified 2026-07-03): our eval harness
  (`JidoClaw.Eval.{Case,Run}`, shipped as the next-five #5 minimal slice) asserts on
  structured assertions against production functions; it has no notion of *"rerun this and
  check the failure still reproduces,"* no failure-signature oracle, and no infra-error-vs-
  verdict separation. Our `OutputShaper.MixTest` parses `mix test` stdout into counts +
  verbatim failure blocks (`tools/output_shaper/mix_test.ex`) but discards them after
  shaping — no durable, replayable failure record.
- **Why it matters**: two independent subjects now converge on the same contract, which the
  corpus treats as its strongest design-validation signal. crabbox's `inconclusive_env_error`
  ≠ `fail_*` is a concrete instance of camus **C1-3**'s verdict-normalizer (infra ≠ verdict ≠
  inconclusive), specialized to a repro run — and camus C1-3 is already queued (next-ten #4).
  The *novel* half crabbox adds is the **signature-gated repro**: a deterministic "is this
  still the same failure" oracle, which is exactly what a flaky-test triage or regression-
  capsule feature on top of the eval harness would need.
- **Adoption sketch**: when C1-3's normalizer is built, adopt crabbox's four-way vocabulary
  verbatim as the outcome enum (`reproduced` / `passed` / `new_failure` / `inconclusive`),
  and reserve `inconclusive` for infrastructure/tooling errors so a broker/sandbox failure
  never scores as a test verdict. Separately, if a "regression capsule" feature is ever
  wanted (pin a failing agent-run command + a derived signature; rerun to prove a fix), build
  it as an `Eval.Case` kind whose oracle is the signature match — crabbox's bottom-up
  scan-to-240-chars is a fine v1 signature. Cross-ref camus C1-3; do **not** stand this up as
  its own program.

### CB2-2 — Tree-sync remote execution on tailnet/static capacity

- **Recommendation**: BUILD-ON (crabbox is the reference).
- **Where in crabbox**: the SSH-lease run pipeline. Sync is `git ls-files --cached --others
  --exclude-standard -z` → rsync `-az --files-from=- --from0` local→remote
  (`internal/cli/repo.go:298-360`, `ssh.go:703-735`), gated by a content fingerprint that
  skips the whole pass when unchanged (`syncFingerprintForManifest` `repo.go:244-272`) and a
  mass-deletion sanity floor (≥200 tracked deletions → abort, `ssh.go:1563`). Remote exec
  shells the system `ssh` binary with `ControlMaster` multiplexing (`ssh.go:517-633`);
  results (JUnit, downloads, artifacts) come back over *separate* SSH-exec back-channels,
  never rsync (`results_remote.go:87-114`). The static-SSH provider points all of this at an
  existing box with zero provisioning (`docs/providers/ssh.md:114-171`), and `--network
  tailscale` resolves the host via MagicDNS (`docs/features/tailscale.md:238-246`).
- **Gap in jido_radclaw** (verified 2026-07-03): our SSH path (`run_command backend:ssh`)
  runs a *command* on a static declared host but does **not sync a working tree** first —
  it's `cd <cwd> && env … <command>` against whatever is already on the box
  (`server_registry.ex:49-57`). No rsync, no fingerprint skip, no results-back channel, no
  file-artifact persistence (confirmed: no blob store, no JUnit parsing anywhere). So "edit
  locally, run the suite on the 32-core tailnet desktop against my exact dirty tree" is not
  expressible today.
- **Why it matters**: the operator's setup is *literally* crabbox's sweet spot — a personal
  tailnet with spare machines that could be runners. This is the one genuine *capability*
  crabbox has that we lack and that fits the environment. But it's BUILD-ON, not adopt: our
  direction (argus: full JidoClaw per node + shared Postgres) is a heavier peer model, whereas
  this is the lightweight "dumb runner + tree sync" model, and the useful core (rsync a git
  manifest + ssh-exec + read results back) is a few hundred lines atop the SSH backend we
  already own — without crabbox's coordinator, leasing, or 70 providers.
- **Adoption sketch**: if/when wanted, extend the SSH backend (or add a `run_remote` tool
  sibling registered in `agent.ex`) with an optional pre-exec tree sync: `git ls-files
  --cached --others --exclude-standard -z | rsync -az --files-from=- --from0` to
  `<server.cwd>`, guarded by a content fingerprint and a mass-deletion floor (both borrowable
  near-verbatim from `repo.go`). Gate it behind ToolApproval like any host-reaching tool.
  Trigger: an explicit "run this remotely against my working tree" ask, or the argus tailnet
  program reaching the point of wanting scale-out test capacity without a full node on the
  runner. Until then, TRACK.

---

## Tier 3 — Parked / garnish

### CB3-1 — External-provider JSON-stdio protocol as the integration shape

- **Recommendation**: TRACK (trigger: a decision to use crabbox for real cloud leasing).
- **Where in crabbox**: `internal/providers/external/` implements a complete, registered
  provider that speaks a v1 JSON-over-stdio protocol — one request on stdin, one response on
  stdout, per operation (`acquire`/`resolve`/`list`/`release`/`touch`/`cleanup`/`doctor`),
  1 MiB output cap (`protocol.go`, `backend.go:559-611`). A third party implements a provider
  with **no crabbox recompile** — proven by `examples/slurm-external-provider/slurm-cbx.py`.
  (Finding: crabbox's own `docs/provider-backends.md:645` and `provider-authoring.md:529`
  *stale-claim* external plugins "are not implemented yet" — the code and
  `docs/providers/external.md` contradict them.)
- **Why it's only TRACK**: this matters only in the world where we *do* want crabbox to lease
  cloud/static capacity for us and want JidoClaw's own hosts to appear as crabbox providers —
  a world we're rejecting per the Determination. But it's the cleanest integration shape if
  that ever flips: an Elixir escript speaking this JSON contract registers as `provider:
  external`. Recorded so the option isn't re-discovered from scratch. No gap to verify on our
  side; nothing to build now.

### CB3-2 — Env-forwarding secret-name-shape list (garnish)

- **Recommendation**: ALREADY-COVERED (cite `Security.Redaction`), take at most the list.
- crabbox's `envNameLooksSecret` treats names containing `KEY`, `TOKEN`, `SECRET`, `PASSWORD`,
  `PASS`, `CREDENTIAL`, `AUTH` as secret-shaped and renders `secret=true len=N` in diagnostics
  — with the *loud, honest* caveat that this redacts diagnostics but **does not stop
  forwarding** (`docs/env-forwarding.md:181-182`), and that failure bundles/captures are not
  redacted at all (`internal/cli/run_observability.go:793`). This honesty-about-limits
  doctrine is one we already hold (our OutputRedaction root + the documented S-M3 operator-
  echo residual). The only liftable atom is the name-shape token list — worth a one-time diff
  against our redaction key-classifier to check for a missing token (e.g. `CREDENTIAL`,
  `PASS`), nothing more.

---

## Skip / Already Covered

- **S-1 — The coordinator (Cloudflare DO / Node+Postgres), spend caps, admin-vs-user split,
  GitHub-team allowlists.** SKIP — team credential-custody machinery; a single operator has
  no fleet to govern (`docs/coordinator.md`, `docs/cost-usage.md`).
- **S-2 — Coordinator-owned-credential *custody* model** (the scan's "worth studying"
  pointer). ALREADY-COVERED by nono **N2-2** (phantom tokens) + openshell **OSH1-1**
  (placeholder/resolver brokering). crabbox's custody design is a coarser instance of the
  same idea; its *distinct* credential contribution is the provenance guard CB1-1, not the
  custody.
- **S-3 — 70 provider adapters, capacity fallback, machine classes, prebaked images, runner
  bootstrap.** SKIP — cloud-fleet breadth irrelevant to a personal tailnet; our sbx microVM
  is the isolation tier and `backend:ssh` the static-host tier.
- **S-4 — Checkpoints / `checkpoint fork --count` / pond peer groups / desktop-proof
  bundles / Actions hydration.** SKIP. (Note the `fork --count` docs/code divergence — docs
  read "fan-out," code is a *sequential, abort-on-first-error* loop, `checkpoint.go:750-756`
  — a caution against citing crabbox's fork as a parallel-fanout precedent.)
- **S-5 — Provider-neutral core/adapter split with capability dispatch** (`VISION.md`).
  ALREADY-COVERED — `Forge.Sandbox.Behaviour` + the VFS adapter pattern
  (`vfs/resolver.ex`) + the MCP consumer are the same shape in our idioms.
- **S-6 — CI needle-scan test that forbids reintroducing non-constant-time secret compares**
  (`worker/test/timing-safe-auth.test.ts`). ALREADY-COVERED by the agentos borrow **AO2-1/
  AO2-2** (architecture needle-scans); crabbox is a second data point, not a new pattern.
- **S-7 — Constant-time secret comparison itself** (`worker/src/timing-safe.ts`). SKIP —
  guards a network-exposed shared-secret control plane we don't run; no equivalent surface.

## Open questions

- **OQ-1 — Does CB1-1 want to cover `key_path` and MCP endpoints in v1, or just the SSH
  `password_env` case?** The password case transmits the secret (sharp); `key_path` only
  risks an auth attempt against a chosen host (softer); MCP endpoint env-overrides are
  operator-provided today. Recommend: ship the SSH-password guard first, design the provenance
  tag general enough to extend.
- **OQ-2 — What is the right owner-token grain for CB1-2** — an `sbx` label vs. baking the
  instance ID into the sandbox name? Label is cleaner but needs an `sbx ls --json` field we
  haven't verified carries labels; name-embedding is guaranteed to work with the current
  prefix filter. Spike against the sbx CLI.
- **OQ-3 — Does CB2-2 belong to the SSH backend or a new `run_remote` tool?** Backend keeps
  it inside the existing `run_command backend:ssh` surface (one gate, one config); a new tool
  is a cleaner approval boundary but duplicates session plumbing. Defer to when the trigger
  fires.

## Cross-references and dependencies

```
CB1-1 (credential provenance) ── independent, present-day; touches ServerRegistry + ToolApproval
CB1-2 (ownership reaper)      ── independent, present-day; touches Forge.SandboxInit
CB2-1 (capsule taxonomy)      ── FOLDS INTO camus C1-3 (next-ten #4) + Eval harness (shipped)
CB2-2 (tree-sync remote)      ── BUILD-ON the SSH backend; gated on argus / an explicit ask
CB3-1 (external protocol)     ── TRACK; gated on wanting real cloud leasing (rejected today)
```

**Suggested first wave**: the two Tier-1 defects as one **security-hardening PR** — lead with
**CB1-1** (present-day, threat-model-central, exploitable in the common single-instance case,
no external gate — the trigger is satisfied by deciding to work), with **CB1-2** as its natural
rider (both are "prove trust before acting" on subsystems the agent can reach; CB1-2's fix is
unconditional even though its bite is concurrency-gated). Half a day together. **CB2-1** should
*not* be scheduled independently — it waits for camus C1-3 (next-ten queue) and grafts its
vocabulary on. **CB2-2** and **CB3-1** are TRACK.

**Collision notes against the queues** (`docs/plans/unadopted-next-five`, `-next-ten`): no
overlap on CB1-1/CB1-2 — the queues are camus/ouroboros/osa/alp-river composer-and-front-door
work; crabbox adds a *security-hardening* lane those don't touch. CB2-1 is the one point of
contact: it strengthens the case for next-ten #4 (camus C1-3 verdict normalizer) with a
converging second source and hands it a ready outcome vocabulary — reconcile CB2-1's status
when C1-3 ships.

## Corpus-wiring findings (not borrows)

- **CB-note-1 — third-party evidence for pi-sbx OQ-1.** The pi-sbx-llamacpp doc's OQ-1 asks
  whether `sbx create` accepts `--kit` (its kit demos `--kit` only on `sbx run`). crabbox's
  shipped docker-sandbox adapter passes repeatable `--kit` **and** `--mcp` flags to
  `sbx create` (`internal/providers/dockersandbox/client.go:89-116`), validated against sbx
  client/server v0.31.3 (`docs/providers/docker-sandbox.md:41-45`) — independent code
  evidence that `sbx create --kit` is real. Worth a one-line note in the pi-sbx doc's OQ-1
  when that spike runs.
- **CB-note-2 — the scan's crabbox pointer, corrected.** The landscape scan said "the
  coordinator-owned-credentials model is the part worth studying." The dig found that model
  is (a) mostly irrelevant to a single operator and (b) already covered where it isn't
  (nono N2-2, openshell OSH1-1). The genuinely-distinct, worth-studying credential idea turned
  out to be the *provenance-destination guard* (CB1-1) — a different mechanism than custody.

## Bottom line

crabbox is a SKIP-as-dependency — a team-scale remote-execution control plane whose reason to
exist doesn't apply to one operator, on the scale-out axis rather than the isolation axis this
corpus studies. But it is a rigorous, security-serious codebase on our exact threat axis, and
two of its patterns are present-day defects on our side: **CB1-1**, the credential-destination
provenance guard (an LLM that edits `.jido/config.yaml` can redirect a host-env SSH password to
a host it chose — the sharpest borrow in this doc), and **CB1-2**, ownership proof before the
sandbox reaper destroys anything (our `forge-*` prefix match is exactly the "names are not
ownership proof" mistake crabbox codifies against). Beyond those, **CB2-1** hands the queued
camus C1-3 verdict-normalizer a converging second source and a ready four-outcome vocabulary.
Everything else — the coordinator, the fleet, the 70 providers, the tree-sync remote execution
we could build thin — is SKIP or a triggered TRACK.
