# AR-8b-2 — F2: `sandbox: :docker` code-execution sketch tier (design)

*Implements the deferred F2 follow-on sketched in `AR-8b-2-GRADUATION.md` §F2 and roadmapped in
`.claude/plans/please-review-docs-exploration-alp-river-steady-lagoon.md` (P1–P6). Delivered in **two
implementation passes** — Phase 1 (plumbing) then Phase 2 (activation). Greenfield: no
migration/back-compat. **Done = `mix precommit` green.***

> **Status — SHIPPED (Phase 1 `fc9fd38b` 2026-06-24, Phase 2 `c3d3df99` 2026-06-25; reconciled
> 2026-07-02).** All the load-bearing pieces are in-tree as designed:
> `Tools.RunCommand.ForgeBridge` (+ the `run_command` dispatch branch), the
> `sketch_build_exec` worker on the shared `SketchWorker` macro with the `sandbox: :docker`
> template (and D5's `forward_context: {:only, …}`), the `must-execute` 4-file thread
> (schema/verdict/prompt/catalog), `Forge.start_session_ready/3`, and the D2-a
> `isolate_global_config` opt-out in the Docker backend. One refinement over the text below:
> the exec working directory is stamped from `sandbox_spec.workdir` (a general flag) rather
> than a hardcoded `--workdir /proto` branch. The verification posture holds as written — the
> real in-microVM path (no-egress, mount round-trip, workdir) is proven only by the manual
> `:docker_sandbox`-tagged run, excluded from CI by design (the "sole caveat" the
> FEATURES-WORTH-BORROWING AR-8 entry records). The Non-goals stand (no per-tool approval
> overlay; no auto-merge; file tools stay host-mounted).
>
> **sbx 0.34.0 remediation (docker write build, 2026-07-07):** the emission mechanics this
> page designed against have since moved — the installed sbx rejects `--mount`/`--network`;
> workspaces are now same-path `create` positionals (host == container, the front door's
> `/proto` remap became a same-path `proto_dir` mount + workdir) and the no-egress request
> applies post-create as a per-sandbox `sbx policy deny network "**"` rule, enforced by a
> transparent proxy answering in-band HTTP 403 (the `:docker_sandbox` egress probe is
> body-aware accordingly). The tier's guarantees (no-egress, rw round-trip, workdir) hold
> under the new mechanics — re-proven by the same tagged run.

---

## Context — why this, and why a new tier

The sketch path (AR-8b) launches a `sketch-build` worker in a hard-isolated `<project>/.prototypes/<uuid>/`
sandbox with **file tools only**, and converges the instant the worker finishes. F1 added a light
correctness reviewer; F3 added read-only real-tree tools. The one thing a sketch still cannot do is
**run** its tracer-bullet.

It cannot, *by design*: `RunCommand` shells to `JidoClaw.Shell.SessionManager` (host/vfs/ssh,
`run_command.ex:161-182`), which escapes the VFS jail entirely — the jail only constrains file-tool
*paths*, not a spawned shell. So a sketch that must execute code needs **OS-level** isolation
(filesystem, process, network), which the file jail does not provide.

F2 adds that isolation tier. The `sandbox` template policy was built to anticipate it: `:prototype`
means the file jail; **`:docker`** means "the file jail **plus** an OS sandbox for `RunCommand`,"
routed into the existing Forge Docker microVM substrate (`Forge.exec/3` → `Forge.Sandbox.Docker`,
`sbx` CLI). `external_tools?/1` stays false for the new tier (a sandboxed tier never gets external MCP
tools), and the policy/stamp machinery already keys on the atom — so the tier is a new **branch**, not
a new mechanism.

### The core architectural finding (the heart of the work)

**Two execution substrates are fully disconnected.** `RunCommand` → `Shell.SessionManager` (jido_shell
sessions, keyed by `workspace_id`, returns `{:ok, %{output:, exit_code:}}`) and `JidoClaw.Forge` (microVM
sessions, keyed by `session_id`, returns `{:ok, {output, exit_code}}`) share **nothing**. Nothing routes
a tool command into a Forge sandbox today. Building that bridge — with its return-shape adapter and two
distinct "`sbx` is missing" channels — is the load-bearing part of Phase 1.

### What `mix precommit` can and cannot prove

Real Docker is excluded from the suite (`@moduletag :docker_sandbox`, excluded in
`test/test_helper.exs:1`). So "precommit green" is met by (a) unit-testing the `ForgeBridge`
return-shape/normalization helper **directly** with hand-fed backend tuples (the `sbx`-missing 127,
timeout 124, output-limit 153, and the success shape) and (b) driving the bridge *wiring* with
`JidoClaw.Test.StubSandbox` + `Application.put_env(:jido_claw, :forge_sandbox, …)` — with a new
programmable `StubSandbox.exec` (§1.5). The `:sbx_finder` seam is **not** part of this path: it lives
inside the Docker backend's `exec_with_timeout` (`docker.ex:336`), which `StubSandbox` never runs. The
actual *in-microVM execution* is verified only by a `:docker_sandbox`-tagged integration test run
manually where Docker/`sbx` is available. This is acceptable and matches the existing Forge test posture.

---

## Substrate this rides on (all live today)

| Hook | Where | What it gives F2 |
| --- | --- | --- |
| `sandbox` template policy | `Templates.validate_sandbox/2` (`templates.ex:263`), `sandbox/1` (`:173`), `external_tools?/1` (`:188`) | One atom drives the enforcement table; today admits only `:none \| :prototype` |
| `:sandbox` canonical key | `tool_context.ex:38,72` | Never policy-strippable; auto-propagates to nested children |
| `:forge_session_key` | `tool_context.ex:54,97`; preserved in `build/1` (`:110`) | Policy-controlled string handle; **no producer sets it today** — F2 is the first |
| `apply_visibility {:only, …}` | `tool_context.ex:208` | Keeps only the listed strippable keys — the clean way to pass the session key to a jailed worker |
| Forge API | `forge.ex`: `start_session/2` (`:22`), `exec/3` (`:68`), `stop_session/2` (`:52`), `get_handle/1` (`:26`), `wake/2` (`:35`) | The microVM lifecycle + exec the bridge calls; `wake/2` + Manager auto-recovery (`manager.ex:162`) is the spec read-back path F2 hardens (D3 / Finding 1) |
| Forge Docker backend | `forge/sandbox/docker.ex`: `create/1` (`:32`), `exec` (`:130`), `exec_with_timeout` (`:305`) | The `sbx` runner; `:forge_sandbox` app-config selects it (`runtime.exs:6`) |
| Sketch front-door scope | `front_door.ex` `sketch_scope/2` (`:293`) | Creates `.prototypes/<uuid>/`, reroots `project_dir`, persists premises — the natural place to also mint the Forge session |
| Sketch catalog stages | `catalog.ex` `sketch-build` (`:183`), `sketch-review` (`:205`) | The route F2 extends with an exec sibling |
| Triage signal vocabulary | `triage/schema.ex:22`, `triage/verdict.ex:45`, `triage/prompt.ex:52`, `catalog.ex:42` (`triage.publishes`) | The 4 places a new "must-execute" verdict signal threads through — **not** `@signal_topics` (the discriminator is seeded by the launch decision, §2.3/D4) |
| StubSandbox + seams | `test/support/stub_sandbox.ex`, `:sbx_finder` (`docker.ex:336`), `:docker_sandbox` tag | Lets the bridge be tested without real Docker |

---

## Cross-cutting design decisions (resolved here)

These shape both phases; settle them before writing code.

### D1 — File-tools workspace: **mount `.prototypes/<id>/` into the Forge session** (roadmap P4)

An exec sketch writes files (`WriteFile`) then runs them (`RunCommand`). They **must** hit one tree or
the tracer-bullet can't see its own files. The Forge Docker session host-mounts paths into the
container and `write_file`/`read_file` operate on the host side (`docker.ex:191-203`), so a mount is the
bridge between "host file tools" and "in-container exec."

The naïve route — make the Forge session's `workspace_dir` *be* `.prototypes/<id>/` — **deletes the
prototype on teardown.** `Forge.stop_session` → `Harness.terminate/2` (`harness.ex:705-725`) →
`Docker.destroy/2` does `File.rm_rf(workspace_dir)` (`docker.ex:240`), so if `workspace_dir ==
.prototypes/<id>/` the run's terminalization (D3) wipes the very dir C1 provenance, C3 retention, and
`PrototypeSummary.summarize/1` (`front_door.ex:486`, `prototype_summary.ex:87`) depend on. Workspace
ownership must stay with the front door, not the Forge session.

**Decision: keep `.prototypes/<id>/` front-door-owned and *mount* it into the container (variant ii).**
File tools (host VFS, jailed to `project_dir == .prototypes/<id>/`, **unchanged from `sketch_build`**)
write the prototype on the host; the Forge session owns only a throwaway `/tmp/jidoclaw_forge/<name>`
`workspace_dir` and gets `.prototypes/<id>/` as a read-write `extra_mount` (e.g. at `/proto`);
`RunCommand` (Forge exec) runs with that mount as its cwd. Both substrates see one tree, and teardown's
`rm_rf` hits only the throwaway `/tmp` dir — the prototype survives.

| Variant | Mechanism | Why / why not |
| --- | --- | --- |
| **(ii) `extra_mounts`** *(decided)* | Pass `sandbox_spec.extra_mounts` (a **JSON-safe** mount entry — not a raw tuple, since the spec is persisted as jsonb; see D3) and run exec with `--workdir /proto` | **No backend change for the *mount* mechanism** (mount already supported, `docker.ex:542-549`; teardown safely `rm_rf`s only the Forge-owned `/tmp` workspace); file tools untouched. (Two small *additive* backend branches are required — D2-a's global-config opt-out (Finding P1) on `create`, and the `--workdir /proto` flag on `exec` (see below) — but the mount *mechanism* itself is unchanged.) Cost: `RunCommand` must force the working dir to the mount (the `--workdir` flag, see below), and the JSON-safe map must be **normalized back to a `{h, c, m}` tuple at the harness boundary** (`build_sandbox_spec`/`merge_resource_mounts`, `harness.ex:1278-1292`) before the backend's tuple-only `add_spec_mounts/2` sees it — see D3 "Mounts must be JSON-safe." |
| (i) caller-supplied `workspace_dir` | Extend the backend to accept `workspace_dir: <prototype_dir>` and skip the generated-dir path | **Rejected:** makes the Forge session *own* the prototype, so `Docker.destroy/2`'s `rm_rf` deletes it. Salvaging it needs a *second* backend change (an `owns_workspace?` flag so `destroy/2` skips `rm_rf` for a caller-supplied dir) — more lifecycle surface than (ii). |

**Load-bearing implementation detail (variant ii requires it):** `build_exec_args/3` (`docker.ex:278-290`)
runs `sbx exec <name> sh -c <cmd>` with **no `--workdir`**, so exec defaults to the throwaway `/tmp`
workspace, *not* the mount. **Decision: pass an explicit `--workdir /proto` via a small *additive*
backend change** (`sbx exec` supports a working-directory flag) rather than prefixing `cd /proto && ` onto
the command. The workdir flag is strictly better than the shell prefix on three counts: (1) it preserves
the **raw command** verbatim — so the Forge exec event log (`harness.ex:478` logs the command handed to
`Forge.exec`) and any command-derived telemetry stay faithful, where a `cd /proto && ` prefix would
pollute them; (2) it avoids shell-prefix edge cases (a command that *itself* `cd`s, an empty/comment-only
command, a leading-newline heredoc); (3) it keeps the in-container cwd authoritative at the runner layer,
not woven into user text. Thread the workdir through the exec opts / `sandbox_spec` so `build_exec_args/3`
emits `sbx exec --workdir /proto …`. (This **amends D1's "no backend change for the *mount*"** the same
way D2-a's `isolate_global_config` does — one small additive `build_exec_args` branch; the *mount*
mechanism itself is still unchanged.) **Fingerprint/approval are unaffected either way** — the
`ToolApproval` gate and its fingerprint run in the `Tools.Action` wrapper *before* the tool body
(`action.ex:55`), on the model-supplied `command` param, so neither the workdir flag nor a hypothetical
prefix (both applied *inside* the body at the Forge boundary) ever reach them. Confirm `sbx`'s mount +
`--workdir` behavior with the manual `:docker_sandbox` test (§2.5).

### D2 — Network isolation & the approval gate

The roadmap's "likely no gate **if** the Docker sandbox is network-isolated by default" rests on a
premise that is **false in the current code**:

- `build_create_args/4` (`docker.ex:249-260`) passes **no `--network` flag** to `sbx create`; the
  moduledoc states each microVM gets "a dedicated Docker daemon, filesystem, **and network**."
- The OneCLI outbound proxy is **opt-in and off by default** (`onecli_env/1` returns `%{}` unless
  `:onecli` config has `enabled: true`, `docker.ex:468-502`) — so absence-of-proxy ≠ absence-of-egress.

And "gate-free" is **not free** either: the shared `Tools.Action` wrapper runs `ToolApproval.gate/4`
*before* the tool body (`action.ex:55`), and `run_command` carries a non-disableable approval floor —
`{:effect, :opaque}` (any unresolved parse), `:structure` (`$()`/backticks/pipe-to-shell), plus
`git_commit`/`git_config_*`/`crontab` (`tool_approval.ex:154-173`). Ordinary build/test commands
(`a | b`, `$(...)`, an opaque one-liner) would hit that floor and surface an approval prompt mid-sketch.
So a sandboxed tier is gate-free only if something *removes* that floor for it.

**Decision: the exec tier must (a) *enforce* isolation — network egress **and** global host config — and
(b) bypass the `run_command` floor once that isolation is proven.**

- **(a) Enforce isolation — *two* axes, both enforced at `sbx create`.**
  - **Network egress.** The `sketch_build_exec` session spec disables egress (verify the `sbx` flag — e.g.
    `--network none`/equivalent — and thread it through `build_create_args` via the nested `sandbox_spec`,
    D3).
  - **Global host config (Finding — P1).** `build_create_args/4` *unconditionally* layers the OneCLI
    CA-cert mount + global `:extra_mounts` (`docker.ex:249-260,511-540`) and `inject_onecli_env` injects
    the OneCLI proxy (`docker.ex:67,79-94`) onto **every** Docker session — *before* the spec mounts. The
    content is off-by-default, but **a host-path mount survives `--network none`** (it's a local read, not
    egress) and would surface arbitrary mounted files through `RunCommand` output — so the no-egress bypass
    (b) cannot rest on egress alone. **Decision (force-isolate): the exec tier opts *out* of all three
    global layers at create.** Thread a `sandbox_spec` flag (e.g. `isolate_global_config: true`) that
    `create_sandbox`/`build_create_args` honor to **skip** `maybe_add_ca_cert_mount` + `add_extra_mounts`
    and **skip** `inject_onecli_env` — so an exec session carries *only* the prototype `extra_mount` + no
    egress, regardless of operator globals. (This amends D1's "no backend `create`/`destroy` change": one
    small, additive `create_sandbox`/`build_create_args` branch is now required; the tuple-only
    `add_spec_mounts/2` is untouched.) A no-egress throwaway never needs operator globals, so there is no
    functional downside. The flag is JSON-safe and **joins the D3 recovery atomization set** (a recovered
    exec spec must re-atomize `isolate_global_config`, else it silently reverts to global-config-applied on
    read-back).
- **(b) No-egress bypass — skip *only* the shell-pattern floor, never an explicit operator gate.** The
  bypass must sit **inside `native_requirement/4`** (`tool_approval.ex:250`), *after* the require-list
  check and *before* `pattern_match/3`: for `run_command` under `sandbox: :docker` it skips the
  `pattern_match` floor (the `:effect`/`:structure` matchers — opaque/structure/git/crontab) but
  **preserves** both the operator's explicit global `require: ["run_command"]` (the `:listed` branch)
  and the template's `require_approval` overlay (`template_requirement/2`). The current policy is
  strictly **additive** — the moduledoc's "can only gate *more* native tools … never weaken the global
  floor" — so a `requirement/3`-level bypass that returns `nil` outright (a naïve reading of §1.1) would
  wrongly undo a deliberate operator/template gate. Only the floor's *reasons* (a host-repo `git commit`,
  a host `crontab`, an opaque host command) are inapplicable in-container, so only the floor is skipped:
  the command runs *in the container*, not on the host. This keeps the throwaway flow ceremony-free,
  matching the AR-8b "no gate on the sketch path" posture. (This is a per-**tier** bypass, distinct from
  the per-**tool** overlay the Non-goals decline.) The invariant is upheld structurally: a worker only
  carries `sandbox: :docker` when the front door *successfully* created a **no-egress, globally-unmounted**
  session (egress disabled **and** global host config opted out, (a)) — otherwise it degraded to file-only
  (below), so `sandbox: :docker` ⇒ isolated (no egress, no host mount beyond the prototype).

**Fail closed → degrade to file-only + notice (D7):** if egress cannot be disabled for a
session, the exec tier does not start and the run **degrades to a file-only sketch** with a notice (never
exec with an open network, and never apply the bypass to a session whose no-egress invariant is unproven).
A per-call approval gate remains the documented escalation if a network-reachable sandboxed sketch is ever
wanted.

### D3 — Forge-session lifecycle (roadmap P3)

- **Creation: eager, at the front door, *and await-ready before seeding*.** `sketch_scope/2` already
  creates `.prototypes/<id>/` when the sketch path is chosen; extend it to *also* **start a Forge session**
  (via the race-safe combined entrypoint below) **when the exec tier is selected** (the `must-execute`
  discriminator, D4/§Phase 2). Then **wait for the sandbox to be ready before seeding the composer**: `Forge.start_session/2` returns the instant the
  `Harness` child starts (`manager.ex:213`), but `Harness` only accepts `exec` in `:ready`
  (`harness.ex:475`; any other state → `{:error, {:invalid_state, _}}`, `:490`), and `:ready` is set in
  the *async* `:init_runner` step (`harness.ex:316/331`). A first `RunCommand` racing a slow `sbx create`
  would otherwise hit `:invalid_state`. **The public Forge entrypoint must own the
  subscribe→start→await ordering as one operation** — the subscribe-before-start race **cannot** be
  papered over by a `Forge.await_ready/2` called *after* `start_session` (by then the `{:ready, …}`
  broadcast may already be gone). Model it on the proven pattern in
  `Memory.Consolidator.RunServer.drive_harness/4` (`run_server.ex:442-501`), where the **caller subscribes
  to `Forge.PubSub` *before* `start_session`** (so the `{:ready, session_id}` broadcast `harness.ex:323/338`
  can't be missed if bootstrap completes in the same quantum) and the helper (`await_ready/3` there) takes
  the **started pid** and **monitors** it so a `{:DOWN, …, {:runner_init_failed, _}}`/provision crash
  returns *immediately* (not on timeout), with a bounded timeout as the backstop. Expose this as a
  **combined `Forge.start_session_ready/3`** (subscribe → `start_session` → await-ready, returning only
  once `:ready` or on a bounded failure) so the front door makes **one** call and cannot get the ordering
  wrong; a bare post-start `await_ready/2` (session + timeout, no pid) is **not** sufficient.
  **Subscription cleanup is part of the entrypoint's contract (Finding — P2).** `run_server`'s pattern
  leaks no subscription only because `drive_harness/4` runs inside a `Task.Supervisor.async_nolink`
  (`run_server.ex:422`) — a **short-lived** process whose death auto-evicts its `Forge.PubSub`
  subscription. The front door is **not** short-lived (it handles the turn and lives on), so
  `start_session_ready/3` must clean up explicitly or it retains the `forge:session:<id>` subscription and
  accumulates every later `{:stopped, …}`/`{:error, …}`/`{:needs_input, …}` broadcast (`harness.ex:605-712`)
  in the caller's mailbox. `Forge.PubSub` exposes only `subscribe/1` today (`pubsub.ex:19`) — **add a
  `Forge.PubSub.unsubscribe/1`** wrapper (`Phoenix.PubSub.unsubscribe/2`).

  **Orphan-safety invariant (Finding — orphan race): the started session must never outlive a
  failed/abandoned `start_session_ready/3` call.** The front door is long-lived, so a clumsy timeout can strand a microVM.
  Two model choices, both orphan-safe *only if* they obey the same three rules below:
  - **(preferred) run_server-faithful task.** Run subscribe→start→await **inside a short-lived
    `Task.Supervisor.async_nolink` task** (`async_nolink`, *not* a bare `async`/`spawn`, so a helper crash
    can't take down the front door; mirrors `run_server.ex:422`), and have **the task itself own both the
    bounded await-ready *and* the failure-path teardown** — exactly as `drive_harness/4` does: `await_ready/3`
    carries the timeout *internally* (`run_server.ex:485-503`) and an `after` block stops the session on
    every non-success exit (`run_server.ex:463-471`). **The one F2 difference:** on **success** the task
    returns `{:ok, session_id}` and **leaves the session alive** (the front door uses it), so it self-stops
    only on its **failure** paths (start-failed, await-timeout, harness-down) — *never* on success. The
    subscription + any stray in-window broadcast die with the task; the *started* session outlives it
    (`start_session` registers under the Manager's supervisor, not the caller).
  - **(simpler) caller-side await.** Subscribe in the front door, `start_session`, await via a plain
    `receive`-with-timeout in the caller, `unsubscribe/1` in an `after`. This is **naturally orphan-safe**
    because there is *no task to `Task.shutdown`* — a `receive` timeout kills nothing; the caller simply
    stops waiting and runs cleanup. Cost: the front door blocks during await (fine — it's deciding the route
    synchronously) and a non-`:ready` in-window broadcast stays queued in its mailbox (drain/ignore).

  **The race to avoid: never let the parent's `Task.yield`/`Task.shutdown` be the *primary* timeout.** If the
  parent imposed the deadline by `Task.shutdown`-ing a task still mid-`Manager.start_session`, it could kill
  the task *after* the supervised `Harness` child began registering but *before* the task recorded/returned
  the handle — an orphaned microVM. The three rules that close it (both models): **(1)** the front door
  **mints the `session_id` itself and passes it in** (it's `forge_session_key`, D3) — so it *always* holds a
  handle to clean up, even on a mid-flight death; **(2)** any parent-side `Task.yield`/`Task.shutdown` is a
  **backstop** sized *longer* than the task's internal await timeout, so the task normally finishes (success
  or self-cleaned failure) before the parent would ever kill it; **(3)** on *any* abandon/degrade path the
  front door issues an **unconditional `Forge.stop_session(session_id)`** — `Manager` serializes
  `start_session`/`stop_session` through one GenServer (`manager.ex:117-133,206-235`), so a stop enqueued
  after the shutdown is processed *after* the in-flight start finishes registering, and therefore **finds and
  terminates the child** (closing the "registers just after the cleanup attempt" window). A bounded
  post-stop `get_handle` poll is optional belt-and-suspenders. Any failure (egress-disable, `start_session`,
  await-ready timeout, or harness-down) → **degrade to a file-only sketch + notice** (D2 / D7), never a
  fall-through.
- **Forge spec shape (where the knobs live).** The backend is selected by the **top-level** `spec.sandbox`
  atom (`resolve_client(:docker_sandbox) → Docker`, `harness.ex:142,1275`), but `Docker.create/1` reads
  the **nested** `spec.sandbox_spec` map (`harness.ex:214-221`). So the start spec is
  `%{sandbox: :docker_sandbox, sandbox_spec: %{extra_mounts: [<json-safe mount>], <no-egress flag>,
  isolate_global_config: true}, runner: :shell, tenant_id: ctx[:tenant_id],
  workspace_uuid: ctx[:workspace_uuid]}` (the `isolate_global_config` flag is D2-a / Finding P1). **Three persistence
  traps the spec must respect** (the whole `spec` is persisted as an Ash `:map`/jsonb column via
  `redact_map(spec)`, `session.ex:209`, `persistence.ex:153`):
  - **Mounts must be JSON-safe — *and* normalized back to a tuple at the harness boundary.**
    `[{proto_dir, "/proto", "rw"}]` is a **tuple** — it cannot be JSON-encoded, so persisting it (or
    recovery-reading it) raises. Use a JSON-safe shape in the *persisted* spec, e.g.
    `%{"host" => proto_dir, "container" => "/proto", "mode" => "rw"}`. But the backend's
    `Docker.add_spec_mounts/2` (`docker.ex:542-549`) **destructures `{h, c, m}` tuples**, and at create
    time `build_sandbox_spec`/`merge_resource_mounts` (`harness.ex:1278-1292`) does
    `existing ++ resource_mounts` — concatenating the spec's `extra_mounts` with the **tuples**
    `ResourceProvisioner.file_mount_specs/1` returns (`resource_provisioner.ex:237-244`) into one list
    that flows to `add_spec_mounts/2`. So a map entry there crashes the tuple destructure (even with *no*
    resource mounts, since the `[]` clause of `merge_resource_mounts/2` passes the spec through
    unchanged). **Decision: normalize maps→tuples at the harness boundary** (in `build_sandbox_spec`,
    unconditionally, so the concatenated list is uniformly tuples) — leaving the persisted spec JSON-safe
    and `add_spec_mounts/2` tuple-only and untouched. (Teaching `add_spec_mounts/2` to accept maps
    *additively* is the fallback, but it must **keep** tuple support — a maps-only rewrite breaks
    `file_mount_specs` resource mounts.)
  - **`workspace_id` must be a UUID.** The Forge `Session.workspace_id` attribute is `:uuid`, non-nullable
    (`session.ex:167`), and `scope_from_spec/1` reads `spec.workspace_id || spec.workspace_uuid ||
    tool_context.workspace_uuid` (`persistence.ex:521-524`). The sketch's **synthetic** workspace id
    (`"<ws>:proto:<id>"`, `front_door.ex:296`) is **not** a UUID and would fail the cast — pass the real
    `ctx[:workspace_uuid]` to Forge and keep the synthetic id only in the composer/worker shell scope
    (`composer_context`). If no `workspace_uuid` is available, the exec tier can't persist a session →
    degrade to file-only (D7).
  - **Recovered specs round-trip to *string* keys/values — normalize on read-back, *and* fail closed
    (chosen: harden `wake/2` centrally).** Persisting + reading the spec back through jsonb turns atom
    keys *and atom values* into strings: a stored `%{sandbox: :docker_sandbox, sandbox_spec: %{…},
    runner: :shell}` reads back as `%{"sandbox" => "docker_sandbox", "sandbox_spec" => %{…},
    "runner" => "shell"}`. But the Harness reads **atom** keys —
    `resolve_client(Map.get(spec, :sandbox, :default))` (`harness.ex:142`) and
    `Map.get(spec, :sandbox_spec, %{})` / `:runner` (`harness.ex:214-217`). On a miss it falls to
    `resolve_client(:default)` = the global-default backend (`harness.ex:1271`, often HostShell) with an
    **empty** `sandbox_spec` — i.e. **no Docker isolation, no prototype mount, and no `--network none`**:
    a silent **fail-*open*** on the exact boundary this tier exists to enforce. `Forge.wake/2`
    (`forge.ex:35-45`) passes `db_session.spec` straight through (it only `Map.put`s 3 atom keys onto the
    JSON-shaped map), so any read-back path mis-provisions. **Mitigating fact (calibrates severity, does
    not remove it):** an exec-only F2 session never checkpoints — `save_topology_checkpoint` fires only on
    `run_iteration`/attach/detach (`harness.ex:588/661/773`), never on `{:exec, …}` (`harness.ex:475`) —
    so `wake/2` returns `{:error, :no_checkpoint}` and the Manager's auto-recovery (`recoverable?` requires
    a checkpoint, `manager.ex:237-243`) never fires *today*. It is a **latent** fail-open, not an active
    one. **Decision (harden centrally so it can't bite even if exec sessions later checkpoint):**
    (1) `Forge.wake/2` (or a helper it calls) normalizes a recovered spec's known fields back to atoms —
    the `sandbox`/`sandbox_spec`/`runner` **keys**, the `sandbox`/`runner` **values**, and the nested
    `sandbox_spec` keys (`extra_mounts`, the no-egress flag, **and `isolate_global_config`** — D2-a, else a
    recovered exec session silently re-applies operator globals) — before `Manager.start_session`;
    (2) a recovered `:docker_sandbox` spec that can't be normalized to a real Docker + no-egress session
    **fails closed** (never silently `:default`/HostShell); (3) F2's own post-launch recovery path (D3
    restart wrinkle / §1.4) **fails closed** — it does *not* re-provision (P1: a fresh `start_session`
    against the stale `:ready` row hits `:already_claimed`), so it never reads the spec back. The
    wake-normalization in (1)-(2) is the defensive guard for the **latent** Manager-auto-recovery path, not
    something F2's own recovery exercises.

  Scope identity travels separately as `forge_session_key` in `tool_context` (D5). (The template-policy
  atom `:docker` and the Forge-backend atom `:docker_sandbox` are deliberately distinct.)
- **`forge_session_key` == the Forge `session_id`.** One string. The front door generates it (e.g. from
  the prototype id), starts the session under it, stamps it into the scope; `RunCommand` reads
  `tool_context[:forge_session_key]` and calls `Forge.exec(key, …)`.
- **Teardown — composer-owned *after* `ensure_started`, front-door-owned *before* it.**
  On the **success** path, a **completion-aware close** — a **new** `Forge.complete_session/2` (P2) — runs
  **after the composer's durable terminal append succeeds**. **Build it on the existing `Session.:complete`
  Ash action (Finding — P3)** (`session.ex:104` — it sets `phase: :completed` **and stamps `completed_at`**;
  the generic `:update_phase` would not) rather than hand-updating phase: add a `Persistence.complete_session/1`
  mirroring `update_session_phase/2` (`persistence.ex:270`) plus a `Manager`/`Forge` wrapper that terminates
  the supervised child like `stop_session` but writes `:completed` (the `Session.:complete` action is
  presently **unwired** — only `ExecutionSession.:complete` is used, `persistence.ex:217`).
  **Guarantee `:completed` even if the stamp write fails — close with `reason: :normal` (Finding —
  close-phase).** `stop_session` prewrites `:cancelled` not just for recovery bookkeeping but to *preempt*
  `Harness.terminate/2`'s finalizer, which stamps a fallback terminal phase on any row not already
  `:cancelled/:completed/:failed`: `:completed` for `reason == :normal`, else **`:failed`**
  (`maybe_finalize_phase`, `harness.ex:730-743`). `DynamicSupervisor.terminate_child` delivers `:shutdown` —
  so a Manager-driven close that prewrites `:completed` and then has that write *fail* falls through to
  **`:failed`**, re-introducing the exact converged-misread `:completed` exists to avoid. **Decision: route
  the close as a Harness self-stop with `reason: :normal`** — a `handle_call({:complete, …})` that
  *best-effort* writes `Session.:complete` (for `completed_at`), swallows any write error, then returns
  `{:stop, :normal, :ok, state}`. The finalizer's `:normal ⇒ :completed` branch is then the **fallback**, so
  the row lands `:completed` *both* on a clean stamp (`:completed` + `completed_at`) *and* on a failed one
  (`:completed`, no `completed_at`) — **never `:failed`**. The microVM is destroyed either way (`terminate/2`
  runs the sandbox `destroy`s) and the Manager's `:DOWN` monitor decrements without spurious recovery
  (`:completed ∉ recoverable`, `manager.ex:237-243`). (Simpler alternative: keep the Manager-driven
  `terminate_child` and **accept** a failed stamp degrading the row to `:failed` — then document + test
  *that*, not `:completed`.) **Sequencing
  (Finding — P3): the close runs strictly *after* `append_parent_terminal/5` returns `:ok`**
  (`route_composer.ex:2265`) **with its result discarded** — it must **not** flow into `notify_payload/2`
  (`route_composer.ex:2214-2215`), or a cleanup `{:error, _}` becomes `{:terminalize_failed, reason}` and
  misreports a *converged* run as failed + leaves the parent `:running` for recovery
  (`log_supervised_terminal_failure`). So "hooked inside `parent_terminal_notify`" means *sequenced after
  the append, return value swallowed* — **best-effort + telemetry, never raising.** Plain
  `Forge.stop_session/2` marks the session
  **`:cancelled`** (`Manager.stop_session` writes `:cancelled` before terminating, `manager.ex:123`, and
  `Harness.terminate` won't overwrite it, `harness.ex:730-733`), which would misread a *converged* sketch
  as cancelled in ForgeView/history; the completion-aware close marks **`:completed`**. (The **failure**
  teardowns — front-door Window 1/1b and the P3 timeout taint — correctly stay `stop_session`/`:cancelled`,
  since those sessions *were* aborted.) Crucially, a *failed* terminal append leaves the run
  recoverable (the parent is left `:running`, `route_composer.ex:2154`), so teardown must **not** fire on
  that path — tearing down the microVM would strand a run that's about to be retried. **But that hook only
  covers the session's life *once the composer is running*.** The front door creates the session in
  `sketch_scope/2` **before** `create_parent_run/1` + `ensure_started/2` (`front_door.ex:195-223`) — so if
  *either* composer-launch step fails, the `else`/`maybe_terminalize_orphan` path
  (`route_composer.ex:575`) terminalizes the durable parent but **never runs the composer's
  `parent_terminal_notify`**, and the live Forge session would leak (orphaned microVM + `/tmp`
  workspace). **Ownership rule (D7 Window 1):** the **front door owns Forge cleanup from session-creation
  until `ensure_started/2` returns `{:ok, _}`**; only after that does the composer's terminal hook take
  over. With D1 (variant ii) the Forge session owns **only** the throwaway `/tmp/jidoclaw_forge/<name>`
  `workspace_dir`, so `Docker.destroy/2`'s `rm --force` + `rm_rf` (`docker.ex:240`) wipes *that* — **not**
  the front-door-owned `.prototypes/<id>/` mount, which survives for C1/C3.
- **Restart wrinkle (call it out — see Risks):** composer runs are durable and survive a node reboot;
  Forge microVMs are **not** (`Harness` is `restart: :temporary`, and a microVM dies with the node). A
  recovered composer-exec run will find a dead `forge_session_key`. `validate_sandbox_scope(:docker)`
  (D6/§1.4) must assert the session is not just live but **`:ready`** (a live `Forge.get_handle/1` pid can
  still be mid-provision) and, on a miss, **fail closed** — never exec against a dead or not-yet-ready
  handle. **Re-provision is deliberately *not* offered (P1):** a fresh `start_session` against the stale
  `:ready` DB row hits `:already_claimed` (the recovery-claim that could reclaim a `@recoverable_phases`
  row, `persistence.ex:104-135`, is only passed with a `resume_checkpoint_id` — `harness.ex:1357-1363` —
  which exec-only sessions lack), and adding a recovery-claim API was declined for this throwaway tier. So
  the recovered run fails the stage and the user re-sends. The stale `:ready` row is a harmless zombie (its
  `session_id` is per-prototype and never reused).

### D4 — Mutual exclusion of the two builders (**resolved: distinct triggers**)

The router has **no "pick one of N"** — `compose_route/4` runs *every* stage that (triggers ∧ on-path ∧
satisfiable) as a parallel wave (`router.ex:69-78`). So `sketch-build` and `sketch-build-exec`, both on
`routes: ["sketch"]`, **must** be made mutually exclusive on `live`, or both run (and the existing
`[sketch-build, sketch-review]` wave assertions in `router_test.exs:398` / `composer_loop_test.exs`
break). The triage `must-execute` signal (§2.3) is the discriminator.

**Decision: B — distinct triggers.** `sketch-build` ← `subscribes: ["sketch-plain"]`; `sketch-build-exec`
← `subscribes: ["must-execute"]`; the front door seeds **exactly one** discriminator, chosen by the
explicit launch decision (D7) — `must-execute` only when the verdict carries `:must_execute` **and** the
Forge session came up; `sketch-plain` otherwise (a non-exec sketch *or* a degraded exec one). The seed
must consume that decision rather than deriving it from the raw verdict, since the verdict still says
`:must_execute` even on the degraded path (`seed_live`, `front_door.ex:207/314`). **Critically, the
discriminator is seeded *directly* by the launch decision and is deliberately kept OUT of `@signal_topics`**
— otherwise `mapped_signals/1` (which seeds any topic in `@signal_topics ∩ triage.publishes`) would
auto-inject `"must-execute"` from the verdict on **both** the exec and degraded paths, double-seeding the
degraded sketch with `"sketch-plain"` + `"must-execute"` (§2.3). So `mapped_signals` carries neither
discriminator; `seed_live` adds exactly the one the launch decision chose. Mutually exclusive **by
construction**;
symmetric; no lock, no sentinel. The cost is small and contained: `sketch-build`'s shipped trigger moves
off `request-received`, so a bare `["request-received","sketch"]` live with no discriminator now composes
to **empty** — a non-issue (the front door is the sole seeder + greenfield), and existing sketch test
seeds gain the explicit `"sketch-plain"`.

**Why not A (lock on `sketch-build`) — it deadlocks.** The tempting "idiom-consistent" option
(`sketch-build` keeps `request-received` and gains `lock: [%{while: "must-execute", until: <never>}]`,
mirroring `implementer`'s lock, `catalog.ex:113-116`) is **not viable**. A lock is active iff `while ∈
live ∧ until ∉ live` (`router.ex:194-197`), and every locked stage is placed in `display.held`
(`router.ex:236-237`). The only never-co-occurring topic to use for `until` is a cross-lane signal like
`"code"`, which never goes live on a sketch run — so the lock stays active **for the entire run** and
`sketch-build` stays in `held` forever. At convergence `Loop.terminal/2` checks `map_size(display.held)
> 0 → :deadlock` *before* the cleanliness check (`loop.ex:84`): the run terminalizes as **`:deadlock`,
not `:converged`.** Worse, it passes the *compile-time* lock validator (`catalog_validator.ex:273` only
requires `code` to have a publisher/seed), so the breakage is runtime-only and easy to miss. A
"hold-forever" lock is simply the wrong primitive — locks *defer-until-ready*, they don't
*exclude-entirely*.

Under B, `sketch-review` is **unchanged** (`subscribes: ["request-received"]`, requires the `prototype`
artifact, which *either* builder produces — `prototype` stays in the output union, so invariants 3/4 hold
and it orders into wave 2 after whichever builder ran).

(Add `"must-execute"` **and** `"sketch-plain"` to `triage`'s `publishes`, `catalog.ex:42-63`, so the
subscriptions validate; publishes need no consumer.)

### D5 — Threading the session key to the jailed worker

`sketch_build`/`sketch_reviewer` use `forward_context: :none`, which strips **all** policy-controlled
keys — including `:forge_session_key` (`apply_visibility/2` `:none`, `tool_context.ex:206`). The exec
worker *needs* the key. **Decision:** give `sketch_build_exec` `forward_context: {:only,
[:forge_session_key]}` — same strict isolation as `:none` except it lets the session key through
(`tool_context.ex:208-212`). This avoids making `:forge_session_key` canonical (which would forward it
everywhere, broad blast radius). The threading chain is otherwise net-new (no producer sets the key
today): `sketch_scope/2` → `composer_context/3` (`front_door.ex:271-285`) → `@persisted_context_keys`
(`route_composer.ex:211-214`, for restart survival) → `resolve_scope/2` (`agent_runner.ex:336-354`,
must read it) → `apply_visibility` → `build/1` → worker `tool_context`.

### D6 — `:docker` is composer-private (widen 5 refusal sites)

Like `:prototype`, the exec tier is front-door-only: it must not be spawnable, handoff-able, or own a
session. Widen each `%{sandbox: :prototype}` match to `%{sandbox: s} when s in [:prototype, :docker]`:
`spawn_agent.ex:61`, `send_to_agent.ex:175`, `handoff.ex:233`, `agent/handoff/router.ex:275` & `:358`.

### D7 — Failure semantics: **window-dependent (file-only degrade / error-ack / fail-closed)**

There are **three** failure windows, and they resolve **differently** — the distinction matters because
once the composer is seeded with `must-execute`, you can no longer "reseed" it to the plain branch:
**Window 1** (exec-setup fails before seeding → degrade to file-only + notice), **Window 1b** (the session
came up but the composer launch then fails → bounded error ack + front-door teardown), and **Window 2**
(post-seeding recovery onto a dead microVM → fail closed).

**Window 1 — pre-launch (at the front door, before seeding):** egress can't be disabled, `start_session`
fails, `await_ready` times out / harness goes down, or no `workspace_uuid` is available (D3). Here the
composer hasn't been seeded yet, so **degrade to a file-only sketch + notice**:

1. **Tear down** any partially-created Forge session (`Forge.stop_session/2`), so no orphaned microVM or
   `/tmp` workspace leaks.
2. **Degrade via an explicit launch decision, don't abort.** This must be a *first-class* value, not an
   implicit consequence — `seed_live(path, verdict)` (`front_door.ex:207`) derives the discriminator from
   the verdict, and the verdict still carries `:must_execute`, so a failed `sketch_scope` that simply
   "continues" would **still seed the exec branch**. Model the launch outcome explicitly, e.g.
   `sketch_scope/2` returns `{:exec, {dir, ws}, premises}` vs `{:plain_degraded, {dir, ws}, notice}`, and
   the seed (and premises/ack) consume *that* — seeding `"sketch-plain"` (D4-B) only on the degraded
   outcome. The result is a different, fully-isolated route (**not** a fall-through to the host
   `SessionManager`).
3. **Notice.** Tell the user execution was unavailable (so a silent file-only sketch isn't mistaken for a
   run).

**Window 1b — `sketch_scope` succeeded, but the composer launch then failed.** If `sketch_scope/2`
returned `{:exec, …}` (the Forge session is **live**) and `create_parent_run/1` *or* `ensure_started/2`
then fails, this is **not** a degrade — the whole composer run failed to start, so it takes the existing
**bounded `{:error, ack}`** (P1 no-fall-through, the same path a `code`/`system` launch failure takes).
The **only** F2 addition is the ownership obligation from D3: the front door must `Forge.stop_session/2`
the live session on this path too, because the composer's `parent_terminal_notify` teardown never runs
(the composer never started). Concretely, `start_composer/5` must **hold the `forge_session_key` from the
`{:exec, …}` outcome** so its failure branch can tear it down — the current single `else {:error, reason}`
(`front_door.ex:234`) has no access to it, so the `with` must be restructured (e.g. bind the launch
outcome first, then guard the composer-launch steps with a teardown-on-failure). Net rule: **the front
door owns Forge cleanup until `ensure_started/2` returns `{:ok, _}`; after that, the composer owns it.**

**Window 2 — post-launch / recovery (at worker setup, §1.4):** a durable exec run is recovered onto a
dead/not-ready microVM (D3 restart wrinkle), checked in `validate_sandbox_scope(:docker)`. The composer
**already** seeded `must-execute` and dispatched `sketch-build-exec`, so a file-only degrade is **not**
available (it would mean mutating/reseeding live route signals mid-run). **Decision: fail closed** — the
worker-setup error fails the stage and the composer terminalizes (`:not_converged`/failed); the user
re-sends the throwaway. Re-provision is **not** offered: a fresh `start_session` against the stale
`:ready` row hits `:already_claimed` (P1 — recovery-claim is checkpoint-coupled, `persistence.ex:104-135`,
and exec sessions have no checkpoint), and adding a recovery-claim API was declined for this tier. Do
**not** route this through the Window-1 degrade.

Two pre-launch failures are **non-degradable** (no file-only fallback): (a) the **prototype-dir** itself
(`create_prototype_dir` fails, `front_door.ex:294`) — there's no sketch at all without the dir, so that
stays the bounded `{:error, {:sketch_sandbox_unavailable, _}}` ack; and (b) a **composer-launch** failure
*after* a successful `{:exec, …}` (Window 1b) — the whole run failed to start, so it takes the generic P1
bounded ack (plus the front-door Forge teardown). Everything else in Window 1 (the exec-setup failures:
egress / `start_session` / await-ready / harness-down / missing `workspace_uuid`) degrades to a file-only
sketch. ("Never a fall-through" in D3 means *never silently run exec unsafely / never reach the host
shell* — it does **not** forbid the Window-1 isolated file-only degrade.)

---

## Phase 1 — Plumbing (`:docker` policy tier + `RunCommand`↔Forge bridge)

**Deliverable:** `:docker` is a first-class sandbox policy everywhere, and `RunCommand` routes into a
Forge Docker session when `tool_context[:sandbox] == :docker`. Fully unit-tested with `StubSandbox`.
**No worker uses it yet** — Phase 1 is exercised purely by policy + bridge unit tests, and is
precommit-green standalone.

### 1.1 — Admit `:docker` as a policy (the "fails-closed-to-`:prototype`" trap)

`validate_sandbox/2` (`templates.ex:263`) admits only `:none | :prototype`; an unknown *present* value
fails **closed to `:prototype`**. So a `:docker` template would silently route through the **file jail**
unless the guard is widened. Changes:

- `templates.ex:263` — `when s in [:none, :prototype]` → `… [:none, :prototype, :docker]`.
- `templates.ex:188` — `external_tools?/1`: `sandbox(name) != :prototype` → `… not in [:prototype, :docker]`
  (else `:docker` workers wrongly keep external MCP tools, via `Consumer.modules_for_template/3`,
  `consumer.ex:641`).
- `templates.ex:173` `@spec sandbox/1` + its docstring (`:166-172`) — add `:docker`.
- `tool_context.ex:38-45` — extend the `:sandbox` doc enum to `:none | :prototype | :docker` (doc only;
  `:sandbox` is canonical so propagation is automatic, no code change).
- `tool_approval.ex` `native_requirement/4` (reached via `gate/4 → requirement/3`, `:185/207/250`) — add a
  `sandbox: :docker` bypass that, for `run_command`, **skips `pattern_match/3`** (the non-disableable
  opaque/structure/git/crontab floor, `:154-173`) while **still honoring** the require-list (`:listed`)
  and the template overlay (`template_requirement/2`). Place it **after** the `tool in require_list(opts)`
  check and **before** `pattern_match/3`, reading `context[:tool_context][:sandbox]`. This preserves the
  additive policy (an operator's explicit `require: ["run_command"]` or a template `require_approval`
  still gates) while dropping the in-container-irrelevant shell floor (D2-b). Safe because a worker
  carries `sandbox: :docker` only when the front door created a proven-no-egress, **globally-unmounted**
  session (egress disabled **and** global host config opted out, D2-a; else it degraded to file-only,
  D2/§2.4). Inert in Phase 1 (no `:docker` worker exists yet); active in Phase 2.

The explicit shape — the bypass branch still consults `template_requirement/2`, so the template overlay is
never accidentally skipped while "bypassing before `pattern_match/3`":

```elixir
cond do
  tool in require_list(opts) -> :listed
  docker_run_command?(tool, context) -> template_requirement(tool, context)
  true -> pattern_match(tool, params, opts) || template_requirement(tool, context)
end
```

### 1.2 — The bridge (the hard part)

A `:docker` branch inside `RunCommand.run/2`'s body (i.e. inside `super`, **after** `ToolApproval.gate`
and **before** `Error.normalize → OutputRedaction → OutputShaper → OutputLimit`, `action.ex:42-44`), so
adapted Docker output flows through the **same** redact/shape/cap tail as host/vfs/ssh:

```
sandbox = get_in(enriched, [:tool_context, :sandbox])
forge_key = get_in(enriched, [:tool_context, :forge_session_key])
# when sandbox == :docker → docker_dispatch(command, forge_key, timeout)  (NOT SessionManager)
```

**Branch placement: short-circuit *before* the `backend`/`server` read + validation.** `run/2` today
reads `backend`/`server` from params and runs `validate_backend_server/2` before dispatching
(`run_command.ex:99-122`); `validate_backend_server(:ssh, nil)` is an error. The `:docker` branch must sit
at the **top** of the body so a model-supplied `backend: "ssh"` (or any `backend`/`server`) can neither
preempt the Forge route nor raise a spurious SSH error — the sandbox is set by **template policy**, not by
params. In `:docker` mode, **ignore `backend`/`server` entirely** (route to `ForgeBridge` regardless).

**Streaming must be neutralized for `:docker` — at the *predicate*, not inside `RunCommand` (Finding — stream-skip).**
`RunCommand` derives both `stream_to_display?` and `capture?` from the **model-supplied** `stream_to_display`
param *before* dispatch (`run_command.ex:64,102,109`): `capture? = OutputShaper.shapeable?(…)` is **false**
whenever `effective_streaming?(params)` holds (`output_shaper.ex:171-176`). But `Forge.exec` returns the
whole `{output, exit_code}` tuple at once — the Docker route **never streams**. So a model that sets
`stream_to_display: true` on a `:docker` exec would get **neither** real streaming (the bridge can't)
**nor** ref-backed shaping (capture skipped) — its output would hit `OutputLimit`'s 32 KB head/tail cut
**with no `fetch_output` ref**, silently dropping the middle of large test/build output.

**The fix must live in the predicate — the *final* shaper re-checks with the original params (Finding —
stream-skip).** A "force `stream_to_display` false inside `RunCommand.run`" is **insufficient and dangerous
(looks fixed, isn't):** the shared `Tools.Action` wrapper calls `OutputShaper.shape_result(result, …,
params, enriched_context)` with the **original** model params *after* `super` returns (`action.ex:62`), and
`shape_result` re-gates on `shapeable?(tool, params, context)` (`output_shaper.ex:216-218`). A
`RunCommand`-local params copy never reaches that call, so the final shaper would *still* see
`stream_to_display: true` and skip — having captured large output only to ref-lessly head-cut it (worse:
paid for capture, lost it anyway). **Decision: make the streaming predicate context-aware.** Teach
`effective_streaming?` (e.g. a `effective_streaming?(params, context)` arity) — and thus `shapeable?/3` —
to treat `tool_context[:sandbox] == :docker` as **not effectively streaming**, reading the `context` both
sites already receive (the wrapper passes `enriched_context` to `shape_result`; `RunCommand` has `enriched`).
Route `RunCommand`'s `stream_to_display?`/`capture?` through that **same** context-aware predicate. Then the
pre-exec capture decision and the post-exec wrapper shaping **agree by construction**: docker ⇒ never
actually streams, always captures + shapes + ref-stores. (This is the other half of why `FetchOutput` must
ride with `RunCommand` in the exec worker — §2.1: the ref has to be retrievable.) Pin with a test that
asserts the **wrapper-shaped** result is ref-backed (§1.5).

Factor the bridge into a small, separately-testable helper (e.g. `JidoClaw.Tools.RunCommand.ForgeBridge`,
or a private fn) owning these responsibilities:

1. **Call Forge:** `Forge.exec(forge_key, command, timeout: timeout)` → `{:ok, {output, exit_code}}` |
   `{:error, term}` (`forge.ex:68`, `harness.ex` wraps the backend's `{output, exit}` tuple in `:ok`).
   **The outer-call timeout races the inner one (Finding — call-timeout race) — fix it at *both* ends.** `Harness.exec/3`
   reuses the **same** `timeout` for the outer `GenServer.call(pid, {:exec, …}, timeout)` (`harness.ex:63,91`)
   that the Docker backend then hands to the inner `OsCmd.run(…, timeout: timeout)` (`docker.ex:318`). The
   outer call's deadline runs from *send* time; the inner OsCmd's runs from a strictly *later* start (after
   the mailbox hop + `handle_call` setup + `exec.started` persist, `harness.ex:475-479`), so the **outer call
   always elapses first** — and `Harness.call/3` catches only `:exit, {:noproc, _}`, **not** `:exit,
   {:timeout, _}` (`harness.ex:92-96`). So on a real in-container timeout the caller **exits `{:timeout,
   {GenServer, :call, …}}` before the backend ever manufactures `124`** — the bridge's `124`-tuple detection
   (point 3) would **never run**, the session would **not** be tainted/torn down, the zombie would survive,
   and a *generic* (possibly **retryable**) crash/error would surface instead of `:sandbox_command_timeout`.
   **Fix (both, belt-and-suspenders):**
   - **(a) Cushion the outer call** so the manufactured `124`/`153` tuple can actually reach the bridge:
     give `Harness.exec/3`'s outer `GenServer.call` a deadline of `timeout + <cushion>` (e.g. +5 s) while the
     inner `OsCmd` keeps the caller-supplied `timeout`. Then a real timeout fires *inside* the backend at
     `timeout`, returns `{… , 124}`, and the cushioned outer call receives `{:ok, {_, 124}}` so point 3's
     designed taint path runs as written. This touches the shared `Harness.exec/3`, but the only callers
     today are the Forge test suite (no production path routes through it yet — `run_server` uses
     `run_iteration`, not `exec`), and the change is **inert except on the timeout path**: a non-timing-out
     exec completes long before either deadline, while a timing-out one now returns the manufactured `124`
     tuple instead of a premature caller exit — strictly an improvement. *Keep the cushion a Harness-level
     concern* (don't bake it into every caller's `:timeout`), so `Forge.exec(key, cmd, timeout: T)` still
     means "**T** is the in-container deadline."
   - **(b) Catch the residual in the bridge** for any case the cushion doesn't cover (mailbox-queued exec, a
     cushion overshoot): wrap the `Forge.exec` call in `try/… catch :exit, {:timeout, _} ->` and route it to
     the **same** taint outcome as a `124` — `Forge.stop_session` (best-effort) + the non-retryable
     `:sandbox_command_timeout` wire shape (point 3). Both delivery paths (the `124` tuple and the
     `GenServer.call` timeout exit) thus converge on one tear-down-and-fail-closed result.
2. **Shape adapter:** `{:ok, {out, code}} → {:ok, %{output: out, exit_code: code}}` — the map shape this
   tool's `output_schema` and the rest of the pipeline expect (parity with `SessionManager.run/4`).
3. **Manufactured exit-code normalization (sbx-missing 127, timeout 124, output-limit 153 — roadmap P2):**
   - session **creation** failed → `{:error, :sbx_not_found}` surfaces at the front door / scope
     validation (D3/D6), not here.
   - `exec` itself, if `sbx` vanished post-create, returns the **command-output** tuple
     `{"sbx: command not found", 127}` (`docker.ex:308`) — an ordinary success-shaped result. The bridge
     must detect this and surface a **tool error** rather than passing "command not found" back as if the
     user's command exited 127.
   - **Timeout `124` (`docker.ex:320`) / output-limit `153` (`docker.ex:322-324`) — taint + fail closed
     (P3).** A timeout reaches the bridge by **either** delivery path from point 1 — the manufactured `124`
     *tuple* (when the cushion lets the inner OsCmd win) **or** a caught `:exit, {:timeout, _}` from the outer
     `GenServer.call` (point 1b) — and **both** funnel into this same taint outcome; output-limit `153`
     always arrives as a tuple. On any of them, `OsCmd` kills only the *host-side* `sbx` client; the
     **in-container command keeps running until the sandbox is destroyed** (`docker.ex:311-317`), so in a
     long-lived exec-worker session a zombie command can consume CPU/memory and degrade *later* commands. So a `124`/`153` is not just a
     tool error: the bridge **taints the session and tears it down** (`Forge.stop_session`, best-effort) to
     kill the zombie promptly, and returns a **non-retryable tool error — and the error *code* is what makes
     it non-retryable (Finding — P2).** The ReAct runner retries any `Jido.AI.Error.retryable?(result)`
     (`runner.ex:909`), and `retryable?/1` keys off the error's `code`/`type` (`error.ex:244-245`):
     `:timeout` is in the retryable set (`retryable_type?/1`, `error.ex:467`), so echoing the manufactured
     `:timeout`/`124` — or even a `"timeout"` status string, which `Tools.Error.code_from_value/1` maps
     **back** to `:timeout` (`tools/error.ex:402`) — would be silently retried into the just-torn-down
     session. So the bridge must surface a **distinct code not in the retryable set** — e.g.
     `:sandbox_command_timeout` (124) / `:sandbox_output_limit` (153). **An explicit `retryable?: false`
     field does *not* help and must not be relied on:** the wrapper normalizes every tool error through
     `JidoClaw.Tools.Error.normalize_result/1` (`action.ex:60`, aliasing **`JidoClaw.Tools.Error`** — *not*
     the dep's `Jido.AI.Error`), whose wire format is `%{code, message, details}` (`tools/error.ex:119-121`)
     and **drops** any top-level `retryable?` (verified in-VM: `%{code: :timeout, retryable?: false}` →
     `%{code: :timeout}`, still retryable). So return the full `%{code: :sandbox_command_timeout,
     message: …, details: …}` wire shape (matching that clause, so the code passes through verbatim) — the
     **distinct code is the sole load-bearing part.** The same applies to the `sbx`-missing 127 tool error
     above (give it its own non-retryable code — retrying a vanished `sbx` is equally pointless). Because the
     session is now gone,
     any subsequent `RunCommand` hard-fails (point 4 — no host fallback), so the worker cannot keep issuing
     commands into a contaminated microVM and the `sketch-build-exec` stage **fails closed** (it can't
     complete its run-and-validate). The bridge thus becomes a **third teardown trigger** alongside the
     front door (Window 1b) and the composer terminal — all best-effort + idempotent, so a later composer
     close simply no-ops (here `stop_session`/`:cancelled` is correct — the session *was* aborted; P2/D3).
4. **Hard-fail, never host fallback:** when `sandbox == :docker` and the session is missing/unavailable,
   return `{:error, …}` — do **not** fall back to `SessionManager`. (`coerce_backend/1`,
   `run_command.ex:220`, has no `:docker` clause and the `backend` schema enum forbids `"docker"`
   `:54` — correct: the Docker route is driven by `tool_context[:sandbox]`, not a `backend` param, so
   leave the schema alone.)

### 1.3 — File-tool resolver + read-real tools under `:docker`

With D1 (shared tree, `project_dir == .prototypes/<id>/`), `:docker` file tools should behave
**exactly like `:prototype`**:

- `vfs/sandbox.ex` `resolver_opts/1` (`:116-143`) — treat `:docker` like `:prototype` (jail to
  `project_dir`, `local_only: true`); add `:docker` to the `:prototype` branch (`:124`). Without this,
  `:docker` falls into the `_ ->` default (host cwd, `local_only: false`) — the unsandboxed path.
- Read-real tools — `:docker` workers should get them too (same value as for `sketch_build`). Widen the
  `== :prototype` gate to `in [:prototype, :docker]` in `real_tree.ex:38` and the three tool fail-closed
  checks (`read_real_file.ex:10`, `search_real_code.ex:9`, `list_real_directory.ex:8`).
  `Sandbox.real_root/1` already keys off the `.prototypes/<uuid>/` shape, which `:docker` also has.

### 1.4 — `validate_sandbox_scope(:docker)` asserts a valid prototype root **and** a ready Forge session

`validate_sandbox_scope/2` (`agent_runner.ex:100-114`) currently has a `%{sandbox: :prototype}` clause
(→ `Sandbox.validate_root/1`) and a catch-all `:ok`. **A `:docker` template falls through to `:ok` with
no checks** — add a `%{sandbox: :docker}` clause **above** the catch-all. Because D1 jails `:docker` file
tools to `project_dir == .prototypes/<id>/` exactly like `:prototype` (§1.3), the `:docker` tier depends
on **both** guards (file jail *and* OS sandbox):

1. **File jail — valid prototype root.** `Sandbox.validate_root(context[:project_dir])`, same as
   `:prototype`. Without it, `resolve_scope/2`'s `File.cwd!()` fallback (`agent_runner.ex:345`) would let
   the host file tools operate on the *real* tree even though exec is containerized — the unsandboxed path.
2. **OS sandbox — *ready* Forge session.** `forge_key = context[:forge_session_key]` + `Forge.get_handle/1`,
   asserting the session is **`:ready`** (a live pid can still be mid-provision — D3), e.g. via
   `Forge.status/1`. On a missing/dead/not-ready handle (D3 restart wrinkle) → **fail closed** (the stage
   errors and the composer terminalizes) — this is post-launch (the composer already seeded
   `must-execute`), so it does **not** degrade to file-only (no mid-run reseed; D7 Window 2), and it does
   **not** re-provision (P1: a fresh `start_session` against the stale `:ready` row would hit
   `:already_claimed`).

`resolve_scope/2` (`:336-354`) must also start carrying `forge_session_key: context[:forge_session_key]`
(D5). `stamp_sandbox/2` (`:122`) already forwards the atom unchanged.

### 1.5 — Tests (Phase 1, all precommit-green via stubs)

- **Bridge — split the two concerns.** `:sbx_finder` is Docker-backend-only (`docker.ex:336`) and
  `StubSandbox.exec/3` always returns `{"", 0}`, ignoring it (`stub_sandbox.ex:68`) — so neither alone can
  drive the failure codes. Test them separately:
  - **Normalization helper, directly.** Unit-test `ForgeBridge`'s adapter against hand-fed backend tuples:
    `{"sbx: command not found", 127}` → **tool error** (not a user-command exit 127, **no** taint);
    `{"timeout …", 124}` / `{"output limit …", 153}` → **tool error *with a taint flag*** (P3); and an
    ordinary `{out, code}` → `{:ok, %{output: out, exit_code: code}}`. No sandbox needed — this is the
    load-bearing logic (model the manufactured codes on `docker.ex:308/320/322`). **Assert non-retryability
    via the public predicate (Finding P2):** after `JidoClaw.Tools.Error.normalize_result/1`,
    `Jido.AI.Error.retryable?/1` returns **false** on the 124/153/127 tool errors *because of their distinct
    codes* (trap-pins: a `:timeout` *or* `"timeout"`-status error would be `true`; and a `retryable?: false`
    field is **dropped** by the `%{code, message, details}` wire format, so the test must not rely on it).
  - **Wiring, via StubSandbox.** Drive `RunCommand.run(%{command: …}, %{tool_context: %{sandbox: :docker,
    forge_session_key: sid, project_dir: proto}})` against a Forge session backed by `StubSandbox` (spec
    `sandbox: StubSandbox`, per `harness_bootstrap_env_test.exs`): assert the `{:ok, %{output:,
    exit_code:}}` shape adapter end-to-end and **no** `SessionManager` fallback when the session is absent.
    To exercise exec *failures* through the stub, **add a programmable `exec` to `StubSandbox`** (a
    `program_exec/2` mirroring `program_run/2`, `stub_sandbox.ex:51` — today only `run/4` is programmable).
    A programmed `124`/`153` must drive the **taint path** — assert the bridge `stop_session`s the session
    and a *follow-up* `RunCommand` then hard-fails (P3 fail-closed, no host fallback).
  - **Outer-call timeout race (Finding — call-timeout race).** Two assertions for the §1.2 pt-1 fix: **(1) cushion** —
    `Harness.exec/3`'s outer `GenServer.call` deadline is the caller `timeout` *plus* the cushion (unit-test
    the arithmetic, or drive a programmable `StubSandbox.exec` that blocks past `timeout` but under
    `timeout + cushion` and assert the bridge still receives the manufactured `124` *tuple*, **not** a caller
    `:exit, {:timeout, _}`); **(2) bridge-catch** — a `Forge.exec` that *does* raise `:exit, {:timeout, _}`
    (stub `exec` blocking past `timeout + cushion`, or invoke the bridge directly against an exiting
    `Forge.exec`) is converted to the **same** taint + non-retryable `:sandbox_command_timeout` outcome as a
    `124` tuple — `stop_session` runs and a follow-up `RunCommand` hard-fails. Pins that **both** delivery
    paths converge and neither leaks a raw timeout exit nor a retryable code.
  - **Streaming neutralized for `:docker` (Finding — stream-skip).** Drive `RunCommand.run` with `params`
    carrying `stream_to_display: true` and `tool_context: %{sandbox: :docker, tenant_id: <real>, …}` against
    a `StubSandbox`-backed session returning **oversized** output: assert the result is **shaped +
    ref-stored** (a `fetch_output` ref present and retrievable), proving the context-aware predicate forced
    not-streaming and `capture?` held — not a ref-less head/tail cut. **Setup the shaper's *other* gates so
    the test isolates the streaming predicate:** explicitly `put_env(:jido_claw, :output_shaping, enabled?:
    true)` (it's `enabled?: false` in `test.exs`) and supply a non-empty `tenant_id` in `tool_context` —
    else `shapeable?/3` refuses for reasons (`enabled?()`/`tenant_present?`) unrelated to the docker
    predicate (`output_shaper.ex:172-175`), and the test would pass/fail for the wrong reason. **This test catches the wrong-layer
    trap (Finding — stream-skip):** `RunCommand.run` *is* the `Tools.Action` wrapper, so the assertion
    exercises the wrapper's **final** `OutputShaper.shape_result(…, params, …)` call with the *original*
    params (`action.ex:62`) — a predicate-layer fix passes, a `RunCommand`-local `stream_to_display` copy
    **fails** (the final shaper still skips). (Contrast pin: the same `stream_to_display: true` on a
    non-`:docker` host call still skips capture, so the neutralization is `:docker`-scoped, not global.)
- **Approval bypass (D2)** — `tool_approval_test.exs`: drive the **public** `ToolApproval.gate/4`
  (`requirement/3`/`native_requirement/4` are private, `:207/250`) — it returns `:ok` for a
  floor-tripping `run_command` when `tool_context[:sandbox] == :docker`, while the same command in the
  non-sandboxed case still gates (matching how existing approval tests exercise `gate/4`). **Pin the
  additive boundary too:** with `sandbox: :docker` *and* an explicit `require: ["run_command"]` (or a
  template `require_approval` listing it), the call **still gates** — the bypass skips only the shell
  floor, never an explicit operator/template gate (D2-b).
- **Policy** — `templates_sandbox_test.exs`: a `:docker` template resolves `sandbox/1 == :docker` and
  `external_tools?/1 == false`. Update the "malformed sandbox fails closed to `:prototype`" expectation
  (`:docker` is now valid, not coerced).
- **Resolver** — `sandbox_test.exs`: `resolver_opts/1` with `sandbox: :docker` jails like `:prototype`.
- **Refusals (D6)** — `:docker` is refused by spawn/send/handoff/router (extend the existing
  `:prototype` refusal tests).
- **Read-real under `:docker`** — extend the existing real-tool jail tests to cover `sandbox: :docker`.

---

## Phase 2 — Activation (worker + stage + triage signal + lifecycle)

**Deliverable:** a real `must-execute` sketch turn launches `sketch_build_exec` in a Docker microVM and
converges (with `sketch-review`). Depends on Phase 1. End-to-end with stubs; precommit-green standalone.

### 2.1 — `sketch_build_exec` worker + template + doctrine

- **New** `lib/jido_claw/agent/workers/sketch_build_exec.ex` — **do not clone `sketch_build.ex`,** but also
  **do not put a function call in `tools:`.** The two workers differ by exactly one tool
  (`JidoClaw.Tools.RunCommand`, which `sketch_build` omits deliberately, `sketch_build.ex:20-28`); a
  near-identical second module would drift *and* risks tripping the ExSlop clone check (min_mass 30 — cf.
  the "duplicate-clone on seams" posture), failing the precommit DoD. But the obvious dedup —
  `tools: sketch_tools() ++ [RunCommand]` — **won't compile**: `use JidoClaw.Agent.Defaults` forwards
  `tools:` straight to `use Jido.AI.Agent` (`defaults.ex:63`), whose macro `Enum.map`s the `tools:` **AST**
  at compile time and only matches literal module aliases/atoms (`agent.ex:294-298`) — a function-call (or
  `@attr`) AST raises `Protocol.UndefinedError`. So `tools:` **must be a literal list at the macro call
  site.** Single-source via a **thin worker macro** instead: a `JidoClaw.Agent.Workers.SketchWorker`
  (`use …, exec?: true|false`) that *generates* the whole `use Defaults` block and injects a **literal**
  tools list (the shared file + read-real aliases, conditionally appending **`RunCommand` *and*
  `FetchOutput`** for the exec variant). **`FetchOutput` rides with `RunCommand`:** `run_command`'s
  `OutputShaper` ref-stores oversized output and hands back a fetch ref, so without `FetchOutput` the exec
  worker is blind to large test/build output it can't retrieve — every other `RunCommand`-bearing worker
  (coder/refactorer/test_runner/verifier + the main agent) already pairs them, and it's read-only +
  tenant-scoped (`tenant_id` is always-forwarded, so it survives `forward_context: {:only,
  [:forge_session_key]}` — `tool_context.ex:97`). Both sketch
  workers become a one-line `use` of it (plus their distinct `name`/`description`), so the shared shape
  (`model: :fast`, `max_iterations`, `compaction: [mode: :auto]`, shared `OutputSchema` — no `signals`
  field, so the stage publishes nothing and converges trivially like `sketch-build`) lives in one place
  while the emitted `tools:` stays a literal. (A short, deliberately-duplicated literal list is the
  acceptable fallback if the macro feels heavy — but then expect to justify the clone to ExSlop.)
  `sandbox`/`forward_context` are **template** properties, not set on the worker.
- **Template** (`templates.ex` `@templates`, sibling to `sketch_build`):
  ```elixir
  "sketch_build_exec" => %{
    module: JidoClaw.Agent.Workers.SketchBuildExec,
    description: "Builds AND runs a throwaway prototype in a Docker-isolated sandbox",
    model: :fast,
    forward_context: {:only, [:forge_session_key]},   # D5
    sandbox: :docker
  }
  ```
- **Doctrine** (`doctrine.ex:39-49` `@template_slices`): add `"sketch_build_exec" => [:base, :artifacts]`
  (a *producing* worker, like `sketch_build`). **Required** — the drift guard
  (`doctrine_test.exs:62-73`) asserts `Doctrine.template_names() == Templates.names()`; a missing entry
  fails the build-test. No new priv file (reuses `:artifacts`).

### 2.2 — `sketch-build-exec` catalog stage + mutual exclusion (per D4)

New stage in `catalog.ex` (sibling of `sketch-build`):
```elixir
"sketch-build-exec" => %Stage{
  name: "sketch-build-exec",
  unit: {:worker_template, "sketch_build_exec"},
  task: "Build a tracer-bullet prototype AND run it in the sandbox to validate it executes.",
  routes: ["sketch"],
  subscribes: ["must-execute"],                 # D4-B
  input: %{required: ["request"], optional: []},
  output: ["prototype"],
  publishes: ["scope-shift"]
}
```
Plus the D4-B wiring — retarget `sketch-build` to `subscribes: ["sketch-plain"]`, and add **both**
`"must-execute"` and `"sketch-plain"` to `triage.publishes` (`catalog.ex:42-63`). Satisfies every validator
invariant: routes ⊆ paths; `scope-shift` published; `must-execute` is `triage`-published; `request` is a
seed artifact; no lens (light, like `sketch-build`); acyclic. The compile-time guard
(`catalog.ex:225-228`) requires the `sketch_build_exec` **template to exist first** (2.1) or compilation
raises.

### 2.3 — Triage `must-execute` verdict signal (the 4-file thread)

A new verdict signal the LLM can emit and the **front door** reads (`:must_execute in verdict.signals`) to
decide whether to *attempt* the exec launch. Kept coherent across every layer (each load-bearing — miss
one and the signal is silently dropped):

| Layer | File | Change |
| --- | --- | --- |
| LLM may emit it | `triage/schema.ex:22-40` | add `must_execute: "must-execute"` to the `Zoi.enum` |
| Normalized to atom | `triage/verdict.ex:45-58` | add `"must-execute" => :must_execute` (the only string→atom gate) |
| Described to the LLM | `triage/prompt.ex:52-64` | add a `must-execute` ("the sketch must be *run*, not just written") bullet |
| Catalog subscription validates | `catalog.ex:42-63` (`triage.publishes`) | add **both** `"must-execute"` and `"sketch-plain"` — the discriminators `sketch-build-exec`/`sketch-build` subscribe to need a declared publisher (D4-B); publishes need no consumer |

**Deliberately *not* a 5th `@signal_topics` row (D4 / Finding).** The `must-execute`/`sketch-plain`
discriminators are **routing decisions seeded directly by the launch outcome** (D7 Window 1), *not*
verdict-derived live signals. Adding `must_execute` to `@signal_topics` (`front_door.ex:92-106`) would
make `mapped_signals/1` (`front_door.ex:256-262`) auto-inject `"must-execute"` from the verdict — on
**both** the exec and degraded paths (the verdict carries `:must_execute` either way) — double-seeding the
degraded sketch with `"sketch-plain"` + `"must-execute"`. So `@signal_topics` is left untouched; the
discriminator reaches `live` only through `seed_live`'s explicit launch-decision branch (§2.4). The
`triage.publishes` entries are purely a **catalog-validation** declaration (so the subscriptions resolve)
— `mapped_signals/1` never emits either discriminator, because neither is in `@signal_topics`.

### 2.4 — Front-door Forge-session lifecycle (D3)

- **Launch decision is explicit (D7 Window 1).** `sketch_scope/2` (`front_door.ex:293-308`) grows from
  "make the dir" to "decide the route": when the verdict carries `:must_execute`, after creating
  `.prototypes/<id>/` it `Forge.start_session/2`s with the D3 spec shape — top-level
  `sandbox: :docker_sandbox`, nested `sandbox_spec: %{extra_mounts: [%{"host" => proto_dir, "container" =>
  "/proto", "mode" => "rw"}], <no-egress flag>, isolate_global_config: true}` (D1 variant ii + D2,
  **JSON-safe maps not tuples**; `isolate_global_config` opts the session out of global mounts/proxy, D2-a),
  `tenant_id: ctx[:tenant_id]`, `workspace_uuid: ctx[:workspace_uuid]` (**the UUID, never the synthetic
  `:proto:` id** — D3) — built by a **single-sourced spec builder the recovery path reuses** (D3) — via
  the combined **`Forge.start_session_ready/3`** that owns the subscribe→start→await-ready ordering (D3 —
  *not* a bare `start_session` then a separate `await_ready`, which loses the readiness-broadcast race).
  It returns an explicit outcome: `{:exec, {dir, ws}, premises_with_session_key}` on success,
  `{:plain_degraded, {dir, ws}, notice}` if any step fails (egress, start, await-ready, harness-down, or
  missing `workspace_uuid`). The bounded `{:error, {:sketch_sandbox_unavailable, _}}` stays only for a
  **prototype-dir** failure (no dir ⇒ no sketch at all).
- **The seed consumes the launch decision, not the raw verdict.** `start_composer/5` must thread the
  outcome into `live:` (`front_door.ex:207`): seed `"must-execute"` for `{:exec, …}` and `"sketch-plain"`
  for `{:plain_degraded, …}` (and for an ordinary non-exec sketch). Because the verdict still says
  `:must_execute` on the degraded path, deriving the discriminator from `seed_live(:sketch, verdict)` alone
  would wrongly seed the exec branch — the decision value is what disambiguates. Concretely, `seed_live`
  becomes launch-decision-aware (e.g. `seed_live(launch_outcome, verdict)`): it adds exactly one of
  `"must-execute"`/`"sketch-plain"` from the outcome, and its `++ mapped_signals(verdict)` tail is safe
  **only because** neither discriminator is in `@signal_topics` (§2.3) — so `mapped_signals` can't
  re-inject `"must-execute"`. On `{:plain_degraded, …}`, also surface the notice and ensure any partial
  Forge session was torn down (`Forge.stop_session/2`). **Test-pin** that the degraded path seeds
  `"sketch-plain"` *and not* `"must-execute"` (§2.5).
- Thread `forge_session_key` through `composer_context/3` (`:271-285`) and
  `@persisted_context_keys` (`route_composer.ex:211-214`) so it survives restart (string, JSON-safe).
- **Teardown:** after the composer's successful durable terminal append (D3 /
  `route_composer.ex:2163`, best-effort), a **completion-aware close** (`Forge.complete_session/2` built on
  the `Session.:complete` action — stamps `completed_at`; **not** plain `stop_session` which marks
  `:cancelled` — P2). It closes via a **Harness self-stop with `reason: :normal`** so the row lands
  `:completed` even if the `completed_at` stamp write fails (never `:failed` — D3 / Finding — close-phase).
  It is **sequenced after `append_parent_terminal/5` returns `:ok` with its result
  discarded** (never feeding `notify_payload/2`, so a cleanup failure can't become `:terminalize_failed` —
  D3 / Finding P3). `rm_rf` hits only the throwaway Forge `/tmp` workspace, never the `.prototypes/<id>/`
  mount (D1 variant ii). **Before**
  `ensure_started/2` succeeds, teardown is the **front door's** job, not the composer's (D3 ownership rule
  / D7 Window 1b): `start_composer/5`'s failure branch must close a live `{:exec, …}` session (here
  `stop_session`/`:cancelled` is correct — it *was* aborted), else a `create_parent_run`/`ensure_started`
  failure leaks the microVM.

### 2.5 — Tests (Phase 2)

- **`composer_loop_test.exs`** — a `must-execute`-seeded variant: `ran` includes `sketch-build-exec` +
  `sketch-review` (not `sketch-build`); converges. **And** confirm the existing non-exec sketch test
  still yields only `sketch-build` (proves D4 mutual exclusion).
- **`router_test.exs`** (GAP-5, `:398-427`) — with `must-execute` live: `route == ["sketch-build-exec",
  "sketch-review"]`. Without it: unchanged `["sketch-build", "sketch-review"]` (D4-B updates the seed to
  include `"sketch-plain"`). `sketch-build-exec` off-path on a `code` run.
- **`catalog_test.exs`** — pin the `sketch-build-exec` stage (mirror the `sketch-build` pin, `:36-46`).
- **`templates_test.exs`** — bump counts `9 → 10` (`:139`, `:166`); add explicit `sketch_build_exec`
  assertions (`forward_context: {:only, [:forge_session_key]}`, `sandbox: :docker`) — do **not** add it
  to `@valid_names` (that's the 7 public workers; it's composer-private, like the other sketch templates).
- **`doctrine_test.exs`** — drift test passes only with 2.1's slice entry; add a
  `for_template("sketch_build_exec")` assertion.
- **`templates_sandbox_test.exs`** — `sketch_build_exec`: `sandbox/1 == :docker`, `external_tools?/1 ==
  false`.
- **SketchBuildExec worker** — output-schema smoke (mirrors the `SketchBuild` test) + assert its tool list
  includes `RunCommand` **and** `FetchOutput` (Finding 5), and that `SketchBuild`'s includes **neither**.
- **Front-door launch decision (D7 Window 1 / Finding 4)** — with `Forge.start_session_ready` stubbed to
  fail on a `:must_execute` verdict: the launch yields `{:plain_degraded, …}`, the composer is seeded with
  `"sketch-plain"` **and *not* `"must-execute"`** (even though the verdict still carries `:must_execute` —
  this pins the no-double-seed invariant: `mapped_signals` must not re-inject the discriminator) so only
  `sketch-build` runs, the ack carries the execution-unavailable notice, and any partial session was
  `stop_session`'d. The happy path (`{:exec, …}`) seeds `"must-execute"` (and not `"sketch-plain"`).
  **Orphan guard (Finding — orphan race):** cover the **await-ready-timeout** sub-case distinctly (session *started*
  but never reached `:ready`), not just an outright `start_session` failure — assert the degrade still
  issues an **unconditional `Forge.stop_session(session_id)`** on the front-door-owned key, so a session
  that finishes registering after the abandon is still torn down (no leaked microVM).
- **Front-door composer-launch teardown (D7 Window 1b / Finding 2)** — `sketch_scope` returns a live
  `{:exec, …}` but `create_parent_run`/`ensure_started` is stubbed to fail: the front door returns the
  bounded `{:error, ack}` (no fall-through) **and** `Forge.stop_session/2`'s the live session (no leaked
  microVM).
- **Forge-spec persistence round-trip + recovery usability (Finding 1)** — a `start_session` spec with a
  JSON-safe `sandbox_spec.extra_mounts` map and `workspace_uuid` (1) persists + recovers without an Ash
  cast/encode error (guards the mount + UUID D3 traps); **(2) the recovered (string-keyed) spec normalizes
  back to a usable atom-keyed shape** — `resolve_client` still picks `Docker` and `sandbox_spec` still
  carries the mount + no-egress flag (**not** `:default`/empty); **(3) fail-closed** — a recovered
  `:docker_sandbox` spec that can't be normalized to a real Docker + no-egress session is **rejected**,
  never silently downgraded to the default/host backend. A tuple mount or synthetic `workspace_id` is
  rejected/avoided. Drive the normalizer directly (the load-bearing helper) and assert `Forge.wake/2`
  applies it.
- **Window 2 fail-closed (P1)** — `validate_sandbox_scope(:docker)` with a dead/zombie `forge_session_key`
  (no live `:ready` handle): the stage **fails closed** (errors → composer terminalizes), with **no**
  re-provision / `start_session` attempt (so no `:already_claimed`). Pin that a stale `:ready` DB row is
  left untouched (harmless per-prototype zombie).
- **Teardown phase (P2 / Finding P3)** — a clean post-converge close marks the Forge session
  **`:completed`** *and stamps `completed_at`* (proving the `Session.:complete` action ran, not a bare
  `:update_phase`), **not** `:cancelled`; a failure teardown (Window 1b / P3 taint) marks **`:cancelled`**.
  Assert against `Persistence.find_session(sid).phase` (and `.completed_at`). **The close must actually
  terminate the microVM, not just stamp the phase (Finding — close-terminates):** assert
  `Forge.get_handle(session_id)` (registry lookup) **fails** after a clean completion — the supervised
  `Harness` child is gone, mirroring `stop_session`'s terminate (`manager.ex:124`), so a `:completed` row
  never coexists with a live microVM. **And pin the failure-path isolation, both directions:** a
  `complete_session` that errors must **not** turn a converged terminal into `:terminalize_failed` — the
  converged run still reports converged (the close result is swallowed; drive it with a stubbed-failing
  close and assert the composer terminal is unchanged) — **and** that same persistence-failing close must
  **still terminate the child** (`get_handle` fails), so a stale phase write never *leaks* the microVM.
  **Pin the *phase* on that stamp-failure path, not just `get_handle` (Finding — close-phase):** assert
  `find_session(sid).phase == :completed` (with `completed_at` possibly `nil`) — **not `:failed`** — proving
  the `reason: :normal` self-stop drove `maybe_finalize_phase`'s `:normal ⇒ :completed` fallback
  (`harness.ex:730-743`), so a converged run is never cosmetically misread as failed. (So `complete_session`
  terminates the child **independent of** the `:completed` write outcome — best-effort on the stamp,
  mandatory on the teardown, and `:completed` either way.)
- **End-to-end (`:docker_sandbox`-tagged, manual)** — a real `sbx` run: stub-clean unit path for
  precommit, plus a tagged test that builds + runs a tracer-bullet in a real microVM (model:
  `docker_integration_test.exs`). Confirm: (1) network egress is actually denied; (2) `--workdir /proto`
  lands exec in the mount (a relative `ls`/`cat` sees the host-written prototype files). **(3) Prove *both*
  directions of the shared `:rw` mount (Finding — mount round-trip)** — stubs never exercise real bind-mount permissions,
  so assert the round trip on real Docker: a file **created by container exec** (e.g. `RunCommand`
  `… > /proto/out.txt`) is then **readable by the host file tools** (`ReadFile`/`PrototypeSummary`) on
  `.prototypes/<id>/`, *and* cleanup can read/remove it — catching UID/GID or mount-permission mismatches
  (container-uid writes the host process can't read) that a stub mount would silently mask.

---

## Verification

1. **`mix precommit`** — definition of done (both phases). `jidoclaw.compile_check` (no warnings),
   `format --check-formatted`, credo strict, ExSlop reach/clone at **zero** (single-source the two sketch
   workers via the thin `SketchWorker` macro that injects a **literal** tools list — *not* a
   `sketch_tools()` call in `tools:`, which won't compile — so neither the clone nor the macro trips a
   check; §2.1; keep any new `get_env`-style seams non-contiguous), full suite. Never pipe precommit
   through `tail`; build strings via `IO.iodata_to_binary`.
2. **`mix compile`** alone proves the new stage satisfies every `CatalogValidator` invariant and that
   `sketch_build_exec` resolves (the `catalog.ex:220-233` guards `raise` otherwise).
3. **Targeted while iterating:**
   - Phase 1: `mix test test/jido_claw/tools/run_command_test.exs test/jido_claw/forge/`,
     `…/templates_sandbox_test.exs`, `…/vfs/sandbox_test.exs`.
   - Phase 2: `mix test test/jido_claw/route_composer/`,
     `…/doctrine_test.exs …/templates_test.exs …/triage/`.
4. **Manual (`mix test --include docker_sandbox`, where Docker/`sbx` is available)** — the real exec
   path: a `must-execute` sketch builds + runs a tracer-bullet in a microVM. Mirror the full §2.5
   three-part assertion (not just network denial): **(1)** a network call from inside the sandbox is
   **denied** (D2); **(2)** `--workdir /proto` lands exec in the mount (a relative `ls`/`cat` sees the
   host-written prototype files); **(3)** both directions of the shared `:rw` mount — a file **created by
   container exec** is readable by the host file tools (and removable by cleanup), catching UID/GID or
   mount-permission mismatches a stub can't.

---

## Sequencing

- **Phase 1 → Phase 2.** Phase 1 (policy + bridge) is self-contained and precommit-green with no
  user-visible behavior change; Phase 2 (worker + stage + signal + lifecycle) activates it. Ship Phase 1
  first; Phase 2 follows immediately (not deferred).
- D1/D2/D4 should be settled before Phase 1 starts (D1 shapes the bridge's workspace assumption; D4
  shapes Phase 2's catalog but is worth agreeing up front).

---

## Risks & open questions

- **`sbx` exec working directory — now load-bearing (D1 variant ii).** `build_exec_args/3`
  (`docker.ex:278-290`) passes no `--workdir`, so exec defaults to the throwaway `/tmp` workspace, not the
  `.prototypes/<id>/` mount. **Resolved: emit `--workdir /proto` via a small additive `build_exec_args`
  branch** (`sbx exec` supports the flag) — preserves the raw command for logs/telemetry and avoids
  shell-prefix surprises, vs. weaving `cd /proto && ` into user text (D1). *Confirm `sbx` mount +
  `--workdir` behavior with the manual `:docker_sandbox` test (§2.5) before relying on the shared tree.*
- **`sbx` network-disable flag (D2).** Confirm `sbx create` supports denying egress; if not, the tier
  **degrades to a file-only sketch + notice** (D7) rather than shipping the no-egress bypass over an
  open network.
- **Forge-spec persistence traps (resolved in D3 — verify in code).** The whole start `spec` is persisted
  as an Ash `:map`/jsonb column (`redact_map(spec)`, `session.ex:209`, `persistence.ex:153`), so **three**
  shapes must be right: (1) `sandbox_spec.extra_mounts` entries must be **JSON-safe** (maps/lists, not
  tuples) — persisted as maps, normalized back to `{h,c,m}` tuples at the harness boundary
  (`build_sandbox_spec`, D1/D3); (2) the Forge `workspace_id` must be a real **UUID** (`session.ex:167`),
  so pass `ctx[:workspace_uuid]`, never the synthetic `"<ws>:proto:<id>"`; (3) on **read-back** the spec is
  **string-keyed** (jsonb), but the Harness reads atom keys (`:sandbox`/`:sandbox_spec`/`:runner`) — an
  un-normalized recovered spec mis-provisions **fail-open** to the default/host backend with an empty
  `sandbox_spec` (no isolation, no `--network none`). (1)+(2) are the most likely "surprising Ash/Forge
  start failure"; (3) is the security-relevant one — `Forge.wake/2` must normalize known fields to atoms
  and **fail closed** on an un-normalizable Docker spec (Finding 1 / D3). Latent today (exec-only sessions
  don't checkpoint, so neither `wake/2` nor the Manager's auto-recovery reads the spec back), but hardened
  centrally so a future checkpoint can't open the hole. Confirm with a persisted-then-recovered
  **usability** test, not just cast-without-error.
- **Global Docker config vs. the isolation model (resolved: force-isolate — D2-a / Finding P1).**
  `build_create_args/4` unconditionally layers the OneCLI CA-cert mount + global `:extra_mounts`
  (`docker.ex:249-260,511-540`) and `inject_onecli_env` injects the OneCLI proxy (`docker.ex:67,79-94`)
  onto every Docker session *before* the spec mounts. The content is off-by-default, but **a host-path
  mount survives `--network none`** (it's a local read, not egress) and would surface mounted files through
  `RunCommand` output — so the no-egress bypass (D2-b) cannot rest on egress alone. **Decision: the exec
  tier opts *out* of all three global layers at create** via a `sandbox_spec` flag
  (`isolate_global_config: true`) honored by `create_sandbox`/`build_create_args` (skip CA + global
  `extra_mounts`) and the `inject_onecli_env` call (skip proxy) — so `sandbox: :docker` ⇒ only the
  prototype mount + no egress, as a structural invariant. One small additive backend change (amends D1's
  "no backend change"); the flag joins the D3 recovery atomization set. Confirm with **two** assertions
  (Finding P3 — they live in *different* call sites): (1) `build_create_args/4` emits **no global `--mount`**
  (CA-cert + global `extra_mounts`) for an exec spec **even with globals configured**; (2) `create_sandbox`
  **skips the post-create `inject_onecli_env/3` call** (`docker.ex:67,79-94`) when `isolate_global_config:
  true` — the proxy is injected *after* `sbx create`, not as a create arg, so a create-args assertion alone
  can't catch it.
- **`await_ready` timeout + race ownership + subscription cleanup (D3 / Finding — P2 + orphan race).** The combined
  `Forge.start_session_ready/3` (which owns subscribe→start→await — *not* a bare post-start `await_ready/2`,
  which loses the readiness-broadcast race) needs a bounded timeout sized for `sbx create` latency: too
  short spuriously degrades to file-only, too long stalls the front-door ack. Tune at implementation. It
  must also **not leak the `Forge.PubSub` subscription** into the (long-lived) front-door process —
  `run_server` gets that for free via its `async_nolink` task, but the front door doesn't, so add
  `Forge.PubSub.unsubscribe/1` and either do the wait in a short-lived process or `unsubscribe` in an
  `after` (D3). **Orphan guard (Finding — orphan race):** do **not** make the parent's `Task.yield`/`Task.shutdown`
  the *primary* timeout — killing a task still mid-`Manager.start_session` can strand a microVM that
  registers just after cleanup. Mirror `run_server` faithfully (task owns its bounded await **and**
  failure-path `stop_session`, `run_server.ex:463-471,485-503`; the F2 twist is it self-stops only on
  failure, since success must keep the session); the front door **mints + owns the `session_id`** and, on
  any abandon/degrade, issues an **unconditional `Forge.stop_session(session_id)`** that `Manager`'s
  start/stop serialization (`manager.ex:117-133,206-235`) guarantees will find and terminate the child
  (D3).
- **microVM durability vs. durable composer runs (D3 / P1).** A recovered exec run finds a dead session;
  `validate_sandbox_scope(:docker)` asserts **`:ready`** (not just a live handle) and **fails closed** on a
  miss. Re-provision is **not** offered — a fresh `start_session` against the stale `:ready` row hits
  `:already_claimed` (recovery-claim is checkpoint-coupled, `persistence.ex:104-135`; exec sessions have no
  checkpoint), and a recovery-claim API was declined for this throwaway tier. The stale row is a harmless
  per-prototype zombie.
- **Timeout/output-limit taints the microVM (P3 — resolved: taint + fail closed).** A `124`/`153` leaves
  the in-container command running until teardown (`docker.ex:311-317`), so the bridge `stop_session`s the
  session on either and fails the stage closed (§1.2). **Caveat (Finding — call-timeout race): the
  manufactured `124` may never reach the bridge** because `Harness.exec/3` reuses one timeout for both the outer `GenServer.call`
  and the inner `OsCmd` (`harness.ex:63,91`, `docker.ex:318`), and the outer (send-time) deadline elapses
  before the inner (later-start) one — and `call/3` doesn't catch the `:timeout` exit (`harness.ex:92-96`).
  **Fixed at both ends (§1.2 pt 1):** (a) cushion `Harness.exec/3`'s outer call to `timeout + ~5 s` so the
  inner OsCmd wins and the `124` tuple flows through; (b) the bridge also catches any residual `:exit,
  {:timeout, _}` and routes it to the same taint + `:sandbox_command_timeout`. Residual: a *single* timeout
  ends the whole exec sketch (aggressive, but safe for a throwaway), and the zombie runs briefly between
  detection and teardown (bounded by the microVM). Revisit if `sbx` grows a remote-cancel API.
- **Global config vs. per-session backend.** `:forge_sandbox` app-config (`runtime.exs:6`) selects the
  default Forge backend *and* whether `SandboxInit` (the `sbx` validator / orphan-reaper) boots
  (`application.ex:388-397`). The exec tier should force a Docker session per-spec
  (`Harness.resolve_client/1` accepts `sandbox: :docker_sandbox` regardless of global config) — but then
  decide whether orphan-reaping is needed for tool-driven sessions when the global default is HostShell.

## Known limitation (note in code, not blocking)

The exec sandbox can read sensitive files mounted into `.prototypes/<id>/`, bounded by: no write
counterpart outside the jail, **no network egress** (D2), and the `OutputRedaction` pipeline redacting
secrets in tool output. Same posture the F3 read-real tools carry. Operator-configured **global**
`:extra_mounts` / OneCLI proxy / CA-cert do **not** reach the exec tier — it opts out of all three at
create (`isolate_global_config`, D2-a / Finding P1), so its mounted surface is *only* the
front-door-owned `.prototypes/<id>/`.

## Non-goals

- A finer **per-tool** (vs per-server/per-tier) approval overlay for the exec tier.
- Auto-merging an exec prototype into the real tree (the AR-8b isolation boundary stands; graduation is
  C1's summary contract).
- Routing **file tools** through Forge (D1 keeps them on the host-mounted shared tree).
