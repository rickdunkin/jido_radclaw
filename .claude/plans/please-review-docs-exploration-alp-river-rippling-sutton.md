# AR-8b — The Sketch Path (implementation plan)

## Context

AR-8 triage classifies every user turn into `talk` / `sketch` / `code` / `system`. Three are real
today; **`sketch` is not**. `Triage.Verdict.composer?/1` is true only for `:code`/`:system`, so
`FrontDoor.decide/2` groups `sketch` with `talk` and returns `{:inline, verdict}` — handing the turn
to the **inline chat agent**, which carries `WriteFile`/`EditFile`/`RunCommand`/`GitCommit` **against
the real working tree**. So "sketch" today is `talk` with a label: no throwaway semantics and — the
real problem — **no isolation**.

This plan makes `sketch` a genuine composer path: a throwaway-prototyping turn that runs in a
**hard-isolated, per-prototype `.prototypes/<id>/` sandbox** via a new `sketch-build` worker, and
**converges trivially** when the worker finishes.

### What changed after design review (why this plan is bigger than "reroot + prompt")

A first draft made isolation a *prompt + `project_dir` reroot*. Review found four ways that leaks,
all now treated as must-fix:

- **[P1a] Remote-scheme escape.** `WriteFile`/`ReadFile`/`EditFile`/`ListDirectory`/`SearchCode`
  accept `github://`/`s3://`/`git://` paths (`resolver.ex` `parse_path/3` clauses at lines 303/318/326),
  which bypass the local jail entirely.
- **[P1b] External-MCP inheritance.** Step/composer workers get external MCP tools attached
  (`agent_runner.ex:67` → `Consumer.modules_for_template/3`), and a server with no `templates:`
  allowlist applies to **all** templates (`server_spec.ex`, `consumer.ex:635-643`). "File-tools-only"
  is not enforced.
- **[P1c] Fail-open on missing `project_dir`.** `resolve_scope/2` falls back to `File.cwd!()`
  (`agent_runner.ex:319`); a sketch run with no `project_dir` would write the **real cwd**.
- **[P2b] Spawnability.** Registering `sketch_build` in `Templates` makes it reachable via
  `spawn_agent` (`spawn_agent.ex:56`), and `ToolContext.child/2` **always forwards the parent's real
  `project_dir`** (it is deliberately *not* policy-strippable — `tool_context.ex:84-88,162-172`).

Plus **[P2a]** `.prototypes/` was shared per-project (overwrite risk; bad for graduation provenance),
and **[P3]** full isolation removes read access to the real tree (noted as a deliberate first-cut
limitation, §Known limitations).

**The fix: isolation is a capability boundary, not a prompt.** One template policy —
`sandbox: :prototype` — enforced structurally at the chokepoints in the table below (MCP attach,
file-scheme resolution, sandbox-root validation, agent instantiation incl. the handoff router,
launch scope). The reroot still happens; it is no longer the *only* thing standing between a sketch
and the real tree.

A second review round further hardened three details, all folded in below: (1) sandbox-root
**validation is realpath/shape-based, not a substring check** — a crafted `.prototypes/../real-dir`
and a planted `.prototypes` **symlink** are both rejected, at creation and re-validated before any
worker runs (`VFS.Sandbox`, §1.3b); (2) the `local_only` rejection is applied to `Resolver.local_path/3`
too (it bypasses `parse_path/3`), §1.3; (3) the composer-private refusal includes the handoff
**router** (`route_with_owner/2` + `fetch_metadata_template/3`), not just the handoff tool, §1.6.

### Scope (confirmed with the user)

- **IN — Phases A + B + D** built on a real capability boundary, to `mix precommit`-green.
- **OUT — Phase C (graduation):** authored as a separate phased design doc `AR-8b-2` (the final
  step of this plan, §10). Cross-run, with open provenance/oscillation-guard questions.
- **OUT — code-exec sketches (Forge Docker, would be `sandbox: :docker`)** and the **light-lens
  `sketch-review`**: documented as follow-ons in `AR-8b-2`. First cut is file-tools-only + no review.

### Naming note

The AR-8b doc calls the composer `JidoClaw.Reasoning.Composer`; the real module is
`JidoClaw.RouteComposer` (`lib/jido_claw/route_composer/`). All cites use the real names.

---

## The isolation model (capability boundary)

A worker is sandboxed iff its **template** declares `sandbox: :prototype`. That single fact drives
the independent, structural enforcements below — no one of which relies on the LLM behaving or on a
prompt:

| Concern | Chokepoint | Effect |
| --- | --- | --- |
| No external MCP tools (P1b) | `MCP.Consumer.modules_for_template/3` via public `Templates.external_tools?/1` | returns `[]` for the template at attach **and** every reconcile tick — the LLM never sees external tools |
| No remote file schemes (P1a) | `VFS.Resolver` `local_only:` opt, threaded by the file tools from a `tool_context[:sandbox]` flag | `github://`/`s3://`/`git://` → `{:error, {:remote_forbidden_in_sandbox, _}}` |
| Capability can't be forgotten | `AgentRunner` stamps `tool_context[:sandbox]` **from the template policy** (canonical, never-strippable key) | every legit composer/step launch carries the flag; nested children inherit it |
| Sandbox root is genuinely under ignored `.prototypes/<uuid>/` (P1, P2a) | `VFS.Sandbox` — symlink-rejecting creation + realpath/shape validation | crafted `..`/symlink paths are rejected at creation **and** re-validated before any worker runs |
| Can't run unsandboxed (P1c/P2b) | `AgentRunner.run/4` validates the scope via `VFS.Sandbox.validate_root/1`; `spawn_agent`/`send_to_agent`/`handoff` tool **and** the handoff **router** refuse sandbox templates | a sandbox template can only run through the front-door composer path that sets up `.prototypes/<id>/` |

