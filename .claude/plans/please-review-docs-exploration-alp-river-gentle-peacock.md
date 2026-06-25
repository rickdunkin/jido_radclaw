# AR-8b-2 F2 Phase 2 — Activation (`sandbox: :docker` exec sketch tier)

## Context

AR-8b shipped the file-only **sketch path** (a `sketch-build` worker in a hard-isolated
`<project>/.prototypes/<uuid>/` sandbox); F1 added a light correctness reviewer; F3 added read-only
real-tree tools. The one thing a sketch still cannot do is **run** its tracer-bullet — `RunCommand`
shells to the host `Shell.SessionManager` and escapes the VFS jail (the jail only constrains file-tool
*paths*). F2 adds a `sandbox: :docker` tier that routes `RunCommand` into a Forge Docker microVM for
real OS-level isolation (filesystem, process, **network**).

**Phase 1 (commit `fc9fd38b`) shipped the dormant plumbing** and is verified live in the tree:
the `:docker` policy tier (`templates.ex`, `tool_context.ex`), the `RunCommand`↔Forge bridge
(`lib/jido_claw/tools/run_command/forge_bridge.ex` — deadline derivation via `:__jido_deadline_ms__`,
detached taint/teardown, distinct **non-retryable** codes `:sandbox_unavailable` /
`:sandbox_command_timeout` / `:sandbox_output_limit` / `:sandbox_deadline_exceeded`, each with
`details: %{retry: false}`), the harness exec cushion (`Forge.exec_timeout_cushion_ms/0` = 5_000,
`Harness.exec_call_timeout/1`), context-aware streaming neutralization (`OutputShaper.docker_context?/1`),
the approval-floor bypass (`ToolApproval.native_requirement/4` → `docker_run_command?/2`),
`AgentRunner.validate_sandbox_scope(%{sandbox: :docker})` (asserts a **ready, `:default`-provisioned
`Forge.Sandbox.Docker`** session — stronger than the doc minimum), resolver + read-real wiring for
`:docker`, and **all 5 D6 refusal sites**. The `forge_facade` test seam
(`Application.get_env(:jido_claw, :forge_facade, Forge)` + `JidoClaw.Test.ForgeStub`) and a programmable
`StubSandbox.exec` (`program_exec/2`, `:exec_response`) are in place.

**Phase 2 (this plan) activates it**, in one precommit-green pass: a real `must-execute` sketch turn
mints a **no-egress, globally-unmounted** Docker session at the front door, launches a `sketch_build_exec`
worker that builds AND runs a prototype in the microVM (with the F1 reviewer), and converges. Greenfield —
no migration. **Done = `mix precommit` green.** Real in-microVM execution (`sbx`) is excluded from
precommit (`:docker_sandbox` tag); precommit proves everything via `StubSandbox` + arg-builder
assertions, and a manual `:docker_sandbox`-tagged test verifies the real path (egress denial, `--workdir`,
the rw-mount round-trip).

Design source of truth: `docs/exploration/alp-river/AR-8b-2-F2-EXEC-TIER.md` (decisions D1–D7, §2.1–2.5).
The doc's line numbers predate Phase 1; this plan uses **current** line refs.

**Decisions confirmed in planning Q&A:** (1) one single pass; (2) emit best-guess sbx flags
(`--network none`, `--workdir /proto`), assert they are *emitted* via arg-builder unit tests, and verify
real egress / workdir / mount round-trip in the manual `:docker_sandbox` test. Precommit proves the flag is
**emitted**, not **enforced**. Two residual cases: if `sbx` *rejects* the flag at create, the runtime
**degrades to a file-only sketch** (safe — `start_session_ready` fails → Window 1 degrade); if `sbx`
*silently accepts but does not enforce* `--network none`, the session comes up `:ready` and the tier would
run with an open network — that case is caught **only** by the manual `:docker_sandbox` test (which asserts
egress is actually denied), **not** by precommit. **That manual test is the true production-isolation
gate** and must pass before the exec tier is trusted in an environment with real `sbx`.

---

## Build order & dependency rationale

Forge/Docker plumbing (Part 1) is a **prerequisite layer** the activation consumes, so it lands first and
stays dormant (nothing calls it until Part 5). The compile-time catalog guard
(`catalog.ex` `Templates.exists?/1` raise) forces **template before stage** (Part 2 before Part 3). The
front-door lifecycle (Part 5) is the integration point that ties the worker, the triage signal, and the
Forge session together. Tests (Part 6) interleave with each part while iterating; the lockstep seed fixes
(D4-B) must land with the catalog retarget or three existing tests break.

---

## Part 1 — Forge / Docker plumbing (dormant prerequisites)

