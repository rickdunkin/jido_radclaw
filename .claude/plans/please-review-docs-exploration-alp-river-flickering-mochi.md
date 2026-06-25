# AR-8b-2 F2 — Phase 1: `:docker` policy tier + RunCommand↔Forge bridge (plumbing)

## Context

AR-8b shipped the **sketch path**: a `sketch` turn launches a file-tools-only worker in a
hard-isolated `<project>/.prototypes/<uuid>/` jail (`sandbox: :prototype`). The one thing a sketch
**cannot** do is *run* its tracer-bullet — by design. `RunCommand` shells to
`JidoClaw.Shell.SessionManager` (host/vfs/ssh), which escapes the VFS jail entirely (the jail only
constrains file-tool *paths*, not a spawned shell). A sketch that must execute code needs **OS-level**
isolation (filesystem, process, network), which the file jail does not provide.

F2 adds a **`:docker` sandbox tier** that routes `RunCommand` into the existing Forge Docker microVM
substrate (`JidoClaw.Forge` → `Forge.Sandbox.Docker`). Per `docs/exploration/alp-river/AR-8b-2-F2-EXEC-TIER.md`
it ships in **two passes**:

- **Phase 1 — Plumbing (THIS PLAN):** make `:docker` a first-class sandbox policy everywhere, and
  bridge `RunCommand` into a Forge Docker session when `tool_context[:sandbox] == :docker`.
- **Phase 2 — Activation (NOT this plan):** the `sketch_build_exec` worker, the `sketch-build-exec`
  catalog stage, the triage `must-execute` signal, and the front-door Forge-session lifecycle.

**The heart of the work** (the load-bearing finding): two execution substrates are **fully
disconnected** — `RunCommand → Shell.SessionManager` (keyed by `workspace_id`, returns
`{:ok, %{output:, exit_code:}}`) and `JidoClaw.Forge` (microVM sessions keyed by `session_id`, returns
`{:ok, {output, exit_code}}`). Nothing routes a tool command into a Forge sandbox today. Building that
bridge — with its return-shape adapter, two distinct "`sbx` is missing" channels, and a timeout race —
is the bulk of Phase 1.

**Intended outcome.** `:docker` is a first-class policy; `RunCommand` under `:docker` routes into a
Forge Docker session and **hard-fails (never falls back to the host)** if the session is unavailable.
**No worker uses `:docker` yet** (Phase 2), so Phase 1 has **no user-visible behavior change** and is
exercised purely by policy + bridge unit tests via `JidoClaw.Test.StubSandbox`. **Done = `mix precommit`
green.** Greenfield — no migration / back-compat.

---

## Ground-truth corrections (the design doc's line numbers drifted — use these)

| Doc says | Actual |
| --- | --- |
| `lib/jido_claw/agent/tool_context.ex` | **`lib/jido_claw/tool_context.ex`** |
| `lib/jido_claw/agent/agent_runner.ex` / `AgentRunner` | **`lib/jido_claw/skills/steps/agent_runner.ex`**, module **`JidoClaw.Skills.Steps.AgentRunner`** |
| `OutputShaper.effective_streaming?/1` near shapeable? | It's at **lines 153-158, arity 1 (`params` only)** — needs a new `(params, context)` arity |
| `ToolApproval.requirement/3` / `native_requirement/3` | Both are **`/4`** (trailing `opts`); `native_requirement/4` at lines 250-256 |
| read-real `:prototype` check in each of 3 tool files | Single-sourced in **`real_tree.ex:38`** (the per-tool `~:10/:9/:8` are moduledoc prose) → **one** code edit |
| `pattern_match` floor incl. `:structure` | `pattern_match/3` at 280-292; only the **5 `{:effect, _}`** matchers are the non-disableable floor (`:structure` is config-disableable). Irrelevant to the bypass (we skip all of `pattern_match`). |
| `StubSandbox.exec` programmable | `exec/3` returns a hard-coded `{"", 0}` (line ~70); **no `program_exec`** — must add it |

Also note: the template-policy atom **`:docker`** and the Forge-backend atom **`:docker_sandbox`** are
**deliberately distinct** — don't conflate. (Phase 2's front door will start a Forge session with
`sandbox: :docker_sandbox`; this plan only sets/reads the template policy `:docker` and calls
`Forge.exec`/`Forge.stop_session` on a session key.)

---

## Unit A — `:docker` as a first-class policy

**`lib/jido_claw/agent/templates.ex`**
- `validate_sandbox/2` (line 263): `when s in [:none, :prototype]` → `… [:none, :prototype, :docker]`.
  Without this, a `:docker` template value **fails closed to `:prototype`** (silently routes through the
  file jail, not the OS sandbox).
- `external_tools?/1` (line 188): `sandbox(name) != :prototype` → `sandbox(name) not in [:prototype, :docker]`.
  Else `:docker` workers wrongly keep external MCP tools (the sole consumer is
  `MCP.Consumer.modules_for_template/3`, `consumer.ex:641`).
- `sandbox/1` `@spec` (line 173) + docstring (166-172) + moduledoc (40-50): add `:docker`.

