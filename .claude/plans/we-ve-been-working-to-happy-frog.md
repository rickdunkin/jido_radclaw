# Dialyzer Cleanup — Trivial Tier (Revised)

## Context

The codebase has **59 dialyzer findings** (per `.harness/latest.json`). Credo cleanup just wrapped; dialyzer is next. This effort targets **only findings that are unambiguously mechanical** — single config lines, missing `@type` declarations, dead clauses where the upstream spec genuinely rules out the dead arm, and one stale typespec that's narrower than its function actually behaves.

A prior draft of this plan was rejected for: (1) reading the Ash `code_interface define` return shape backwards (it returns `{:ok, list}`, not bare list), (2) treating both `/network connect` and `/network disconnect` CLI error arms as dead-clause deletions, when in fact `connect/0` can genuinely return `{:error, _}` (the spec is stale) while only `disconnect/0`'s CLI arm is actually dead, (3) too-narrow `Skills.t/0`, and (4) bundling in findings (Forge harness, VFS) whose mechanical fix masks a semantic smell. This revision corrects all four.

**Scope:** 34 findings resolved. Findings that need design judgment (Forge harness error tagging, VFS mount contract, verify_certificate.ex cascade, behaviour widening) are deferred.

No commits — full review at the end.

## Approach

Four tiers, executed in order. After each tier, run `mix dialyzer` to confirm the target findings drop.

| Tier | What | Findings |
|---|---|---|
| 1 | PLT config (`mix.exs` plt_add_apps) | 7 |
| 2 | Missing `@type` declarations | 5 |
| 3 | Stale spec widening (`Network.Node.connect/0`) | 1 |
| 4 | Dead-clause deletions | 21 |

---

## Tier 1 — PLT config (7 findings, 1 file)

**File:** `mix.exs:40`

```diff
- plt_add_apps: [:ex_unit, :mix],
+ plt_add_apps: [:ex_unit, :mix, :nostrum, :llm_db],
```

Both are optional deps not currently in the PLT, so dialyzer reports their modules/functions as unknown even though the code is correct.

**Resolves (7):**
- gen_server.ex callback_info_missing (Nostrum.Consumer behaviour)
- deps/nostrum/lib/nostrum/consumer.ex:439 — `Nostrum.ConsumerGroup.join/1`
- lib/jido_claw/cli/repl.ex:574 — `Nostrum.Cache.Me.get/0`
- lib/jido_claw/platform/channel/discord.ex:68 — `Nostrum.Api.Message.create/2`
- lib/jido_claw/core/config.ex:445 — `LLMDB.Model.t/0`
- lib/jido_claw/core/config.ex:448 — `LLMDB.model/1`
- lib/jido_claw/core/config.ex:462 — `LLMDB.Model.t/0`

**Note:** `LLMDB.Model.t/0` is macro-generated via `Zoi.type_spec`, which can defeat PLT resolution. If those two `Model.t/0` findings persist after PLT rebuild, leave them — don't introduce a workaround in this tier.

**Verification:** `mix dialyzer.clean && mix dialyzer` (PLT rebuild is slow, ~minutes).

---

## Tier 2 — Missing `@type` declarations (5 findings, 2 files)

### 2a. `JidoClaw.Skills.t/0` (4 findings)

**File:** `lib/jido_claw/platform/skills.ex` — `defstruct` is at line 46 (`[:name, :description, :steps, :synthesis, :mode, :max_iterations]`) but no `@type t` exists.

Add near the top of the module:

```elixir
@type t :: %__MODULE__{
        name: String.t() | nil,
        description: String.t() | nil,
        steps: list() | nil,
        synthesis: String.t() | nil,
        mode: String.t() | atom() | nil,
        max_iterations: pos_integer() | nil
      }
```

**Why `mode: String.t() | atom() | nil`:** YAML loader stores `mode` as a string (skills.ex:~409); `execution_mode/1` matches the literal `"iterative"` (skills.ex:~323). A `String.t() | atom() | nil` union covers the actual data plus any code path that converts to an atom. Keep it loose; don't tighten to `:iterative` unless follow-up confirms that's exhaustive.

