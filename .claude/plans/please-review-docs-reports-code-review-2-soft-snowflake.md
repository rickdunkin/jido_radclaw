# Code review next batch: M3 + M4 + M5/L7

## Context

All 16 HIGH findings in `docs/reports/code-review-2026-06-10.md` are fixed. The remaining open work is MEDIUMs (M3–M18 minus M1/M2) and most LOWs. This batch picks the three clusters that make the most sense next:

- **M3** (Forge Docker writes cleartext secrets to host disk) + **M4** (trace sanitizer misses content-bearing keys) — these **complete the secrets/redaction theme** the last two fix batches (H7+H8+H9+M1+M2) worked through. M3 is the most severe open finding: resolved vault secrets land in `/tmp/jidoclaw_forge/<sandbox>/.forge_env` world-readable, with no reaping on crash — the same class as the fixed H7.
- **M5 + L7** (memory duplicate-key write silently drops the newer value; brittle `inspect`-substring error classifier) — the last open member of the review's "best-effort paths that aren't as safe as their docs claim" pattern that affects normal operation (H11 ✅, M5 ⬅ this, M15 stays open — it's masked by stubs today). L7 must ship with M5 because the brittle classifier would silently defeat the retry.

All three were re-verified open at HEAD. Greenfield: no data/path compat concerns. **The plan is complete only when `mix precommit` passes** — verified alias (mix.exs:252-261): `jidoclaw.compile_check`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format --check-formatted`, `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`, `test`. So new code needs `@spec`s, and the new module must clear reach/credo.

*(Revised after two user review rounds: symlink guard before read with fatal chmod, fully-verbatim parse so merged validation can see legacy padding, no-whitespace key rule, spec-env inject failures fail bootstrap (tested on `:bootstrap` + `bootstrap_client`), symlink-safe `ensure_workspace_dir`, base-path lstat in the reaper, classifier recursion + two more call sites.)*

---

## Cluster 1 — M3: harden Forge Docker secret files

**Files:** `lib/jido_claw/forge/sandbox/docker.ex`, `lib/jido_claw/forge/harness.ex`, `lib/jido_claw/forge/sandbox_init.ex`, `test/jido_claw/forge/sandbox/docker_test.exs`, `test/jido_claw/forge/sandbox_init_test.exs`, harness test file (likely `test/jido_claw/forge/harness_resources_test.exs`) + `test/support/stub_sandbox.ex`

### 1a. Secure `.forge_env` writes (docker.ex `inject_env/2`, lines 152-167)

New flow, in order:

1. **lstat first, before any read** (`File.lstat(env_file)`): `:enoent` → no existing env; `{:ok, %File.Stat{type: :regular}}` → tighten legacy mode with `File.chmod(env_file, 0o600)` **inside the `with` chain — a chmod failure is fatal** (don't read/merge a file we couldn't protect), then `File.read` — **a read failure on an existing regular file is also an explicit `{:error, ...}` in the `with`, never treated as "no existing env"**; anything else at lstat (symlink, dir, …) → `{:error, {:invalid_env_file, type}}` — a pre-existing symlink must not be **followed on the read** either, not just on the write.
2. **Verbatim parse**: change `parse_env_file/1` (docker.ex:290-299) to preserve **both** raw key and raw value (split on first `=` only, no trimming — it currently trims both). Trimming legacy keys at parse would hide exactly the padding the merged validation must catch (`" BAD=value"` would silently normalize to `BAD`); a padded value silently mutates on round-trip.
3. Merge parsed-existing with the stringified incoming env (incoming wins), then **validate the merged map** — not just the incoming env — so malformed legacy `.forge_env` content is never carried forward. Rules: keys must be non-empty and contain **no whitespace** (covers padding, internal spaces, `\n`, `\r`), no `=`, no NUL; values must contain no `\n`, `\r`, NUL (whitespace edges are legal value content and now round-trip faithfully). Violation → `{:error, {:invalid_env, offending_key}}`, file untouched. Reject — don't encode — because env files have no escape syntax and `sbx --env-file` can't represent multiline values.
4. **`secure_write/2`** (the H7 pattern from `lib/jido_claw/cli/setup.ex:304-337`, adapted to error tuples — callers expect `:ok | {:error, term()}` per `Sandbox.Behaviour` and a Harness GenServer must not crash): unique tmp `<path>.<unique_integer>.tmp`, `File.touch` + `File.chmod(tmp, 0o600)` **before** content, `File.write`, `File.rename` (atomic, preserves mode), in a `with`, wrapped `try/after File.rm(tmp)`.

At the do_create OneCLI inject (docker.ex:57): stop discarding the result — log a warning on `{:error, _}` (trusted config, pre-bootstrap; a warning suffices there).

### 1b. Spec-env inject failures must fail bootstrap (harness.ex)

Four sites inject `state.spec.env` and **discard** the result outside the `with` chain: `handle_info(:bootstrap, …)` (harness.ex:258-262), `recover_bootstrap/1` (:828-832), `bootstrap_sync/1` (:1143-1147), `bootstrap_client/2` (:1297-1301). Env is part of the sandbox spec — with validation now able to reject it, these must fail bootstrap, not silently skip:

- Add a private helper `inject_spec_env(client, spec)` → `:ok` when env is empty, else `Sandbox.inject_env(client, env)`.
- Thread it as the first step of each site's `with` chain, mapping to that site's existing bootstrap-failure shape. Careful: `ResourceProvisioner.provision_all` errors are 3-tuples (`{:error, resource_or_step, reason}`) while `inject_spec_env` returns 2-tuples — each `with`'s `else` must handle both.
- Non-Docker paths unaffected: HostShell's `inject_env` is an in-memory Agent update (always `:ok`), StubSandbox returns `:ok`.

### 1c. Workspace dir creation hardening (docker.ex `do_create/1`, lines 41-42)

A bare `File.mkdir_p!` + `chmod` would follow a pre-existing symlink at `workspace_dir` (the base lives under `/tmp` and sandbox names are guessable `unique_integer`s). Replace with `ensure_workspace_dir(base, sandbox_name)` → `{:ok, path} | {:error, term()}` — **`@doc false` public** so it's directly testable (`Docker.create/1` short-circuits when `sbx` is absent; same public-for-tests pattern as `SandboxInit.cleanup_orphaned_sandboxes/0`). Non-bang throughout:

1. `File.mkdir_p(base)`, then `File.lstat(base)` must be `type: :directory` (rejects a symlinked base — `mkdir_p` follows symlinks).
2. `File.mkdir(path)` — **not** `mkdir_p`: names are unique per boot and SandboxInit reaps stale dirs before any create, so `{:error, :eexist}` (including a planted symlink) is suspicious and rejected rather than reused.
3. `File.chmod(path, 0o700)` — safe now: we just created the real dir ourselves; **on chmod failure, `File.rm_rf` the just-created dir before returning the error** (same spirit as the existing `sbx_create_failed` cleanup at docker.ex:62). `sbx` runs as the invoking user so the bind-mount stays accessible.

`do_create` threads this via `with` into its existing error-tuple return, and **`create/1`'s `@spec` (docker.ex:25) gains the new failure shape** (it currently names only `:sbx_not_found | {:sbx_create_failed, ...}` — dialyzer will care).

### 1d. Boot-time reap of orphaned workspace dirs (sandbox_init.ex)

`Harness` is `restart: :temporary`; `Sandbox.destroy` (the only `.forge_env` cleanup) runs only from `terminate/2`, so a crash strands the dir forever. `SandboxInit` (Docker-only boot task) already reaps orphaned **sandboxes** via `sbx ls`/`sbx rm` but never touches workspace **dirs**.

- Add `reap_orphaned_workspace_dirs/1` (public, `@doc false`, takes the base path for testability). **Guard the base itself first**: `File.lstat(base)` must be `{:ok, %File.Stat{type: :directory}}` — `File.ls` would follow a symlinked base, and the default base lives under `/tmp`; anything else (absent, symlink, file) → log debug, `:ok`. Then for each entry: reap only if the basename starts with `"forge-"` **and** entry `File.lstat` says `type: :directory` (skips symlink entries entirely); `File.rm_rf`; log a summary.
- Call from `run/0` **unconditionally** (after `cleanup_orphaned_sandboxes()`) — filesystem-only, must run even when the `sbx` CLI is absent (the sandbox cleanup bails in that case).
- Add a private `workspace_base/0` mirroring docker.ex's (`Keyword.get(config, :workspace_base, "/tmp/jidoclaw_forge")` off `:forge_docker_sandbox`) — keep the two reads identical.

**Accepted residual (document in the commit message):** a crash-while-running strands a `0600` file until the next boot reap — no periodic sweeper, by design; mode 0600 means it's no longer world-readable in the interim.

### 1e. Tests

`docker_test.exs` (`describe "inject_env/2"`, lines 74-120 — async, untagged, real tmp-dir writes; extend):
- `.forge_env` created `0600` (`File.stat!(...).mode` masked `0o777`; `import Bitwise`); pre-existing `0644` file tightened on next inject.
- **Symlink rejection**: pre-create `.forge_env` as a symlink to a victim file → `{:error, {:invalid_env_file, _}}`, victim byte-identical, symlink not followed for read or write.
- Rejection: value with `\n` (`"a\nINJECTED=evil"`), key with `=`, key with `\n`, whitespace-padded key, key with internal space (`"BAD KEY"`) → `{:error, {:invalid_env, _}}`, file untouched.
- **Merged validation**: hand-write a `.forge_env` containing `" BAD=value"` (padded raw key — survives the verbatim parse; a line *without* `=` is dropped by the parser and proves nothing), inject a clean var → write rejected (legacy content not carried forward).
- **Value round-trip**: inject `%{"K" => " padded "}`, inject another var, assert `K= padded ` preserved verbatim.
- `ensure_workspace_dir` (direct tests against the `@doc false` helper — no `sbx` needed): symlinked base rejected; pre-existing entry (dir or symlink) at the workspace path → `{:error, :eexist}`; fresh create ends up mode `0700`.
- No `*.tmp` left behind on success.

`sandbox_init_test.exs` (exists, untagged, `async: false`): new `describe "reap_orphaned_workspace_dirs/1"` — tmp base with `forge-1/` (nested file), `forge-2/`, `keepme/`, `forge-link` symlink → two dirs gone, `keepme` + symlink target survive; nonexistent base → `:ok`; **base-is-symlink → skipped, target untouched**.

Harness: extend `test/support/stub_sandbox.ex` with a configurable `inject_env` failure (config flag or magic env key), then cover **both** the main `:bootstrap` flow **and** the attached-sandbox `bootstrap_client/2` path (its `else` already mixes 2- and 3-tuple error shapes and is the easiest to regress), asserting a spec-env inject failure surfaces as bootstrap failure rather than a silent skip. Cover `recover_bootstrap`/`bootstrap_sync` too if cheap fixtures exist; otherwise note them as exercised by the same helper.

---

## Cluster 2 — M4: omit content-bearing trace keys

**Files:** `lib/jido_claw/trace/sanitize.ex`, `test/jido_claw/trace/sanitize_test.exs`

- Add `"content"`, `"input"`, `"output"`, `"text"`, `"thinking_content"` to `@large_keys` (sanitize.ex:25-43, keep alphabetical). One moduledoc line noting these cover jido_ai Turn-shaped upstream metadata.
- **Do not** swap to `Redaction.Transcript`: it has no size-omission (and `@large_keys` is the *only* flood guard — `Trace.Persistence` writes metadata verbatim to JSONB, no truncation exists downstream) and it leaves PIDs intact, which would break the JSONB write (`payload/1`'s PID/fun `inspect` is load-bearing).
- Verified safe: none of the 12 first-party `Trace.emit` sites uses these metadata keys, and no trace consumer (web/, CLI) reads them — the `thinking_content` reads in `conversations/recorder.ex` consume raw jido_ai telemetry in their own handlers, not the sanitized Collector path.
- Tests: assert each new key → `"[OMITTED]"` at top level and nested (payload recurses), and one atom-key case (`:thinking_content`). The existing large-key test iterates a literal list and keeps passing.

---

## Cluster 3 — M5 + L7: memory duplicate-key retry + structural classifier

**Files:** `lib/jido_claw/memory.ex`, `lib/jido_claw/memory/resources/fact.ex` (moduledoc only), `lib/jido_claw/conversations/recorder.ex`, `lib/jido_claw/tools/mcp_scope.ex`, `lib/mix/tasks/jidoclaw.migrate.conversations.ex`, new `lib/jido_claw/core/ash_errors.ex`, `test/jido_claw/memory/fact_test.exs`, new `test/jido_claw/core/ash_errors_test.exs`

### 3a. Verified error shape (the basis for L7)

A DB-level unique violation surfaces as `Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{message: "has already been taken", private_vars: [constraint: <index_name>, constraint_type: :unique, detail: ...]}]}` (ash_postgres `data_layer.ex:2927-2936`; constraint registered per identity at :3241-3279). No eager/pre-check on Fact identities, so this is the only shape `do_remember` sees. **The structured handle is `private_vars[:constraint]` (the index name) + `constraint_type: :unique`.**

Subtlety found while verifying: the constraint string is the **index** name, not the identity name. The four active-label indexes use default names (`memory_facts_unique_active_label_per_scope_<scope>_index` — the current fragment matches), but the promoted identities map to shortened index names (`mf_promoted_*_idx`, fact.ex:93-97) — so the current fragment `"unique_active_promoted_content_per_scope_"` can never match a real error. Harmless today (promoted identities are unreachable via `remember_*` — they require `source == :consolidator_promoted`), but the new fragment list must use **index-name** fragments.

### 3b. New shared classifier `JidoClaw.Core.AshErrors`

(`Core` namespace per the `Core.OsCmd` precedent for cross-cutting utilities.)

```elixir
@spec unique_violation?(term(), [String.t()]) :: boolean()
def unique_violation?(%Ash.Error.Invalid{errors: errors}, index_fragments), do: Enum.any?(errors, &unique_violation_error?(&1, index_fragments))
def unique_violation?(_other, _fragments), do: false