**`lib/jido_claw/tool_context.ex`**
- `:sandbox` doc/enum (lines 38-45): extend to `:none | :prototype | :docker`. **Doc only** — `:sandbox`
  is canonical (not policy-controlled), so propagation/inheritance is value-agnostic; `:docker` rides
  the existing machinery with no code change. (Proven by the existing `tool_context_test.exs` `:sandbox`
  block.)

**`lib/jido_claw/vfs/sandbox.ex`**
- `resolver_opts/1` (lines 125-143): treat `:docker` like `:prototype` (jail to `project_dir`,
  `local_only: true`) — add a `:docker ->` clause delegating to `sandbox_resolver_opts/2`, or match
  `sandbox when sandbox in [:prototype, :docker]`. Without this, `:docker` falls into the `_ ->` default
  (host cwd, `local_only: false`) — the unsandboxed path. `validate_root/1` / `real_root/1` already key
  off the `.prototypes/<uuid>/` shape, which `:docker` also has.

**`lib/jido_claw/tools/real_tree.ex`**
- `resolver_opts/1` (line 38): widen the `:prototype ->` gate to also accept `:docker`
  (`sandbox when sandbox in [:prototype, :docker] ->`). This is the **single source** for all three
  read-real tools (`read_real_file`/`search_real_code`/`list_real_directory`) — no per-tool code edit.
  (Optionally update the moduledoc prose in those three files to mention `:docker`.)

---

## Unit B — Approval-gate bypass for `:docker` (D2-b)

**`lib/jido_claw/security/tool_approval.ex`** — `native_requirement/4` (lines 250-256). Add a
`sandbox: :docker` bypass **after** the `tool in require_list(opts)` check and **before**
`pattern_match/3`: for `run_command` under `:docker`, skip the whole `pattern_match/3` matcher set — the
five non-disableable `{:effect, _}` matchers (`git_commit`/`git_config_injection`/
`git_config_persistent_write`/`crontab`/`opaque`, `tool_approval.ex:154-173`) **plus** the
config-disableable `:structure` matcher — but **still** consult `template_requirement/2`:

```elixir
defp native_requirement(tool, params, context, opts) do
  cond do
    tool in require_list(opts) -> :listed
    docker_run_command?(tool, context) -> template_requirement(tool, context)
    true -> pattern_match(tool, params, opts) || template_requirement(tool, context)
  end
end
```

Add `docker_run_command?/2` (`tool == "run_command" and sandbox_from(context) == :docker`) and a nil-safe
`sandbox_from/1` mirroring the existing `template_name/1` (`%{tool_context: %{sandbox: s}} -> s`).
Rationale (comment it): a worker carries `:docker` only when Phase 2's front door created a
proven-no-egress, globally-unmounted session — else it degrades to file-only; the floor's *reasons*
(host git/crontab/opaque) are inapplicable in-container. The bypass keeps the **additive** policy intact
(operator `require:` and template overlay still gate). **The bypass's safety rests on a structural
invariant, not just the `:docker` stamp (review P2):** the per-call gate can't afford a Forge lookup, so it
trusts `sandbox: :docker`. What makes that trust safe is **Unit D's `validate_sandbox_scope(:docker)`, which
refuses to launch a `:docker` worker unless its Forge session is a *real* `:docker_sandbox` backend** — so a
`:docker` stamp accidentally placed on a ready HostShell/default session never produces a running worker,
and the bypass therefore never fires against a non-isolated session. (Plus the Phase 2 front-door invariant:
stamp `:docker` only after a successful `:docker_sandbox` no-egress create.) **Inert in Phase 1** (no
`:docker` worker); active
in Phase 2.

---

## Unit C — The RunCommand↔Forge bridge (the hard part)

### C1 — Branch in `RunCommand.run/2` (`lib/jido_claw/tools/run_command.ex`)
As the **first** expression inside the `MCPScope.wrap` callback (after line 89), read
`sandbox = get_in(enriched, [:tool_context, :sandbox])` and
`forge_key = get_in(enriched, [:tool_context, :forge_session_key])`. When `sandbox == :docker`, route to
`ForgeBridge.dispatch(command, forge_key, params, enriched)` and **ignore `backend`/`server` entirely** —
short-circuit **before** `coerce_backend` / `validate_backend_server` so a model-supplied `backend: "ssh"`
can neither preempt the Forge route nor raise a spurious SSH error (the sandbox is set by template policy,
not params). Leave the `backend` schema enum and `coerce_backend/1` untouched. Pass `enriched` (not just
`forge_key`/`timeout`) so the bridge can read the outer deadline (C2.0): `:__jido_deadline_ms__` is set on
the action context by `Jido.Exec` and **preserved by `ensure_nested/1`** (all three clauses keep top-level
keys) — confirm it also survives `MCPScope.wrap` into the body's context; if not, capture it in the
`Tools.Action` wrapper before `MCPScope.wrap` and stash it. The branch returns
`{:ok, %{output:, exit_code:}}` | `{:error, %{code:, message:, details:}}`, which flows through the outer
`Tools.Action` pipeline (`action.ex:60-63`: normalize → redact → shape → cap) like any result.