**Resolves:**
- lib/jido_claw/workflows/iterative_workflow.ex:51, 102
- lib/jido_claw/workflows/plan_workflow.ex:37
- lib/jido_claw/workflows/skill_workflow.ex:38

### 2b. `JidoClaw.Agent.Prompt.sync_result/0` (1 finding)

**File:** `lib/jido_claw/agent/prompt.ex`

`sync/1`'s `@spec` already inlines `:noop | :overwritten | :sidecar_written | :stamp_only`. Promote to a named alias near the top:

```elixir
@type sync_result :: :noop | :overwritten | :sidecar_written | :stamp_only
```

Then update `sync/1`'s `@spec` to use the alias, and update `lib/jido_claw/startup.ex:27`'s spec to reference only `Prompt.sync_result()`. `startup.ex:17` currently defines a local `@type sync_result` with the same union; remove that local type unless it's used elsewhere in the module — the `@spec` at line 27 already references both `Prompt.sync_result() | sync_result()` which is redundant once `Prompt.sync_result/0` exists.

**Resolves:** lib/jido_claw/startup.ex:27

---

## Tier 3 — Stale spec widening (1 finding, 1 file)

**File:** `lib/jido_claw/network/node.ex`

`connect/0` is spec'd `:: :ok`, but `handle_call(:connect, ...)` (around line 160) can return `{:error, reason}` when identity initialization fails. The CLI handler at `lib/jido_claw/cli/commands.ex:424` is correctly handling that error — the spec is the stale piece.

Widen the spec:

```elixir
@spec connect() :: :ok | {:error, term()}
```

(Read the file to confirm the existing spec name and arity match — adjust if not.)

**Resolves:** lib/jido_claw/cli/commands.ex:424

**Do not** delete the `{:error, _}` arm in `commands.ex:424`. It handles real runtime failures.

**Note on `disconnect/0`:** Unlike `connect/0`, `disconnect/0` (and its `handle_call(:disconnect, ...)` at ~line 184) only returns `:ok`. The `{:error, _}` arm in `commands.ex:436` is genuinely dead and is handled in Tier 4 as a deletion.

---

## Tier 4 — Dead-clause deletions (21 findings, 13 files)

In every entry below, the noted clause is provably unreachable because the upstream function's `@spec` (or call-site invariant) rules it out. Action is **delete the clause**. No behavior change. Read each function first to confirm the line and clause direction.

### Ash `code_interface` reads return `{:ok, list}` — bare-list fallback is dead (7 findings)

Ash's generated read functions return `{:ok, [record]}` for list-returning queries; the defensively-added `list when is_list(list)` fallback in each `case` is unreachable. **Keep the `{:ok, list}` arm. Delete the bare-list fallback** at the line dialyzer flags.

