# Dialyzer cleanup — Phase 1

## Context

Following recent Credo cleanup, `mix dialyzer` reports 26 findings (25 in-project, 1 in `deps/postgrex`). This plan resolves **17** of them in a single coherent effort, deferring the verify_certificate cluster (7, needs spec work on the reasoning chain) and the pull_request_coordinator stub (1, needs design decision on retry validation). The deps issue is not ours to fix.

The selected fixes cluster into two groups: nine trivial one-liners (dead clauses, type tweaks, a missing `@dialyzer :nowarn_function`) and eight slightly larger fixes (callback widening, dead-parameter removal, a `List.keyfind` → `Map.get` correction, a fake-struct port value). Most have a shared character: dialyzer is catching defensive/dead branches and a few drifted specs.

## Scope summary

| Group | Findings | Effort |
|-------|----------|--------|
| A. Trivial one-liners | 9 | small |
| B. Small fixes | 8 | small-medium |
| **Total resolved** | **17** | |
| Deferred (`verify_certificate.ex` cluster) | 7 | future effort |
| Deferred (`pull_request_coordinator.ex:11`) | 1 | needs design decision |
| Out of scope (`deps/postgrex`) | 1 | upstream |

---

## Group A — Trivial fixes (9 findings)

### 1. `lib/jido_claw/forge/harness.ex:137` — dead `stop_unclaimed_session/2` fallthrough
`Persistence.claim_session/3` only returns `:ok | {:error, :already_claimed}`. The first clause covers it; delete the second clause (lines 137–140).

### 2. `lib/jido_claw/forge/harness.ex:738, 1071` — dead 2-tuple `{:error, reason}` clauses
Both `ResourceProvisioner.provision_all/2` and `run_bootstrap_steps/1` return 3-tuple errors only. Delete the trailing `{:error, reason} -> {:error, {:bootstrap_failed, reason}}` clauses at both lines.

### 3. `lib/jido_claw/forge/harness.ex:257, 1064` — distinguish provision vs bootstrap errors
Both error sources currently emit `{:error, map(), term()}`, so the `is_map(resource)` guard at 246/1054 is always true and the unguarded `{:error, step, reason}` clause is unreachable. Fix at the source by tagging bootstrap errors uniquely.

`run_bootstrap_steps/2` (defined at line 1231, arity 2 with default `client \\ nil`) is called from four sites:

| Caller | Line | Today's else handling | Notes |
|--------|------|----------------------|-------|
| `handle_info(:bootstrap, state)` (line 225) | 240 | distinguishes resource vs bootstrap (lines 245–267) — **dead bootstrap clause** | discriminating log + stop tuple |
| `recover_bootstrap/1` (line 724) | 734 | merged `{:error, _resource_or_step, reason}` + dead 2-tuple | no per-source logging |
| `bootstrap_sync/1` (line 1037) | 1050 | distinguishes resource vs bootstrap (lines 1054–1074) — **dead bootstrap clause + dead 2-tuple** | discriminating log + return |
| `bootstrap_client/2` (line 1197) | 1207 | merged 3-tuple + **real 2-tuple from `init_runner_for_sandbox/2`** | keep 2-tuple — it's reachable |

Changes:
1. Tag bootstrap errors at the source. Have `run_bootstrap_steps/2` wrap only the known bootstrap shape and pass everything else through unchanged:

   ```elixir
   case Bootstrap.execute(client || default_client(state), bootstrap_steps) do
     {:error, step, reason} -> {:error, {:bootstrap_step, step}, reason}
     other -> other
   end
   ```

   (Keeps the wrapper conservative and the new contract obvious.)
2. At lines 240 and 1050: add an explicit `{:error, {:bootstrap_step, step}, reason}` clause **before** the `{:error, resource, reason} when is_map(resource)` clause so each source is matched cleanly.
3. At line 734: keep the merged `{:error, _resource_or_step, reason}` clause (works for both tagged-tuple and resource map); delete the trailing 2-tuple (covered by item 2 above).
4. At line 1207 (`bootstrap_client/2`): leave both clauses alone — the 2-tuple is real because `init_runner_for_sandbox/2` returns `{:error, {:runner_init_failed, reason}}` (line 1227).

This preserves the existing log-event distinction (`resource.provision_failed` vs `bootstrap.failed`).

### 4. `lib/jido_claw/authorization/actor.ex:30` — actor type missing `:kind`
The `system/1` function returns `%{kind: :system, user_id: nil, tenant_id: ...}` but the `@type actor` shape doesn't allow `:kind`. Split the type:

```elixir
@type user_actor :: %{user_id: String.t(), tenant_id: String.t()}
@type system_actor :: %{kind: :system, user_id: nil, tenant_id: String.t()}
@type actor :: user_actor() | system_actor() | nil
```