### C2 — New `JidoClaw.Tools.RunCommand.ForgeBridge` (`lib/jido_claw/tools/run_command/forge_bridge.ex`)
A small helper. Split it into a **pure, public `normalize_exec_result/2`** (the load-bearing logic, hand-fed
backend tuples in tests — review note) and a thin `dispatch/4` (`command, forge_key, params, context`) that
does the Forge I/O + taint side-effect. `dispatch/4` owns:

0. **Derive the inner command timeout from the Jido outer deadline (the real timeout-race fix — review P1).**
   The bridge passes `timeout` to `Forge.exec`, but the **whole `RunCommand` action** is wrapped by
   `Jido.Exec`, which **kills the task at its own deadline** (`deps/jido_action/lib/jido_action/exec.ex:542`)
   sized from `tool_timeout_ms` (default **30_000** on the main agent + every worker, `agent.ex:54`,
   `coder.ex:25`). Since `RunCommand`'s `timeout` param **also** defaults to **30_000**
   (`run_command.ex:42`), a bare cushion is moot: Jido kills the action before the bridge can
   taint/stop/return. **Fix:** read the absolute deadline `Jido.Exec` stamps into the action context —
   `context[:__jido_deadline_ms__]` (`exec.ex:54,644`, a `System.monotonic_time(:millisecond)` value) and
   derive the **inner Forge command timeout** from the remaining budget. **Normalize the requested timeout
   *inside the bridge* (review P2):** the docker branch short-circuits **before** `run/2`'s own
   `timeout = Map.get(params, :timeout, 30_000)` line (`run_command.ex:90`), so a direct
   `RunCommand.run/2` call that omits `:timeout` would otherwise hand `nil` to `min/2` — apply the same
   default locally: `requested = Map.get(params, :timeout, 30_000)`. Then
   `remaining = deadline_ms - System.monotonic_time(:millisecond)`; `budget = remaining - margin` where
   `margin = Forge.exec_timeout_cushion_ms() + taint_overhead` (the cushion is **single-sourced** behind the
   `Forge` facade — review P3; never a duplicated `5_000` literal). Then:
   - **If `budget` is below a minimum-viable-launch threshold (e.g. ~1_000ms) → refuse**: return a
     non-retryable `:sandbox_deadline_exceeded` and **don't launch** (there isn't time to run + taint +
     return before Jido kills the action).
   - **Otherwise `inner = min(requested, budget)`** — a legitimately small **explicit** command timeout is
     honored (never raised; `RunCommand` accepts any positive integer, `run_command.ex:42`), a
     large/default one is clamped under the outer budget. The threshold gates *whether to launch*, not the
     floor of an explicit timeout.

   This guarantees the inner `OsCmd` fires, the cushioned Harness call returns the manufactured `124`, and
   the bridge taints + returns its non-retryable error **all before** Jido's deadline. Fall back to
   `requested` (the locally-defaulted timeout) only when `:__jido_deadline_ms__` is absent (e.g. a direct
   test call).
1. **Call Forge:** `Forge.exec(forge_key, command, timeout: inner_timeout)`, wrapped in
   `try … catch :exit, {:timeout, _} -> <taint outcome>` (the residual catch; pairs with the C3 cushion and
   the C2.0 deadline derivation).
2. **`normalize_exec_result/2` (pure, public) — covers EVERY shape (review P2):**
   - `{:ok, {out, code}}` **with `is_integer(code)`** → manufactured-code dispatch (below). Only adapt a
     success when `code` is an integer.
   - **Any** `{:error, term}` from `Forge.exec`/`Harness.exec` — `:not_found`, `{:invalid_state, _}`
     (`harness.ex:490`), `{:provision_failed, _}` (`:984`), `{:unknown_sandbox, _}` (`:991`), or any other —
     → a **non-retryable** `:sandbox_unavailable` error (no taint; nothing ran in-container). **Hard-fail,
     never `SessionManager`.**
   - Any other/`{:ok, <non-tuple>}` shape → defensive non-retryable `:sandbox_unavailable` error.
   - Returns a tagged value so the side-effect stays in `dispatch`, e.g. `{:ok, map}` |
     `{:error, err}` | `{:taint, err}` (the caller runs `Forge.stop_session` on `:taint`).
3. **Manufactured-code dispatch — match the manufactured *exact message* + code, never code alone
   (review P2/P3).** The Docker backend manufactures recognizable `{message, code}` pairs (`docker.ex:308/320/
   322-324`); a *user* command can legitimately exit 124/153/127 with its **own** output, so disambiguate by
   the exact message the backend emits — **exact/anchored, not prefix (review P3)**, to minimize false
   taints when a user command exits 124/153 with manufactured-*looking* output (same posture as the existing
   `sbx`-127 exact match):
   - `code == 127` **and** `out == "sbx: command not found"` → non-retryable `:sandbox_unavailable`;
     **no taint** (nothing ran).
   - `code == 124` **and** `out == "timeout after #{inner_timeout}ms"` (an **exact** match — the bridge knows
     the `inner_timeout` it passed, `docker.ex:320`) → **`:taint`** + non-retryable `:sandbox_command_timeout`.
     (The caught `:exit, {:timeout, _}` from step 1 funnels to the **same** outcome — both delivery paths
     converge.)
   - `code == 153` **and** `out` matches the **anchored** `~r/\Aoutput limit exceeded after \d+ bytes\z/`
     (the byte count is dynamic, `docker.ex:322-324`, so anchor rather than exact-compare) → **`:taint`** +
     non-retryable `:sandbox_output_limit`.
   - **everything else — including a user command that genuinely exits 124/153/127 with different output** →
     ordinary `{out, code}` → `{:ok, %{output: out, exit_code: code}}` (parity with `SessionManager.run/4`
     and the tool's `output_schema` — `Forge.exec` yields a *tuple inside `:ok`*, the schema wants a *map
     inside `:ok`*). **No taint** on a user's own exit code.

   On a `:taint` result, `dispatch/4` runs `Forge.stop_session(forge_key)` (best-effort, kills the
   in-container zombie).