The **location** (which `.prototypes/<id>/` dir) is supplied by the front door (it knows
`project_dir`); the **capability** (`sandbox: :prototype` flag + denials) is supplied by the template
policy (it travels everywhere the template goes). Location + capability are independent and both
required; `AgentRunner` refuses to run if they're inconsistent or if the location isn't a validated
sandbox root.

---

## Part 1 — The sandbox capability (foundation)

### 1.1 Template policy — `lib/jido_claw/agent/templates.ex`

Mirror the existing `forward_context`/`require_approval` policy pattern (declare in `@templates`,
hydrate + validate fail-closed in `hydrate_template/1`, expose readers). Add `ensure_sandbox/1` to
the `hydrate_template/1` pipe (line 134):

```elixir
defp ensure_sandbox(%{sandbox: s} = t), do: Map.put(t, :sandbox, validate_sandbox(s, t))
defp ensure_sandbox(t), do: Map.put(t, :sandbox, :none)

defp validate_sandbox(s, _t) when s in [:none, :prototype], do: s
# Fail CLOSED to the most-restrictive value: a malformed *present* value sandboxes harder,
# never weaker (a static-registry typo is caught by that template's tests).
defp validate_sandbox(other, t), do: warn_sandbox(other, t)   # returns :prototype + Logger.warning

# Public readers (mirror require_approval/1). Unknown template (e.g. "main") ⇒ unsandboxed.
def sandbox(name) do
  case get(name) do
    {:ok, %{sandbox: s}} -> s
    _ -> :none
  end
end

@doc "False when the template forbids external (MCP) tools — i.e. is sandboxed."
def external_tools?(name), do: sandbox(name) != :prototype
```

### 1.2 `tool_context` canonical key — `lib/jido_claw/tool_context.ex`

Add `:sandbox` to `@canonical_keys` (line 52-66), documented like the `:sanitize_sensitive_context`
precedent (line 32-37): *canonical, always-forwarded, never policy-strippable, so it propagates to
nested `spawn_agent`/`send_to_agent` children automatically.* This is the only `tool_context` change;
`build/1` then preserves it and `apply_visibility/2` cannot strip it (it isn't in
`@policy_controlled_keys`).

### 1.3 Resolver local-only gate — `lib/jido_claw/vfs/resolver.ex`

`local_path/3` (line 257) calls `resolve_local_path/3` **directly**, bypassing `parse_path/3`, so a
single `parse_path` funnel does **not** cover it (and `ListDirectory`'s local listing uses
`local_path/3`). Add the rejection at **both** entry points via a shared helper:

```elixir
# A funnel above the prefix-matched parse_path clauses (covers read/2, write/3, atomic_write/3, ls/2,
# which all route through parse_path/3) — rename the three remote clauses + local catch-all to
# do_parse_path/3 and add:
defp parse_path(path, opts, mode) do
  if local_only_violation?(path, opts),
    do: {:error, {:remote_forbidden_in_sandbox, path}},
    else: do_parse_path(path, opts, mode)
end

# AND at the top of local_path/3 (the parse_path-bypassing entry):
def local_path(path, opts \\ [], mode \\ :read) when mode in [:read, :write] do
  if local_only_violation?(path, opts) do
    {:error, {:remote_forbidden_in_sandbox, path}}
  else
    case resolve_local_path(path, opts, mode) do
      {:local, lp} -> {:ok, lp}
      {:error, reason} -> {:error, reason}
    end
  end
end

defp local_only_violation?(path, opts), do: Keyword.get(opts, :local_only, false) and remote?(path)
```

`remote?/1` already exists (used at `maybe_ensure_workspace/2:273`, `list_directory.ex:57`). The
`{:error, _}` is already handled by the `with`-pipelines in `read`/`write`/`atomic_write`/`ls`
("never silently fall through to `File.*`", lines 266-270) and by `local_path/3`'s callers. No
signature changes — the opt rides the existing `opts` keyword.

Also **expose the existing private realpath** for the sandbox validator (§1.3b), since it is the
project's tested, depth-capped (`@max_symlink_depth 40`) symlink-resolving walk (`resolver.ex:453-497`).
**Flip the visibility of the existing `defp realpath(path)` clause (line 453) to `def`** — add the
`@doc`/`@spec` and change `defp` → `def`; do **not** add a second `realpath/1` clause (that would be
a duplicate-arity compile error). The `realpath/2` accumulator clauses stay private.

```elixir
@doc "Fully resolve symlinks in `path` (depth-capped). `{:ok, resolved} | {:error, reason}`."
@spec realpath(String.t()) :: {:ok, String.t()} | {:error, term()}
def realpath(path), do: realpath(path, 0)   # was `defp realpath(path)` at resolver.ex:453
```

