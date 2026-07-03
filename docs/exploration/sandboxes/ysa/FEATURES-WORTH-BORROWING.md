# Features Worth Borrowing from ysa

Exploration notes — not a plan, not a commitment. Deep-dive **2026-07-03**, fulfilling the
"read ysa's `container/` hardening + network-policy implementation" next-step of the
[sandbox landscape scan](../README.md). Source: `~/workspace/research/sandboxes/ysa`
(ysa-ai/ysa, HEAD `d1e6faeb`, npm `@ysa-ai/ysa` v0.5.5). Self-description: *"a secure
container runtime for AI coding agents — a CLI and SDK, nothing else"* (`README.md:11`) —
a composable primitive that *"Use[s] `runTask()` … to build any orchestration layer on
top"* (`README.md:25`). Shape: a TypeScript/Bun workspace, ~9.1k LOC across `src/` (CLI +
runtime + providers) and `container/` (the hardened-podman assets: `sandbox-run.sh`,
`seccomp.json`, `Containerfile`, `network-proxy.ts`, git guards, OCI hooks). Maturity: 116
commits over ~4 months (Feb–Jul 2026), **effectively single-author** (two git identities,
one person), one CHANGELOG entry (0.5.0), the only CI a docs-deploy workflow (no test/
security CI), Apache-2.0, self-described *"Early development … Expect breaking changes"*
(`README.md:9`). Everything below is from reading docs + source; **ysa was not installed,
built, or executed this review** — runtime claims (latency, escape-resistance) are
per-docs/per-code until a spike.

**A calibration note stated up front** (per the corpus README's "say so when the subject
is broken" rule): ysa's `CLAUDE.md` describes a full-stack app (tRPC, Drizzle/SQLite,
React dashboard, Hono server — `CLAUDE.md:27-40`) whose `src/api`, `src/db`, `src/dashboard`,
`src/server` **do not exist** in the tree; and `docs/guides/network.md:89-91` claims policy
`none` gives *"no outbound network access at all"* while the code gives `none` = full
unrestricted internet (verified below). Both are drift in the **dangerous** direction —
docs/comments promising *more* safety than the code delivers — the inverse of nono's
"docs understate shipped capability." This is load-bearing evidence, not a footnote: it
lowers the trust you can place in ysa's *own* security claims and pushes every verdict
toward "read the code as a reference, don't adopt the artifact."