4. **Non-retryability — the `code` AND the `details` matter (review P1 / P3):** the ReAct runner retries any
   `Jido.AI.Error.retryable?(result)` (`deps/jido_ai/.../reasoning/react/runner.ex:909`). `retryable?/1`
   keys off the error `code` (`:timeout`/`:transient`/`:transient_error`/`:rate_limited` are retryable,
   `error.ex:467`) **and also digs into `details`** — `extract_retry_hint/1` reads retry-values and a nested
   `:reason` from `details` (`error.ex:387-418`). And `JidoClaw.Tools.Error.normalize_result/1`
   (`error.ex:80-88,119-122`) **drops** a top-level `retryable?` field but **preserves** `details`, and
   `code_from_value/1` maps a `"timeout"` *string* back to `:timeout`. ⇒ the bridge MUST: (a) use **distinct
   non-retryable codes** (`:sandbox_command_timeout`, `:sandbox_output_limit`, `:sandbox_unavailable`,
   `:sandbox_deadline_exceeded`) — never `:timeout`/`"timeout"`; **(b)** keep `details` **free of any
   retry-hint key/value** — no `:reason`, `:retry*`, `:retryable`; use neutral keys like `exit_status`,
   `sandbox_status`, `operation`. Return the full `%{code:, message:, details:}` shape so the code passes
   through verbatim.