### 1.3b The sandbox-root validator — `lib/jido_claw/vfs/sandbox.ex` (new)

A single-sourced, unit-tested module owning **safe creation** and **shape/realpath validation** of a
`.prototypes/<uuid>/` root, so neither the front door nor `AgentRunner` re-implements path safety. It
defeats the two concrete attacks the review named — a crafted `.prototypes/../real-dir` and a planted
`.prototypes` **symlink** (which `File.mkdir_p/1` would happily follow):

```elixir
defmodule JidoClaw.VFS.Sandbox do
  @moduledoc "Creation + validation of the throwaway sketch sandbox root `<project>/.prototypes/<uuid>/`."
  alias JidoClaw.VFS.Resolver

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "Create a fresh per-prototype sandbox dir under `base/.prototypes/`, symlink-safe + validated."
  @spec create_prototype_dir(term()) :: {:ok, %{dir: String.t(), id: String.t()}} | {:error, term()}
  def create_prototype_dir(base) when is_binary(base) and base != "" do
    expanded_base = Path.expand(base)
    root = Path.join(expanded_base, ".prototypes")

    with :ok <- ensure_existing_dir(expanded_base),  # base must ALREADY exist (no phantom-project create)
         :ok <- reject_symlink(root),                # reject a planted `.prototypes` symlink
         :ok <- File.mkdir_p(root),
         id = Ash.UUID.generate(),
         dir = Path.join(root, id),
         :ok <- File.mkdir_p(dir),
         :ok <- validate_root(dir) do                # realpath + shape + symlink re-check after creation
      {:ok, %{dir: dir, id: id}}
    end
  end

  def create_prototype_dir(_), do: {:error, :missing_project_dir}

  @doc "Validate an existing path IS a legit `.prototypes/<uuid>/` root (shape + symlink + realpath)."
  @spec validate_root(String.t()) :: :ok | {:error, term()}
  def validate_root(dir) when is_binary(dir) do
    expanded = Path.expand(dir)            # collapses `..` lexically → defeats `.prototypes/../x`
    parent = Path.dirname(expanded)

    with :ok <- ensure(Path.basename(parent) == ".prototypes", :not_under_prototypes),
         :ok <- ensure(Regex.match?(@uuid, Path.basename(expanded)), :child_not_uuid),
         # lstat the parent ITSELF — a `<base>/.prototypes -> /elsewhere/.prototypes` symlink would
         # otherwise pass the realpath-basename check below (target basename is also `.prototypes`).
         :ok <- reject_symlink(parent),
         :ok <- reject_symlink(expanded),
         {:ok, real_dir} <- Resolver.realpath(expanded),
         {:ok, real_parent} <- Resolver.realpath(parent),
         :ok <- ensure(Path.basename(real_parent) == ".prototypes", :symlinked_prototypes),
         :ok <- ensure(under?(real_dir, real_parent), :escapes_prototypes) do
      :ok
    end
  end

  def validate_root(_), do: {:error, :invalid_sandbox_root}

  # ensure_existing_dir/1: File.stat (FOLLOWS symlinks — a legitimately symlinked project root is
  #   fine) → require %File.Stat{type: :directory}, else {:error, :base_not_a_directory}; a missing
  #   base is the rejection that prevents File.mkdir_p/1 from fabricating a phantom project tree.
  # reject_symlink/1: File.lstat (does NOT follow) → {:ok, %{type: :symlink}} ⇒ {:error, :symlinked_prototypes};
  #   a non-symlink (incl. :enoent for a not-yet-created path) ⇒ :ok.
  # ensure/2, under?/2 are trivial helpers (under?/2 mirrors Resolver.under_path?/2).
end
```

The UUID is **generated by us** (`Ash.UUID.generate/0`, confirmed available), so the child basename
can't be attacker-influenced. Three independent layers — lexical shape (`Path.expand` + basename),
`lstat` symlink rejection on the `.prototypes` parent **and** the child, and the realpath
under-parent check — together guarantee writes can only land under the real, ignored
`.prototypes/<uuid>/`, and that a wrong-but-non-empty `base` is rejected rather than fabricated.

### 1.4 File tools thread the flag — `lib/jido_claw/tools/{read_file,write_file,edit_file,search_code,list_directory}.ex`

Each tool already reads `workspace_id`/`project_dir` from `enriched.tool_context` and passes them as
Resolver opts. Add one derived opt from the same context:

```elixir
local_only = get_in(enriched, [:tool_context, :sandbox]) == :prototype
# ... Resolver.write(path, content, workspace_id: ws, project_dir: pd, local_only: local_only)
```

**`ListDirectory` needs an extra guard** (`list_directory.ex:56-62`): its `Resolver.remote?(path)`
branch calls `Resolver.ls(path)` with **no opts**, bypassing the funnel. Gate it directly:

```elixir
defp fetch_entries(path, params, ws_opts) do
  cond do
    Keyword.get(ws_opts, :local_only, false) and Resolver.remote?(path) ->
      {:error, "Cannot list #{path}: remote schemes are forbidden in the sketch sandbox"}
    Resolver.remote?(path) -> list_remote(path)
    true -> list_workspace_or_local(path, params, ws_opts)
  end
end
```