### 1.1 `Forge.PubSub.unsubscribe/1`
**Edit** `lib/jido_claw/forge/pubsub.ex` — add `unsubscribe/1`, a thin `Phoenix.PubSub.unsubscribe(@pubsub, session_topic(id))` wrapper mirroring the existing `subscribe/1` (`pubsub.ex:19-22`). Needed because the long-lived front door (unlike `run_server`'s short-lived `async_nolink` task, whose death auto-evicts its subscription) must explicitly drop the `forge:session:<id>` subscription or accumulate every later session broadcast.

### 1.2 `Forge.start_session_ready/3` (race-safe combined entrypoint)
**Edit** `lib/jido_claw/forge.ex` (helper logic may live in a small sibling, e.g. `lib/jido_claw/forge/ready_start.ex`, to keep `forge.ex` tidy). Add `start_session_ready(session_id, spec, opts \\ [])`.

**Model it on the proven pattern** in `lib/jido_claw/memory/consolidator/run_server.ex:442-517`
(`drive_harness/4` + `await_ready/3`): **subscribe to `Forge.PubSub` _before_ `Manager.start_session`**
(so the `{:ready, session_id}` broadcast — `harness.ex:346/361`, also `:227/:383` — can't be missed in the
same scheduler quantum), run the wait inside a short-lived `Task.Supervisor.async_nolink`
(`JidoClaw.TaskSupervisor`, the supervisor the bridge already uses) so a helper crash can't take down the
caller, **monitor the started pid** so a `{:DOWN, …, {:runner_init_failed, _}}` / provision crash returns
immediately, carry the bounded await-ready timeout **internally**, and `unsubscribe/1` in an `after`.

**Three F2 differences from `run_server` (all load-bearing):**
1. **Leave the session alive on success.** On `{:ready, session_id}` return `{:ok, session_id}` and do
   **not** stop the session (the front door uses it). Self-stop (`Forge.stop_session/2`) only on the
   failure paths (start-failed / await-timeout / harness-down). `run_server` stops on *every* exit; F2
   must not.
2. **Caller mints + owns the `session_id`** (it is the `forge_session_key`, D5) and passes it in — so the
   front door always holds a handle to clean up, even on a mid-flight death. The parent-side
   `Task.yield`/`Task.shutdown` backstop must be sized **longer** than the task's internal await timeout
   (so the task normally self-resolves first), and on any abandon the front door issues an
   **unconditional `Forge.stop_session(session_id)`** — `Manager` serializes start/stop through one
   GenServer (`manager.ex:117-133`), so a stop enqueued after a mid-flight start still finds + terminates
   the child (closes the "registers just after cleanup" orphan window).
3. **Ready *and usable* — status-check after the `:ready` broadcast, not the broadcast alone.** Phase 1's
   `validate_sandbox_scope(:docker)` (`agent_runner.ex:144-159`) is the bridge's usability contract:
   `sandbox_module == Docker`, `state: :ready`, `sandbox_status: :ready`, **`:default in sandboxes`**. A
   `{:ready, …}` broadcast satisfies `state: :ready` but does **not** by itself guarantee the `:default`
   Docker sandbox is provisioned (that separate `:default in sandboxes` assertion is exactly why Phase 1
   checks it). So after the broadcast, `start_session_ready/3` does a `Forge.status/1` check asserting the
   **same four conditions** and treats a miss as a launch failure (→ degrade) — it never returns `{:ok, _}`
   on a not-yet-usable session. This makes the front-door-minted session **guaranteed-usable by the bridge
   before the composer is seeded**, closing the window where the worker's `validate_sandbox_scope(:docker)`
   would otherwise fail closed mid-run (D7 Window 2) on a session the front door already committed to. (The
   alternative — document "callers must pass only non-deferred F2 specs" — is weaker; the status-check makes
   it structural.) **Testability:** the asserted backend is an `opts` value **defaulting to
   `JidoClaw.Forge.Sandbox.Docker`**. A `StubSandbox` session reports `sandbox_module: StubSandbox`, which
   would otherwise fail the Docker assertion — so the Part-6 wiring test passes `expected_backend:
   StubSandbox` to exercise the full subscribe→start→await→status-assert path without a real Docker daemon
   (`state`/`sandbox_status: :ready` + `:default in sandboxes` are still asserted). Production always uses the
   Docker default.

Return `{:ok, session_id}` | `{:error, reason}`. The default await timeout: start at `60_000` (matching
`run_server`'s `bootstrap_timeout/1`), tunable — too short spuriously degrades, too long stalls the ack.

### 1.3 Completion-aware close: `Forge.complete_session/1` (lands `:completed`, never `:failed`)
The success teardown must mark the session **`:completed`** (with `completed_at`), distinct from
`stop_session`'s **`:cancelled`** (which would misread a converged sketch as cancelled in ForgeView/history).
Build it on the **existing but unwired** `Session.:complete` Ash action
(`lib/jido_claw/forge/resources/session.ex:104-110` — sets `phase: :completed` **and stamps
`completed_at`**; the generic `:update_phase` does not).

- **`Persistence.complete_session/1`** (`lib/jido_claw/forge/persistence.ex`) — mirror
  `update_session_phase/2` (`persistence.ex:270-295`) but call the `:complete` action. Best-effort (log on
  error).
- **`Harness.complete/1`** (public) → `call(session_id, {:complete, …})`; a `handle_call({:complete, …},
  _, state)` that **best-effort** runs `persistence().complete_session(state.session_id)`, **swallows any
  write error**, then returns `{:stop, :normal, :ok, state}`. **Named test seam:** `persistence/0` →
  `Application.get_env(:jido_claw, :forge_persistence, JidoClaw.Forge.Persistence)` (the app-env-seam idiom,
  cf. `:forge_facade`/`:sbx_finder`), so a test installs a stub whose `complete_session/1` returns
  `{:error, _}` to drive the stamp-failure → `:normal`-fallback path (Part 6) — no one-off hook invented at
  implementation time.
- **`Forge.complete_session/1`** (`forge.ex`) → `Harness.complete/1`. Idiomatic `/1` — "complete" always
  means a clean `:normal` close, so (unlike `stop_session/2`'s `reason`) there is no meaningful second arg.

**Why a `reason: :normal` self-stop, not a Manager prewrite-then-terminate (Finding — close-phase):**
`terminate/2` runs `maybe_finalize_phase(state, reason)` (`harness.ex:759-773`): if the row is already
`:completed` (clean stamp) it no-ops; if the stamp **failed** (row still `:ready`/`:running`),
`reason == :normal` ⇒ it finalizes **`:completed`** (not `:failed`). So the row lands `:completed` *both*
on a clean stamp (with `completed_at`) *and* on a failed one (without) — never `:failed`. `terminate/2`
also destroys the microVM (`Sandbox.destroy` → `rm --force` + `rm_rf`), and Manager's `:DOWN` monitor
decrements with no spurious recovery (`:completed ∉ recoverable`, and exec sessions never checkpoint). A
Manager prewrite-`:completed`-then-`terminate_child` would deliver `:shutdown` (not `:normal`), so a failed
prewrite would fall through to `:failed` — the exact misread `:completed` exists to avoid.

### 1.4 `Forge.wake/2` recovered-spec atom-normalization + fail-closed (defensive)
**Edit** `lib/jido_claw/forge.ex` `wake/2` (`forge.ex:35-50`). The whole start `spec` is persisted as jsonb
(`redact_map`, `persistence.ex:148-156`); on read-back atom keys **and atom values** become strings, so a
recovered `%{sandbox: :docker_sandbox, …}` reads as `%{"sandbox" => "docker_sandbox", …}`. The Harness reads
**atom** keys (`Map.get(spec, :sandbox, :default)`, `harness.ex:165` → `resolve_client/1`,
`harness.ex:1300-1305`); a miss falls to `:default` (HostShell) with an **empty** `sandbox_spec` — a silent
**fail-open** to no isolation, no `--network none`, no mount.

Add a normalizer (a helper `wake/2` calls before `Manager.start_session`) that **faithfully re-atomizes** the
known fields of *any* recovered spec: the `sandbox`/`sandbox_spec`/`runner` **keys**, the `sandbox`/`runner`
**values**, and the nested `sandbox_spec` keys (`extra_mounts`, plus — *when present* — the no-egress flag
and `isolate_global_config`). **Fail closed** (`{:error, _}`, never silent `:default`/HostShell) on an
**un-normalizable spec** (unknown shape) or an **invalid mount shape** — these are general Docker-recovery
safety. **Scope, do NOT over-broaden (review P2):** do **not** require `network: :none`/`isolate_global_config`
on *every* recovered `:docker_sandbox` spec — the harness legitimately supports generic Docker specs
(`resolve_client(:docker_sandbox)`, `harness.ex:1304`) and attached sandboxes (`harness.ex:775`) that have
network by design. The F2 markers are restored **only if they were persisted** (so an F2 exec spec recovers
no-egress + isolated, closing the fail-open hole), and a generic Docker spec recovers as-is. **Latent today**
(exec-only F2 sessions never checkpoint, so
`wake/2` returns `{:error, :no_checkpoint}` and Manager auto-recovery — `recoverable?` requires a checkpoint —
never reads the spec back), but hardened centrally so a future checkpoint can't open the hole. F2's own
post-launch recovery does **not** re-provision (it fails closed in `validate_sandbox_scope`, Part 1 already
shipped); this normalizer guards only the latent Manager-auto-recovery path.

### 1.5 `Harness.build_sandbox_spec` — normalize JSON-safe mount maps → tuples
**Edit** `lib/jido_claw/forge/harness.ex` `build_sandbox_spec/2` / `merge_resource_mounts/2`
(`harness.ex:1307-1321`). The persisted spec must carry **JSON-safe** mount entries (maps, not tuples — a
tuple cannot be jsonb-encoded and `redact_map` would raise), e.g.
`%{"host" => proto_dir, "container" => "/proto", "mode" => "rw"}`. But the backend's `add_spec_mounts/2`
(`docker.ex:542-549`) destructures `{h, c, m}` **tuples**, and `merge_resource_mounts/2` concatenates the
spec's `extra_mounts` with the tuples `ResourceProvisioner.file_mount_specs/1` returns. **Normalize maps →
`{h, c, m}` tuples at this harness boundary, unconditionally** (including the `[]`-resource-mounts clause,
which currently passes the spec through unchanged), so the list reaching `add_spec_mounts/2` is uniformly
tuples and the backend stays tuple-only and untouched. The persisted spec stays JSON-safe; the conversion is
in-memory at create. **Keep `build_sandbox_spec`'s return type UNCHANGED (a bare spec) — do NOT thread a
tagged error through it.** It has **five** callers (`harness.ex:242` bootstrap, `:777` attach, `:835`/`:954`/
`:1101` recovery/sync), each passing the result straight into `sandbox_module.create(...)`; switching to
`{:ok, spec} | {:error, _}` would force all five to pattern-match or the tuple lands in `create/1` as a
"spec". Instead, **handle malformed mounts at the spec-input boundaries**, so by the time this conversion runs
the map is already well-formed. There are **three** such boundaries:
- **Create path (F2):** the front door builds the mount map literally + well-formed by construction (5.2) — no
  malformed map originates there.
- **Recovery path:** `wake/2` **validates + fail-closes** on a recovered invalid mount shape (1.4) *before*
  the spec reaches `build_sandbox_spec`.
- **Attach path — `Forge.attach_sandbox/3` (`forge.ex:103` → `attach_new_sandbox/3`, `harness.ex:775`):** a
  *third*, **public** input boundary that also flows an arbitrary caller spec through `build_sandbox_spec`
  (`:777`). **Not an F2 path** — F2 creates its session via `start_session`, never `attach_sandbox` — so it
  has no file-only-degrade semantics. The centralized normalization is a **net improvement** here: a
  well-formed JSON-safe map mount now **converts correctly** (today it would crash in `add_spec_mounts/2`'s
  tuple destructure), and a *malformed* attach map hits the same **descriptive `raise`** below — a documented
  **invariant crash** (option b). If a graceful public-API error is wanted later, `attach_new_sandbox/3` can
  rescue that raise into `{:error, {:provision_failed, {:invalid_mount_spec, entry}}}`; out of F2's required
  scope.

For the F2 create + recovery paths a malformed entry reaching this conversion is an **impossible invariant
violation** (both pre-validate); for the public attach path it's the documented invariant crash. Either way
it is guarded by a **descriptive `raise`** (an `ArgumentError` naming the bad entry — a clear boundary
failure, *not* a `FunctionClauseError` buried in `add_spec_mounts/2`'s tuple destructure). With
`restart: :temporary` Harness semantics that raise becomes a clean session death → the front door degrades
(Window 1) / recovery fails closed. So the map→tuple normalization stays **total**, the backend stays
tuple-only, and there is **zero** call-site ripple. Non-F2 sessions (tuple resource mounts only) pass through
untouched. **Make the
normalization idempotent** — accept **both** an already-`{h, c, m}` tuple (pass through) and a
`%{"host" => …}` map (convert) — since `build_sandbox_spec` runs on both the create path and the
recovery/sync paths and the in-memory spec may already hold converted tuples by the later calls.

### 1.6 Docker backend — three additive branches
**Edit** `lib/jido_claw/forge/sandbox/docker.ex`. All three are gated on the nested `sandbox_spec`, so
non-exec Docker sessions are unchanged. Stub-path tests assert the emitted args; real `sbx` behavior is the
manual `:docker_sandbox` test.

1. **`--workdir /proto` on exec** — `build_exec_args/3` (`docker.ex:278-290`) emits no `--workdir`, so exec
   defaults to the throwaway `/tmp` workspace, not the mount. Thread a workdir (from `sandbox_spec`, stamped
   onto the Docker sandbox client state at `create`, read at exec) and emit `sbx exec --workdir <dir> …`.
   **Workdir, not a `cd /proto &&` prefix** — preserves the raw command for the Forge event log / telemetry
   (`harness.ex:478`), avoids shell-prefix edge cases (a command that itself `cd`s, empty/heredoc commands),
   and keeps cwd authoritative at the runner layer. Fingerprint/approval are unaffected (the gate runs in the
   `Tools.Action` wrapper on the model's `command` *before* the body, `action.ex:55`).
2. **No network egress** — `build_create_args/4` (`docker.ex:249-260`) passes no `--network`. Emit a
   no-egress flag (best-guess `--network none`) when the `sandbox_spec` requests it. The moduledoc's claim
   that each microVM gets "a dedicated … network" is exactly the egress this disables.
3. **`isolate_global_config: true` opt-out** — `build_create_args/4` *unconditionally* layers the OneCLI
   CA-cert mount + global `:extra_mounts` (`maybe_add_ca_cert_mount`/`add_extra_mounts`,
   `docker.ex:251-255,511-540`), and `create_sandbox` *unconditionally* injects the OneCLI proxy
   (`inject_onecli_env`, `docker.ex:67,79-94`) **post-create**. A host-path mount **survives `--network
   none`** (it's a local read, not egress) and would surface arbitrary mounted files through `RunCommand`
   output — so the no-egress bypass cannot rest on egress alone. When `isolate_global_config: true`: **skip**
   `maybe_add_ca_cert_mount` + `add_extra_mounts` in `build_create_args`, **and skip** the
   `inject_onecli_env` call in `create_sandbox`. The two checks live at **different call sites** (a create-arg
   assertion alone can't catch the post-create proxy injection — see tests).

The `sandbox_spec` shape the front door builds (Part 5.2) and these branches honor:
```elixir
%{
  extra_mounts: [%{"host" => proto_dir, "container" => "/proto", "mode" => "rw"}],
  workdir: "/proto",
  network: :none,                # no-egress request
  isolate_global_config: true
}
```

---

## Part 2 — Worker + template + doctrine (§2.1)

### 2.1 Thin `SketchWorker` macro (single-source the two builders; avoid the ExSlop clone gate)
`sketch_build` and `sketch_build_exec` differ by **exactly one tool** (`RunCommand`, plus its mandatory
`FetchOutput` pair). A near-identical second worker module would drift *and* trip the ExSlop clone check
(min_mass 30 — cf. the documented clone-seam friction). The obvious dedup `tools: sketch_tools() ++
[RunCommand]` **won't compile**: `use JidoClaw.Agent.Defaults` forwards `tools:` to `use Jido.AI.Agent`
(`defaults.ex:63`), whose macro `Enum.map`s the `tools:` **AST** and matches **only** literal module aliases
/ bare atoms (`deps/jido_ai/lib/jido_ai/agent.ex:294-298`) — a function-call AST raises at compile.

**New file** `lib/jido_claw/agent/workers/sketch_worker.ex` (`JidoClaw.Agent.Workers.SketchWorker`): a
`__using__(opts)` macro taking `name:`, `description:`, `exec?: true|false`. It builds a **literal list of
fully-qualified tool module atoms** at macro-expansion time (the shared file + read-real tools, plus
`JidoClaw.Tools.RunCommand` **and** `JidoClaw.Tools.FetchOutput` when `exec?`), and emits
`use JidoClaw.Agent.Defaults, name: …, tools: unquote(tool_list), model: :fast, max_iterations: 15,
streaming: false, tool_timeout_ms: <opt>, compaction: [mode: :auto], output: <builder output map>`. Because
`tool_list` is a list of atoms, `unquote(tool_list)` is a literal-atom list AST → `Jido.AI.Agent`'s `is_atom`
clause accepts each. The builder `output:` is a **map** carrying the `Zoi.object` schema (status / summary /
files_changed / notes + `OutputSchema.artifacts()`, **no `signals` field** → the stage publishes nothing and
converges trivially) **plus its `retries`/`on_validation_error` keys** — those live **inside** the `output:`
map (read by `Jido.AI.Output` from the output attrs, `output.ex:41`), **not** as top-level agent options;
mirror today's `sketch_build.ex:34` exactly. This whole output map lives once in the macro.

**`tool_timeout_ms` is a macro opt** (default `30_000`, the file-builder value). The exec worker needs a
larger one: the bridge reserves a **~5.5s cushion** (`Forge.exec_timeout_cushion_ms` 5_000 + 500 taint
overhead) off the outer deadline before launching the in-container command, so the **effective in-container
budget ≈ `tool_timeout_ms − 5_500`** (a budget below ~6.5s returns `:sandbox_deadline_exceeded` and never
launches). At `30_000` an exec command gets only ~24.5s — too tight for "build *and* run." See 2.2.

This unifies the **two builders only**. `sketch_reviewer` (different tools, `OutputSchema.reviewer_verdict()`)
stays as-is — it is not a clone of the builders, and F1 already shipped it green.

**`FetchOutput` rides with `RunCommand`** (Finding 5): `run_command`'s shaper ref-stores oversized output and
hands back a fetch ref; without `FetchOutput` the exec worker is blind to large test/build output. It's
read-only + tenant-scoped (`tenant_id` is always-forwarded, so it survives `forward_context: {:only,
[:forge_session_key]}`). Every other `RunCommand`-bearing worker already pairs them
(`coder`/`refactorer`/`test_runner`/`verifier` + the main agent).

### 2.2 The two builder workers
- **Refactor** `lib/jido_claw/agent/workers/sketch_build.ex` → one-line `use SketchWorker, exec?: false,
  name: "jido_claw_sketch_build", description: …` (same emitted shape it has today; output unchanged).
- **New** `lib/jido_claw/agent/workers/sketch_build_exec.ex` → `use SketchWorker, exec?: true, name:
  "jido_claw_sketch_build_exec", description: "Builds AND runs a throwaway prototype in a Docker-isolated
  sandbox", tool_timeout_ms: 90_000`. The larger budget (≈84.5s in-container after the ~5.5s cushion) gives a
  tracer-bullet room to build and run; `90_000` is a starting value — **tune against real microVM exec
  latencies** (the three cushion constants `5_000`/`500`/`1_000` are Phase-1 estimates too). `sandbox`/
  `forward_context` are **template** properties (Part 2.3), not set on the worker.

### 2.3 Template + doctrine
- **Edit** `lib/jido_claw/agent/templates.ex` `@templates` (sibling to `sketch_build`, `templates.ex:99-118`):
  ```elixir
  "sketch_build_exec" => %{
    module: JidoClaw.Agent.Workers.SketchBuildExec,
    description: "Builds AND runs a throwaway prototype in a Docker-isolated sandbox",
    model: :fast,
    forward_context: {:only, [:forge_session_key]},   # D5 — strict isolation, but the session key passes
    sandbox: :docker
  }
  ```
  `sandbox: :docker` + `external_tools?/1` (→ `false` for `:docker`, `templates.ex:197`) are already wired
  (Phase 1). Count 9 → **10**.
- **Edit** `lib/jido_claw/doctrine.ex` `@template_slices` (`doctrine.ex:39-49`): add
  `"sketch_build_exec" => [:base, :artifacts]` (a producing worker, like `sketch_build`; reuses the existing
  `:artifacts` slice — no new priv file). **Required** — the drift guard
  (`doctrine_test.exs:70`, `template_names() == names()`) fails without it.

---

## Part 3 — Catalog stage + mutual exclusion (§2.2 / D4-B)

The router has **no "pick one of N"** (`compose_route/4` runs every triggered+on-path+satisfiable stage as a
parallel wave, `router.ex:69-78`; confirmed via `trigger/3` `:122-141`). So the two builders, both
`routes: ["sketch"]`, **must be mutually exclusive by `subscribes`** — **D4-B distinct triggers**.

**Edit** `lib/jido_claw/route_composer/catalog.ex`:
- **New stage** (sibling of `sketch-build`, `catalog.ex:183-194`):
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
- **Retarget** `sketch-build`: `subscribes: ["request-received"]` → **`["sketch-plain"]`** (`catalog.ex:190`).
- **Add both** `"must-execute"` **and** `"sketch-plain"` to `triage.publishes` (`catalog.ex:42-63`) — the
  discriminators need a declared publisher to satisfy `CatalogValidator` invariant 3; publishes need no
  consumer.

`sketch-review` is **unchanged** (`subscribes: ["request-received"]`, `input.required: ["prototype"]`):
`prototype` stays in the output union (either builder produces it), so invariants 3/4 hold and the data graph
orders it into wave 2 after whichever builder ran.

Satisfies every validator invariant (routes ⊆ paths; `scope-shift` published; `must-execute` is
triage-published; `request` is a seed artifact; no lens; no self-dep; acyclic — `catalog_validator.ex`).
Compilation **raises** unless `sketch_build_exec` template exists first (`catalog.ex` `Templates.exists?/1`
guard), so Part 2.3 precedes this.

**Why not a lock on `sketch-build` (D4-A) — it deadlocks.** A `lock: [%{while: "must-execute", until:
<never>}]` stays active for the whole run (the only never-co-occurring `until` is a cross-lane signal that
never goes live on a sketch run), placing `sketch-build` in `display.held` forever → `Loop.terminal/2`
returns `:deadlock` *before* the cleanliness check (`loop.ex:82-88`). Distinct triggers are mutually
exclusive **by construction**, no lock.

---

## Part 4 — Triage `must-execute` verdict signal (§2.3)

A verdict signal the LLM may emit and the **front door** reads (`:must_execute in verdict.signals`) to decide
whether to *attempt* the exec launch. Threaded through every layer (miss one ⇒ silently dropped):

| Layer | File | Change |
| --- | --- | --- |
| LLM may emit it | `lib/jido_claw/triage/schema.ex:26-37` | add `must_execute: "must-execute"` to the `Zoi.enum` |
| Normalized to atom | `lib/jido_claw/triage/verdict.ex:45-58` | add `"must-execute" => :must_execute` (the only string→atom gate) |
| Described to the LLM | `lib/jido_claw/triage/prompt.ex:52-64` | add a `must-execute` bullet ("the sketch must be *run*, not just written") |
| Catalog subscription validates | `catalog.ex:42-63` (`triage.publishes`) | done in Part 3 |

**Deliberately NOT a `@signal_topics` row** (`front_door.ex:93-106`). `must-execute`/`sketch-plain` are
**routing decisions seeded directly by the launch outcome** (Part 5), not verdict-derived live signals.
Adding `must_execute` to `@signal_topics` would make `mapped_signals/1` (`front_door.ex:256-262`)
auto-inject `"must-execute"` from the verdict on **both** the exec and degraded paths, double-seeding the
degraded sketch with `"sketch-plain"` + `"must-execute"`. The `triage.publishes` entries are purely a
catalog-validation declaration; `mapped_signals` never emits either discriminator.

---

## Part 5 — Front-door Forge-session lifecycle (§2.4 / D3 / D7)

The integration point. `lib/jido_claw/front_door.ex`.

### 5.0 Forge seam (testability — REQUIRED)
`FrontDoor` today resolves only the composer through a seam (`composer/0`, `front_door.ex:327`) — it has **no
Forge seam**, and the existing `ForgeStub` only implements `exec/3` + `stop_session/2`. The front-door
launch-decision and composer-teardown tests can't run without one. Add a private `forge/0` →
`Application.get_env(:jido_claw, :forge_facade, Forge)` (the **same** key Phase 1's bridge uses) to **both**
`FrontDoor` and `RouteComposer`, and route every Forge call in this part — `start_session_ready/3`,
`stop_session/2`, `complete_session/1` — through it. (`ForgeStub` is extended to match in Part 6.)

### 5.1 `sketch_scope/2` → explicit three-way launch decision (D7 Window 1)
Grow `sketch_scope/2` (`front_door.ex:293-308`) from "make the dir" to "decide the route." After
`create_prototype_dir/1`, **when the verdict carries `:must_execute`**, build the Forge spec (5.2) and call
`Forge.start_session_ready/3` (1.2). Return an explicit, first-class outcome (never derive the branch from
the raw verdict downstream — the verdict still says `:must_execute` even when exec setup failed):

- `{:exec, {proto, ws}, premises, forge_session_key}` — must_execute **and** the session came up `:ready`.
- `{:plain_degraded, {proto, ws}, premises, notice}` — must_execute but exec setup failed (egress/start/
  await-ready/harness-down, or **no `workspace_uuid`** available). Any partial session was already
  `stop_session`'d; carry a user notice.
- `{:plain, {proto, ws}, premises}` — an ordinary (non-must_execute) sketch.
- `{:error, {:sketch_sandbox_unavailable, reason}}` — **prototype-dir** failure only (no sketch at all;
  non-degradable bounded ack, unchanged).

`sketch_scope(_path, ctx)` (code/system) returns `{:plain, {dir, ws}, %{}}` (scope unchanged).

The `{:exec, …}` outcome carries `forge_session_key` as a **separate tuple element**, **not** inside
`premises`: `premises` flows into the `route_composed` event + `Observe` as **summary labels**
(`observe.ex:10`, `route_composer.ex:1422`), whose contract is safe-label-only — an internal session handle
doesn't belong there. The key reaches the worker + composer via the persisted **context** (5.4); the front
door holds it from the tuple for Window-1b teardown (5.5). `premises` stays `prototype_id`/`prototype_dir`
(+ C1 `graduated_from`).

### 5.2 Single-sourced Forge spec builder (reused by recovery)
A private builder produces the **top-level** start spec the Harness expects (backend selected by the
top-level `:sandbox` atom; knobs in the **nested** `:sandbox_spec`):
```elixir
%{
  sandbox: :docker_sandbox,                  # backend atom (distinct from the :docker policy atom)
  sandbox_spec: %{ extra_mounts: [%{"host" => proto, "container" => "/proto", "mode" => "rw"}],
                   workdir: "/proto", network: :none, isolate_global_config: true },  # 1.5/1.6
  runner: :shell,
  tenant_id: ctx[:tenant_id],
  workspace_uuid: ctx[:workspace_uuid]       # the REAL UUID — never the synthetic "<ws>:proto:<id>"
}
```
**`workspace_uuid` must be the real UUID** — `Session.workspace_id` is `:uuid` non-nullable
(`session.ex:167`) and `scope_from_spec/1` (`persistence.ex:518-527`) would fail to cast the synthetic
`"<ws>:proto:<id>"`. If `ctx[:workspace_uuid]` is absent, the exec tier **cannot persist a session →
degrade** (Window 1). The synthetic id stays only in `composer_context` (the worker shell scope). The
`forge_session_key` (== the Forge `session_id`/`Session.name`) is a **freshly generated bare UUID**
(`Ash.UUID.generate/0`) — **not** a `sketch:<id>`-prefixed string: `Session`'s name invariant
(`session.ex:15`) holds that every name source is a fresh UUID, and a prefix would violate it. It lives in
the persisted **context** (5.4 — `composer_context` + `@persisted_context_keys`: the worker-scope /
restart / teardown home), and in the launch-outcome tuple for Window-1b teardown — **not** in `premises`
(summary-label-only; `prototype_id` there already links session↔prototype for observability). It is what the
front door passes to `start_session_ready/3`.

### 5.3 `seed_live` consumes the launch decision (D4-B)
`start_composer/5` (`front_door.ex:178-251`) binds the launch outcome and threads it into `live:`. Make
`seed_live` launch-outcome-aware — the sketch seed stays **`["request-received", "sketch", <discriminator>]
++ mapped_signals(verdict)`**: it still seeds the `"sketch"` **path signal** (without a live path the router
intentionally skips route filtering, `router.ex:147`), plus **exactly one** *discriminator* — `"must-execute"`
for `:exec`, `"sketch-plain"` for any sketch that isn't exec (`:plain_degraded` or a `:plain` sketch). The
`++ mapped_signals(verdict)` tail is safe **only because** neither discriminator is in `@signal_topics`
(Part 4). The code/system clause (`front_door.ex:317-318`) is unchanged.

### 5.4 Thread `forge_session_key` (D5)
- `composer_context/3` (`front_door.ex:271-285`) — add `forge_session_key: forge_key` (nil-rejected like the
  rest, so non-exec runs are unchanged).
- `@persisted_context_keys` (`lib/jido_claw/route_composer/route_composer.ex:211-214`) — add
  `forge_session_key` (string, JSON-safe) so it survives restart and reaches `resolve_scope/2`
  (`agent_runner.ex:406-409`, already reads it) → `apply_visibility {:only, [:forge_session_key]}` → the
  jailed worker's `tool_context`.

### 5.5 `start_composer/5` — Window 1b teardown ownership (D7)
Restructure the `with` (`front_door.ex:195-223`) so the failure branch can tear down a live exec session.
Today the single `else {:error, reason}` (`front_door.ex:234`) has **no access** to a session handle. Bind
the launch outcome first; when it is `{:exec, …, forge_session_key}`, guard the two composer-launch steps
(`create_parent_run` / `ensure_started`) so a failure **`Forge.stop_session(forge_session_key)`** (here
`:cancelled` is correct — the session *was* aborted) and then surfaces the **bounded `{:error, ack}`** (the
same P1 no-fall-through a code/system launch failure takes — this is **not** a degrade; the whole run failed
to start). Without this, the composer's terminal teardown (5.6) never runs (the composer never started — see
`maybe_terminalize_orphan`, `route_composer.ex:575-586`, which terminalizes the durable parent but never
runs `parent_terminal_notify`), leaking the microVM + `/tmp` workspace.

On the `{:plain_degraded, …}` outcome, surface the notice in the ack (so a silent file-only sketch isn't
mistaken for a run) and proceed with the `"sketch-plain"` seed.

**Ownership rule:** the front door owns Forge cleanup **from session-creation until `ensure_started/2`
returns `{:ok, _}`**; after that, the composer's terminal hook (5.6) owns it.

### 5.6 Composer terminal teardown — EVERY terminal, not just `:converged` (D3 / Findings P3, close-phase)
**Edit** `route_composer.ex`. Teardown must run for **every** `parent_terminal_notify/4` clause —
`:converged` (`:2163`), `:rejected`/`:abandoned` (`:2179`), and the `:not_converged`/`:failed`/
`:budget_exhausted` catch-all (`:2191`) — **not only `:converged`**. The bridge taint teardown (Phase 1)
covers *only* manufactured timeout/output-limit failures (`forge_bridge.ex:222`), so a normal "ran but the
reviewer requested changes" sketch (`:not_converged`) would otherwise leave the microVM **alive**. This was
the review's headline gap.

Add a shared helper, called from each clause **after** `append_parent_terminal/5` returns, with the
**append** result (not the teardown result) flowing into `notify_payload/2`:
```elixir
# Fires only on :ok — a failed append leaves the parent :running/recoverable, so
# tearing down the microVM there would strand a retry. Guard a non-empty binary
# key BEFORE touching Forge: every non-exec route has none → no-op, NEVER
# forge().stop_session(nil) (don't lean on best_effort to absorb bad input).
defp maybe_teardown_forge_session(:ok, terminal, state) do
  case forge_key(state) do
    key when is_binary(key) and key != "" -> do_forge_teardown(terminal, key)
    _ -> :ok
  end
end
defp maybe_teardown_forge_session(_not_ok, _terminal, _state), do: :ok

defp do_forge_teardown(:converged, key), do: best_effort(fn -> forge().complete_session(key) end)  # :completed
defp do_forge_teardown(_other, key),     do: best_effort(fn -> forge().stop_session(key) end)      # :cancelled

defp parent_terminal_notify(:converged, _reason, summary, state) do
  result = append_parent_terminal(state.parent_run_id, :route_converged,
             %{result: terminal_summary_subset(summary)}, state.tenant, state.actor)
  maybe_teardown_forge_session(result, :converged, state)
  notify_payload(result, summary)
end
# …the :rejected/:abandoned and failure catch-all clauses likewise, passing their `kind`.
```
The teardown must **not** flow into `notify_payload` (`route_composer.ex:2214-2215`) — a cleanup
`{:error, _}` becoming `{:terminalize_failed, reason}` would misreport the run's outcome and leave the parent
`:running`. `forge_key/1` reads the `forge_session_key` from the composer's persisted context (the
`@persisted_context_keys` subset, so it survives restart); a non-exec run has none ⇒ the helper no-ops
**before** calling Forge (never `stop_session(nil)`).

**Phase semantics:** `:converged → :completed` (clean run, `complete_session`, 1.3); **every other terminal →
`:cancelled`** (`stop_session` — the throwaway run ended without converging, the session is torn down). The
*why* is already recorded by the durable WorkflowRun terminal kind (`route_not_converged`/`route_failed`/…);
the Forge phase records only completed-vs-torn-down. With the mount variant, teardown's `rm_rf` hits only the
Forge `/tmp` workspace, never the front-door-owned `.prototypes/<id>/`.

`forge()` is the `Application.get_env(:jido_claw, :forge_facade, Forge)` seam (5.0), so `ForgeStub` drives
all teardown in tests. All teardown triggers (bridge taint, front-door Window 1/1b, this hook) are
best-effort + idempotent; a later call no-ops on an already-gone session.

---

## Part 6 — Tests (precommit-green via stubs; one manual `:docker_sandbox` test)

### Forge / Docker plumbing (Part 1)
- **`ForgeStub` + seam extensions (test scaffolding, REQUIRED).** Extend `JidoClaw.Test.ForgeStub` (today
  only `exec/3` + `stop_session/2`, `forge_stub.ex:88`) with `start_session_ready/3` and `complete_session/1`,
  each with a call recorder (mirror `execs/0`/`stops/0`) and programmable outcome (e.g.
  `set_start_ready_result/1` to force `{:ok, sid}` vs a failure/timeout). This is what makes the front-door
  launch-decision (5.0 seam) and all-terminal teardown tests possible.
- **`forge/pubsub` / `start_session_ready`** — drive `start_session_ready/3` against a `StubSandbox`-backed
  session (spec `sandbox: StubSandbox`, per `harness_bootstrap_env_test.exs`) **with `expected_backend:
  StubSandbox`** (else the Docker-default status assertion rejects the stub session — the [P2] tension):
  success → `{:ok, session_id}` and the session is **still alive** (`Forge.get_handle` succeeds); a stubbed
  start-failure / await-timeout / harness-down → `{:error, _}` **and** `stop_session` ran (`ForgeStub.stops/0`
  or `get_handle` fails). Add a **status-assert** case: a session that broadcasts `:ready` but whose status
  lacks `:default in sandboxes` (deferred sandbox) → `{:error, _}` + torn down (proves the usability
  contract, not just the broadcast). **Orphan guard:** the **await-ready-timeout** sub-case (session
  *started* but never `:ready`) issues an **unconditional `stop_session(session_id)`** on the minted key.
- **`complete_session`** (Forge layer) — clean post-converge close marks the session **`:completed`** *with*
  `completed_at` (proving `Session.:complete` ran, not `:update_phase`) and `Forge.get_handle(session_id)`
  **fails** (child gone — `:completed` never coexists with a live microVM). A **stamp-failing** close (install
  a `:forge_persistence` stub whose `complete_session/1` returns `{:error, _}`, the named seam from 1.3)
  **still** terminates the child **and** lands `find_session(sid).phase == :completed` (`completed_at`
  possibly nil) — **not `:failed`** (proves the `reason: :normal` fallback). *(The composer-layer "cleanup
  error ≠ `:terminalize_failed`" assertion lives in the all-terminal teardown test below — it's a different
  layer, driven at the **facade**.)*
- **`wake/2` normalization** — a `start_session` spec with a JSON-safe `sandbox_spec.extra_mounts` map +
  `workspace_uuid` **persists + recovers** without an Ash cast/encode error; the recovered (string-keyed)
  spec **normalizes** back to a usable atom-keyed shape (`resolve_client` still picks `Docker`,
  `sandbox_spec` still carries the mount + no-egress flag + `isolate_global_config` — **not** `:default`/
  empty); a recovered `:docker_sandbox` spec that can't be normalized **fails closed** (rejected, not
  downgraded), **including an invalid recovered mount-map shape** (the real malformed-mount guard, 1.4/1.5).
  Drive the normalizer directly + assert `wake/2` applies it.
- **`build_sandbox_spec` mount normalization** — a JSON-safe map mount in `extra_mounts` becomes a `{h,c,m}`
  tuple reaching `add_spec_mounts/2` (assert via the built args), including the no-resource-mounts case; a
  resource-mount tuple still works (no regression). Return type is a **bare spec** (no tagged-error contract,
  1.5); a malformed map at this boundary raises a descriptive `ArgumentError` (defensive-invariant smoke —
  the realistic malformed case is caught upstream by `wake/2`, so this raise never fires in normal flow).
- **Docker arg-builders** — with `isolate_global_config: true` **and globals configured**:
  `build_create_args/4` emits **no** global `--mount` (CA-cert + global `extra_mounts`) **and** a no-egress
  flag; `create_sandbox` **skips** the post-create `inject_onecli_env` call (a separate call site —
  create-args assertion can't catch it); `build_exec_args/3` emits `--workdir /proto`.

### Activation (Parts 2–5)
- **`composer_loop_test.exs`** (sketch tests ~`:179-209`) — **UPDATE** the F1 seeds: add `"sketch-plain"`
  so the existing clean/request_changes cases still trigger `sketch-build`+`sketch-review`. **Add** a
  `must-execute`-seeded variant: `ran` includes `sketch-build-exec`+`sketch-review` (not `sketch-build`),
  converges; the `must-execute` stub needs a `sketch_build_exec` `StubWorker` override in `put_sketch_env`.
  Keep a `sketch-plain` variant to prove D4 mutual exclusion (only `sketch-build` runs).
- **`router_test.exs`** (GAP-5 ~`:398-428`) — add `"sketch-plain"` to the seed; with `must-execute` live:
  `route == ["sketch-build-exec", "sketch-review"]`, `waves == [["sketch-build-exec"], ["sketch-review"]]`;
  without it (`sketch-plain`): unchanged `["sketch-build", "sketch-review"]`; `sketch-build-exec` off-path on
  a `code` run.
- **`catalog_test.exs`** — pin the new `sketch-build-exec` stage (mirror the `sketch-build` pin `:36-46`);
  update the `sketch-build` pin (`subscribes == ["sketch-plain"]`, `:40`).
- **`templates_test.exs`** — bump counts 9 → **10** (`:139`, `:166`); add explicit `sketch_build_exec`
  assertions (`forward_context: {:only, [:forge_session_key]}`, `sandbox: :docker`); do **not** add it to
  `@valid_names` (the 7 public workers — it's composer-private).
- **`doctrine_test.exs`** — the drift test passes only with the 2.3 slice entry; add a
  `for_template("sketch_build_exec")` producer assertion (base + artifacts).
- **`agent/templates_sandbox_test.exs`** — `sketch_build_exec`: `sandbox/1 == :docker`, `external_tools?/1
  == false` (the existing `"docker_stub"` describe `:47-70` proves the policy; this pins the real template).
- **`triage_test.exs`** — add a `"must-execute" → :must_execute` normalization case (the enum isn't pinned
  wholesale, so existing cases don't break).
- **`worker_output_schemas_test.exs`** — a `SketchBuildExec` output-schema smoke (mirrors `SketchReviewer`
  `:170+`); assert its tool list includes `RunCommand` **and** `FetchOutput`, and `SketchBuild`'s includes
  **neither** (idiom: `Keyword.fetch!(module.strategy_opts(), :tools)`, cf.
  `real_tree_capability_test.exs:21`).
- **Front-door launch decision** (`front_door` tests, via the `front_door_composer` + `forge_facade` seams) —
  with `start_session_ready` stubbed to **fail** on a `:must_execute` verdict: outcome `{:plain_degraded,
  …}`, composer seeded `"sketch-plain"` **and *not* `"must-execute"`** (pins no-double-seed), only
  `sketch-build` runs, ack carries the execution-unavailable notice, partial session `stop_session`'d.
  Happy path: `{:exec, …}` seeds `"must-execute"`. **Window 1b:** `start_session_ready` returns a live
  `{:exec, …}` but `create_parent_run`/`ensure_started` stubbed to fail → bounded `{:error, ack}` (no
  fall-through) **and** `Forge.stop_session/2` ran. **Window 2** (already-shipped guard, pin it):
  `validate_sandbox_scope(:docker)` with a dead `forge_session_key` fails closed (errors → terminalizes),
  **no** re-provision.
- **Direct composer-private pins (cheap)** — `sketch_build_exec` *specifically* cannot be spawned
  (`spawn_agent`), handed off (`handoff`), or followed-up (`send_to_agent`) — direct assertions naming the
  template, alongside the generic `:docker` refusal tests Phase 1 added (D6).
- **Teardown phase — every terminal (the headline-gap regression)** — clean converge → session `:completed`
  + `completed_at`, `Forge.get_handle/1` **fails** (microVM gone); **`:not_converged`** (reviewer requested
  changes) → session **`:cancelled`** *and* `get_handle` **fails** — explicitly assert the microVM is **not
  left alive** (this is the leak the review caught); **at least one failure/cancel terminal** (e.g. `:failed`
  or `:abandoned`) → `:cancelled` + child gone; a **failed terminal append** (parent left `:running`) →
  teardown does **NOT** fire (no `complete_session`/`stop_session` recorded — the run is recoverable).
  **Facade-level cleanup failure (composer layer):** with `ForgeStub.complete_session/1` programmed to return
  `{:error, _}` (or raise) — **not** the `:forge_persistence` seam, which only proves the Forge-layer stamp
  fallback — a converged run's terminal stays **`:converged`/`:done`**, never `:terminalize_failed` (the
  composer `best_effort`-swallows the facade error and the teardown result never reaches `notify_payload`).
  Assert against `Persistence.find_session(sid).phase`/`.completed_at`, `Forge.get_handle/1`, the composer
  terminal/notify payload, and `ForgeStub` call records.

### Manual (`:docker_sandbox`-tagged, requires Docker/`sbx`)
A `must-execute` sketch builds + runs a tracer-bullet in a real microVM (model
`docker_integration_test.exs`): (1) network egress is **denied**; (2) `--workdir /proto` lands exec in the
mount (a relative `ls`/`cat` sees the host-written prototype files); (3) **both directions of the `:rw`
mount** — a file **created by container exec** (`… > /proto/out.txt`) is **readable by host file tools**
(`ReadFile`/`PrototypeSummary`) on `.prototypes/<id>/` and removable by cleanup (catches UID/GID / mount
mismatches a stub masks).

---

## Verification

1. **`mix precommit`** — definition of done. The alias (`mix.exs:251`) runs, in order:
   `jidoclaw.compile_check` (no warnings), **`jidoclaw.system_prompt.check`**, **`deps.unlock --unused`**,
   `format --check-formatted`, **`reach.check --arch --smells --strict`** (ExSlop reach/clone — must stay
   **zero**: the `SketchWorker` macro single-sources the two builders with a *literal* tools list, so neither
   the clone nor the macro trips a check; keep any new `get_env`-style seams non-contiguous), `credo --strict`,
   **`dialyzer --format short`**, then the full `test` suite. Three components beyond compile/format/credo/test:
   - **`system_prompt.check`** compares the **main agent's** tool surface to `priv/defaults/system_prompt.md`.
     Phase 2 adds tools only to **worker-private** surfaces (`sketch_build_exec` via its template) and does
     **not** touch `agent/agent.ex` or `core/mcp_server.ex`, so the main-agent surface is unchanged and this
     passes with no prompt edit. (If it flags, a tool leaked onto the main agent — fix *that*, don't edit the
     prompt.)
   - **`dialyzer`** must be clean on the new error channels (`start_session_ready/3`, `complete_session/1`, the
     wake normalizer, the launch-outcome tuples). Watch the Ash.transact gotcha: a custom `{:error, atom}`
     raised *inside* an `Ash.transact` fn is erased from the caller's success-typing — route such a sentinel
     through the success channel and remap in the wrapper (relevant to the `Persistence.complete_session`
     action call).
   - **`deps.unlock --unused`** — no new deps, inert.
   Never pipe precommit through `tail`; build strings via `IO.iodata_to_binary`.
2. **`mix compile`** alone proves the `sketch-build-exec` stage satisfies every `CatalogValidator` invariant
   and that `sketch_build_exec` resolves (the catalog guards `raise` otherwise).
3. **Targeted while iterating:**
   - Plumbing: `mix test test/jido_claw/forge/ test/jido_claw/tools/run_command/`.
   - Routing: `mix test test/jido_claw/route_composer/` (catalog/validator/router/loop/composer-loop).
   - Wiring: `mix test test/jido_claw/doctrine_test.exs test/jido_claw/templates_test.exs
     test/jido_claw/agent/templates_sandbox_test.exs test/jido_claw/triage_test.exs
     test/jido_claw/agent/workers/worker_output_schemas_test.exs`.
4. **Manual** (`mix test --include docker_sandbox`, where Docker/`sbx` is available) — the real exec path,
   per the three-part assertion above. **This is the true production-isolation gate** (precommit only proves
   the no-egress flag is *emitted*): a `sbx` that *rejects* the flag degrades to file-only (safe, surfaced as
   no exec session), but a `sbx` that *silently ignores* `--network none` would fail open — only this test's
   "egress is actually denied" assertion catches that. Must pass before trusting the tier with real `sbx`.

---

## Critical files

| Concern | File |
| --- | --- |
| 1.1 PubSub | `lib/jido_claw/forge/pubsub.ex` (`unsubscribe/1`) |
| 1.2 start-ready | `lib/jido_claw/forge.ex` (+ opt. `forge/ready_start.ex`); model: `memory/consolidator/run_server.ex:442-517` |
| 1.3 complete | `lib/jido_claw/forge.ex`, `forge/harness.ex` (`:complete` self-stop + `maybe_finalize_phase`), `forge/persistence.ex` (`complete_session/1`), `forge/resources/session.ex:104` (`:complete` action) |
| 1.4 wake | `lib/jido_claw/forge.ex` (`wake/2` normalize + fail-closed) |
| 1.5 mounts | `lib/jido_claw/forge/harness.ex:1307-1321` (`build_sandbox_spec`/`merge_resource_mounts`) |
| 1.6 backend | `lib/jido_claw/forge/sandbox/docker.ex` (`build_create_args`/`build_exec_args`/`create_sandbox`) |
| 2.1 macro | `lib/jido_claw/agent/workers/sketch_worker.ex` (new) |
| 2.2 workers | `workers/sketch_build.ex` (refactor), `workers/sketch_build_exec.ex` (new) |
| 2.3 template/doctrine | `lib/jido_claw/agent/templates.ex`, `lib/jido_claw/doctrine.ex` |
| 3 catalog | `lib/jido_claw/route_composer/catalog.ex` (new stage + retarget + `triage.publishes`) |
| 4 triage | `lib/jido_claw/triage/{schema,verdict,prompt}.ex` |
| 5.0 forge seam | `lib/jido_claw/front_door.ex` + `route_composer.ex` (`forge/0` → `:forge_facade` seam) |
| 5 front door | `lib/jido_claw/front_door.ex` (`sketch_scope`/`seed_live`/`composer_context`/`start_composer`) |
| 5.4/5.6 composer | `lib/jido_claw/route_composer/route_composer.ex` (`@persisted_context_keys`, **all** `parent_terminal_notify/4` clauses + `maybe_teardown_forge_session/3`) |
| Test scaffolding | `test/support/forge_stub.ex` (+`start_session_ready/3`, `complete_session/1`, recorders); `test/support/stub_sandbox.ex` if more programmability needed |
| Tests | `route_composer/{composer_loop,catalog,router,loop}_test.exs`; `doctrine_test.exs`; `templates_test.exs`; `agent/templates_sandbox_test.exs`; `triage_test.exs`; `agent/workers/worker_output_schemas_test.exs`; `forge/*` (pubsub/start-ready/complete/wake/mounts); `forge/sandbox/docker_*test.exs`; front-door launch-decision + all-terminal-teardown tests; direct `sketch_build_exec` refusal pins; new `:docker_sandbox` integration test |
