# AR-8b-2 Follow-ons F1 + F3 (+ F2 roadmap)

## Context

AR-8b shipped the **sketch path**: a `sketch` turn launches a `sketch-build` worker in a
hard-isolated `<project>/.prototypes/<uuid>/` sandbox (file tools only), and the composer route
**converges trivially** the instant the worker finishes — there is no review and no real-tree access.
`docs/exploration/alp-river/AR-8b-2-GRADUATION.md` designs the deferred follow-ons. Phase C
(C1/C2/C3) already shipped (commit `40383c2a`). This plan implements:

- **F1 — Light-lens `sketch-review`.** A correctness reviewer runs on the sketch path so a
  genuinely-broken prototype surfaces findings instead of silently converging.
- **F3 — Read-only real-tree access.** Three dedicated read-only tools let a sketch worker be
  *informed* by the real project without being able to *mutate* it (every write still lands in
  `.prototypes/<id>/`).
- **F2 — Code-execution sketch tier (`sandbox: :docker`).** Appended as a **phased roadmap only**:
  it bridges two disconnected execution substrates, adds Forge-session lifecycle, needs a new triage
  signal, and can't be exercised by `mix precommit`. Its own implementation pass later.

**Decisions taken** (planning Q&A): F1 uses a **new `sketch_reviewer`** template (`sandbox: :prototype`,
file tools, no git), **correctness lens only**; F3 uses **dedicated read-only tools** (the VFS dep
can't enforce read-only) including **`list_real_directory`**.

**Corrections incorporated from plan review** (the previous draft got these wrong):
1. The Router does **not** drop `sketch-review` in wave 1 — `drop_unsatisfiable/3` counts artifacts
   produced by in-route producers, so the stage is kept and the data graph orders it into wave 2.
2. A new worker template **must** be wired into `JidoClaw.Doctrine.@template_slices` or the drift
   guard (`doctrine_test.exs:62`) fails.
3. The read-only tools must **reuse the existing read/list/search internals** (so `read_real_file`
   preserves `FilePayloadLimit` + line formatting; `search_real_code`/`list_real_directory` preserve
   their source tools' current behavior), not raw `Resolver` access.
4. Test sweep must include template **counts/names** (`templates_test.exs`), **doctrine** tests, a
   `SketchReviewer` **output-schema** smoke, and a **negative capability** test.

**Greenfield**: no migration/back-compat. Done = `mix precommit` green.

---

## Why these shapes (load-bearing findings)

1. **`prototype` is an artifact, not a signal.** `sketch-build` declares `output: ["prototype"]`
   (`catalog.ex:192`) but publishes only `scope-shift`. `CatalogValidator` invariant 3
   (`catalog_validator.ex:239`) requires every `subscribes` topic to be a seed signal or
   family-published, so the doc's literal `subscribes: ["prototype"]` would **fail at compile time**.
   Fix: `sketch-review` subscribes to the seed signal `request-received` and depends on the
   `prototype` **artifact** via `input.required` (invariant 4: `prototype` is in the output union).

2. **How the two stages sequence (corrected).** On a sketch run with `available: ["request"]`,
   `ran: ["triage"]`, `compose_route/4` (`router.ex:69`) keeps **both** stages: `drop_unsatisfiable/3`
   (`router.ex:164`) builds `produced` from the outputs of *all in-route stages* (`produced_set/2`,
   `router.ex:174`), and `unsatisfiable?/4` (`router.ex:180`) accepts an input present in `available`
   **or** `produced`. `sketch-review`'s `prototype` is satisfied by in-route producer `sketch-build`,
   so it is **not dropped**. `Graph.kahn/2` (`graph.ex`) then orders producer→consumer:
   `route = ["sketch-build", "sketch-review"]`, `waves = [["sketch-build"], ["sketch-review"]]`. The
   loop's `dispatch_cohort/2` (`loop.ex:34`) dispatches only the first non-`ran` wave
   (`["sketch-build"]`); the next tick (prototype now `available`) dispatches `["sketch-review"]`.

3. **Lens-gated convergence is already wired.** `Loop.lenses_clean?/3` (`loop.ex:94`) requires
   `clean:<lens>` live for every `ran` stage carrying a `lens`. Adding `sketch-review`
   (`lens: "correctness"`) flips the sketch path from trivially-clean to gated: approve + no findings →
   `clean:correctness` → `terminal/2` (`loop.ex:82`) `:converged`; request_changes →
   `findings:correctness` → `:not_converged` (findings surfaced, run ends). **No fixer on the sketch
   path** (fixer is `routes: ["code"]`) ⇒ **report-only**, the F1 first-cut recommendation. The
   reviewer `overall`/`findings` output maps via `DefaultMapper.reviewer_verdict/3`
   (`default_mapper.ex:74`) with **no mapper change**.

4. **VFS dep cannot enforce read-only.** `Jido.Shell.VFS.write_file/3` / `Jido.VFS.Adapter.Local.write/4`
   never consult `mount.opts` (zero `read_only` hits in `deps/jido_shell` + `deps/jido_vfs`). Dedicated
   tools with **no write counterpart** make mutation structurally impossible — smaller blast radius
   than a new Resolver gate.

5. **Real project dir needs no new threading.** The sketch sandbox reroots `project_dir` to
   `<real>/.prototypes/<uuid>/` (`front_door.ex:293`) and `Sandbox.validate_root/1` (`sandbox.ex:73`)
   guarantees that shape, so `real_dir == Path.dirname(Path.dirname(project_dir))`, deterministically.

---

## F1 — Light-lens `sketch-review`

### F1.1 New worker `JidoClaw.Agent.Workers.SketchReviewer`
**New file** `lib/jido_claw/agent/workers/sketch_reviewer.ex`, modeled on `workers/reviewer.ex`:
- `name: "jido_claw_sketch_reviewer"`, description geared to reviewing a sandboxed prototype.
- `tools: [ReadFile, ListDirectory, SearchCode]` (work in a `.prototypes/` sandbox) **plus the F3
  read-real tools** (F3.4) — **no** `GitDiff`/`GitStatus` (no git in the sandbox).
- Same reviewer output schema (`overall`/`summary`/`findings`) as `Reviewer` — what
  `DefaultMapper.reviewer_verdict/3` consumes. **Single-source** it: add `reviewer_verdict/0` to
  `JidoClaw.Agent.Workers.OutputSchema` (already used for `OutputSchema.artifacts()`) and have **both**
  `Reviewer` and `SketchReviewer` call it (DRYs the existing reviewer; avoids the ExSlop clone gate).
- `model: :fast`, `max_iterations: 15`, `streaming: false`, `tool_timeout_ms: 30_000`,
  `compaction: [mode: :auto]`.

### F1.2 Register the template
**Edit** `lib/jido_claw/agent/templates.ex` `@templates` (sibling to `sketch_build`):
```elixir
"sketch_reviewer" => %{
  module: JidoClaw.Agent.Workers.SketchReviewer,
  description: "Reviews a throwaway prototype in the sandbox (read-only, file tools)",
  model: :fast,
  forward_context: :none,
  sandbox: :prototype
}
```
`sandbox: :prototype` is already a valid policy and `external_tools?/1` already returns `false` for it.
On a sketch run the composer's `project_dir` is a valid `.prototypes/<uuid>/` root, so
`AgentRunner.validate_sandbox_scope` (`agent_runner.ex:107`) jails the reviewer to the prototype dir.

### F1.3 Doctrine wiring (REQUIRED — was missed)
**Edit** `lib/jido_claw/doctrine.ex` `@template_slices` (line 37): add
```elixir
"sketch_reviewer" => [:base, :reviewer_min]
```
`sketch_reviewer` is a read-only judge, so it reuses the existing `:reviewer_min` slice (like
`reviewer`/`verifier`) — **no new priv file**. Without this, the drift guard
`doctrine_test.exs:62` (`Doctrine.template_names() == Templates.names()`) fails, and the subagent
prompt would carry no doctrine block for the template.

### F1.4 New catalog stage `sketch-review`
**Edit** `lib/jido_claw/route_composer/catalog.ex`, add to `@catalog` right after `sketch-build`:
```elixir
"sketch-review" => %Stage{
  name: "sketch-review",
  unit: {:worker_template, "sketch_reviewer"},
  lens: "correctness",
  task:
    "Review the sandbox prototype for logic and edge-case correctness; " <>
      "flag findings, else emit clean:correctness.",
  routes: ["sketch"],
  subscribes: ["request-received"],
  input: %{required: ["prototype"], optional: []},
  output: ["findings"],
  publishes: ["findings:correctness", "clean:correctness", "scope-shift"]
}
```
Satisfies every validator invariant (routes ⊆ paths; `scope-shift` published; `request-received` is a
seed signal; `prototype` in output union; `task` present; no self-dep; `emit: :default` + `lens`
declares **both** `clean:correctness` and `findings:correctness`; data graph acyclic). The compile-time
guards (`catalog.ex:197-210`) pass.

### F1.5 Tests (F1)
- **`composer_loop_test.exs`** — **UPDATE** the AR-8b sketch test (~133-170): it currently stubs only
  `sketch_build` and asserts `ran == MapSet.new(["triage", "sketch-build"])` + `:converged` — this
  **breaks**. Stub `sketch_reviewer` too; add two cases: (a) `overall: :approve` no findings → `ran`
  also has `sketch-review`, `clean:correctness` live, `:converged`, history shows two dispatches
  `["sketch-build"]` then `["sketch-review"]`; (b) `overall: :request_changes` + a finding →
  `findings:correctness` live, `clean:correctness` not live, `:not_converged`, findings artifact
  present. Reuse `TestFixtures.phase1_clean_reviewer/0` / `phase1_findings_reviewer/0`.
- **`router_test.exs`** — **UPDATE GAP-5** (~398-412): with `available: ["request"]`, `ran: ["triage"]`,
  assert `res.route == ["sketch-build", "sketch-review"]` **and**
  `res.waves == [["sketch-build"], ["sketch-review"]]` (rename the test — it no longer composes to a
  single stage). Add a `code`-run assertion that `sketch-review` is off-path.
- **`catalog_test.exs`** — pin the `sketch-review` stage (mirror the `sketch-build` pin): `lens`,
  `routes`, `subscribes`, `input`, `publishes`.
- **`loop_test.exs`** — a `lenses_clean?/3` case with a sketch-review-shaped lens stage in `ran`:
  clean present → `:converged`; absent → `:not_converged`.
- **`templates_test.exs`** — bump the **direct** count assertions (`map_size(Templates.list()) == 8`
  ~138, "exactly 8 names" ~164) → **9** and the comment. Do **NOT** add `sketch_reviewer` to
  `@valid_names` (line 8): that list is the 7 **public** workers, looped at lines 210/238 asserting
  `forward_context: :public` / `require_approval: []` — `sketch_reviewer` is `forward_context: :none`
  and would fail there. Instead follow the existing `sketch_build` pattern (also excluded from
  `@valid_names`): add **explicit** assertions for `sketch_reviewer` — `forward_context: :none`,
  `sandbox: :prototype`. (Optionally split `@valid_names`→`@general_names`/`@all_names` if cleaner.)
- **`templates_sandbox_test.exs`** — `sketch_reviewer`: `sandbox/1 == :prototype`,
  `external_tools?/1 == false`.
- **`doctrine_test.exs`** — the drift test now passes only with F1.3; add a `for_template("sketch_reviewer")`
  assertion (`=~ "Review discipline"`, `refute =~ "Runtime artifacts"`).
- **SketchReviewer output-schema smoke** — a small worker test that the `overall`/`summary`/`findings`
  schema validates a sample reviewer verdict (covers the shared `OutputSchema.reviewer_verdict/0`).

---

## F3 — Read-only real-tree access (three dedicated tools)

### F3.1 `Sandbox.real_root/1` (single-source the derivation)
**Edit** `lib/jido_claw/vfs/sandbox.ex`: add public `real_root/1` that takes a sandbox `project_dir`,
runs the existing `validate_root/1` (rejects anything not a real `.prototypes/<uuid>/` root, incl.
symlink escapes), and returns `{:ok, Path.dirname(Path.dirname(expanded))}` (the real base) or
`{:error, reason}`.

### F3.2 Shared real-tree opts + reused IO (payload-limit parity)
**New file** `lib/jido_claw/tools/real_tree.ex` (`JidoClaw.Tools.RealTree`):
- `resolver_opts(tool_context)` — fail **closed** unless `tool_context[:sandbox] == :prototype`;
  derive `real_dir` via `Sandbox.real_root/1`; return
  `{:ok, [project_dir: real_dir, local_only: true, workspace_id: nil]}` (`local_only: true` forbids
  remote schemes — local real tree only; `project_dir: real_dir` jails reads via the Resolver's
  existing project jail).

**Reuse, do not re-implement, the read/list/search internals** (review point: a thin `Resolver.read`
wrapper would bypass `FilePayloadLimit` + line numbering). Factor the existing bodies into shared
**pure** functions (taking `(path, opts, …)` and returning `{:ok, result} | {:error, _}`) that both
surfaces call, parameterized only by the opts source:
- `read_file.ex` — extract its `validate_read → read_with_content_cap → number-lines` core to a shared
  pure function (e.g. `ReadFile.read_numbered/4`); `read_file` calls it with `Sandbox.resolver_opts`,
  `read_real_file` with `RealTree.resolver_opts`.
- `search_code.ex` — extract the recursive `search_path/4` core similarly. **Note:** `search_code`
  reads via `Resolver.read/2` **without** a `FilePayloadLimit` cap today (`search_code.ex:95`); the
  shared core preserves that (adding a cap would change existing `search_code` behavior — out of
  scope), so `search_real_code` is uncapped, matching its source.
- `list_directory.ex` — extract the workspace/local listing core (its remote branch is already gated
  by `local_only`).

**Keep the shared functions pure, below the action wrapper.** Each real-tree tool owns its **own**
`MCPScope.wrap(:<own_name>, …)` and opts derivation, then calls the shared pure core — the shared
function must **not** call `MCPScope.wrap(:read_file, …)` or `ReadFile.run/2`. The `Tools.Action`
wrapper (`tools/action.ex:47`) already owns scope-lifting, approval, redaction, shaping, and the
real tool name, so wrapping under each tool's own name keeps transcripts/shaping attributed to
`read_real_file`/`search_real_code`/`list_real_directory`. Net effect: `read_real_file` preserves
`FilePayloadLimit` + line formatting and the other two preserve their source tools' current
behavior, *and* the ExSlop clone count stays at zero.

### F3.3 The three tools
**New files**, each `use JidoClaw.Tools.Action` (full ToolApproval→redact→shape→cap pipeline), calling
`RealTree.resolver_opts/1` then the shared IO. **No write counterpart exists**, so mutation is
structurally impossible. Descriptions state clearly these read the **real project tree, read-only**:
- `lib/jido_claw/tools/read_real_file.ex` — `read_real_file`
- `lib/jido_claw/tools/search_real_code.ex` — `search_real_code`
- `lib/jido_claw/tools/list_real_directory.ex` — `list_real_directory`

### F3.4 Wire into the sketch workers (worker-private)
Add `ReadRealFile`, `SearchRealCode`, `ListRealDirectory` to the `tools:` of
`workers/sketch_build.ex` **and** the new `SketchReviewer`. **Do NOT** add them to `agent/agent.ex`
(main agent) or `core/mcp_server.ex` (MCP surface) — tools are registered explicitly per-surface
(confirmed: no auto-registration), so omitting them there keeps them worker-private; the fail-closed
`sandbox == :prototype` check makes them inert anywhere else.

### F3.5 Tests (F3)
- **New** `read_real_file_test.exs`, `search_real_code_test.exs`, `list_real_directory_test.exs` (mirror
  the existing tools' "AR-8b sketch jail" blocks). Each: in a real-tree-with-`.prototypes/<uuid>/`
  fixture, the tool **reads** a file/dir in the real tree (two levels up from the sandbox); **fails
  closed** when `sandbox != :prototype`; is **jailed** to the real root (traversal/abs-escape rejected);
  **forbids** remote schemes; and there is **no** write/edit counterpart. The oversized-file
  (`FilePayloadLimit`) rejection assertion applies to **`read_real_file` only** — `search_real_code`
  and `list_real_directory` mirror their (uncapped) source tools, so don't assert a size cap there.
- **New negative capability test** — the three modules are present in `SketchBuild` + `SketchReviewer`
  tool lists and **absent** from the main agent (`Agent` default tool list) and `mcp_server.ex`'s
  exposed tools.
- **`sandbox_test.exs`** — `real_root/1`: derives the real base from a valid prototype dir; fails
  closed on a non-prototype / symlink-escaping path.

---

## F2 — `sandbox: :docker` exec tier: phased roadmap (NOT implemented this pass)

Central gap: `RunCommand → Shell.SessionManager` (host/vfs/ssh) and the `Forge`/`Forge.Sandbox.Docker`
microVM substrate are **fully disconnected** — nothing routes a tool command into a Forge sandbox.

- **P1 — Policy tier + type/spec drift.** Add `:docker` to `Templates.validate_sandbox/2`
  (`templates.ex:253`); broaden `external_tools?/1` (`templates.ex:178`) to `not in [:prototype, :docker]`
  (it hard-codes `!= :prototype` today, so `:docker` would wrongly enable external MCP tools); update
  the `Templates.sandbox/1` `@spec` (`:none | :prototype` → `+ :docker`) and the `ToolContext`
  `:sandbox` doc/type (`tool_context.ex:38`); add a `:docker` branch to `Sandbox.resolver_opts/1`
  (`sandbox.ex:106`) and `AgentRunner.validate_sandbox_scope/2` (`agent_runner.ex:107`) — the latter
  must assert a **Forge sandbox session**, not a `.prototypes/` dir. (`stamp_sandbox/2` passes the atom
  through unchanged.)
- **P2 — RunCommand↔Forge bridge + error normalization** (the hard part). Route
  `tool_context[:sandbox] == :docker` to `Forge.exec/3` (`forge.ex:68`) /
  `Forge.Sandbox.Docker.exec/3` instead of `SessionManager.run/4`. **Hard-fail** (never host fallback)
  when sbx is absent — but note missing sbx surfaces **two ways**: `Docker.create/1` returns
  `{:error, :sbx_not_found}` *and* `Docker.exec` can return command output `{"sbx: command not found", 127}`
  (`docker.ex:305-341`); the bridge must normalize the exit-127 case into a tool error, not pass it
  back as ordinary output.
- **P3 — Forge-session lifecycle** tied to the durable composer run: who creates the microVM
  (`front_door.ex:293` `sketch_scope/2`, extended), id carried via `tool_context[:forge_session_key]`
  (already a preserved key), teardown via `Forge.stop_session/2`, surviving composer restarts.
- **P4 — File-tools-in-microVM semantics.** Resolve whether file tools operate on the host-mounted
  Forge `workspace_dir` (one shared tree for file tools + `RunCommand`) or route through Forge.
- **P5 — Triage "must-execute" signal.** None exists (`significant-build` means something else). Add a
  verdict signal across `triage/verdict.ex:56`, `triage/prompt.ex:63`, `front_door.ex:104`; a new
  `sketch-build-exec` stage (`routes: ["sketch"]`) is selected over file-only `sketch-build`.
- **P6 — Worker + tier.** `sketch_build_exec` worker (`sandbox: :docker`, `RunCommand` bound to the
  Forge runner + jailed file tools) — and its own Doctrine `@template_slices` entry.
- **Testing constraint.** Real Docker is excluded from `mix precommit` (`:docker_sandbox` tag). Drive
  the bridge with `test/support/stub_sandbox.ex` + `Application.put_env(:jido_claw, :forge_sandbox, …)`;
  the real path stays integration-tagged.

---

## Known limitation (note in code, not blocking)

The read-real tools can read sensitive files in the real tree (e.g. `.env`), bounded by: no write
counterpart, no network egress (remote schemes forbidden, writes jailed to `.prototypes/`), and the
`OutputRedaction` pipeline redacting secrets in tool output. Path-filtering the real tree is a
reasonable future hardening; out of scope here.

---

## Verification

1. **`mix precommit`** — definition of done. Runs `jidoclaw.compile_check` (no warnings),
   `format --check-formatted`, credo strict, the ExSlop reach/clone check (zero — see the
   single-source notes in F1.1 / F3.2), and the full suite. Never pipe precommit through `tail`; build
   strings via `IO.iodata_to_binary`.
2. **Targeted** while iterating:
   - `mix test test/jido_claw/route_composer/` (catalog/validator/loop/router/composer-loop — F1).
   - `mix test test/jido_claw/doctrine_test.exs test/jido_claw/templates_test.exs test/jido_claw/agent/templates_sandbox_test.exs`.
   - `mix test test/jido_claw/tools/read_real_file_test.exs test/jido_claw/tools/search_real_code_test.exs test/jido_claw/tools/list_real_directory_test.exs`.
   - `mix test test/jido_claw/vfs/sandbox_test.exs`.
3. **`mix compile`** alone proves the `sketch-review` stage satisfies every `CatalogValidator`
   invariant and that `sketch_reviewer` resolves (catalog guards `raise` otherwise).
4. **Manual end-to-end (Tidewave `project_eval`)**: a stubbed clean reviewer → `:converged` +
   `clean:correctness`; a stubbed request_changes reviewer → `:not_converged` + `findings:correctness`.
   Confirm a `read_real_file` call from a sketch worker reads the real tree while no write tool targets
   it.

## Critical files

| Concern | File |
| --- | --- |
| F1 worker | `lib/jido_claw/agent/workers/sketch_reviewer.ex` (new); `.../reviewer.ex` + `.../output_schema.ex` (add `reviewer_verdict/0`) |
| F1 template | `lib/jido_claw/agent/templates.ex` |
| F1 doctrine | `lib/jido_claw/doctrine.ex` (`@template_slices`) |
| F1 stage | `lib/jido_claw/route_composer/catalog.ex` |
| F1 convergence (no change) | `route_composer/{loop,router,graph}.ex`, `.../emit/default_mapper.ex` |
| F3 derivation | `lib/jido_claw/vfs/sandbox.ex` (`real_root/1`) |
| F3 shared IO | `lib/jido_claw/tools/real_tree.ex` (new) + extracted cores in `read_file.ex` / `search_code.ex` / `list_directory.ex` |
| F3 tools | `lib/jido_claw/tools/{read_real_file,search_real_code,list_real_directory}.ex` (new) |
| F3 wiring (worker-private) | `workers/sketch_build.ex` + new `sketch_reviewer.ex`; **not** `agent/agent.ex` / `core/mcp_server.ex` |
| Tests | `route_composer/{composer_loop,catalog,router,loop}_test.exs`; `doctrine_test.exs`; `templates_test.exs`; `agent/templates_sandbox_test.exs`; `tools/*real*_test.exs` + negative-capability test; `vfs/sandbox_test.exs` |
