# Resolve AR-8b sketch-path code-review findings (P2 + P3)

## Context

The AR-8b "sketch path" (plan `.claude/plans/please-review-docs-exploration-alp-river-rippling-sutton.md`)
shipped a **capability boundary** for sandboxed sketch workers: a `sandbox: :prototype` template runs
jailed under `<project>/.prototypes/<uuid>/`, enforced structurally (not by prompt). A code review of the
unstaged implementation found two holes in that boundary. **Both are validated against the current code**;
this plan fails closed on both, to `mix precommit`-green.

- **P2 — file tools fail OPEN to the real working tree.** Every sandbox-aware file tool computes
  `project_dir = get_in(enriched, [:tool_context, :project_dir]) || File.cwd!()` and sets `local_only`
  independently from `tool_context[:sandbox]`. When a context carries `sandbox: :prototype` **but no
  `project_dir`**, the tool silently uses the real cwd — and `local_only: true` only rejects *remote*
  schemes (`github://`/`s3://`/`git://`), never local cwd access. Confirmed via Tidewave:
  `ReadFile.run(%{path: "mix.exs"}, %{tool_context: %{sandbox: :prototype}})` returns the repo's `mix.exs`.
  The review named `read_file.ex:52` and `write_file.ex:45`, but the **identical** pattern is in
  `edit_file.ex:50`, `search_code.ex:66`, and `list_directory.ex:49`. It is one bug class in five places —
  fixing only the two named tools leaves three known-identical escapes (edit/search/list) open, so the fix
  covers **all five** (the boundary is all-or-nothing). The legit sketch flow is unaffected: the front door
  creates a real `.prototypes/<id>/` and `AgentRunner` already validates it, so a sketch worker's
  `tool_context.project_dir` is always a valid sandbox root.

- **P3 — `VFS.Sandbox.validate_root/1` accepts a non-directory.** `validate_root/1` (`sandbox.ex:63`) checks
  basename shape, `lstat` symlink rejection, and a realpath-under-parent walk, but **never checks the path is
  a directory**. A regular file named `.prototypes/<uuid>` (valid UUID, not a symlink) passes every check,
  because `reject_symlink/1` only rejects symlinks and `Resolver.realpath/1` happily resolves an *existing*
  file. Confirmed: `validate_root(<a regular file>)` returns `:ok`. Effect: `AgentRunner` would start a sketch
  worker after the sandbox dir was replaced by a file, instead of failing setup. (A *non-existent* path is
  **not** the hole — `realpath/1` already returns `{:error, :enoent}` for it today; only the regular-file
  case slips through.)

---

## Fix 1 — P3: directory check in `validate_root/1`

**`lib/jido_claw/vfs/sandbox.ex`**

The base check and the sandbox-child check have **different** symlink invariants, so keep them as two
helpers (do not merge into one `File.stat` helper):

- **Base** (`ensure_existing_dir/1`, `sandbox.ex:86`) stays **unchanged**: `File.stat` *follows* symlinks on
  purpose — a legitimately symlinked project root is fine; it only rejects a *missing* base.
