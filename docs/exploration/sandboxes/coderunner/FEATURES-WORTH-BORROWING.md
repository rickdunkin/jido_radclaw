# Features Worth Borrowing from coderunner

Exploration notes — not a plan, not a commitment. Deep-dive **2026-07-03**, informing the
"coderunner as an external MCP server" next-step of the
[sandbox landscape scan](../README.md). Source: `~/workspace/research/sandboxes/coderunner`
(instavm/coderunner, HEAD `948095ee`, 2026-05-16). Self-description: *"A local sandbox for
your AI agents … you can run multiple Claude Code or AI agents in our sandbox without any
fear of data loss and exfilteration"* (`README.md:8-12` — see the calibration note on that
second clause). Shape: a single ~1,030-line Python FastMCP server (`server.py`) running
*inside* an Apple-`container` VM on Apple-Silicon macOS, plus the image build (Debian
`python:3.13.3` + Jupyter + Node/Playwright, `Dockerfile`), a provisioning script
(`install.sh` — downloads Apple `container` 0.8.0, sets up mDNS, runs the VM), two bundled
skills, and client examples. 42 files total. Maturity: 93 commits (2025-06-23 →
2026-05-16), effectively single-author (72/93 by one person, 9 by a colleague, 2 outside),
**no git tags, no CHANGELOG, no tests** (CONTRIBUTING.md:60 says "Ensure all existing
tests pass" — there are none; the only scripts are build smoke-tests), SECURITY.md + a
serious incident-response plan added April 2026, Apache-2.0. Activity: tapering — the last
substantive commit (May 2026) is an outside contributor's stop/resume fix. Cites are
firsthand reads of both trees, accurate to within a few lines. **coderunner was not
installed or executed during this review** — the Apple `container` runtime, mDNS reach,
kernel latency, and VM-isolation claims are per-docs/per-code until the trial spike
(CR1-1) runs it.

**Calibration note, stated up front** (ysa precedent — drift in the dangerous direction
lowers trust in a subject's own security claims): the README's headline — *"without any
fear of data loss and exfilteration"* (`README.md:12`) — is **host-protection true,
data-protection false**. The artifact has **zero egress control** (no network policy
anywhere in the tree; the VM has full outbound reach), and every in-VM service is
deliberately unauthenticated: a tokenless Jupyter on `0.0.0.0:8888` with XSRF disabled and
CORS `*` (`entrypoint.sh:3-14`), an open Playwright browser server on `0.0.0.0:3000`
(`entrypoint.sh:46`), and an MCP+REST exec endpoint with no auth of any kind (grep for
auth/token/secret in `server.py` is clean). Code running in the sandbox can freely ship
anywhere anything you feed the sandbox. The posture is *coherent* under "the VM boundary
is the perimeter and the vmnet is host-only" — but it is a **capability boundary, not a
data-security one**, and the README's claim inverts entirely on the plain-Docker fallback
path (`DOCKER_SETUP.md:36-46` publishes the same tokenless stack on a shared kernel).
Smaller drift, same direction of sloppiness: dead code in `server.py` (`KERNEL_TIMEOUT`
defined at `:57`, never used — there is no idle-kernel eviction; `base64`/`binascii`
imported, unused; `resolve_with_system_dns` defined at `:82`, never called there), a bash
Jupyter kernel installed in the image (`Dockerfile:68`) that no tool path can ever reach
(only `"python3"` kernels are requested — `server.py:242`, `entrypoint.sh:39`), and the
"persistent kernel" headline undermined by its own pool design (no session affinity — see
CR2-1). Weigh all of this when deciding how much to *depend* on it versus *learn* from it.

Companion docs: the [sandbox landscape scan](../README.md) (this doc informs its
coderunner spike item and confirms its "cheapest experiment" early read);
[`nono/FEATURES-WORTH-BORROWING.md`](../nono/FEATURES-WORTH-BORROWING.md) (the
approval-floor relaxation precedent N1-2 that OQ-1 leans on; note nono's N1-3 MCP-stdio
containment does *not* apply here — coderunner is consumed over HTTP, never spawned by
us); [`ysa/FEATURES-WORTH-BORROWING.md`](../ysa/FEATURES-WORTH-BORROWING.md) (the
calibration-note discipline this doc reuses);
[`agentos/FEATURES-WORTH-BORROWING.md`](../agentos/FEATURES-WORTH-BORROWING.md) (dug the
same day — its AO1-1/AO1-2 Forge-transcript pair is the runner-tier sibling of CR2-1's
durable-session itch, and AO2-2's bounded-by-default doctrine is the caps discipline a
CR2-1 executor's lifecycle should be born under); and
[`pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md`](../pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md)
(a CR2-1 kernel-in-sbx build is a direct consumer of its PS1-1/PS1-2 wiring — recorded on
its side, reciprocal here). The house threat model applies throughout
(personal, tailnet-only: LLM-misbehavior containment + secret/data-leakage hygiene) — and
cuts both ways here: the VM tier is exactly right for containing agent-run code, and the
egress-open posture is exactly the thing our threat model says to stay honest about.

## Determination (TL;DR)

**Trial it as a consumed MCP server — config-only, as the scan predicted — and borrow two
designs as patterns; adopt none of the code.** The integration really is one
`mcp_servers:` entry: our Consumer speaks `streamable_http` natively and wraps every
proxied tool in the full approval/redaction/shaping pipeline automatically, so coderunner
costs zero new code to evaluate and one config line to remove. What the trial evaluates is
a genuine capability gap: **JidoClaw has no stateful code execution anywhere** (every exec
surface is a discrete spawn) and **no agent-reachable sandboxed exec** (Forge is
triage/composer-gated, never an ordinary tool). But coderunner itself does not earn a
durable dependency slot — single-author, dormant since May 2026, untested, unauthenticated,
egress-open, and its isolation tier duplicates the sbx microVMs we already run. Its two
real ideas — a per-conversation stateful executor and the Anthropic-skills execution
surface — are worth owning natively if the trial proves the demand, with coderunner as the
existence proof *and* the flaw list.

| Part of coderunner | As a dependency | What to take |
| --- | --- | --- |
| The MCP server (5 tools over streamable HTTP at `coderunner.local:8222/mcp`) | **ADOPT-AS-TOOL, trial-scoped** | CR1-1: one config-only `mcp_servers:` entry; the cheapest capability experiment on the books |
| Kernel pool / persistent Jupyter execution | No | CR2-1: the pattern (pool floor/ceiling, health loop, resume-by-id) **plus its three flaws as the fix-first spec**, if a native stateful executor is ever built |
| Anthropic-skills compatibility surface (3 discovery tools + path translation) | No | CR2-2: the execution-side skills surface as the spec for giving *our* agents skill folders; the `anthropics/skills` corpus is the prize |
| Playwright-in-VM browser | No | CR3-1 TRACK: the browser-in-*sandbox* tier, for when agent browsing outgrows host-side `browse_web` |
| The batteries-included image (`requirements.txt` + apt set) | No | CR3-2: the curated inventory for a future Forge "analyst" image |
| Apple `container` runtime as a Forge backend | No | S-1 ALREADY-COVERED: `sbx` microVMs are the same isolation tier, already integrated |
| REST/SDK shim, fake sessions, stdio proxy | No | S-2/S-3 SKIP — one garnish: the pre-resolve-`.local` workaround their own clients use |
| In-VM security posture (tokenless everything) | No | S-4 SKIP — cautionary reference, not a design input |

## Why trial-scoped adopt-as-tool (and not more)

nono earned the corpus's first ADOPT-AS-TOOL because it was a mature, security-pedigreed
binary wrapping a spawn shape we already owned. coderunner earns only the **trial-scoped**
variant of the same verdict, and the asymmetry is the point:

1. **The integration is free, so the bar is low.** `JidoClaw.MCP.EndpointConfig` accepts
   `transport: streamable_http` with a `url:` (`lib/jido_claw/mcp/endpoint_config.ex:47-48,156-161`);
   the Consumer compiles a `use JidoClaw.Tools.Action` proxy per remote tool
   (`lib/jido_claw/mcp/proxy_generator.ex:234`), so approval-gating, outbound arg
   redaction (`proxy_generator.ex:244-248`), inbound redact/shape/cap, and the
   `isError`-lift all apply to `mcp_coderunner_*` automatically. Trying it is an
   afternoon; removing it is deleting five YAML lines.
2. **The capability gap is real, verified on our side.** No jupyter/ipython/kernel/REPL
   exists anywhere in `lib/` (grep clean, 2026-07-03); shell "sessions" persist cwd/env as
   *environment* state re-applied to each fresh `sh -c` spawn
   (`lib/jido_claw/shell/backend_host.ex:47-48,134-141`), never in-memory program state.
   And the in-REPL agent cannot reach Forge as a tool: `sandbox:` is stamped only from
   template policy (`Templates.sandbox("main")` → `:none`,
   `lib/jido_claw/agent/templates.ex:283-292`), the sole `:docker` template is
   composer-private and `spawn_agent` refuses it (`templates.ex:334-338`,
   `lib/jido_claw/tools/spawn_agent.ex:65-75`), and `validate_sandbox_scope` fails closed
   without a pre-provisioned front-door session
   (`lib/jido_claw/skills/steps/agent_runner.ex:144-185`). coderunner would be the first
   agent-reachable "run code, keep state" surface — which is exactly what makes it worth
   *measuring* before building.
3. **But it cannot be load-bearing.** The calibration note is disqualifying for a durable
   slot in the execution path: no tests, no releases, dormant, unauthenticated by design,
   egress-open with a README that claims otherwise, and a kernel pool whose headline
   feature (persistence) breaks under exactly the concurrency our platform would apply to
   it (CR2-1). The isolation tier itself adds nothing we lack — `Sandbox.Docker` already
   runs `sbx` microVMs (`lib/jido_claw/forge/sandbox/docker.ex:1-8,38`).
4. **The exit paths are owned, not hoped for.** If the trial shows the agent reaching for
   `execute_python_code` constantly, CR2-1 is the native successor; if `list_skills`/
   `get_skill_info` earn use, CR2-2 is. Either way the trial's job is to generate demand
   evidence, not to become infrastructure.

## How to read this document

Recommendations: **ADOPT-AS-TOOL (trial-scoped)** — the nono-earned axis, qualified: run
it as-is behind config, explicitly not a durable dependency; **BORROW-PATTERN** (translate
the design into our idioms), **BORROW-REFERENCE** (read their implementation as the spec
for something we build), **TRACK** (parked on a named trigger), **ALREADY-COVERED** (cite
the local equal-or-better), **SKIP**. No new axis is coined. Tiers scoped to this project:
**Tier 1** = do now (the trial); **Tier 2** = the native successors, trigger-gated on what
the trial teaches; **Tier 3** = reference/parked. Per-entry fields as usual: **Where in
coderunner** (file:line, "start here"), **What**, **Gap in jido_radclaw** (verified against
source 2026-07-03, largely via a dedicated seams pass), **Why it matters**, **Adoption
sketch**. IDs are `CR<tier>-<seq>`; `S-n` skips, `OQ-n` open questions.

---

## Tier 1 — The trial

### CR1-1. Consume coderunner as an external MCP server (config-only)

**Recommendation**: ADOPT-AS-TOOL, trial-scoped — the scan's "cheapest experiment,"
confirmed cheap after the dig.

**Where in coderunner**: `server.py:501-524` (`execute_python_code` — Python on a pooled
persistent Jupyter kernel, stdout streamed as MCP progress, 600s ceiling at `:67,429`);
`:527-556` (`navigate_and_get_all_visible_text` — Playwright `goto` + BeautifulSoup text);
`:587-653` (`list_skills`), `:700-722` (`get_skill_info`), `:724-751` (`get_skill_file`);
`:766` (`mcp.streamable_http_app()` — the transport is streamable HTTP, served at
`http://coderunner.local:8222/mcp`, `README.md:60`); `install.sh:108-116` (the VM:
`container run --volume ~/.coderunner/assets/skills/user:/app/uploads/skills/user
--volume ~/.coderunner/assets/outputs:/app/uploads/outputs --cpus 8 --memory 4g`);
`README.md:29-46` (stop/resume preserves kernels, uploads, installed packages).

**What**: Five tools over a transport we already speak, executing inside an Apple
`container` VM (per Apple's docs, full-VM isolation properties — `README.md:274-277`,
not executed this review). File exchange with the host rides the two volume mounts.

**Gap in jido_radclaw**: Confirmed config-only. The endpoint schema takes exactly
`name` + `transport: streamable_http` + `url:` (+ optional `headers:`)
(`endpoint_config.ex:156-161`; URL validation requires only scheme+host, `:208-219` — no
private-IP restriction on the MCP path; that deny-list belongs to `browse_web`'s
`DestinationPolicy`, single-caller noted at
`lib/jido_claw/security/destination_policy.ex:97`). The shipped config doc shows the
identical shape for tidewave (`config/config.exs:227-240`). Approval: `mcp_*` tools are
**gated by default** (`mcp_require_approval: true`, `config.exs:207`; unknown `mcp_` names
fail closed to gated, `lib/jido_claw/security/tool_approval.ex:240-257`); per-server
`require_approval: false` is the trust knob, `templates:` the reach knob
(`endpoint_config.ex:127-143`). Nothing resolves `.local`/mDNS today: no resolver
configuration anywhere in `lib/`/`config/` (grep clean), and the MCP transport runs
anubis→Finch→Mint→Erlang `:inet`, whose default resolver does not do mDNS — see OQ-2.

**Why it matters**: This is the only entry that produces *evidence* rather than code: does
a stateful, sandboxed executor actually change how the agent works (data analysis,
document processing via skills, iterative computation), or is it a novelty? Risk is
bounded on three sides — the VM contains what the code does to the machine, our approval
gate fronts every call until trusted, and outbound args are redacted before they leave
(`proxy_generator.ex:244-248`). The un-bounded side is stated plainly: **egress-open** —
anything placed in the sandbox can leave it, so the trial policy is "never feed it secrets
or private data," not "trust the sandbox."

**Adoption sketch**: `.jido/config.yaml`:

```yaml
mcp_servers:
  - name: coderunner
    transport: streamable_http
    url: "http://coderunner.local:8222/mcp"   # pre-resolve to the VM IP if the BEAM balks — OQ-2
    require_approval: false                    # OQ-1; leave absent (gated) to measure friction instead
    templates: ["main"]                        # interactive agent only; workers don't get it
```

Pre-flight: run their `install.sh` (it wants `sudo` for the Apple `container` pkg + mDNS
domain; review it first — it's 122 lines), confirm `curl http://coderunner.local:8222/mcp`
from the host, then boot the REPL and check the Consumer's discovery. Trial caveats to
carry into usage, all verified against their source: (a) **results are strings, errors are
`"Error: …"` strings** — no MCP `isError` (`server.py:522-524`), so failures arrive as
ok-text; fine for a trial, but our `isError`-lift path simply won't trigger. (b) **their
retry re-executes your code** — up to 3 attempts with backoff on *any* failure
(`server.py:372-402`), so side-effectful snippets may run more than once; keep trial usage
idempotent. (c) **state is best-effort** — repeated user-code errors mark the kernel
failed and destroy it, taking accumulated state with it (`server.py:197-216,471-474`), and
pool assignment has no session affinity (CR2-1), so serial single-user use is sticky only
by dict-order accident (`server.py:174-182`). (d) **rich output degrades to
`text/plain`** (`server.py:467-469`) — plots come back as `<Figure …>`; artifacts should
be written to `/app/uploads/outputs` and read host-side from `~/.coderunner/assets/outputs`.
(e) Progress notifications may be dropped by our client; harmless. (f) Mount nothing of
ours into it (OQ-3). Success criteria worth writing down before starting: N sessions where
`execute_python_code` was reached for unprompted; whether state-across-calls was ever
load-bearing; whether skills tools got used at all.

---

## Tier 2 — The native successors (trigger-gated on the trial)

### CR2-1. A session-affine stateful executor — the pattern, plus the three flaws to fix

**Recommendation**: BORROW-PATTERN — trigger: the CR1-1 trial shows stateful execution
earning real use (or a concrete analyst-workflow demand arrives first).

**Where in coderunner**: `server.py:132-334` (the `KernelPool`: floor/ceiling 2–5
(`:55-56`), lock-guarded checkout (`:169-195`), release-with-failure-accounting
(`:197-220`), replace-after-3-failures (`:211-216`), background health loop every 30s
executing `1+1` over a fresh websocket (`:273-331`)); `:339-367` (raw Jupyter
`execute_request` framing, `store_history: False`, `stop_on_error: True`); `:404-498`
(execution loop: adaptive recv timeout by recent activity (`:429-445`), stdout streamed as
progress (`:461-465`), 600s ceiling); `entrypoint.sh:39-44` + `server.py:222-234` (kernel
bootstrap + resume: kernel id persisted to a file, revalidated on server start — the
mechanism behind "stop/resume preserves kernels").

**What**: A pool of persistent interpreters fronted by health checks and
replace-on-failure, giving "define a dataframe in call 1, use it in call 40" semantics
with crash recovery.

**Gap in jido_radclaw**: There is no persistent interpreter anywhere — verified honest
not-found (grep for jupyter/ipython/kernel/repl/notebook across `lib/`: only project-type
detection, the shell *gate's* interpreter-oneliner patterns
(`lib/jido_claw/security/shell_command.ex:106-109,702-737`), and the CLI REPL). Every
execution surface is a discrete OS spawn: host `run_command` opens a fresh
`Port.open({:spawn, "sh -c …"})` per call (`backend_host.ex:134-141`), and Forge exec is
per-command `sbx exec … sh -c` (`docker.ex:346-358`). What *does* persist —
`SessionManager`'s per-workspace cwd/env/history
(`lib/jido_claw/shell/session_manager.ex:1-27,87`) — is environment state re-applied to
each spawn, not program state. The "load once, iterate across turns" class is impossible
today; every call pays imports + data load again.

**Why it matters**: Stateful execution is the capability class behind analyst work
(explore a dataset across a conversation), long multi-step computations, and cheap
incremental retries — and it's the one thing in coderunner that is neither replaceable by
our existing tiers nor already planned. Equally important: coderunner shows precisely
where the naive version breaks, which is the expensive part of the design done for us —
**(1) no session affinity**: `get_available_kernel` hands back *any* healthy kernel
(`server.py:174-195`), so two concurrent conversations interleave state on one kernel and
one conversation's state scatters across kernels — persistence by accident, broken under
exactly the concurrency this platform would apply. A native version must key kernel ↔
conversation identity; we already own the precedent for that keying discipline
(`JidoClaw.Reasoning.Compactor.Identity`, per-agent state slices). **(2) user-error /
kernel-health conflation**: a syntax error in submitted code raises, marks the kernel
FAILED (`server.py:388-391,471-474`), burns 3 retries re-running broken code, and after
repeated errors destroys the kernel — i.e. the *state the feature exists to keep*. Execute
status (their `execute_reply`) and kernel liveness are different signals; classify them
separately. **(3) side-effect-unsafe retry**: auto re-execute of arbitrary stateful code
is wrong at the semantics level; retry only transport/connection failures, surface code
errors to the model as results. Their unused `KERNEL_TIMEOUT` (`server.py:57`) is the
fourth tell: idle eviction was intended and never wired — state lifecycle needs an owner,
not a constant.

**Adoption sketch**: A Forge runner, not a new platform: `Forge.Runners.Kernel` (beside
`shell`/`claude_code`, resolved at `lib/jido_claw/forge/harness.ex:1330-1336`) that starts
one interpreter *inside* an sbx sandbox and holds the connection in the runner's session
state — session-affine by construction (one kernel per Forge session; Forge sessions are
already per-workspace GenServers). Execute = send to *that* kernel; kernel death = surface
"state lost, restarting" to the model, never silent replacement. Substrate choice (Jupyter
protocol vs a plain long-lived interpreter over a Port with a line protocol) is OQ-4;
lifecycle ties to the owning Session, with explicit idle eviction. The reach question —
how the *REPL* agent gets to it, given Forge's composer-gating — is the same "agent-
reachable sandbox" policy decision the trial exists to inform; do not solve it before the
trial says the capability matters. *(2026-07-03 cross-dig: when this fires, the sbx
wiring rides [pi-sbx PS1-1/PS1-2](../pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md) — that
doc already lists CR2-1 as a consumer — the executor's caps are born under
[agentos AO2-2](../agentos/FEATURES-WORTH-BORROWING.md)'s bounded-by-default doctrine,
and AO1-1's Forge transcript rows are the same durable-session record at the
agent-runner tier.)*

---

### CR2-2. The Anthropic-skills execution surface (SKILL.md folders our agents can use)

**Recommendation**: BORROW-PATTERN — stands on its own merits; the trial is merely its
cheapest evaluation vehicle. This is coderunner's sleeper feature.

**Where in coderunner**: `server.py:587-653` (`list_skills`: scan
`/app/uploads/skills/{public,user}`, parse SKILL.md frontmatter for `name`/`description`
only — `:562-585`); `:656-697` (`_read_skill_file` with the load-bearing trick at `:691`:
rewrite `/mnt/user-data` → `/app/uploads`, so skills written for *Anthropic's* runtime run
unmodified); `:700-751` (`get_skill_info` = SKILL.md, `get_skill_file` = any referenced
doc — three levels of progressive disclosure: names → instructions → deep files);
`install.sh:86-88,110` + `Dockerfile:80-81` (public skills baked into the image, user
skills volume-mounted from `~/.coderunner/assets/skills/user`); `SKILLS-README.md:73-127`
(import `anthropics/skills` — docx/pptx/xlsx/pdf/image — by copying folders; drop a .zip
and `list_skills` auto-extracts it, `server.py:599-604`).

**What**: Skills as knowledge-plus-scripts folders (the Anthropic SKILL.md convention),
mounted into the execution sandbox, discovered at runtime through three cheap tools, with
path translation making the entire public Anthropic skills corpus compatible for free.
Model reads instructions → composes a call to `execute_python_code` running the skill's
script inside the sandbox.

**Gap in jido_radclaw**: Our `.jido/skills/*.yaml` are a different animal entirely —
LLM/operator-authored *workflow* definitions compiled to Reactor DAGs
(`lib/jido_claw/platform/skills.ex:3`, `lib/jido_claw/skills/compiler.ex:23-31`), whose
steps spawn in-process LLM sub-agents (`lib/jido_claw/skills/steps/agent_runner.ex:65-121`)
— orchestration, not capability folders; nothing executes in a sandbox. SKILL.md support
is grep-clean in `lib/` with one narrow exception that proves the point: the `ClaudeCode`
Forge runner syncs the host's `~/.claude/skills` into the sandbox *for the guest `claude`
CLI* (`lib/jido_claw/forge/runners/claude_code.ex:10,151-217`) — Anthropic-style skills
already reach a CLI we host, but **JidoClaw's own agents have no skills surface**: the
`anthropics/skills` document-processing corpus is unusable by our workers today.

**Why it matters**: Skill folders are capability the model discovers only when needed —
near-zero prompt cost until used (frontmatter name+description at list level is the whole
catalog entry), and the public corpus is real, maintained capability (Office documents,
PDF) that we'd otherwise reimplement tool-by-tool. The pattern composes with what we own:
scripts execute inside a Forge sandbox (mount ro), discovery tools are cheap reads. And
the meta-evidence is in this very repo — `.claude/skills/` runs our own development — the
convention works; our agents are the only ones here who can't use it. Trust framing: a
SKILL.md's content is prompt-trusted the moment the model reads it — the same class as MCP
tool descriptions, which AGENTS.md's trust-boundary paragraph already covers; operator-
installed skill dirs carry the same trust grant as `.claude/skills` does for Claude Code.

**Adoption sketch**: Three small pieces, none requiring coderunner. (a) A skills dir
(name it carefully — OQ-5; "skill" is already taken twice in-house) mounted read-only into
sbx sandboxes via the existing `extra_mounts` normalization
(`lib/jido_claw/forge/harness.ex:1384-1415`; the front door already builds exactly this
shape for `/proto`, `lib/jido_claw/front_door.ex:416-428`). (b) Three thin tools
(list/info/file) — host-side reads of the same dir, so discovery works even without a live
sandbox; only *execution* needs one. Frontmatter parsing is trivial (theirs is 20 lines).
(c) A prompt note telling agents skills exist and where scripts live in-sandbox. Two
of their details to consciously *not* copy: the zip-auto-extract side effect inside a
*list* tool (`server.py:599-604` — discovery tools should be read-only; make install an
operator action), and path-translation-by-string-replace (ours would be a documented mount
convention, not a rewrite). Gate the build on demand evidence (the trial's skills-tools
usage, or the first real "process these documents" ask).

---

## Tier 3 — Reference material and parked items

### CR3-1. Browser-in-sandbox: the missing tier above `browse_web`

**Recommendation**: TRACK — trigger: agent web automation outgrows fetch-and-read
(logins, form-filling, file downloads, untrusted-site interaction), or `browse_web`'s
host-side blast radius starts feeling wrong for a task.

**Where in coderunner**: `entrypoint.sh:46` (`npx playwright run-server` inside the VM);
`server.py:527-556` (connect over ws to the in-VM browser, `goto`, extract text);
`Dockerfile:101-108` (Chromium + deps baked into the image).

**What**: The browser process itself lives inside the VM — cookies, downloads, renderer
exploits, and whatever a hostile page triggers are all contained by the same boundary as
the code execution.

**Gap in jido_radclaw**: Corrected against source — we *do* have a real headless browser:
`browse_web` drives `jido_browser`'s vibium driver with `get_content`/`extract_links`/
`screenshot` (`lib/jido_claw/tools/browse_web.ex:69,136-200,215-217`), fronted by
`DestinationPolicy` (deny loopback/RFC-1918/link-local/CGNAT by default, re-checked on the
final URL after redirects — `destination_policy.ex:108-123`, `browse_web.ex:97-108`). What
we lack is the *tier*: that browser runs on the **host**. The destination gate bounds
where it goes, nothing bounds what a permitted-but-hostile page does to host-side browser
state. (Same-neighborhood fact: `DestinationPolicy` would deny `coderunner.local` itself
to `browse_web` — private IP — but that gate is single-caller and irrelevant to the MCP
path, `destination_policy.ex:97`.)

**Why parked**: coderunner's own implementation is a toy (goto + visible text — strictly
less capable than our `browse_web`), so there is nothing to lift today; the *pattern* only
pays when richer automation is wanted. When the trigger fires, the shape is an sbx image
with Playwright plus a thin driver — or, interim, coderunner itself via CR1-1's config.

### CR3-2. The batteries-included analyst image inventory

**Recommendation**: BORROW-REFERENCE (garnish) — trigger: building a purpose-built Forge
image (natural companion to CR2-1/CR2-2).

**Where in coderunner**: `requirements.txt` (the curated analyst env: pandas/numpy/scipy/
sklearn/statsmodels, matplotlib/seaborn, the full document stack — openpyxl/xlsxwriter/
python-pptx/python-docx/pypdf/pdfplumber/pypdfium2/pdf2image/pdfkit/tabula-py/reportlab/
img2pdf — plus duckdb, pyarrow, sympy, imageio+ffmpeg); `Dockerfile:13-54` (the apt layer:
wkhtmltopdf, poppler-utils, ffmpeg, ripgrep, fd-find, sqlite3, default-jre for tabula).

**What / why**: The value of "execute code" tools is mostly the toolchain already present
when the code runs. This is a field-tested inventory for the document/data class of work —
the same class the Anthropic skills corpus targets — worth cribbing when we cut a Forge
image, instead of rediscovering it one missing-import at a time. Nothing to do until then.

---

## Skip / Already Covered

- **S-1. Apple `container` as a second Forge sandbox backend.** ALREADY-COVERED by
  `Sandbox.Docker` on `sbx` microVMs (`docker.ex:1-8,38`) — the same VM-class isolation
  tier, already integrated behind `Forge.Sandbox.Behaviour`, on the same machine. A
  `Sandbox.AppleContainer` would be a redundant twin. Named trigger to revisit: `sbx`
  becomes unavailable on macOS (Docker Desktop licensing/removal) — then `install.sh:22-82`
  is the provisioning worked example (pkg install, `container system start`, the
  `container system dns create local` mDNS trick, stop/start resume semantics).
- **S-2. The REST/SDK-compat shim and fake sessions.** SKIP. `server.py:754-1028` exists
  for instavm's cloud SDK: `/execute`, `/v1/browser/*`, and session endpoints whose
  "sessions" are an in-memory counter returning `active` (`:965-1019`) — decorative state,
  ignored by execution. Nothing for us.
- **S-3. `mcpproxy.py` stdio shim.** SKIP — it exists for clients that can't speak
  streamable HTTP; we can (`endpoint_config.ex:47-48`). Its one durable teaching is that
  **their own first-party clients pre-resolve `coderunner.local` to an IP** before
  building the URL (`examples/claude_desktop/mcpproxy.py:6-14`,
  `examples/openai_agents/openai_client.py:37-44`) — upstream's own admission that mDNS
  hostnames are unreliable across HTTP stacks. That workaround feeds OQ-2.
- **S-4. The in-VM service posture as a design input.** SKIP, cautionary. Tokenless
  Jupyter on `0.0.0.0` with XSRF off and CORS `*`, an open browser server, root execution,
  `sudo`+`openssh-server` baked into the image (`Dockerfile:14,22-23`), and a DNS-rebinding
  allowlist that includes `0.0.0.0:*` (`server.py:40-45`) — all coherent *only* while "the
  VM is the perimeter" holds, and the project's own Docker fallback publishes the same
  stack on a shared kernel (`DOCKER_SETUP.md:36-46`), where the README's security claims
  invert. Treat as a reference for what not to normalize on any surface of ours that
  outlives a VM.
- **S-5. `GEMINI.md` prompt-integration example.** SKIP — typo-ridden, and our prompt
  assembly (SubagentPrompt, system_prompt.md) is a different class. Its one good instinct
  — "always check whether a skill covers the task first" — belongs in CR2-2's prompt note,
  and Anthropic's own skills docs state it better.

## Open questions

- **OQ-1. Approval posture for the trial.** Leave `mcp_coderunner_*` gated (the default:
  `mcp_require_approval: true`, fail-closed — `tool_approval.ex:240-257`) and measure the
  friction, or set `require_approval: false` because the VM moots the reach rationale —
  the same argument as the shipped `:docker` shell-floor skip (`tool_approval.ex:271-296`)
  and nono N1-2's `:contained` tier. Leaning: **trusted, scoped `templates: ["main"]`**,
  because per-call approvals on an iterating executor would smother the trial — with the
  explicit trade recorded that "trusted" here means "trusted to stay in its VM," not
  "trusted with data" (egress-open; the never-feed-it-secrets rule stands regardless).
- **OQ-2. Does `coderunner.local` resolve from the BEAM?** Erlang's default `:inet`
  resolver does not do mDNS, and we configure no resolver overrides anywhere (verified
  grep-clean in `lib/` + `config/`); macOS resolves `.local` via mDNSResponder only when
  `getaddrinfo` is in the loop. Options, in order of preference at spike time: pin the
  VM's IP in the `url:` (what their own clients effectively do), an `/etc/hosts` entry, or
  an `ERL_INETRC` native-resolver stanza. Resolve empirically at CR1-1 pre-flight; wrong
  answers fail loud (Consumer prep just fails that endpoint, boot unaffected —
  `consumer.ex:744-864`).
- **OQ-3. Mounts.** Recommend mounting nothing of ours for the trial — exchange files via
  their `~/.coderunner/assets/outputs` mount only. Rationale: the endpoint is
  unauthenticated host-wide and the VM is egress-open; a project-dir mount would hand both
  read and exfil of the working tree to anything that reaches the port. Revisit only if
  the trial graduates toward CR2-1, where mounts become *our* sbx mounts under *our*
  policy (`harness.ex:1384-1415`).
- **OQ-4. Substrate for CR2-1 if it fires.** Jupyter-in-sbx (their shape: mature protocol,
  rich-output story, heavy image) vs a plain long-lived interpreter over a Port with a
  line protocol (lighter, ours, no display data) vs in-BEAM bridges like Pythonx/erlport
  (wrong isolation — code would run in the BEAM's memory space; effectively disqualified
  by the threat model). Decide only when CR2-1's trigger fires; the affinity/error/retry
  requirements in that entry hold for any substrate.
- **OQ-5. Naming the skills surface.** "Skill" is already two things here — `.jido/skills`
  YAML→Reactor workflows and `.claude/skills` for Claude Code development. CR2-2 adds a
  third kind (agent-facing capability folders). Settle the vocabulary before building —
  candidate: "agent skills" with the dir named to match — and decide whether YAML skills
  and folder skills eventually share a discovery surface or deliberately stay apart.

## Cross-references and dependencies

```
CR1-1 (config-only trial) ── demand evidence ──> CR2-1 (native session-affine executor)
   │                                        └──> CR2-2 (agent-skills surface — stands alone;
   │                                              trial is just its cheapest evaluation)
   ├── OQ-1 (approval posture), OQ-2 (.local), OQ-3 (mounts) gate the trial config
   └── S-3's pre-resolve workaround feeds OQ-2

CR3-1 (browser-in-sandbox)  — trigger: automation beyond fetch/extract/screenshot
CR3-2 (analyst image)       — trigger: purpose-built Forge image work
S-1  (Apple container)      — trigger: sbx unavailable on macOS
```

Suggested first (and possibly only) wave: **CR1-1 alone** — an afternoon including the
OQ-2 resolver fiddling, off-machine risk bounded by the VM, reversible by deleting five
YAML lines. Run it for a few real sessions with the success criteria written down, then
let the usage data pick between "keep as-is," "retire," and "build CR2-1/CR2-2." Queue
collision: none — `unadopted-next-five` is complete, `unadopted-next-ten` is composer/
judgment work, and the nono containment program is host-tier; this trial is config-only
and displaces nothing. One interaction worth noting: a Forge-sandboxed template would
never see coderunner's tools anyway — sandboxed templates get zero external MCP tools at
registration (`consumer.ex:659-678`), a pleasing default here.

## Bottom line

coderunner is a small, honest-in-code, oversold-in-README artifact whose *architecture* —
stateful execution behind MCP inside a genuine VM, with Anthropic-skills compatibility —
is more valuable than its implementation. The ideas that must not slip: **run the
config-only trial** (CR1-1 — the cheapest capability experiment available to us, already
anticipated by the scan, reversible in minutes); **if stateful execution earns its keep,
build it session-affine** (CR2-1 — coderunner's pool teaches the pattern and, in its three
flaws, the spec: affinity by construction, user-error ≠ kernel-death, never auto-re-run
stateful code); and **the skills surface is the sleeper** (CR2-2 — three thin tools plus a
read-only mount buys our agents the entire public Anthropic skills corpus, independent of
coderunner entirely). Against the threat model, keep the one sentence that matters:
coderunner contains what code *does to the machine*, not where data *goes* — a capability
boundary, never a data-security one.