# Recurses into nested %Ash.Error.Invalid{} so the recorder's current
# nested-error tolerance is preserved without relying on inspect.
defp unique_violation_error?(%Ash.Error.Invalid{errors: nested}, fragments), do: Enum.any?(nested, &unique_violation_error?(&1, fragments))
defp unique_violation_error?(%Ash.Error.Changes.InvalidAttribute{private_vars: vars}, fragments) when is_list(vars),
  do: vars[:constraint_type] == :unique and is_binary(vars[:constraint]) and String.contains?(vars[:constraint], fragments)
defp unique_violation_error?(_, _), do: false
```

Convert **all four** same-class inspect-substring classifiers to delegate (local wrapper names stay; bodies become one-line delegations):
- `memory.ex` `duplicate_key?/1` (:317-327) — fragments `["unique_active_label_per_scope_", "mf_promoted_", "unique_import_hash"]` (index-name based; latter two defensive).
- `conversations/recorder.ex` `duplicate_key?/1` (:867-882) — fragments `["unique_session_sequence", "unique_live_tool_row", "unique_import_hash"]` (all substrings of Message's default index names; Message sets no `identity_index_names`).
- `tools/mcp_scope.ex` `duplicate_key?/1` (:259-263) — fragment `["unique_live_tool_row"]`.
- `mix/tasks/jidoclaw.migrate.conversations.ex` `duplicate_import_hash?/1` (:244-248) — fragment `["unique_import_hash"]`.

### 3c. Retry-once in `do_remember` (memory.ex:267-289)

Add `attempt \\ 1`; extract the `Fact.record` call into `record_fact/3` with a test seam (`Application.get_env(:jido_claw, :memory_fact_recorder, Fact)` — same pattern as H11's `:compaction_storage`). On `duplicate_key?(err) and attempt == 1` → debug-log + `do_remember(attrs, tool_context, opts, 2)`; on second duplicate → current idempotent-skip debug + `:ok`; everything else unchanged. On retry, the loser's `InvalidatePriorActiveLabel` invalidates the winner's fresh row → **last-writer-wins** instead of silent drop. Safe: both callers (`tools/remember.ex:54-59`, `cli/commands.ex:236-241`) ignore the return; the always-`:ok` contract is unchanged.

### 3d. Fix the false moduledoc (fact.ex:689-700)

`Changes.InvalidatePriorActiveLabel` claims "Callers retry via `JidoClaw.Memory.remember_*`'s `{:error, :duplicate_key}` path" — no such path exists. Rewrite to describe reality: the race is bounded by the partial unique identity; `JidoClaw.Memory.do_remember` classifies the violation via `Core.AshErrors.unique_violation?/2` and retries once (last-writer-wins); a second duplicate is logged and skipped idempotently.

### 3e. Tests

- **Real-error pin** (in `ash_errors_test.exs`): reuse the existing genuine-violation fixture — `Message.import` twice with the same `(session_id, import_hash)` produces a real Postgres-level `Ash.Error.Invalid` (exactly as `test/jido_claw/conversations/message_test.exs:118-152` does today). Assert `unique_violation?(err, ["unique_import_hash"])` is true, false for non-matching fragments, and pin `private_vars[:constraint_type] == :unique` so an ash_postgres shape change fails loudly here instead of silently breaking classification.
- **Constructed-struct unit tests**: matching/non-matching fragments; **nested `Invalid`-in-`Invalid` recursion**; `constraint_type: :foreign_key` → false; non-`InvalidAttribute` inner errors → false; non-`Invalid` input → false.
- **Retry-path tests** (in `fact_test.exs`, via the `:memory_fact_recorder` seam + a small stateful double): duplicate-once-then-delegate → `:ok` and the **second** value's fact lands (last-writer-wins); duplicate-twice → `:ok`, no third attempt. Reset the app env in `on_exit`.
- **Fix the misnamed test** `"active label uniqueness — concurrent writes collide"` (fact_test.exs:74-82): it's a single sequential write. Rename honestly (e.g. `"single active row per (scope, label)"`) and note in a comment that the true commit race is unreproducible under the SQL sandbox (transactions never commit) and is covered by the seam-based retry tests.
- Run the existing recorder/mcp_scope/migrate-task suites to confirm the delegated classifiers cause no behavior change.

---

## Documentation

Update `docs/reports/code-review-2026-06-10.md` per repo convention: append "✅ fixed 2026-06-11" + a short fix note to M3, M4, M5; mark L7 closed by the M5 fix (same style as L18's note); update priority-order item 6 if applicable.

## Commits (matching the repo's existing style)

1. `Code review M3 fix` — docker.ex, harness.ex, sandbox_init.ex, stub_sandbox.ex + tests
2. `Code review M4 fix` — sanitize.ex + tests
3. `Code review M5 + L7 fixes` — memory.ex, fact.ex moduledoc, recorder.ex, mcp_scope.ex, migrate task, core/ash_errors.ex + tests, review-doc updates

(Stage only the files belonging to each cluster — check `git status --short` before each commit.)

## Verification

1. Per cluster while implementing: `mix test test/jido_claw/forge/` (M3), `mix test test/jido_claw/trace/sanitize_test.exs` (M4), `mix test test/jido_claw/memory/ test/jido_claw/core/ash_errors_test.exs test/jido_claw/conversations/ test/jido_claw/tools/mcp_scope_test.exs test/mix/tasks/` (M5/L7 — all four delegated classifiers)
2. `mix format` after each cluster
3. After creating `core/ash_errors.ex`, run `mix reach.check --arch --smells --strict` early — if an arch rule rejects the new module's location (a mix task and a tool now depend on it), fall back to local matchers with the same structural logic
4. Final gate: **`mix precommit`** (includes dialyzer — watch the new `@spec`s and the `do_remember` default-arg arity)

## Risks / first-verify during implementation

- **L7:** the `private_vars` shape is taken from deps source (ash_postgres `data_layer.ex:2927`) — the real-error pin test (3e) is the guard; write it first and confirm it passes against the current matcher's behavior before swapping the classifier in.
- **M3:** the harness `with`-chain threading must respect each site's distinct error shapes (2-tuple inject vs 3-tuple provision); check each `else` clause. The existing three inject_env tests must keep passing (the verbatim parse can alter round-trip expectations — adjust only if a test pinned the trimming). `do_create`'s switch from `mkdir_p!` (raise) to `ensure_workspace_dir` (error tuple) changes its failure mode — confirm `create/1` callers treat `{:error, _}` as they treated a crash (they already handle `{:error, {:sbx_create_failed, ...}}`).
- **M5:** the seam double must implement `record/2` with `(attrs, opts)` exactly as the `Fact.record` code interface.

## Out of scope (noted for later batches)

M15 (ResearchCoordinator rescue — masked by stubs today), the unbounded-growth cluster (M7/M8 before long-running production use), migration cluster (M11/M12 before the next data migration), Discord (M9/M10), M16–M18, remaining LOWs.