- **Sandbox child** (new `ensure_real_directory/1`) uses `File.lstat` and requires a real directory —
  matching the "no symlink at the sandbox root, and it must actually *be* a directory" invariant in one
  self-contained check. It **replaces** the child's `reject_symlink(expanded)` line in `validate_root/1`: an
  `lstat`-dir check subsumes symlink rejection (a symlink's type is `:symlink`, never `:directory`) and stays
  correct even if the explicit child `reject_symlink` were ever removed:

```elixir
# validate_root/1 with-chain — REPLACE `:ok <- reject_symlink(expanded)` with:
     :ok <- ensure_real_directory(expanded),   # review P3: a real dir, never a file/symlink/missing
     {:ok, real_dir} <- Resolver.realpath(expanded),
     ...

# lstat does NOT follow: a symlink → :symlinked_prototypes (preserves the prior reason for a symlinked
# child); a regular file or a missing path → :not_a_directory (the review P3 fix).
defp ensure_real_directory(path) do
  case File.lstat(path) do
    {:ok, %File.Stat{type: :directory}} -> :ok
    {:ok, %File.Stat{type: :symlink}} -> {:error, :symlinked_prototypes}
    _ -> {:error, :not_a_directory}
  end
end
```

`reject_symlink/1` is still used for the `.prototypes` **parent** (and in `create_prototype_dir/1`), so it
stays; `ensure_existing_dir/1` and `create_prototype_dir/1` are untouched. A non-existent child already fails
today (`Resolver.realpath/1` → `{:error, :enoent}`); after this change it fails earlier with the clearer
`:not_a_directory`. All three `validate_root` callers (`create_prototype_dir/1` post-`mkdir_p`,
`AgentRunner.validate_sandbox_scope/2`, the new `resolver_opts/1`) operate on real on-disk dirs in the legit
flow, so nothing legitimate regresses.

## Fix 2 — P2: fail-closed file-tool scope (one shared helper + five tools)

**New `JidoClaw.VFS.Sandbox.resolver_opts/1`** — single-source the tool→Resolver opts derivation, including
the fail-closed sandbox decision. This is the natural third consumer of the module whose stated job is to
single-source sketch path-safety (front door creates, `AgentRunner` re-validates, file tools now derive
opts):

```elixir
@doc """
Derive `Resolver` opts (`workspace_id`/`project_dir`/`local_only`) from a tool's `tool_context`.

Fails CLOSED for a `sandbox: :prototype` context: a sketch tool call MUST carry a `project_dir` that
`validate_root/1` accepts — never the `File.cwd!()` fallback (review P2). Non-sandbox contexts keep the
existing `project_dir || File.cwd!()` default.
"""
@spec resolver_opts(map() | nil) :: {:ok, keyword()} | {:error, term()}
def resolver_opts(tool_context) when is_map(tool_context) do
  workspace_id = Map.get(tool_context, :workspace_id)

  case Map.get(tool_context, :sandbox) do
    :prototype -> sandbox_resolver_opts(workspace_id, Map.get(tool_context, :project_dir))
    _ -> {:ok, [workspace_id: workspace_id, project_dir: Map.get(tool_context, :project_dir) || File.cwd!(), local_only: false]}
  end
end

def resolver_opts(_), do: resolver_opts(%{})

defp sandbox_resolver_opts(workspace_id, project_dir) when is_binary(project_dir) and project_dir != "" do
  case validate_root(project_dir) do
    :ok -> {:ok, [workspace_id: workspace_id, project_dir: project_dir, local_only: true]}
    # inspect/1, not raw interpolation: validate_root/1 is specced term(), so a tuple reason
    # (e.g. realpath's) would raise under `#{...}`.
    {:error, reason} -> {:error, "sketch sandbox scope invalid (#{inspect(reason)}): project_dir is not a validated .prototypes/<uuid>/ root"}
  end
end

defp sandbox_resolver_opts(_workspace_id, _project_dir),
  do: {:error, "sketch sandbox scope missing: a sandboxed tool call requires a validated .prototypes/<uuid>/ project_dir"}
```

Error is a **string** (matches the four string-erroring file tools; normalizes to a clean `%{message: ...}`),
with the `validate_root` reason wrapped via `inspect/1`. The non-sandbox branch produces a keyword list
byte-identical to what every tool builds today, so all existing non-sandbox tests are unaffected.

**Thread it through all five tools** — replace the `project_dir || File.cwd!()` + `local_only = ... == :prototype`
lines with the helper, adding `alias JidoClaw.VFS.Sandbox`:

- `lib/jido_claw/tools/read_file.ex` (`do_read/5`), `write_file.ex` (the `MCPScope.wrap` body),
  `edit_file.ex` (`edit_with_context/4`): prepend `{:ok, opts} <- Sandbox.resolver_opts(get_in(enriched, [:tool_context]))`
  to the existing `with`; the `{:error, _}` propagates (no `else` needed — read/write/edit already let
  resolver errors flow out).
- `lib/jido_claw/tools/search_code.ex` (`run/2`): add `{:ok, opts} <- Sandbox.resolver_opts(get_in(enriched, [:tool_context]))`
  as the first `with` clause, pass `opts` to `search_path`, and **delete** the private `resolver_opts/1`
  (lines 63-69). Its existing `else` already maps `{:error, binary}`/other.
- `lib/jido_claw/tools/list_directory.ex` (`do_list/2`): `case Sandbox.resolver_opts(get_in(context, [:tool_context]))`
  → `{:ok, ws_opts}` runs `fetch_entries`; `{:error, message}` returns it directly (the existing
  remote-branch guard in `fetch_entries/3` still gates `github://` once `local_only: true` is set).

After the fix, the reviewer's repro fails closed: `ReadFile.run(%{path: "mix.exs"}, %{tool_context: %{sandbox: :prototype}})`
returns `{:error, _}` instead of the repo's `mix.exs`.

---

## Tests (precommit-green)

### Update existing tests that the fail-closed change breaks (greenfield — no compat shim)

The 4 existing AR-8b sketch-jail tests set `project_dir: dir` (a plain tmp dir). Under fail-closed,
`validate_root(dir)` fails, so they must use a **real** sandbox root created with
`JidoClaw.VFS.Sandbox.create_prototype_dir/1` (then the `github://` test still hits
`remote_forbidden_in_sandbox` via `local_only`, and the write/list test still works jailed under the root):

- `test/jido_claw/tools/write_file_test.exs:183-202` (2 tests) — create `{:ok, %{dir: proto}} = Sandbox.create_prototype_dir(dir)`, use `project_dir: proto`, write under `proto`.
- `test/jido_claw/tools/list_directory_test.exs:232-249` (2 tests) — same.

### New tests — P3 (`test/jido_claw/vfs/sandbox_test.exs`, under the existing `validate_root/1` describe)

- A regular **file** at `<base>/.prototypes/<uuid>` (write a file, valid UUID basename) → `{:error, :not_a_directory}` (the confirmed hole).
- A **non-existent** `<base>/.prototypes/<uuid>` (parent dir exists, child absent) → `{:error, :not_a_directory}` (normalized from today's `:enoent`; documents the missing-child rejection).

### New tests — P2 (fail-closed file tools)

Add a "sketch jail fails closed" describe to `read_file_test.exs`, `write_file_test.exs`, `edit_file_test.exs`,
`search_code_test.exs`, `list_directory_test.exs`. For each, two cases:

- `sandbox: :prototype` with **no** `project_dir` → `{:error, _}`. Prove no real-tree access per tool
  **without touching real repo files**:
  - `read_file`: the review's exact repro — `%{path: "mix.exs"}` must return `{:error, _}`, not repo content.
  - `write_file`: a unique sentinel path under `File.cwd!()` → `{:error, _}` **and** `refute File.exists?(sentinel)` (cleaned in `on_exit`).
  - `edit_file`: create a unique sentinel file under `File.cwd!()` with known content, attempt the edit under the sandbox context, assert `{:error, _}`, and assert `File.read!(sentinel)` is **unchanged** before cleanup.
  - `search_code` / `list_directory`: `{:error, _}` (no cwd search/listing).
- `sandbox: :prototype` with a **non-`.prototypes`** `project_dir` (a plain tmp dir) → `{:error, _}`.

Keep an existing/added "valid sandbox root still works" case per tool (writes/reads jailed under a
`create_prototype_dir/1` root) so the happy path stays covered.

(`AgentRunner`'s sandbox-scope tests at `agent_runner_test.exs:189-248` already create a real dir via
`create_prototype_dir/1` and assert `not_under_prototypes`/`sandbox_scope_missing` for bad scopes — they
pass unchanged under the directory check.)

---

## Precommit checklist

`mix precommit` = `jidoclaw.compile_check` (clean recompile, empty warning allowlist) + format +
`reach.check --arch --smells --strict` + `credo --strict` + `dialyzer` + full suite.

- **credo --strict / specs:** the one new **public** fn `VFS.Sandbox.resolver_opts/1` needs `@doc` + `@spec`
  (`map() | nil :: {:ok, keyword()} | {:error, term()}`). `ensure_real_directory/1`, `sandbox_resolver_opts/2`
  are `defp` (no spec). Tool edits are `defp`/inline (no spec burden).
- **ExSlop:** no comment line may begin with the word "step" (EXS3004). Comments explain *why*.
- **reach --smells:** helper returns keyword lists, not map literals (no `fixed_shape_map`); no new `rescue`
  (`File.stat`/`validate_root` return values). FrontDoor/Resolver/Sandbox/tools are arch-unconstrained.
- **compile/format:** removing `search_code`'s private `resolver_opts/1` and the inline opts in the other
  tools leaves no unused bindings; keep `alias JidoClaw.VFS.Resolver` (still used) and add
  `alias JidoClaw.VFS.Sandbox`. `mix format` every touched file.

## Verification (Tidewave: `ToolSearch "select:mcp__tidewave__project_eval"`)

1. **P2 closed:** `ReadFile.run(%{path: "mix.exs"}, %{tool_context: %{sandbox: :prototype}})` → `{:error, _}`
   (was the repo's `mix.exs`); same for `WriteFile`/`EditFile`/`SearchCode`/`ListDirectory`. With a real
   `create_prototype_dir/1` root as `project_dir`, the tools work jailed; `github://` still →
   `remote_forbidden_in_sandbox`.
2. **P3 closed:** create `.prototypes/<uuid>` as a regular file → `Sandbox.validate_root/1` →
   `{:error, :not_a_directory}`; a real dir still → `:ok`.
3. **No legit regression:** `AgentRunner.run("sketch_stub", ...)` with a real `.prototypes` scope still
   starts the worker and stamps `tool_context[:sandbox] == :prototype`.
4. **`mix precommit` must pass** — run bare in the background and read the output tail (never pipe through
   `tail`, which masks the exit code). Verify any async:false singleton flakes
   (MCPServer/Prompt/PipelineStore/MultiSandbox) in isolation, not seed 0, before blaming this change.

## Ordered checklist

1. `vfs/sandbox.ex` — add `ensure_real_directory/1` (`File.lstat`) and use it in `validate_root/1` in place
   of the child `reject_symlink(expanded)` (keep `ensure_existing_dir/1` + `reject_symlink/1` as-is); add
   public `resolver_opts/1` + private `sandbox_resolver_opts/2` (Fixes 1 + 2).
2. Thread `Sandbox.resolver_opts/1` through `read_file.ex`, `write_file.ex`, `edit_file.ex`,
   `search_code.ex`, `list_directory.ex` (remove `|| File.cwd!()` + inline `local_only`).
3. Update the 4 broken sketch-jail tests (`write_file_test.exs`, `list_directory_test.exs`) to a real root.
4. Add P3 tests (`sandbox_test.exs`) + P2 fail-closed tests (all five tool test files).
5. `mix format`; `mix precommit` to green.