(`ws_opts` gains `local_only:` like the others.)

### 1.5 External-MCP denial — `lib/jido_claw/mcp/consumer.ex`

`modules_for_template/3` (lines 635-643) is the universal chokepoint (attach, fan-out, **and**
reconcile). Short-circuit to `[]` for a sandboxed template. The Consumer already aliases `Templates`
(`consumer.ex:97`) and calls `Templates.get/1` (`consumer.ex:779`):

```elixir
defp modules_for_template(modules, module_templates, template) do
  if is_binary(template) and not Templates.external_tools?(template) do
    []
  else
    Enum.filter(modules, fn mod -> ... end)   # existing body unchanged
  end
end
```

Empty result is already in-contract (registers vacuously `:ok`, `consumer.ex:627-632`). Because this
runs on every reconcile tick, a tool can never be re-added.

### 1.6 Instantiation guards

**Composer/step path — `lib/jido_claw/skills/steps/agent_runner.ex` `run/4` (the only legit path).**
After `Templates.get` resolves the template, (a) validate the sandbox scope and (b) stamp the
capability flag from the policy:

```elixir
with {:ok, template} <- Templates.get(template_name),
     :ok <- validate_sandbox_scope(template, context),          # NEW
     tag = ...,
     scope = resolve_scope(context, tag) |> stamp_sandbox(template),  # NEW
     ...

# A sandbox template MUST run against a real .prototypes root — never the resolve_scope/2
# File.cwd!() fallback (P1c) and never an inherited real project_dir (P2b). Delegate the
# realpath/shape check to the single-sourced validator (§1.3b). Fail closed.
defp validate_sandbox_scope(%{sandbox: :prototype}, context) do
  case context[:project_dir] do
    pd when is_binary(pd) and pd != "" -> JidoClaw.VFS.Sandbox.validate_root(pd)
    _ -> {:error, :sandbox_scope_missing}
  end
end
defp validate_sandbox_scope(_template, _context), do: :ok

defp stamp_sandbox(scope, %{sandbox: s}), do: Map.put(scope, :sandbox, s)
```

`stamp_sandbox` sets the canonical `:sandbox` key from the **template** (not the launch context), so
the capability can't be dropped by persistence or forgotten by a caller; `ToolContext.build` (with
§1.2) carries it onto the worker.

**Swarm/follow-up/handoff paths — refuse sandbox templates (composer-private).** A one-line guard
after each template resolve. Required:

- `spawn_agent.ex` (`:56`, the LLM-exposed swarm tool) — return an error instead of
  `register_spawned_agent/7` when `Map.get(template, :sandbox) == :prototype`.
- `send_to_agent.ex` (`:172`) and `tools/handoff.ex` (`:91`) — same guard.
- **The handoff _router_** `lib/jido_claw/agent/handoff/router.ex` — `tools/handoff.ex` is not the
  only path: a stale or externally-mutated session owner flows through `route_with_owner/2` (`:350`)
  and `fetch_metadata_template/3` (`:272`), both resolving the owner template via `Templates.get/1`.
  A composer-private template must never own a session, so treat `sandbox: :prototype` like a
  stale/unavailable owner (clear + fall back to `main`):

```elixir
# route_with_owner/2 (router.ex:350) — add a clause BEFORE the {:ok, _template} clause:
case Templates.get(template_name) do
  {:ok, %{sandbox: :prototype}} ->
    Logger.warning("[handoff.router] composer-private template '#{template_name}' cannot own a session — clearing")
    HandoffRegistry.clear(ctx.tenant_id, ctx.runtime_session_id)
    clear_stale_metadata(ctx.effective_uuid, ctx.tenant_id, ctx.actor)
    default_tuple(ctx)
  {:ok, _template} -> route_known_template(owner, module, template_name, ctx)
  {:error, _reason} -> ... # existing stale handling
end

# fetch_metadata_template/3 (router.ex:272) — treat a sandbox owner as :stale:
case Templates.get(name) do
  {:ok, %{sandbox: :prototype}} -> :stale
  {:ok, template} -> {:ok, name, template}
  {:error, _} -> :stale
end
```

---

## Part 2 — The sketch path

### 2.1 `composer?/1` — `lib/jido_claw/triage/verdict.ex`

Add `:sketch` (only caller is `front_door.ex` `decide/2`; safe):

```elixir
@doc "True when the verdict routes into the composer (`code`, `system`, or `sketch`)."
@spec composer?(t()) :: boolean()
def composer?(%__MODULE__{path: p}), do: p in [:code, :system, :sketch]
```

### 2.2 The worker — `lib/jido_claw/agent/workers/sketch_build.ex` (new)

Model on `DocsWriter` (`agent/workers/docs_writer.ex`): `use JidoClaw.Agent.Defaults`,
file-tools-only (`ReadFile`, `WriteFile`, `ListDirectory`, `SearchCode` — **no `RunCommand`/git**,
which shell to the host and bypass the VFS jail), `model: :fast`, `max_iterations: 15`. Output schema
mirrors DocsWriter (`status`/`summary`/`files_changed`/`notes` + `artifacts: OutputSchema.artifacts()`)
with **no `signals` field** — its absence makes `DefaultMapper.explicit_signals/1` emit `[]`, which is
what makes convergence trivial.