- `lib/jido_claw/cli/commands.ex:313` — delete the `runs when is_list(runs)` arm (L312's `{:ok, runs}` is live)
- `lib/jido_claw/memory/consolidator/run_server.ex:599` — delete `facts when is_list(facts) -> {:ok, facts}` (L598 is live)
- `lib/jido_claw/memory/consolidator/run_server.ex:617` — delete `messages when is_list(messages) -> {:ok, messages}` (L616 is live)
- `lib/jido_claw/memory/consolidator/run_server.ex:649` — delete `list when is_list(list) -> list` (L648's `{:ok, list} when is_list(list)` is live)
- `lib/jido_claw/memory/consolidator/run_server.ex:682` — delete `runs when is_list(runs) -> first_non_null_watermark(runs, stream)` (L681 is live)
- `lib/jido_claw/shell/commands/jido.ex:130` — delete `{:ok, %JidoClaw.Solutions.Solution{} = sol} -> {:ok, sol}` (L128 `{:ok, [first | _]}` and L129 `{:ok, []}` together cover the type)
- `lib/jido_claw/solutions/matcher.ex:140` — delete `{:ok, %Solution{} = sol} -> {:ok, sol}` (same pattern as above)

### Upstream `@spec` is tighter than the catch-all assumes (10 findings)

- `lib/jido_claw/audit/producers.ex:85` — delete `defp field(_, _), do: nil`. The earlier `when is_map(map)` clause covers all call sites.
- `lib/jido_claw/conversations/recorder.ex:258` — delete the bare `:ok -> :ok` clause. `RequestCorrelation.record_telemetry/2` returns only `{:ok, _} | {:error, _}`.
- `lib/jido_claw/conversations/recorder.ex:415` — same as 258.
- `lib/jido_claw/forge/persistence.ex:93` — delete the `{:error, :already_claimed}` arm. Dialyzer reports the upstream return type rules it out (the transaction body's error shapes don't include this tuple).
- `lib/jido_claw/memory.ex:239` — delete bare `:error -> ...` clause. `Scope.resolve/1` returns only `{:ok, _} | {:error, _}`.
- `lib/jido_claw/tools/kill_agent.ex:43` — delete the `{:error, reason}` catch-all. `JidoClaw.Jido.stop_agent/1` only returns `:ok | {:error, :not_found}` (which is matched by the preceding clause).
- `lib/jido_claw/cli/commands.ex:436` — delete the `{:error, _}` arm. `Network.Node.disconnect/0` only returns `:ok` (see Tier 3 note).
- `lib/jido_claw/cli/commands.ex:889` — delete `defp primary_fk(_), do: nil` after specific struct-pattern clauses; all call sites pass a known scope map.
- `lib/jido_claw/shell/profile_manager.ex:392` — delete the 2-elem `{:error, _}` catch-all. `SessionManager.update_env/3` only returns 3- and 4-elem error tuples.
- `lib/jido_claw/shell/profile_manager.ex:470` — same as 392.

### Non-Ash list/tuple returns where fallback is dead (3 findings)

- `lib/jido_claw/web/controllers/health_controller.ex:14` — delete `_ -> 0`. `Registry.select/2` is spec'd to return a list, so the `list when is_list(list)` arm at L13 is exhaustive.
- `lib/jido_claw/memory/consolidator/mcp_endpoint.ex:44` — delete `{_addr, port} -> port`. `ThousandIsland.listener_info/1` returns only `{:ok, _}`; L43's `{:ok, {_addr, port}}` is the live arm.
- `lib/jido_claw/shell/session_manager.ex:801` — delete the 2-elem `{:error, %Jido.Shell.Error{} = err}` arm. `start_ssh_session/4` only returns the struct in 3-elem form `{:error, err, entry}`.

### Status-tagged case never reached (1 finding)

- `lib/jido_claw/memory/consolidator/run_server.ex:1081` — in `finalise/3`, the `{:succeeded, {:ok, run}} -> {:ok, run}` arm is unreachable: `finalise/3` is only called on non-success paths (success goes through `finalise_with_run/3`). Cleanest mechanical fix is to write the run row for its side effects and ignore its return — e.g., call `maybe_write_run_row/3` then dispatch to `do_finalise(state, {:error, reason})` (or the existing non-success helper). Read the function before editing to confirm the exact helper names and to make sure all `maybe_write_run_row/3` return shapes are still handled; do NOT just delete the `:succeeded` arm in isolation if that leaves a brittle case match against shapes the function can still return.

### Note: Solution presenter fallback (no extra finding)

`shell/commands/jido.ex:130` and `solutions/matcher.ex:140` are both already counted under the "Ash bare-list" subsection above. No double-count.

---

## Deferred (not in this effort)

| Finding(s) | File(s) | Why deferred |
|---|---|---|
| Forge harness `with` `else` arms × 5 | `lib/jido_claw/forge/harness.ex:137, 257, 738, 1064, 1071` | Both `ResourceProvisioner.provision_all/2` and `Bootstrap.execute/3` return `{:error, map(), reason}`, so the earlier `when is_map(resource)` arm silently classifies bootstrap failures as resource failures. The mechanical deletion clears dialyzer but the right fix tags the two error sources before the `with`. |
| VFS workspace `else` branches × 4 | `lib/jido_claw/vfs/workspace.ex:278, 290, 295, 384` | `do_mount`/`do_vfs_mount` are currently only called with `fail_soft?: true`, so the `else: {:error, _}` branches are dead. But public `mount/4` is spec'd `:ok \| {:error, term()}` — needs a contract decision on whether external callers should be able to opt into hard-fail before we delete the branch. |
| verify_certificate.ex × 7 | `lib/jido_claw/tools/verify_certificate.ex:104, 108, 111, 114, 117, 130, 208` | All cascade from `run_reasoning/2` having no inferred return type. Needs `@spec` design across `Telemetry.with_outcome/4` and the reasoning runner dispatch. |
| Forge runner callback widening × 3 | `lib/jido_claw/forge/runner.ex` (behaviour) | `@callback init` and `@callback apply_input` are spec'd `:ok` but all implementations return `{:ok, state}`. One-line fix to the behaviour, but it's a contract change worth scrutinizing on its own. |
| voyage.ex retry-after × 1 | `lib/jido_claw/embeddings/voyage.ex:139` | Real runtime bug: `List.keyfind` on Req's headers map silently returns nil. Switching to `Req.Response.get_header` needs verification against current Req behavior. |
| authorization actor() type × 1 | `lib/jido_claw/authorization/actor.ex:30` | Widen `@type actor` to allow `:kind => :system`. Small, but a type definition decision. |
| `repo.ex` `all_tenants/0` no_return × 1 | `lib/jido_claw/repo.ex:2` | Add `@dialyzer {:no_return, all_tenants: 0}` for auto-injected AshPostgres function. Trivial but a project-wide annotation pattern worth deciding consistently. |
| ServerEntry port spec × 1 | `lib/jido_claw/shell/session_manager.ex:796` | Widen `ServerEntry.port` from `pos_integer()` to `non_neg_integer()` (the `0` sentinel for "unknown port" is intentional). |
| pull_request_coordinator guard × 1 | `lib/jido_claw/github/agents/pull_request_coordinator.ex:11` | Guard never reached because recursion structure prevents `attempt > @max_attempts`. Needs control-flow rethink. |
| postgrex improper list × 1 | `deps/postgrex/lib/postgrex/type_module.ex:1045` | External, not actionable. |

**Total deferred:** 25 findings.
**Targeted in this effort:** 34 findings.
**59 − 34 − 25 = 0** (counts reconcile).

---

## Verification

1. **After Tier 1:** `mix dialyzer.clean && mix dialyzer` — expect 7 findings drop. PLT rebuild will be slow; that's the one-time cost.
2. **After Tier 2:** `mix dialyzer` — expect 5 more drop (total 12).
3. **After Tier 3:** `mix dialyzer` — expect 1 more drop (total 13).
4. **Per Tier 4 file or small batch:** `mix dialyzer` — confirm the targeted finding(s) clear without new ones appearing. Tier 4 takes the cumulative drop from 13 to 34 resolved.
5. **Final:**
   - `mix compile --warnings-as-errors`
   - `mix format --check-formatted`
   - `mix test`
   - Smoke-run `mix jidoclaw` briefly — most Tier 4 deletions sit in CLI command handlers, so a quick REPL boot + a couple of commands (`/memory status`, `/network status`) is worth doing.

Expected final dialyzer count: **~25 findings remaining**, all in the "Deferred" table.

## Files touched

**Tier 1:** `mix.exs`
**Tier 2:** `lib/jido_claw/platform/skills.ex`, `lib/jido_claw/agent/prompt.ex`
**Tier 3:** `lib/jido_claw/network/node.ex`
**Tier 4 (13 files):**
- `lib/jido_claw/audit/producers.ex`
- `lib/jido_claw/cli/commands.ex`
- `lib/jido_claw/conversations/recorder.ex`
- `lib/jido_claw/forge/persistence.ex`
- `lib/jido_claw/memory.ex`
- `lib/jido_claw/memory/consolidator/mcp_endpoint.ex`
- `lib/jido_claw/memory/consolidator/run_server.ex`
- `lib/jido_claw/shell/commands/jido.ex`
- `lib/jido_claw/shell/profile_manager.ex`
- `lib/jido_claw/shell/session_manager.ex`
- `lib/jido_claw/solutions/matcher.ex`
- `lib/jido_claw/tools/kill_agent.ex`
- `lib/jido_claw/web/controllers/health_controller.ex`