Narrow `@spec build` to `user_actor() | nil` and `@spec system` to `system_actor()`.

### 5. `lib/jido_claw/cli/repl.ex:273` + `config/config.exs` — wrong limits key (REPL + custom models)
`LLMDB.Model.limits` exposes `:context` and `:output`. The REPL pattern destructures `:context_window` (which doesn't exist after LLMDB validation), so it falls through to the 131_072 default for every model.

But fixing only the REPL pattern leaves the custom Ollama config (`config/config.exs:7–`) still using `limits: %{context_window: ..., max_output_tokens: ...}` for ~6+ models — LLMDB drops those non-canonical keys during validation, so the new `:context` match would still fail for custom models. Fix both as one change:

- `lib/jido_claw/cli/repl.ex:273`: change to `{:ok, %{limits: %{context: cw}}} -> cw`.
- `config/config.exs`: convert every `limits: %{context_window: X, max_output_tokens: Y}` to `limits: %{context: X, output: Y}` across the Ollama model registry.

### 6. `lib/jido_claw/repo.ex:2` — `all_tenants/0` raise-only by design
`use AshPostgres.Repo` injects a `raise`-only default. This project uses attribute multitenancy, so overriding isn't necessary. Add inside the module:

```elixir
@dialyzer {:nowarn_function, all_tenants: 0}
```

(If the project ever moves to schema-based tenant migrations, the proper fix is to implement `all_tenants/0` returning the list of schema names instead.)

### 7. `lib/jido_claw/vfs/workspace.ex:384` — dead atom guard in `to_existing_atom_safe/1`
Callers (`fetch_string/2` at lines 371/378) only pass binaries. Delete the `defp to_existing_atom_safe(s) when is_atom(s), do: s` clause.

---

## Group B — Small fixes (8 findings)

### 8. `lib/jido_claw/forge/runner.ex` — widen `init`/`apply_input` callbacks + fix `restore_state` (resolves 3 findings)
Both real runner implementations (`workflow.ex`, plus likely codex/claude_code) return `{:ok, state}`. Update `runner.ex`:

```elixir
@callback init(sandbox(), config()) :: :ok | {:ok, state()} | {:error, term()}
@callback apply_input(sandbox(), input(), state()) :: :ok | {:ok, state()} | {:error, term()}
```

Verify that the `case` blocks at the `init/apply_input` call sites in `harness.ex` (around lines 275, 753, 1081) already handle `{:ok, state}` — the agent's exploration says they do, but confirm during implementation.

While in the file, also fix the misleading `restore_state/2` callback at line 28:

```elixir
@callback restore_state(state(), snapshot :: map()) :: {:ok, state()} | {:error, term()}
```

(Currently typed `config(), snapshot :: map()` — `state()` matches the actual harness call. Both alias to `map()` today, so this is a docs/intent fix, not a dialyzer fix.)

Resolves: `fake.ex:28`, `workflow.ex:8`, `workflow.ex:27`.

### 9. `lib/jido_claw/vfs/workspace.ex` — remove dead `fail_soft?` parameter, narrow public spec (resolves 3 findings)
Both callers (`handle_call({:mount, ...})` at line 200, `mount_from_config/2` at line 249) pass `fail_soft?: true`. The three `if soft?, do: :ok, else: {:error, reason}` branches at 278/290/295 always pick `:ok`. The non-default mount path is documented as always fail-soft.

- Drop the `fail_soft?:` kwarg from `do_mount/5` → `do_mount/4`.
- Drop the `soft?` parameter from `do_vfs_mount/5` → `do_vfs_mount/4`.
- Replace the three `if soft?, do: :ok, else: {:error, reason}` with `:ok`.
- Remove `fail_soft?: true` from both call sites (200, 249).
- Narrow the public `@spec mount/4` at line 151 from `:: :ok | {:error, term()}` to `:: :ok` (the docstring already says it's fail-soft; the spec is what's lying).

### 10. `lib/jido_claw/embeddings/voyage.ex:139` — use `Req.Response.get_header/2`
`Req.Response.headers` is typed `%{binary() => [binary()]}`, and `Req.Response.get_header/2` is spec'd `(t(), binary()) :: [binary()]` (always a list, possibly empty). Change the `handle_response/4` head to match the full response (`%Req.Response{status: 429} = response`) and rewrite the lookup:

```elixir
retry_after =
  case Req.Response.get_header(response, "retry-after") do
    [val | _] -> parse_retry_after(val)
    [] -> 60
  end
```

Two clauses only — no dead `is_binary(val)` fallback.

### 11. `lib/jido_claw/shell/session_manager.ex:796` — fake `ServerEntry` has `port: 0`
`ServerEntry.t()`'s `:port` field likely types as `1..65535`, so `fake_entry_for_error/1`'s `port: 0` violates the spec, causing dialyzer to mark the `SSHError.format/2` call as ill-typed. Change `port: 0` to `port: 22` at line 860. (Sanity-check `ServerEntry`'s type definition during implementation; if `:port` permits 0, instead widen the type. Adjusting the fake is preferred — it's a stub for error message rendering only.)

---

## Deferred / out of scope

- **`lib/jido_claw/tools/verify_certificate.ex`** (7 findings, lines 104–117, 130, 208): all collapse to one shared root cause — imprecise/missing specs threading through `Telemetry.with_outcome` / `execute_cert/2` / `run_reasoning/2` / `Certificates.parse_certificate/1`. Resolving this cleanly requires tightening specs upstream (~10–20 lines plus careful review of the reasoning chain). Defer to a follow-up dialyzer pass focused on the reasoning subsystem.
- **`lib/jido_claw/github/agents/pull_request_coordinator.ex:11`** (1 finding): `validate_quality/1` is stubbed to always return `{:ok, %{passed: true}}`, so the retry-attempt guard is unreachable. The scaffold is intentional unfinished work. Defer until the real validation is implemented.
- **`deps/postgrex/lib/postgrex/type_module.ex:1045`**: in `deps/`, not actionable here.

---

## Verification

1. `mix compile --warnings-as-errors` — no warnings introduced.
2. `mix dialyzer` — confirms count drops from 26 → 9 (8 deferred + 1 in deps). If new findings appear elsewhere (e.g. from widened callback specs or the narrowed `Workspace.mount/4` spec), address them in this pass.
3. `mix test` — full suite passes. Areas most likely to surface regressions:
   - `test/jido_claw/forge/` (callback widening, harness `with` restructure, bootstrap tagging)
   - `test/jido_claw/vfs/` (workspace mount paths — existing tests already cover fail-soft behavior, should pass unchanged)
   - `test/jido_claw/embeddings/` (voyage retry-after parsing)
   - `test/jido_claw/shell/` (SSH error formatting)
4. `mix format --check-formatted` — no formatting drift.

### New focused tests to add

- **`test/jido_claw/embeddings/voyage_test.exs`** — cover the 429 `retry-after` path:
  - Header present with a single value → returns `{:error, {:rate_limited, parsed_value}}`.
  - Header absent → returns `{:error, {:rate_limited, 60}}` (default).
- **`test/jido_claw/cli/repl_test.exs`** (or wherever `configure_display_from_config/2` is reachable) — assert that a custom Ollama model in `config/config.exs` resolves through `Config.model_info/1` and yields the configured context (not the 131_072 fallback). Equivalently, an `LLMDB.Model` round-trip test for one of the custom Ollama entries verifying `model.limits.context` is populated.

## Critical files to be modified

| File | Findings touched |
|------|------------------|
| `lib/jido_claw/forge/harness.ex` | 137, 257, 738, 1064, 1071 |
| `lib/jido_claw/forge/runner.ex` | (callback specs; resolves 3 in runner files; also tightens `restore_state` types) |
| `lib/jido_claw/authorization/actor.ex` | 30 |
| `lib/jido_claw/cli/repl.ex` | 273 |
| `config/config.exs` | (custom Ollama model `limits` keys — required for repl.ex fix to actually work) |
| `lib/jido_claw/repo.ex` | 2 |
| `lib/jido_claw/vfs/workspace.ex` | 278, 290, 295, 384 + public `@spec mount/4` |
| `lib/jido_claw/embeddings/voyage.ex` | 139 |
| `lib/jido_claw/shell/session_manager.ex` | 796 |

## Commit plan (slicing guidance, not authorization)

Three logical commits keep blame readable:

1. **`fix(dialyzer): trivial dead-clause and spec fixes`** — Group A items 1, 2, 4–7 (harness deletes at 137/738/1071, actor type split, repl key + config.exs Ollama limits, repo nowarn, workspace atom guard). **7 findings.**
2. **`fix(dialyzer): tag bootstrap errors so harness clauses are reachable`** — Group A item 3 (`run_bootstrap_steps/2` tag + matching pattern updates at lines 240 and 1050). **2 findings.**
3. **`fix(dialyzer): widen runner callbacks, drop dead fail_soft?, fix req headers + ssh port`** — Group B items 8–11 (runner callbacks + `restore_state` type fix, workspace `fail_soft?` removal + narrowed public spec, voyage `get_header`, session_manager port). **8 findings.**

Total resolved: 17 findings. (Slicing only — do not commit without an explicit request.)