### 2.3 Register the template — `lib/jido_claw/agent/templates.ex`

```elixir
"sketch_build" => %{
  module: JidoClaw.Agent.Workers.SketchBuild,
  description: "Builds a throwaway prototype in an isolated sandbox (file tools only)",
  model: :fast,
  sandbox: :prototype          # ← drives all four enforcements in Part 1
},
```

`forward_context: :none` may also be set (no reason to widen a sandboxed worker's scope), but
`project_dir` forwards regardless; the real guard is `sandbox: :prototype`.

### 2.4 Catalog stage — `lib/jido_claw/route_composer/catalog.ex`

Add after the template is registered (the compile-time guards at `catalog.ex:179-192` call
`Templates.exists?("sketch_build")` and `CatalogValidator.validate/1` and **raise** on failure):

```elixir
"sketch-build" => %Stage{
  name: "sketch-build",
  unit: {:worker_template, "sketch_build"},
  task:
    "Build a throwaway prototype for the request in the sandbox: a tracer-bullet, scaffold, " <>
      "diagram, or idea sketch. Write files only — do not run commands or touch git.",
  routes: ["sketch"],
  subscribes: ["request-received"],
  input: %{required: ["request"], optional: []},
  output: ["prototype"],
  publishes: ["scope-shift"]
},
```

Validator-clean (`catalog_validator.ex`): `routes ⊆ @paths`; publishes the mandatory `scope-shift`;
`subscribes: ["request-received"]` is the **only** clean trigger (no stage publishes `"sketch"`;
`request-received` is a seed signal) — route-filter (`router.ex` `on_live_path/3`) then drops it on
every non-sketch run; `request` is a seed artifact; worker_template + required input + non-blank task;
no lock; no lens (skips the `clean:/findings:` requirement); no self-dep; still acyclic. Do **not**
subscribe `"sketch"` and do **not** add `"sketch"` to `triage.publishes` — the path topic is seeded
into `live` directly and read only by route-filter.

### 2.5 Front-door sketch path — `lib/jido_claw/front_door.ex`

Three seams in `start_composer/3` / its helpers. Preserve the **P1 safety property**: a sketch run
that can't get a sandbox must route through the existing bounded `{:error, ...}` ack — **never** fall
through to the inline agent (which writes the real tree).

**a. Per-prototype sandbox + hard-fail (P1c, P2a) — `sketch_scope/2` (new).** Fold the context build
into `start_composer`'s existing `with` so a sandbox failure yields the bounded ack:

```elixir
# with {:ok, context, premises_extra} <- prepare_sketch_context(ctx, path), ...
#      live: seed_live(path, verdict), context: context,
#      premises: Map.merge(%{"path" => ..., "est_size" => ...}, premises_extra), ...

# Delegate symlink-safe creation + validation to the single-sourced validator (§1.3b); a missing
# project_dir or a hostile `.prototypes` symlink/shape all surface as {:error, _} → bounded ack
# (NOT pass-through, so the worker can never cwd-fallback onto the real tree).
defp sketch_scope(:sketch, ctx) do
  case JidoClaw.VFS.Sandbox.create_prototype_dir(Map.get(ctx, :project_dir)) do
    {:ok, %{dir: proto, id: id}} ->
      ws = sketch_workspace_id(Map.get(ctx, :workspace_id), id)
      {:ok, {proto, ws}, %{"prototype_id" => id, "prototype_dir" => proto}}

    {:error, reason} ->
      {:error, {:sketch_sandbox_unavailable, reason}}
  end
end

defp sketch_scope(_path, ctx),
  do: {:ok, {Map.get(ctx, :project_dir), Map.get(ctx, :workspace_id)}, %{}}

defp sketch_workspace_id(ws, id) when is_binary(ws) and ws != "", do: ws <> ":proto:" <> id
defp sketch_workspace_id(_ws, id), do: "proto:" <> id
```

The per-prototype `project_dir` (`.prototypes/<id>/`) and matching `workspace_id` are persisted via
the existing `project_dir`/`workspace_id` keys in `@persisted_context_keys` (`route_composer.ex:211-214`),
so the sandbox survives crash recovery. `prototype_id`/`prototype_dir` go into `premises` for Phase C
provenance. The capability flag itself is **not** threaded here — `AgentRunner.stamp_sandbox` derives
it from the template (§1.6), which is strictly more robust.

**b. `seed_live/2`** — sketch omits `plan-needed` (no plan gate; throwaway):

```elixir
defp seed_live(:sketch, verdict), do: Enum.uniq(["request-received", "sketch"] ++ mapped_signals(verdict))
defp seed_live(path, verdict), do: Enum.uniq(["request-received", to_string(path), "plan-needed"] ++ mapped_signals(verdict))
```

**c. Ack clauses** (before the generic `ack_message/4`) + fix the stale `@moduledoc` (lines 9-10):

```elixir
defp ack_message(:sketch, intent, run_id, false),
  do: "Sketching a throwaway prototype in .prototypes/ for: #{preview(intent)} (run #{run_id})."
defp ack_message(:sketch, _intent, run_id, true),
  do: "Sketching a sensitive throwaway prototype in .prototypes/ (run #{run_id})."
```

The existing `{:error, reason}` arm already produces a bounded ack and logs via
`Error.summarize_reason/1`; `{:sketch_sandbox_unavailable, _}` flows through it unchanged.

### 2.6 `.gitignore`

```
# AR-8b sketch path — throwaway prototype sandbox (never committed)
.prototypes/
```

### 2.7 Inline call sites — no code change

`jido_claw.ex` (~272-298) and `cli/repl.ex` (~409-440) already match `{:composer, {_status, resp}}`
and render `resp.message` without invoking the inline agent; sketch now returns `{:composer, {:ok, ack}}`,
handled identically to code/system. Optionally refresh the stale "talk/sketch stay inline" comments.

---

## Test surface (required for precommit-green)

### Existing tests that break (greenfield — update, no compat shim)

- `test/jido_claw/triage_test.exs:118` — flip `refute Verdict.composer?(%Verdict{path: :sketch})` to `assert`.
- `test/jido_claw/front_door_test.exs:121-125` — replace `"sketch routes inline …"` with a
  sketch-**composer** launch test: assert `{:composer, {:ok, %{path: :sketch, parent_run_id: id}}}`,
  reload the parent, assert `config["context"]["project_dir"]` starts with
  `Path.join(ctx.project_dir, ".prototypes")`, `config["context"]["workspace_id"]` contains `":proto:"`,
  the seeded `live` has `"sketch"`+`"request-received"` but **not** `"plan-needed"`,
  `premises["prototype_id"]` is present, and the dir exists. Add a second test: a `ctx` with **no**
  `project_dir` yields `{:composer, {:error, %{path: :sketch}}}` (hard-fail, no inline fall-through).
  (`.prototypes` lands under the test `tmp` dir, cleaned by the existing `on_exit`.)

Grep-confirmed these are the only two `sketch`=inline assertions. `router_test.exs` GAP tests use
membership assertions, not exact-`dropped`-map equality, and `observe_test.exs:140` is over a
synthetic event list — so `sketch-build` newly triggering-then-dropping (`:off_path`) on code/system
composes breaks nothing.

### New tests — capability boundary (Part 1)

- **Templates** (`test/jido_claw/agent/templates_test.exs`): `sandbox("sketch_build") == :prototype`;
  `external_tools?("sketch_build") == false`; `external_tools?("coder") == true`;
  `external_tools?("main") == true`; a malformed `sandbox:` hydrates fail-closed to `:prototype`.
- **Consumer** (`test/jido_claw/mcp/consumer_test.exs`): test through the **public** surface — drive
  `JidoClaw.MCP.ensure_attached/3` (or the Consumer's existing fake-server test seam) with an `:all`
  server and assert a sandboxed template attaches **zero** modules while a normal template attaches
  them. Do **not** reference the private `modules_for_template/3`. (The decision itself is covered by
  the `Templates.external_tools?/1` unit test above.)
- **Sandbox** (`test/jido_claw/vfs/sandbox_test.exs`, new): `create_prototype_dir/1` returns a
  `.prototypes/<uuid>/` dir and an id under an existing base; `nil`/`""` → `{:error, :missing_project_dir}`;
  a **non-existent** base → `{:error, :base_not_a_directory}` **and no directory is created** (the
  phantom-project guard, review P3); a planted `.prototypes` **symlink** → `{:error, :symlinked_prototypes}`
  with the link target left untouched. `validate_root/1` (called standalone, as `AgentRunner` does):
  accepts a real `.prototypes/<uuid>/`; rejects `<base>/.prototypes/../real-dir` (`:not_under_prototypes`),
  a non-UUID child (`:child_not_uuid`), and — critically — a `<base>/.prototypes` that is itself a
  **symlink to another `.prototypes`** (`:symlinked_prototypes`, the realpath-basename-bypass the
  review flagged).
- **Resolver** (`test/jido_claw/vfs/resolver_test.exs`, mirroring the existing remote-recognition +
  `../`-escape tests): `read`/`write`/`ls` **and `local_path/3`** with `local_only: true` reject
  `github://`/`s3://`/`git://` with `{:error, {:remote_forbidden_in_sandbox, _}}`; with
  `local_only: false`/absent they route remotely as today; the local `.prototypes` jail still works.
  `realpath/1` is exercised via the Sandbox tests.
- **File tools**: `WriteFile` with `tool_context[:sandbox] == :prototype` rejects a `github://` path
  and writes a local path jailed under `.prototypes`; `ListDirectory` with the flag rejects a
  `github://` path (the remote-branch guard).
- **tool_context** (`test/jido_claw/tool_context_test.exs`): `:sandbox` survives `build/1` and
  `child/2`, and is not stripped by `forward_context: :none`.
- **AgentRunner** (`test/jido_claw/skills/steps/agent_runner_test.exs`): a `sandbox: :prototype`
  template with a non-`.prototypes` `project_dir` (or nil) returns the setup error and starts no
  worker; with a valid `.prototypes` scope, the worker's `tool_context[:sandbox] == :prototype`
  (assert via the existing scope-capture/stub seam).
- **spawn_agent** (`test/jido_claw/tools/spawn_agent_test.exs`): spawning `"sketch_build"` returns the
  composer-private error and registers no agent.
- **send_to_agent** (`test/jido_claw/tools/send_to_agent_test.exs`): a follow-up targeting an
  already-registered `sandbox: :prototype` agent returns the composer-private error.
- **handoff tool** (`test/jido_claw/tools/handoff_test.exs`): `to_template: "sketch_build"` is
  rejected (not handed off to).
- **handoff router** (`test/jido_claw/agent/handoff/router_test.exs`): a session whose owner /
  `current_agent_template` metadata is a `sandbox: :prototype` template routes to `main` (cleared),
  not into the sandbox worker (covers both `route_with_owner/2` and `fetch_metadata_template/3`).

### New tests — sketch path (Part 2)

- **catalog_test.exs**: pin the stage (`unit`/`routes == ["sketch"]`/`subscribes == ["request-received"]`/
  `lens == nil`/`lock == []`/`"scope-shift" in publishes`).
- **router_test.exs**: `Router.compose_route(Catalog.all(), MapSet.new(["request-received","sketch"]),
  MapSet.new(["request"]), MapSet.new(["triage"]))` → `route == ["sketch-build"]`; planner/implementer/
  fixer/reviewers absent.
- **composer_loop_test.exs**: drive `RouteComposer.run_sync/1` with a stub `sketch_build` template +
  canned output and a sketch seed; assert `terminal == :converged` and `ran == MapSet<["triage","sketch-build"]>`.

Existing infra: `TriageStub` resolves `:sketch` (`triage_stub.ex:40`); `StubWorker` keys canned output
by `tool_context.agent_template`; `:agent_templates_override` registers stub templates (so the
composer-loop test can stub `sketch_build` without `sandbox` enforcement interfering).

---

## Precommit risk checklist

`mix precommit` = `jidoclaw.compile_check` (clean recompile, **empty** warning allowlist) + format +
`reach.check --arch --smells --strict` + `credo --strict` + `dialyzer` + full suite.

- **compile_check:** register the template (§2.3) **before** the catalog stage (§2.4) or the
  compile-time guard raises. Use `use JidoClaw.Agent.Defaults` (Recorder-plugin coverage test). No
  unused bindings in the new `defp` clauses.
- **credo --strict:** new public functions need `@spec` — `Templates.sandbox/1`, `external_tools?/1`,
  `Resolver.realpath/1`, and `VFS.Sandbox.create_prototype_dir/1` + `validate_root/1`.
  AgentRunner/front-door/tool additions are `defp` (no spec burden). No `# Step N:`/`# step …`
  comments (ExSlop EXS3004). Keep `composer_context`'s two-step pipe; call `File.mkdir_p` directly
  (no single-pipe). The new `VFS.Sandbox` `with`-chains use `:ok <- ...` guards, not nested `case`.
  Comments explain *why*, not *what*.
- **dialyzer:** worker schema uses `Zoi.object(...)`; specs use `Zoi.schema()` not `Zoi.t()`.
  `decide/2`/`ack` types already cover `:sketch`. New `:sandbox` opt/keys are plain atoms/maps.
- **reach --smells:** keep `composer_context`'s map shape stable (don't introduce a second
  differently-shaped literal → `fixed_shape_map`). Add no new `rescue` (mkdir is a value via
  `File.mkdir_p/1`; Resolver returns `{:error, _}`). `--arch`: FrontDoor/Catalog/Consumer/Templates/
  Resolver/AgentRunner are unconstrained (only `{:data, :web}` is forbidden).
- **format/test:** `mix format` every touched file; update the two broken tests.

---

## Verification (end-to-end)

Prefer Tidewave (`ToolSearch "select:mcp__tidewave__project_eval,mcp__tidewave__get_logs"`):

1. Force sketch triage (`:triage_impl` → `TriageStub`, canned `:sketch`), build a `ctx` with a real
   `project_dir`, call `FrontDoor.decide("sketch a throwaway rate-limiter prototype", ctx)`. Assert
   `{:composer, {:ok, %{path: :sketch, parent_run_id: id}}}`.
2. `WorkflowRun.by_id(id)` → `config["context"]["project_dir"]` ends in `/.prototypes/<uuid>`,
   `["workspace_id"]` contains `:proto:`; `config["premises"]["prototype_id"]` present.
3. **Capability proofs (the review's asks):** in `project_eval`, build the sketch worker's
   `tool_context` and confirm: `WriteFile` of a `github://…` path returns
   `{:error, {:remote_forbidden_in_sandbox, _}}`; `Templates.external_tools?("sketch_build") == false`;
   `spawn_agent` of `"sketch_build"` returns the composer-private error;
   `VFS.Sandbox.validate_root("<base>/.prototypes/../real")` returns `{:error, :not_under_prototypes}`
   and a planted `.prototypes` symlink is rejected by `create_prototype_dir/1`.
4. With a stub worker (or a real `sketch_build` if an LLM key is set), confirm the parent reaches
   `:completed` (converged), the only dispatched wave is `["sketch-build"]`, the prototype file landed
   under `.prototypes/<id>/`, and `git status --short` shows `.prototypes/` ignored with the rest of
   the tree clean (isolation proof). `get_logs` to watch dispatch + `route_converged`.

Full REPL: a sketch prompt → "Sketching a throwaway prototype in .prototypes/…" ack → file in
`.prototypes/<id>/` → `git status` clean.

Finally **`mix precommit` must pass** — run bare in the background and read the output tail (never pipe
through `tail`, which masks the exit code). Verify any async:false singleton flakes
(MCPServer/Prompt/PipelineStore/MultiSandbox) in isolation, not seed 0, before blaming this change.

---

## Ordered checklist

1. `templates.ex` — `ensure_sandbox/1` + `sandbox/1` + `external_tools?/1` (Part 1.1).
2. `tool_context.ex` — add `:sandbox` to `@canonical_keys` (1.2).
3. `vfs/resolver.ex` — `local_only` guard in the `parse_path/3` funnel **and** `local_path/3`; expose public `realpath/1` (1.3).
4. `vfs/sandbox.ex` (new) — `create_prototype_dir/1` + `validate_root/1` (1.3b).
5. file tools — thread `local_only:`; `list_directory.ex` remote-branch guard (1.4).
6. `mcp/consumer.ex` — `modules_for_template/3` denial via `Templates.external_tools?/1` (1.5).
7. `skills/steps/agent_runner.ex` — `validate_sandbox_scope/2` (→ `Sandbox.validate_root/1`) + `stamp_sandbox/2` (1.6).
8. Refuse sandbox templates: `tools/spawn_agent.ex` + `send_to_agent.ex` + `tools/handoff.ex`, **and** `agent/handoff/router.ex` (`route_with_owner/2` + `fetch_metadata_template/3`) (1.6).
9. `agent/workers/sketch_build.ex` (new) (2.2).
10. `templates.ex` — register `"sketch_build"` with `sandbox: :prototype` (2.3).
11. `route_composer/catalog.ex` — `sketch-build` stage (needs step 10) (2.4).
12. `triage/verdict.ex` — `composer?/1` (2.1).
13. `front_door.ex` — `sketch_scope/2` (→ `Sandbox.create_prototype_dir/1`)/`seed_live/2`/ack/`@moduledoc`, thread through the `with` (2.5).
14. `.gitignore` (2.6).
15. Tests (capability boundary + sketch path); fix the two broken tests.
16. `mix format`; `mix precommit` to green.
17. Author `docs/exploration/alp-river/AR-8b-2-GRADUATION.md` (§10).

---

## §10 — Final deliverable: the graduation design doc (`AR-8b-2`)

Per "no deferrals — break large units into their own phased design doc," author
`docs/exploration/alp-river/AR-8b-2-GRADUATION.md` (a phased design doc, not hand-waving) covering:

- **Phase C1 — Prototype provenance into the graduating run.** When triage re-classifies a later turn
  to `code`/`system` and the prior path was `sketch` with a prototype, carry it into the fresh
  composer seed (the persisted `premises["prototype_id"]`/`["prototype_dir"]` + `metadata["last_triage_path"]`
  are the hooks). Resolve the open form: by-ref vs re-read vs `intent` summary (recommendation: a
  reference/summary; the real run starts fresh against the real tree — the prototype *informs*, it
  does not auto-merge).
- **Phase C2 — Oscillation guard.** Cross-run, so AR-2's within-loop guard doesn't cover it; design a
  front-door/triage-level guard so `sketch ⇄ code` can't thrash new runs.
- **Phase C3 — Retention/cleanup.** Current default: never auto-GC (`.prototypes/` is gitignored).
  Capture when/whether a prototype is GC'd (on graduation / session end / never) as an explicit
  decision, mirroring the `ComposerArtifact` retention note.
- **Follow-on F1 — Light-lens `sketch-review`.** Phase D's richer option: a `sketch-review` stage with
  a correctness/security `lens` gating convergence; must declare `clean:<lens>`+`findings:<lens>`
  (validator inv 8) and emit the reviewer `overall` shape (`DefaultMapper.reviewer_verdict/3`).
- **Follow-on F2 — Code-execution sketch tier (`sandbox: :docker`).** A sketch that must *run* a
  tracer-bullet needs OS isolation (Forge Docker, `forge/sandbox/docker.ex`) since `run_command`
  escapes the VFS jail. The `sandbox` template policy already anticipates this (`:prototype` → file
  jail; `:docker` → Forge). Cover the gate question (network-reachable sandboxed sketch) + the
  `sbx`-CLI/Docker-Desktop prerequisites.
- **Follow-on F3 — Read-only access to the real project (review P3).** First cut is fully isolated
  (no real-tree reads), which keeps the boundary simple but may limit prototype quality. Design a
  safe read-only view (a read-only mount of the real tree, or bounded summaries / dedicated read-only
  tools) while all writes stay in `.prototypes/<id>/`.

## Known limitations (this plan)

- **No real-tree reads (P3):** the sketch sandbox is fully isolated; the worker cannot read the real
  project. Deliberate first-cut safety trade-off — see `AR-8b-2` F3.
- **File-only (no code execution):** `sketch-build` has no `RunCommand`; a sketch can't *run* a
  tracer-bullet. The `sandbox: :docker` tier (`AR-8b-2` F2) lifts this.