### C3 — `Harness.exec/3` timeout cushion (`lib/jido_claw/forge/harness.ex:61-65`)
Complements C2.0 (which keeps the bridge under the *outer Jido* deadline); this keeps the *inner Forge*
ordering right. Today the outer `GenServer.call(pid, {:exec, …}, timeout)` and the inner
`OsCmd.run(…, timeout: timeout)` use the **same** `opts[:timeout]`; the outer (send-time) deadline elapses
before the inner (later-start) one, and `call/3` (lines 87-112) catches only `:exit, {:noproc, _}` (not
`:timeout`). So a real in-container timeout would surface as an **uncaught caller `:exit, {:timeout, _}`** and
the manufactured `124` would never reach the bridge. **Fix:** give the **outer** call a deadline of
`timeout + cushion` (e.g. +5_000ms) while the **inner** `opts[:timeout]` stays the caller value — so the
inner backend wins, returns `{_, 124}`, and the bridge's 124-taint path runs as designed. **Single-source
the cushion behind the `Forge` facade (review P3):** expose `@doc false` `JidoClaw.Forge.exec_timeout_cushion_ms/0`
(the bridge already depends on `Forge`, not `Forge.Harness`, so a tool helper reaching a harness internal is
avoided; a tiny `JidoClaw.Forge.Timeouts` module is the equivalent alternative). It's read by **both** the
outer-call arithmetic here (a small `exec_call_timeout(opts)` seam, so it's unit-testable) **and** C2.0's
`margin` — so the value can never drift. (C2.0's `margin = Forge.exec_timeout_cushion_ms() +
taint_overhead`, so the chain is `inner_OsCmd < harness_outer (inner + cushion) < jido_deadline`.)
**Blast radius:** *before* this bridge, `Harness.exec/3` had **no production callers** (verified — only the
Forge test suite; `run_server` uses `run_iteration`, not `exec`), so the cushion regresses nothing
pre-existing. Phase 1 *adds* the `RunCommand → Forge.exec → Harness.exec` production path, but does **not**
activate it through any shipped template (no `:docker` worker until Phase 2), so the change is inert except
on the timeout path of that new, not-yet-prod-reachable route.

### C4 — Docker streaming-neutralization (`lib/jido_claw/tools/output_shaper.ex`)
`Forge.exec` returns the whole `{output, exit_code}` at once — the docker route **never streams**. But a
model setting `stream_to_display: true` makes `effective_streaming?(params)` true →
`capture? = shapeable?(…)` false → oversized docker output hits `OutputLimit`'s 32KB head/tail cut **with
no `fetch_output` ref** (silent middle-drop). The fix must live in the **predicate** — the wrapper's final
`OutputShaper.shape_result(result, …, params, enriched_context)` (`action.ex:62`) re-gates on `shapeable?`
with the **original** params, so a RunCommand-local copy wouldn't reach it.
- Add `effective_streaming?(params, context)` returning `false` when
  `get_in(context, [:tool_context, :sandbox]) == :docker`, else delegating to the existing `/1` logic.
  Keep `/1` (delegate with no context).
- `shapeable?/3` (line 174): call `effective_streaming?(params, context)` (it already has `context`).
- `RunCommand.run/2:102`: call `effective_streaming?(params, enriched)`.

Net: docker ⇒ never actually streams, always captures + shapes + ref-stores; the pre-exec capture
decision and the post-exec wrapper shaping agree by construction.

### C5 — `StubSandbox.program_exec/2` (`test/support/stub_sandbox.ex`)
`exec/3` returns a hard-coded `{"", 0}`. Add an `exec_response` field to `create/1`'s state (default
`{"", 0}`), a `program_exec/2` mirroring `program_run/2`, and have `exec/3` return it. To exercise the
**timeout race** (C3), `program_exec` must also accept a **blocking form** (e.g. a `{:sleep, ms, response}`
directive or a 0-arity fn) so a test can block past `timeout` (cushion check) or past `timeout + cushion`
(bridge-catch check). Keep the existing event recording.

---

## Unit D — Scope validation + `forge_session_key` threading (D5)

**`lib/jido_claw/skills/steps/agent_runner.ex`**
- `validate_sandbox_scope/2` (lines 107-114): add a `%{sandbox: :docker}` clause **above** the catch-all
  `:ok`, asserting **both**:
  1. **valid prototype root** — `Sandbox.validate_root(context[:project_dir])` (same as `:prototype`;
     `:docker` file tools are jailed to `project_dir == .prototypes/<id>/` exactly like `:prototype`, so
     without it `resolve_scope`'s `File.cwd!()` fallback would let host file tools hit the real tree);
  2. **ready Forge session — assert backend identity + *sandbox* readiness, not just session state
     (review P1/P2).** `forge_key = context[:forge_session_key]`, then `Forge.status/1`. **First expose the
     backend in status:** the harness state already carries the resolved default-client module
     `state.sandbox_module` (`harness.ex:40,142`) but `:status` (`harness.ex:540-553`) doesn't surface it —
     add `sandbox_module: state.sandbox_module` to that status map (small additive change). Then require
     **all** of:
     - **`sandbox_module == JidoClaw.Forge.Sandbox.Docker`** — the session is a *real* Docker backend, not a
       HostShell/default one (review P2). This is what makes Unit B's per-call approval bypass safe: a
       `:docker` stamp on a non-Docker session can never launch a worker.
     - **`state == :ready`** AND **`sandbox_status == :ready`** AND **`:default in sandboxes`** (the default
       sandbox is already provisioned). Load-bearing: a *deferred* session can be `state: :ready` with **no**
       default sandbox, and a later `Forge.exec` (no `:sandbox` opt) would **lazily provision** it
       (`ensure_default_sandbox → provision_sync`, `harness.ex:1005-1011`) — silent re-provisioning, contrary
       to "do not re-provision." Checking `:default in sandboxes` at validate time forecloses it.

     On missing/dead/not-fully-ready/**wrong-backend** → **fail closed** (`{:error, …}` → stage errors,
     composer terminalizes). Do **not** re-provision (Phase 2 / D7 Window 2). (The Phase 2 front door is the
     *other* half of the invariant: stamp `:docker` only after a successful `:docker_sandbox` no-egress
     create — documented there.)
- `resolve_scope/2` (lines 336-354): add `forge_session_key: context[:forge_session_key]` to the scope map
  (`build/1` preserves it when non-nil, omits it when nil). `stamp_sandbox/2` (line 122) already forwards
  the `:docker` atom unchanged — no edit.

In Phase 1 no `:docker` worker launches in production, so this clause is exercised only by unit tests.

---

## Unit E — D6 composer-private refusals

Widen the literal `%{sandbox: :prototype}` match to `%{sandbox: s} when s in [:prototype, :docker]`
(or add a `:docker` clause) at the 5 sites, so `:docker` (like `:prototype`) can't be spawned /
handed-off / own a session directly (front-door-only):
- `lib/jido_claw/tools/spawn_agent.ex:61`
- `lib/jido_claw/tools/send_to_agent.ex:175`
- `lib/jido_claw/tools/handoff.ex:233`
- `lib/jido_claw/agent/handoff/router.ex:275` **and** `:358`

---

## Unit F — Tests (all precommit-green via stubs)

**Testability key:** `Templates.get/1` honors the `:agent_templates_override` env, so `sandbox/1`/
`external_tools?/1` for `:docker` are tested by injecting a synthetic
`%{"docker_stub" => %{module: <an existing worker, e.g. Coder>, sandbox: :docker}}` — **no real `:docker`
template/worker needed** (matches the existing "malformed sandbox" test). Works only after Unit A's edits.
For StubSandbox-backed Forge sessions, prefer the per-spec `sandbox: StubSandbox` route (resolved by
`Harness.resolve_client/1`) + disabling `JidoClaw.Forge.Persistence` — mirror
`test/jido_claw/forge/harness_bootstrap_env_test.exs`.

1. **Bridge normalization** — new `test/jido_claw/tools/run_command/forge_bridge_test.exs`: hand-feed
   backend tuples to the **pure public `normalize_exec_result/2`** (the explicit test seam — review note;
   `dispatch/4` otherwise only calls `Forge.exec`). `{"sbx: command not found", 127}` →
   `{:error, _}` non-retryable, **no taint**; the manufactured `{"timeout after 5000ms", 124}` (with the
   bridge's `inner_timeout == 5000`) / `{"output limit exceeded after 1234 bytes", 153}` → `{:taint, _}`
   non-retryable. **Exact/anchored disambiguation (review P2/P3) — the trap-pins:** a *user* command exiting
   the same codes with **manufactured-looking-but-not-exact** output — `{"timeout after 999ms", 124}` (wrong
   value), `{"output limit exceeded after lots", 153}` (unanchored), `{"job done", 124}`, `{"nope", 127}` —
   must be **ordinary** `{:ok, %{output:, exit_code:}}` with **no taint** (the manufactured match is the exact
   message-for-this-`inner_timeout` / anchored regex **and** code, not code alone, not prefix). Plain ordinary
   `{out, code}` (integer code) → `{:ok, %{output:, exit_code:}}`; **and the error shapes**
   `{:error, :not_found}` / `{:error, {:invalid_state, _}}` / `{:error, {:provision_failed, _}}` /
   `{:error, {:unknown_sandbox, _}}` / a non-tuple `{:ok, _}` → `{:error, _}` non-retryable (review P2).
   **Assert non-retryability through the full pipeline on the REAL bridge error maps (details included —
   review P1/P3):** run each error map through `Tools.Error.normalize_result/1` and assert
   `Jido.AI.Error.retryable?/1` is **false** — using the actual `details` the bridge emits, so the test
   catches a stray `:reason`/`:retry*` key. Trap-pins: a `%{code: :timeout}` or `"timeout"`-status error is
   `true`; a `%{code: :sandbox_command_timeout, details: %{reason: :timeout}}` would be `true` (proving the
   details-hygiene requirement); a top-level `retryable?: false` is dropped by normalize.
2. **Bridge wiring via StubSandbox** (in `run_command_test.exs` or a docker-bridge test): start a
   StubSandbox-backed `:ready` Forge session, `program_exec` it, drive
   `RunCommand.run(%{command: …}, %{tool_context: %{sandbox: :docker, forge_session_key: sid, project_dir: proto}})`
   → assert the `{:ok, %{output:, exit_code:}}` adapter end-to-end, and **no `SessionManager` fallback**
   when the session is absent (hard-fail). A programmed 124/153 drives the taint path — assert
   `stop_session` ran and a follow-up `RunCommand` hard-fails.
3. **Timeout-race + deadline derivation:** (a) **inner-timeout from the Jido deadline (review P1)** —
   call the bridge with `context` carrying `:__jido_deadline_ms__` near-now and assert the inner
   `Forge.exec` timeout is `min(requested, budget)` where `requested = Map.get(params, :timeout, 30_000)`
   (drive a programmable stub or assert the computed value via a pure helper); a `budget` below the
   min-viable threshold returns non-retryable `:sandbox_deadline_exceeded` (no launch); a small **explicit**
   `:timeout` with ample budget is **honored, not raised**; an **omitted** `:timeout` defaults to 30_000
   inside the bridge (pins the C2.0 local-default — review P2). (b) **cushion** — `Harness.exec/3` outer
   deadline is `timeout + cushion`
   (unit-test the `Forge.exec_timeout_cushion_ms/0` seam, or a stub `exec` blocking past `timeout` but under
   `timeout + cushion` still yields the manufactured 124, not a caller `:exit, {:timeout, _}`).
   (c) **bridge-catch** — a `Forge.exec` that raises `:exit, {:timeout, _}` (stub blocking past
   `timeout + cushion`) converts to the **same** taint + `:sandbox_command_timeout`.
   (d) **full `Jido.Exec.run/4` propagation (review P2) — the regression that pins the actual bug** — run
   `RunCommand` through `Jido.Exec.run(RunCommand, params, docker_context, timeout: T_outer)` (the real
   action wrapper, not a bare `RunCommand.run/2` call) against a StubSandbox session whose `exec` blocks
   past the derived inner budget: assert the result is the **bridge's** non-retryable
   `:sandbox_command_timeout` / `:sandbox_deadline_exceeded`, **not** Jido's own `Error.timeout_error`
   (type `:timeout`, retryable). This proves `:__jido_deadline_ms__` survives `Tools.Action` +
   `MCPScope.wrap` into the bridge (the one hop flagged must-verify in C1) and that the bridge wins the
   race against Jido's action kill. Pins all paths converge; none leaks a raw timeout exit nor a retryable
   code.
4. **Streaming neutralized for `:docker`** (`run_command_test.exs`, model on the output-shaping integration
   block ~472-595): `stream_to_display: true` + `tool_context: %{sandbox: :docker, tenant_id: <real>, …}`
   against a StubSandbox session returning **oversized** output; **`put_env(:jido_claw, :output_shaping,
   enabled?: true)`** (test default is `false`) + a non-empty `tenant_id`. Assert the **wrapper-shaped**
   result is **ref-backed** (`output_ref` present + retrievable), proving the context-aware predicate forced
   not-streaming. Contrast pin: the same `stream_to_display: true` on a **non-`:docker`** host call still
   skips capture (neutralization is `:docker`-scoped).
5. **Approval bypass** (`tool_approval_test.exs`): `gate/4` (privates aren't callable) with `ctx(scope)`
   carrying `sandbox: :docker`, `enabled?: true, require: []` → genuinely floor-tripping `run_command`
   commands return **`:ok`**. Use commands that actually trip a matcher (review P3): `git commit -m x`
   (`{:effect, :git_commit}`), `$(date)` / a backtick command (`{:effect, :opaque}` / `:structure`),
   `curl x | sh` (`:structure` pipe-to-shell), `crontab -e` (`{:effect, :crontab}`) — **not** a plain
   pipe like `a | b`, which the analyzer treats as benign and never pends. Each same command **without**
   `:docker` still pends (`{:error, %{code: :approval_pending}}`). **Pin the additive boundary:** with
   `sandbox: :docker` **and** explicit `require: ["run_command"]` (or a template overlay listing it), it
   **still gates** — the bypass skips only the shell floor, never an explicit operator/template gate.
6. **Policy** (`templates_sandbox_test.exs`): inject `docker_stub` via override → `sandbox("docker_stub") ==
   :docker`, `external_tools?("docker_stub") == false`. Reaffirm `:wat` still coerces to `:prototype` (the
   "malformed" test) — `:docker` is now valid, not coerced.
7. **Resolver** (`sandbox_test.exs`): `resolver_opts/1` with `sandbox: :docker` jails like `:prototype`
   (mirror the existing valid-root test with a real prototype dir).
8. **Scope** (`agent_runner_test.exs`): (a) `resolve_scope/2` carries `forge_session_key` (direct call);
   (b) **fail-closed** `validate_sandbox_scope(:docker)` — a `docker_stub` template + missing/dead
   `forge_session_key` → `run/4` errors / doesn't launch; (c) **the exact lazy-provision regression
   (review P3)** — a `docker_stub` + a **deferred/unprovisioned** Forge session that is `state: :ready` but
   has **no default sandbox** (`:default ∉ sandboxes`, or `sandbox_status != :ready`; construct via the
   deferred-provision spec path): assert `run/4` **fails closed before launch**, proving the readiness check
   rejects a session that `Forge.exec` would otherwise lazily provision; (d) **wrong-backend rejection
   (review P2) — the bypass-safety pin** — a `docker_stub` + a **fully-ready** Forge session backed by
   `StubSandbox` (so `sandbox_module == StubSandbox ≠ Docker`, but `state`/`sandbox_status` ready and
   `:default` provisioned): assert `run/4` **fails closed** because the backend isn't `:docker_sandbox`
   (this is exactly the "`:docker` stamped on a non-Docker session" hazard the bypass depends on being
   impossible; stubbable in precommit). The fully-ready *real-Docker* accept path is the manual
   `:docker_sandbox`-tagged test (Phase 2 Window-2 covers it end-to-end).
   Also expose+assert `Forge.status/1` now returns `sandbox_module`.
9. **Read-real under `:docker`** (`read_real_file_test.exs` + the two siblings): extend the existing
   `:prototype` jail blocks to also cover `sandbox: :docker` (reads work, jailed, remote schemes forbidden,
   no write counterpart).
10. **Refusals (D6)** (`spawn_agent_test.exs`, `send_to_agent_test.exs`, `handoff_test.exs`,
    `agent/handoff/router_test.exs`): extend the existing `:prototype` refusal tests to also refuse a
    `:docker` template (synthetic via override, matching each test's existing template-resolution setup).
11. **(optional) ToolContext** (`tool_context_test.exs`): mirror the `:sandbox` canonical/propagation block
    with `:docker` to prove the jail is inherited (value-agnostic; no code change).

---

## Critical files

| Concern | File |
| --- | --- |
| Policy admit/spec/external-tools | `lib/jido_claw/agent/templates.ex` |
| `:sandbox` enum doc (doc-only) | `lib/jido_claw/tool_context.ex` |
| File-tool jail for `:docker` | `lib/jido_claw/vfs/sandbox.ex` (`resolver_opts/1`) |
| Read-real gate (single source) | `lib/jido_claw/tools/real_tree.ex` (line 38) |
| Approval bypass | `lib/jido_claw/security/tool_approval.ex` (`native_requirement/4`) |
| Bridge branch | `lib/jido_claw/tools/run_command.ex` (`run/2`) |
| Bridge helper (new) | `lib/jido_claw/tools/run_command/forge_bridge.ex` (public `normalize_exec_result/2` seam) |
| Cushion facade | `lib/jido_claw/forge.ex` (`exec_timeout_cushion_ms/0` — single source for C2.0 margin + C3) |
| Outer deadline (read-only) | `deps/jido_action/lib/jido_action/exec.ex` (`:__jido_deadline_ms__` @ `:54,:644`; kill @ `:542`) |
| Timeout cushion + status | `lib/jido_claw/forge/harness.ex` (`exec/3`; add `sandbox_module` to `:status` @ `:540-553`; backend @ `:40,:142`; lazy provision @ `:1005-1011`) |
| Streaming predicate | `lib/jido_claw/tools/output_shaper.ex` (`effective_streaming?`, `shapeable?/3`) |
| Scope validate + key | `lib/jido_claw/skills/steps/agent_runner.ex` (`validate_sandbox_scope/2`, `resolve_scope/2`) |
| D6 refusals | `tools/spawn_agent.ex`, `tools/send_to_agent.ex`, `tools/handoff.ex`, `agent/handoff/router.ex` |
| Test stub | `test/support/stub_sandbox.ex` (`program_exec/2`) |
| Error codes (reuse) | `lib/jido_claw/tools/error.ex` (wire format / retryability) |

---

## Risks & notes

- **Two nested deadlines must be ordered (review P1) — the load-bearing timeout subtlety.** The chain is
  `inner OsCmd timeout < Harness outer GenServer.call (inner + cushion) < Jido.Exec action deadline
  (tool_timeout_ms)`. The Harness cushion (C3) keeps the *inner* (Forge) ordering right; the C2.0
  deadline-derivation keeps the bridge under the *outer* (Jido) deadline. Both are required: with the
  default `timeout: 30_000` (`run_command.ex:42`) == `tool_timeout_ms: 30_000` (`agent.ex:54`,
  `coder.ex:25`), a cushion alone is moot — `Jido.Exec` kills the whole action at the deadline
  (`exec.ex:542`) before the bridge can taint/stop/return. The bridge reads the absolute deadline Jido
  stamps into context, `context[:__jido_deadline_ms__]` (`exec.ex:54,644`).
- **`Harness.exec/3` cushion touches shared Forge code.** No *pre-existing* production callers (only the
  Forge test suite); Phase 1 adds the `RunCommand → Forge.exec` path itself but doesn't activate it via a
  shipped template (Phase 2). Inert except on the timeout path. The cushion is *necessary* — the inner
  OsCmd deadline and outer `GenServer.call` deadline both derive from the one `opts[:timeout]`, so they
  can't be separated without touching `Forge.exec`/`Harness.exec`. Belt-and-suspenders with the bridge's
  `:exit, {:timeout, _}` catch.
- **Non-retryable means code AND details (review P1/P3).** `Jido.AI.Error.retryable?/1` digs into the error
  `details` (retry-values + nested `:reason`, `error.ex:387-418`), which `Tools.Error.normalize` preserves.
  Bridge error `details` must carry only neutral keys (`exit_status`/`sandbox_status`/`operation`), never
  `:reason`/`:retry*`/`:retryable` — else a distinct non-retryable `code` is undone by a stray detail.
- **Readiness ≠ session state (review P1).** `validate_sandbox_scope(:docker)` must assert the *default
  sandbox* is provisioned + ready (`sandbox_status == :ready`, `:default in sandboxes`), not just
  `state == :ready`; otherwise `Forge.exec` silently lazily-provisions (`harness.ex:1005-1011`), violating
  "do not re-provision."
- **Normalize every Forge return (review P2).** The bridge maps *any* `{:error, term}` (`:not_found`,
  `{:invalid_state,_}`, `{:provision_failed,_}`, `{:unknown_sandbox,_}`, …) to a non-retryable
  `:sandbox_unavailable`, and only adapts `{:ok, {out, code}}` when `code` is an integer.
- **No user-visible behavior change in Phase 1.** No `:docker` worker/template ships. The
  `validate_sandbox_scope(:docker)` clause, the `resolve_scope` key, the read-real widening, and the D6
  refusals are forward-plumbing for Phase 2 but are cheap and in-scope per the doc.
- **ExSlop / precommit hygiene:** the ForgeBridge is a distinct module (no clone risk); keep any new
  `get_env`-style seams non-contiguous; build strings via `IO.iodata_to_binary`; never pipe precommit
  through `tail`.
- **`:docker` (policy) ≠ `:docker_sandbox` (Forge backend).** Keep distinct.

---

## Verification

1. **`mix precommit`** — definition of done. Runs `jidoclaw.compile_check` (no warnings),
   `format --check-formatted`, credo strict, the ExSlop reach/clone check (zero), and the full suite.
2. **Targeted while iterating:**
   - `mix test test/jido_claw/tools/run_command_test.exs test/jido_claw/tools/run_command/forge_bridge_test.exs`
   - `mix test test/jido_claw/forge/` (harness cushion + StubSandbox)
   - `mix test test/jido_claw/security/tool_approval_test.exs`
   - `mix test test/jido_claw/agent/templates_sandbox_test.exs test/jido_claw/vfs/sandbox_test.exs`
   - `mix test test/jido_claw/skills/steps/agent_runner_test.exs`
   - `mix test test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/tools/handoff_test.exs test/jido_claw/agent/handoff/router_test.exs`
3. **`mix compile --warnings-as-errors`** (or `mix jidoclaw.compile_check`) — confirms the policy/spec edits
   compile clean.
4. **Tidewave `project_eval` smoke** (optional): drive the `ForgeBridge` adapter against hand-fed
   `{msg, 127|124|153}` tuples to eyeball the non-retryable codes end-to-end through
   `Tools.Error.normalize_result/1` + `Jido.AI.Error.retryable?/1`.

> The **real in-microVM exec** path (`@moduletag :docker_sandbox`, excluded from `mix test` by
> `test_helper.exs:1`) is **not** part of Phase 1's precommit DoD — Phase 1 is fully stub-tested. The live
> `sbx` integration test belongs to Phase 2.