Companion docs: the [sandbox landscape scan](../README.md) (this doc answers its ysa
next-step; it overturns the scan's "design donor or CLI wrap" framing — see below), and
**heavily** [`nono/FEATURES-WORTH-BORROWING.md`](../nono/FEATURES-WORTH-BORROWING.md) —
ysa's two headline security features (network policy, credential handling) are each
**superseded by a nono entry already on our books** (N2-4, N2-2), so this doc mostly points
there rather than re-deriving. The house threat model applies throughout (personal,
tailnet-only: LLM-misbehavior containment + secret/data-leakage hygiene, not hostile
multi-tenant isolation).

## Determination (TL;DR)

**Read it as a reference; adopt almost none of it.** This is an empirica/optimal-engine-
shaped outcome — a deliberately short borrow list with verified-empty slots — for two
structural reasons, not for lack of engineering effort on ysa's part:

1. **Wrong isolation tier.** ysa is **rootless Podman** — a *shared-host-kernel* container
   (`README.md:119` states it plainly: *"directly on the host kernel … no virtual machine"*).
   Its entire headline — the `--cap-drop ALL` / `seccomp` / `no-new-privileges` /
   `--read-only` / `/proc`-mask / `userns` flag set (`container/sandbox-run.sh:281-299`) plus
   a 211-syscall deny-by-default seccomp profile — exists *because* a shared kernel must be
   hardened against escape. **Our `Sandbox.Docker` backend runs on Docker `sbx` microVMs**
   (a *separate* kernel; VM-class isolation is already our baseline — scan README §Where
   Forge stands). So that flag set is defending a boundary we don't use, against escapes
   the microVM already contains at a stronger layer. It becomes load-bearing *only* if we
   add a Podman backend — which we'd only want on a Linux host lacking Docker Desktop/sbx,
   i.e. a weaker fallback, not the primary path.
2. **Wrong grain, and superseded where it overlaps.** Unlike nono (a 2 MB binary that wraps
   our exact `sh -c` spawn), ysa is a **full task-runner**: `runTask()` owns worktree
   creation, container launch, agent-CLI invocation, log tailing/parsing, and result
   classification (`src/runtime/runner.ts:91-401`) — every one of which JidoClaw's
   Harness/AgentRunner/runners already own. Wrapping its CLI would cede a large, worse-
   fitted surface to a single-author pre-1.0 TS process. And its two security marquees lose
   head-to-head: its "network policy" is a per-request method/rate L7 filter over *all*
   hosts (**not** an egress allowlist, **no** cloud-metadata deny floor), beaten by nono
   N2-4; its credential path puts the **raw API key in container env** (`sandbox-run.sh:304`),
   whereas we already do better (key never enters sbx env; auth rides copied files) and
   nono N2-2 does better still (phantom tokens).

| Part of ysa | As a dependency | What to take |
| --- | --- | --- |
| `runTask()` CLI/SDK (worktree+container+agent+parse) | **SKIP** | Nothing — full overlap with Harness/AgentRunner, Podman < our sbx, immature |
| git-safe-wrapper + `GIT_CONFIG_COUNT` pins (poisoned-`.git/config` defense) | No | **The one novel threat**: harden git-exec against an attacker-controlled on-disk config (Y1-1) |
| Worktree-per-task + live bind-mount + branch-kept | No | The lighter, reviewable workspace-isolation shape (Y2-1) |
| Podman hardening flag set + seccomp profile | No | **The spec** for a future `Sandbox.Podman` backend — TRACK on a Linux-no-sbx trigger (Y3-1) |
| `attack-test.sh` (165 checks / 41 categories) | No | A backend-agnostic escape/git-injection **rubric** to cherry-pick (Y3-2) |
| Network policy (L7 filter, MITM proxy, CA) | No | **SUPERSEDED** by nono N2-4; ysa's is weaker and drift-ridden (S-1) |
| Credential injection (raw key → container env) | No | **We're already stronger**; nono N2-2 is the real upgrade (S-2) |
| Dep-cache volumes / mise toolchain warm-cache | No | TRACK on a Forge-latency trigger (Y3-3) |
| PreToolUse regex guard, git-push-guard, MITM CA | No | ALREADY-COVERED by ToolApproval / `network: :none` (S-3…S-5) |

## Why not adopt as a dependency (and not even as a tool)

nono earned an ADOPT-AS-TOOL verdict because it was *a binary wrapping the exact process
shape we already spawn, at a tier we lacked*. ysa inverts every one of those properties:

- **It's a framework, not a primitive.** `runTask(config, opts)` (`src/runtime/runner.ts:91`)
  is an 11-stage pipeline — worktree create → provider/auth resolve → image rebuild → proxy
  ensure → mise pre-install → dep-cache → spawn → log-tail → parse → classify. JidoClaw owns
  a *better-fitted* version of every stage (`Harness`, `AgentRunner`, the `forge/runners/`).
  There is no "just wrap the spawn" seam; the whole thing *is* the seam.
- **It's a weaker isolation tier than we already run.** Adopting ysa means adopting Podman-
  on-host-kernel where we run sbx microVMs. That's a downgrade on the primary (macOS) dev
  machine, where Docker Desktop already provides the microVM.
- **Its security artifacts have drift in the unsafe direction** (the calibration note): a
  `none` policy that claims zero-egress but gives full internet, a `custom` policy that's
  half-wired (`runner.ts:216` only branches on `"strict"`, so `custom` gets proxy env but no
  proxy — the runtime reader confirmed), supply-chain tests that assert "no gcc/python"
  against an image that installs both (`attack-test.sh` §30 vs `Containerfile:13`). A
  security tool you'd *depend* on has to be trustworthy about its own gaps; ysa isn't yet.
- **It's single-author, pre-1.0, one release documented.** Fine for a reference read;
  disqualifying for a dependency in the containment path.

What ysa *is* good for is the same thing nono's docs were: a well-organized worked example
of decisions we'll face. Two of those decisions are genuinely ours-to-make-and-ysa-solved-
first (Y1-1, Y2-1); the rest are reference material gated on triggers.

## How to read this document

Recommendations: **BORROW-PATTERN** (translate the contract into our idioms),
**BORROW-REFERENCE** (read their code as the spec for something we build), **BORROW-RUBRIC**
(lift evaluative checks, not machinery), **BUILD-ON** (ours to design; ysa supplies the
precedent), **TRACK** (parked on a named trigger), **ALREADY-COVERED** (cite the local
equal-or-better), **SKIP**. No ADOPT verdict appears — §"Why not adopt" argues it out.
Tiers are **scoped to this project's threat model**: **Tier 1** = borrow that stands on its
own merits now; **Tier 2** = a real pattern, modest fit; **Tier 3** = reference/parked.
Per-entry: **Where in ysa** (file:line, "start here"), **What**, **Gap in jido_radclaw**
(verified against source 2026-07-03), **Why it matters**, **Adoption sketch**. IDs are
`Y<tier>-<seq>`; `S-n` skips, `OQ-n` open questions.

---

## Tier 1 — The borrow that stands on its own

### Y1-1. Harden git execution against a poisoned on-disk `.git/config`

**Recommendation**: BORROW-REFERENCE (their key list + env-pin approach as the spec) +
small BUILD-ON (our own git-exec hardening on the clone path).

**Where in ysa**: `container/git-safe-wrapper.sh` — installed as `/usr/local/bin/git` to
shadow `/usr/bin/git` on `PATH` (`Containerfile:52-53`); on *every* git call it resolves
`--git-dir` **and** `--git-common-dir` (the latter matters for worktrees) and `--unset-all`s
a fixed list of shell-executing config keys from those on-disk files *before* `exec`ing the
real git (`git-safe-wrapper.sh:49-50,54-81`). The stripped set (`:49-50`, quoted): exact —
`core.pager|core.editor|core.sshCommand|core.askPass|core.gitProxy|diff.external|sequence.editor|interactive.diffFilter|gpg.program|sendemail.smtpServer|core.worktreeConfig|init.templateDir|blame.ignoreRevsFile`;
wildcard — `filter.*.{clean,smudge,process}|diff.*.{textconv,command}|merge.*.driver|pager.*|gpg.*.program|trailer.*.{command,cmd}|include.path|includeIf.*.path|url.*.{insteadOf,pushInsteadOf}|submodule.*.update`;
plus `alias.X=!cmd` shell aliases (`:75-78`). Backstop for the "call `/usr/bin/git`
directly" bypass: an image-level `GIT_CONFIG_COUNT=20` env pin hard-setting ~20 of these
keys to safe values (highest precedence after `-c`) — `Containerfile:109-149` — and a
system `core.hooksPath` + `protocol.{ext,file}.allow=never` + `core.symlinks=false` +
fsck settings (`Containerfile:58-69`). The threat model these defend, stated in the
wrapper header (`:9-30`): a **poisoned repository** whose committed `.git/config` or
`.gitattributes` triggers code execution on a later, innocent `git log`/`git diff`/`git status`.

**What**: Neutralize the class of git config keys whose *values are executed as shell
commands*, so that running git inside a repository you did not author cannot execute
attacker-chosen code as a side effect of an ordinary read command.

**Gap in jido_radclaw**: Our `Security.ShellCommand.Git` gate is a far more sophisticated
*command-string* analyzer than ysa's wrapper — a state machine over git's config grammar
(`shell_command/git.ex:30-360`) that already flags the *plant-for-later* and *include/dynamic*
shapes: a `git config alias.*/include.*` persistent write (`:git_config_persistent_write`),
an `-c include.path=…`/`--config-env`/dynamic `-c "$x"` inline injection, and any visible
`GIT_CONFIG_*` env assignment (`shell_command.ex:629-654`). But it analyzes **the command the
agent types**, and there is a precise hole (verified in the git-gate pass): a **literal**
inline code-exec key passes **completely clean** — `absorb_config/5` (`git.ex:319-325`) only
trips on `config_include?` (sections `include`/`includeif` only, `git.ex:456`), `--config-env`,
or a dynamic value, then falls through to `record_alias_def/2`, which ignores any non-`alias`
section. So `git -c core.sshCommand=<cmd> fetch`, `git -c diff.external=<cmd> diff`, and
`git -c core.editor=<cmd> …` produce an Invocation with `inline_injections: []` and no effect
— a one-shot RCE on the host `run_command` path (which shells out), **ungated**. (Only
`core.pager` may not fire, since `System.cmd`/`OsCmd` capture output without a tty.) *The exact
key class ysa's wrapper strips is precisely the class this `-c` analyzer ignores.* More
importantly still, **nothing inspects the repo's on-disk `.git/config`** — a poisoned config
the agent never names is entirely outside the gate's view, and there is **no git-safe-wrapper /
`GIT_CONFIG_*` pin / `core.hooksPath` / `protocol.*.allow` equivalent anywhere in `lib/` or
`config/`** (verified: all grep-clean; the one `core.hooksPath` hit is a *test* neutralizing an
ambient husky hook, which by contrast confirms the production `git_commit` tool does not pin
it). And the Forge path *does* reach attacker-controlled repos: the `git_repo` resource runs
`git clone <source> …` **inside the sandbox** (`forge/resource_provisioner.ex:150-159`), where
`source` is arbitrary, after which any `git` the agent runs there honors that repo's config.
`docker.ex` adds **no** git hardening of its own (verified: `build_create_args/4` emits only
`--name`/`--mount`/`--network`/`--workdir` + the agent-type positional, `docker.ex:282-299`).

**Why it matters**: This is the *one* threat ysa defends that we don't — and it's in-scope
even for a personal project, because agents clone and operate on third-party repos. The
microVM bounds the *blast radius* (a separate kernel, and production runs `network: :none`),
but "arbitrary code runs as the agent inside the sandbox on a plain `git status`" is still a
containment hole worth closing at the source, and it's cheap to close. It also composes with
the "does the agent operate on the live tree" question in Y2-1.

**Adoption sketch**: Two independent, small moves. (a) **Widen the gate**: extend
`absorb_config/5` (`git.ex:316`) to record a literal inline `-c <key>=<value>` as a
`git_config_injection` effect when `<key>` is in a code-exec denylist (the ysa key list is
the ready-made spec — lift it verbatim as `@code_exec_config_keys`), not only when it's an
include/dynamic/alias. This closes the command-string half on the host `run_command` path.
(b) **Harden the clone path**: when the Forge sbx backend (or a future Podman one) runs git
in a cloned/attacker-supplied repo, set the ysa `GIT_CONFIG_COUNT` env pin (or a
`core.hooksPath`/`protocol.*.allow` floor) so a poisoned on-disk config can't fire —
`inject_env` already exists (`docker.ex:239-249`) to carry the env. Neither move needs
Podman; both are backend-agnostic. Ship the gate widening first (pure Elixir, testable
against `git.ex`'s existing suite); the clone-path pin follows if OQ-2 says the vector is
reachable enough.

---

## Tier 2 — A real pattern, modest fit

### Y2-1. Worktree-per-task: isolated, reviewable, live-bind-mounted workspace

**Recommendation**: BORROW-PATTERN — the shape, not the code (it's git plumbing we'd write
in Elixir anyway).

**Where in ysa**: `src/runtime/worktree.ts:57-98` — `createWorktree` under a file-lock
(`.ysa/worktree.lock`, `:30-55,65-67`): `git -C <root> worktree add <path> -b <branch>`
(`:85-86`), cut from current HEAD, retrying `worktree add <path> <branch>` if the branch
exists (`:91-93`); auto-`commit --allow-empty` if HEAD is missing (`:71-74`). The worktree
lives at `<projectRoot>/.ysa/worktrees/<taskId>` (`run.ts:60`) and is **bind-mounted RW**
into the container as `/workspace` (`sandbox-run.sh:322`), so the agent's edits land on the
host worktree **live, both directions, no copy-out**. On completion the worktree and branch
are **kept** — `runTask` has no end-of-run removal (only a pre-create cleanup,
`runner.ts:152`) — and results reach the main repo only by a **manual `git merge`** (docs
`first-task.md:69-70`: *"branch is kept — delete it manually once merged"*). `ysa teardown`
is the explicit reaper (`teardown.ts:20-21`).

**What**: Each agent task gets its own git worktree (a lightweight branch checkout sharing
the repo's object store), operates on it live, and leaves a reviewable branch behind — no
auto-merge, human reviews the diff.

**Gap in jido_radclaw**: We have **no git-worktree isolation anywhere** (seams-mapper grep
clean; the only `worktree` hits are flag-parsing lists and the harness's own Agent-fan-out
worktrees, which are Claude Code sub-agent isolation, not Forge workspace isolation). Our
Forge production path deliberately *sidesteps* the live tree: it mounts a throwaway
`.prototypes/<uuid>/` scaffold at `/proto` (`front_door.ex:416-428`, `network: :none`,
`runner: :shell`), and the one path that touches a real repo does a **full `git clone`
inside the sandbox** (`resource_provisioner.ex:150-159`) — heavier than a worktree (dupes
the object store) and disconnected from the host repo (results are inside the sandbox,
extracted via the bind mount, not surfaced as a branch on the host).

**Why it matters**: The worktree pattern is the missing middle between "throwaway scaffold"
(safe but can't touch the real project) and "clone inside sandbox" (real, but heavy and
review-opaque). For a personal project it's the ergonomic path to "run an agent against my
actual repo, isolated, and let me review the result as a normal branch diff" — which aligns
with the house git policy (agent works commit-ready; *user* stages/commits). It's modest-fit
because we're not blocked without it (the scaffold + clone paths work), so it's Tier 2, not 1.

**Adoption sketch**: A `JidoClaw.Forge.Workspace` helper: `create_worktree(repo_root, task_id)`
→ `git worktree add <base>/.jido/worktrees/<task_id> -b jido/<task_id>` under a file-lock
(the ysa lock pattern avoids the concurrent-`worktree add` race), returning the path to feed
`front_door`'s `extra_mounts` as the RW `/proto`-equivalent. Keep the branch on completion
(don't auto-merge — surface it via `git_diff`/`git_status` for the operator, matching our
"never commit unprompted" policy). Reap on explicit teardown, not run-end. This is pure git
plumbing over `OsCmd`; no Podman, no new backend. Watch the two bugs the runtime reader
flagged in ysa's own version so we don't inherit them: the `task/<id[:8]>` vs `task-<epoch>`
branch-name mismatch between create and teardown (`teardown.ts:17` vs `cli/index.ts:29`), and
the session-volume-not-actually-reused resume bug — both are naming-discipline failures, not
pattern flaws.

---

## Tier 3 — Reference material and parked items

### Y3-1. The Podman hardening flag set + seccomp profile — spec for a future `Sandbox.Podman` backend

**Recommendation**: TRACK — trigger: a Linux deploy target that lacks Docker Desktop/`sbx`
and needs a second `Forge.Sandbox.Behaviour` backend. On the current macOS dev machine the
sbx microVM is the stronger option, so this stays parked.

**Where in ysa**: `container/sandbox-run.sh:281-299` — the full `podman run` hardening block
(quoted verbatim): `--userns=keep-id`, `--cap-drop ALL` (no `--cap-add` anywhere),
`--security-opt no-new-privileges`, `--security-opt seccomp=<profile>`, four `--security-opt
mask=/proc/*` entries, `--read-only`, sized `--tmpfs` for `/tmp` and `/dev/shm`, `--memory
4g`, `--pids-limit 512`, `--cpus 2`, `--ulimit core=0`. `container/seccomp.json` — deny-by-
default (`SCMP_ACT_ERRNO`, `:2-3`), ~211 syscalls allowlisted, with two genuinely clever
touches worth remembering: `clone` allowed only with the namespace-creation flag bits masked
off (`:236-250`) and `clone3` forced to `ENOSYS` so glibc falls back to the filterable
`clone` (`:251-258`). The proxy container reuses the same profile (`security-test.sh:38`).

**What**: A researched, attack-tested hardening posture for a rootless-Podman (shared-kernel)
agent container.

**Gap / why parked**: Our second-backend seam is ready — `Forge.Sandbox.Behaviour` is a
clean 10-callback contract (`behaviour.ex:3-28`), dispatch is one config key
(`:forge_sandbox`, `sandbox.ex:69-71`), and the per-session factory has an explicit slot
(`harness.ex:1338-1343`). A `Sandbox.Podman` implementing that behaviour would drop in. But
we don't want one *yet*: the microVM is a strictly stronger boundary than a hardened shared-
kernel container, so building Podman-on-Linux is a fallback for hosts without sbx, and the
hardening flags are exactly the research we'd otherwise redo. When the trigger fires, this
block (and the seccomp `clone`/`clone3` tricks) is the starting spec — but re-verify against
the drift the calibration note documents (the production `/tmp` lacks `noexec` though tests
assert it; `attack-test.sh` §30's "no gcc/python" contradicts `Containerfile:13`).

### Y3-2. `attack-test.sh` as a backend-agnostic escape/git-injection rubric

**Recommendation**: BORROW-RUBRIC — cherry-pick the backend-agnostic checks; do not adopt
the suite.

**Where in ysa**: `container/tests/attack-test.sh` — 165 `check` calls across 41 numbered
categories (the runner's "155/38" label is stale). Most are Podman/kernel-specific (cgroup
escape, `/proc/self/exe` CVE-2019-5736, FD-leak CVE-2024-21626, seccomp-mode assertions),
but several are **backend-agnostic** and map onto surfaces we already have: git config-
injection (§11, §32-34, §41 — the poisoned-config attacks behind Y1-1), symlink escape
(§14), submodule CVEs (§21), and env-exfil (§19). `git-safe-wrapper-test.sh` is a focused
unit suite for the Y1-1 key list.

**Gap / why a rubric not an adoption**: We have no consolidated "adversarial escape/injection"
test rubric for the Forge path; these categories are a ready checklist. But the suite is
shell-and-Podman-bound and drift-ridden (stale counts; test-rig-only `noexec`; assertions
contradicting the image), so lift the *scenarios* — especially the git-config-injection
cases as fixtures for Y1-1's widened `git.ex` gate — not the harness. Pairs with camus's
deterministic-verify doctrine already in the corpus.

### Y3-3. Dep-cache volumes + mise toolchain warm-cache

**Recommendation**: TRACK — trigger: cold toolchain/dependency installs make Forge run
latency a felt problem.

**Where in ysa**: `src/runtime/runner.ts:241-277` — deps installed into a named Podman volume
`shadow-<dir>-<depsCacheKey>` mounted at `/workspace/<dir>`, reused when the volume exists
(skip reinstall). `src/runtime/mise.ts:46-112` — language runtimes provisioned into a host
bind-mount `~/.ysa/mise-installs/<hash>`, keyed by a tools-hash, mounted `:ro` into the task
container (`sandbox-run.sh:328`), with the in-container `mise` binary *deleted* at startup so
the agent can't reinstall (`:344-347`). `.ysa.toml` declares `runtimes`/`packages`
(`ysa-config.ts:5-12`).

**Gap / why parked**: The Forge sbx path has **no warm-cache story** — toolchains are image-
only, no hex/npm/mise cache mounted (seams-mapper grep clean). This is a *performance*
optimization, orthogonal to the leakage/misbehavior threat model, so it parks until latency
is actually painful. If it fires, the cache-key-addressed-volume + tools-hash pattern is the
shape; note it's cleaner under bind-mounts on macOS (ysa itself moved mise off named volumes
to host bind-mounts because Podman-machine volumes live in the VM — `CHANGELOG.md:76`).
*(2026-07-03: [agentos AO3-2](../agentos/FEATURES-WORTH-BORROWING.md) parks warm-standby
sandbox capacity on this same Forge-latency trigger — when it fires, evaluate the pair
together, starting with AO3-2's lesson: measure the actual `sbx create` p50 first.)*

---

## Skip / Already Covered

- **S-1. Network policy (L7 MITM proxy + CA).** SUPERSEDED by
  [nono N2-4](../nono/FEATURES-WORTH-BORROWING.md) (the reviewed, regression-tested egress-
  allowlist semantics — metadata deny floor, `*.suffix` wildcards, empty-means-deny). ysa's
  is strictly weaker: it's a per-request **method/shape/rate filter over all hosts**
  (`network-proxy.ts:75-104` — GET-only, 200-char URL cap, entropy heuristics, rate limits),
  **not a host allowlist**; it has **no cloud-metadata/link-local deny floor**; provider APIs
  are bypass-tunneled **without** MITM (`network.md:48-49`); default posture `none` = **full
  internet** despite docs claiming zero-egress (`sandbox-run.sh:138,142-143`,
  `network.md:89-91`, control test `network-proxy-test.sh:591-602`); and `custom` is half-
  wired (`runner.ts:216`). Nothing here improves on nono N2-4, which already feeds the sbx
  `allowedDomains` work the scan planned.
- **S-2. Credential injection.** We're **already stronger**, and nono N2-2 is the real
  upgrade. ysa forwards the **raw API key into container env** (`-e ANTHROPIC_API_KEY` value-
  forward, `runner.ts:172-175` → `sandbox-run.sh:304`). JidoClaw never puts the key in sbx
  env — agent auth rides *copied files* (`~/.claude/credentials.json`,
  `forge/runners/claude_code.ex:151-196`) and the host `*_API_KEY` vars are *stripped* from
  the sbx subprocess by the default-deny scrub (`security/redaction/env.ex:159-188`). ysa is
  a cautionary example here, not a donor; the only further improvement is nono N2-2's phantom
  tokens.
- **S-3. `runTask()` as CLI-wrap / adopt-as-tool / adopt-as-dep.** SKIP — §"Why not adopt"
  argues it: full task-runner overlap with Harness/AgentRunner, Podman < our sbx microVM,
  single-author pre-1.0 with security-doc drift. This directly overturns the scan README's
  "design donor or CLI wrap" framing — CLI-wrap is off the table; only the two narrow
  patterns (Y1-1, Y2-1) and the parked references survive.
- **S-4. `container-sandbox-guard.sh` (Claude Code PreToolUse regex hook).** ALREADY-COVERED
  by `Security.ToolApproval` — a DB-backed, single-use, fingerprinted approval gate is far
  more principled than a regex `bash`/`Read` matcher on stdin (`claude-settings.json:7-19`),
  which the ysa file itself notes is shallow/bypassable.
- **S-5. `git-push-guard.sh` (branch-restriction pre-push hook) + MITM CA.** ALREADY-COVERED
  / moot: the push guard is a `core.hooksPath` pre-push hook bypassable via `git push
  --no-verify`; our defense is structural — production sbx runs `network: :none`
  (`front_door.ex:422`), no git credentials reach the sandbox (env scrub + copied-files-only),
  and the `git_commit` *tool* is require-listed regardless of sandbox
  (`tool_approval.ex:267`, default_require). The `generate-ca.sh` MITM machinery is unneeded
  (we don't intercept TLS; browse_web uses a destination-policy gate).
- **S-6. The SDK/CLI surface, providers, `.ysa.toml`.** SKIP — JidoClaw's provider layer,
  session model, and config cascade are richer and native; ysa's 3-provider registry
  (`providers/registry.ts`) and hand-rolled TOML parser (`ysa-config.ts:14-43`, with a
  data-loss bug that drops `global_packages`/`init_commands` on rewrite) have nothing to add.

## Open questions

- **OQ-1. Do we ever want a `Sandbox.Podman` backend at all?** Y3-1 is the spec *if* yes.
  The decision hinges on a concrete Linux deploy target without Docker Desktop/sbx. Until one
  exists, the microVM is strictly better and Podman is dead weight. (If the answer is "never,"
  Y3-1 downgrades from TRACK to SKIP and the seccomp/hardening research is discarded.)
- **OQ-2. Is the poisoned-`.git/config` vector reachable enough to warrant Y1-1's clone-path
  pin (b), or only the gate widening (a)?** Production Forge runs `:shell` against a scaffold
  with `network: :none`; the attacker-config vector needs the `git_repo`-resource clone path
  (`resource_provisioner.ex:150-159`) *and* an autonomous agent running git in that clone.
  The gate-widening half (a) is worth doing regardless (pure host-path hardening); the clone-
  path pin (b) is worth it only if that path ships with autonomy. Decide when the sketch/exec
  worker (`sandbox: :docker`, `templates.ex`) graduates past `:shell`.

## Cross-references and dependencies

```
Y1-1 (harden git-exec) ──(a) widen git.ex gate  ── independent, do first (pure Elixir)
       │                └(b) clone-path config pin ── gated by OQ-2
       └── fixtures from ── Y3-2 (attack-test rubric: git-injection cases)

Y2-1 (worktree-per-task) ── independent; enables "agent on the real tree" (git plumbing only)

Y3-1 (Podman hardening spec) ── gated by OQ-1 (needs a Linux-no-sbx target)
Y3-3 (dep/toolchain cache)  ── gated by Forge-latency trigger

SUPERSEDED-BY-NONO: S-1 → nono N2-4 (egress semantics) · S-2 → nono N2-2 (phantom creds)
```

Suggested first (and likely only) wave: **Y1-1(a)** — widen `git.ex` to flag literal inline
code-exec config keys, with the ysa key list as the denylist spec and Y3-2's git-injection
scenarios as fixtures. It's pure Elixir, testable, closes a real gap, and needs no Podman and
no decision. **Y2-1** is the second candidate if "run an agent against my actual repo,
reviewably" becomes a wanted Forge mode. Everything else is parked on a named trigger.
Collision note: the current work queues (`unadopted-next-five` complete, `unadopted-next-ten`
in flight) contain no git-gate or workspace-isolation items, so Y1-1/Y2-1 don't displace
anything; they're small independent hardening/ergonomics work alongside the queue.

## Bottom line

ysa is a well-built artifact aimed at a different isolation tier than ours, and where it
overlaps our threat model it loses to entries already in the nono inventory. The honest
determination is a short list: **harden git execution against a poisoned repo config**
(Y1-1 — the one novel threat, cheapest as a `git.ex` gate widening with ysa's key list as the
spec), and **the worktree-per-task pattern** (Y2-1 — the lighter, reviewable middle between
our scaffold and our in-sandbox clone). The Podman hardening set and seccomp profile are a
good spec for a `Sandbox.Podman` backend we don't currently want (Y3-1, TRACK), and the
attack-test suite is a rubric to cherry-pick git-injection fixtures from (Y3-2). The scan's
hope that ysa would either be a CLI-wrappable backend or feed the sbx `allowedDomains` work is
retired: it's too coarse a grain to wrap, a weaker tier than we run, and nono N2-4 already owns
the egress-semantics spec. Read it, take the two patterns, and point the network/credential
ambitions at nono.
