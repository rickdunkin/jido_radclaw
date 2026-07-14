# Plan: pre-argus Wave E (reduced scope) — #16 error-code registry + #17 setup doctor

## Context

Executes the reduced-scope cut of Wave E from
[the pre-argus do-now queue](../../docs/plans/pre-argus-do-now/README.md):
**#16** served-MCP boundary error-code registry (pad PD1-2) and **#17**
`/setup` as a state-derived doctor (pad PD3-1). The six-item Wave E plan
proved too large for one build; **#18–#21 are deferred** to a later plan (the
prior draft `.claude/plans/please-review-docs-plans-pre-argus-do-no-tranquil-hoare.md`
remains their reference). #16 and #17 are mutually independent and
independent of the deferred four — no dependency is severed by the split.
Greenfield — no compat shims.

The prior draft's #16/#17 sections carry **binding operator decisions**
(interview 2026-07-12 + three same-day review rounds); this plan incorporates
them inline and re-verifies every claim against HEAD (656e6889, 2026-07-12,
three-reader sweep). Corrections found and folded in:

- `Jido.Exec` lives in the **jido_action** dep
  (`deps/jido_action/lib/jido_action/exec.ex`), not `deps/jido`; the
  exception on the error path is `Jido.Action.Error.ExecutionFailureError`
  (`[:message, :details]` only), and `exception.message` passes through
  `Telemetry.extract_safe_error_message` (sanitized) before landing.
- `Ecto.Migrator.migrations/3` **does** accept `skip_table_creation:` (opts
  flow into `migrated_versions` → `lock_for_migrations`, migrator.ex:555-565)
  — but `with_repo/3` on an **already-running repo restarts its pool** on
  cleanup (migrator.ex:846-855), and a whereis pre-check would leave a
  TOCTOU window — the probe uses an own-start claim wrapper instead of
  `with_repo`.
- The dotenv loader reads **four paths first-wins**
  (`project/.jido/.env` → `project/.env` → `cwd/.jido/.env` → `cwd/.env`,
  application.ex:639-665); the resolver must mirror that order, not parse a
  single `.env`.
- `JidoClaw.Config` lives at `lib/jido_claw/core/config.ex` (listed in
  tool-approval.md `sources:` — path-existence only; no semantic overlap, no
  bump needed).
- `mix jidoclaw.system_docs.check` enforces frontmatter shape + source-path
  existence only — the same-change docs rule is convention; we follow it
  regardless.
- The inventory is **47 literal codes at HEAD** (draft estimated ~45;
  original spec said ~25 — record in Status), growing to **50 registered**
  with the producer changes (`:unknown_skill`, `:skill_run_failed`,
  `:skill_cancelled`). run_skill's forwarded ReactorRunner atoms proved an
  OPEN set (review found `:already_terminal`/`:unexpected_halt` beyond the
  first seven observed), so run_skill normalizes them at its boundary
  instead of the registry enumerating them; the documented forwarded map
  shrinks to `:solution_not_found`.
- Two operator-live-tested facts folded in: OpenRouter's model lookup
  returns 200 without valid auth (so its probe needs a separate
  authenticated `GET /api/v1/key`), and `JsonSafe.encode/1` is not total —
  invalid-UTF-8 binaries reach `Jason.EncodeError`, improper lists
  (`[1 | 2]`) raise in the list clause (hardened as part of #16, plus a
  non-raising final fallback at the boundary).

**Hard gates:**

- **No PORT maps** (both items are posture/contract lifts — docs/exploration/README.md rule).
- **Step 0**: materialize this plan as
  `docs/plans/pre-argus-wave-e-16-17/README.md` (Wave A shape;
  `## Deviations` maintained as work proceeds; operator-confirmed name).
- **Queue discipline** per item: dated Status lines on every source entry,
  falsified claims corrected, cross-refs updated same session.
- Run mix via `mise exec -- mix`. Gates bare (never piped), run in
  background, read the tail. Known-flaky singleton suites verified in
  ISOLATION before blaming new code.
- **Nothing committed by the agent**; work lands unstaged, ending with
  files-to-stage + suggested commit slicing. Completion bar:
  `mise exec -- mix precommit` green.
- New public functions need `@moduledoc`/`@spec` (credo strict); watch the
  known precommit gotchas for new code (Specs/AliasUsage/ExSlop/ExDNA-dup;
  Zoi.schema not Zoi.t in dialyzer-visible types).

**Build order**: #16 → #17.

---

## Item #16 — PD1-2: boundary error-code registry (wire-real, boundary-enforced)

### New `lib/jido_claw/core/mcp_server/error_codes.ex`

`JidoClaw.MCPServer.ErrorCodes` beside SurfaceVersion (served-MCP scope by
construction; interior stays open). Families as **code → one-line-doc maps**
(a code cannot join without its doc):

```elixir
@type family :: :pipeline | :normalization | :lua | :sandbox | :host_exec | :scope | :lookup | :workflow
@spec families() :: %{family() => %{atom() => String.t()}}
@spec all() :: MapSet.t(atom())
@spec member?(atom()) :: boolean()
@spec family(atom()) :: {:ok, family()} | :error
@spec forwarded_codes() :: %{atom() => String.t()}   # documented forwarded atoms (code → where-from);
@spec forwarded() :: MapSet.t(atom())                # derived from its keys; disjoint from all()
@spec stability_sentence() :: String.t()
```

Verified inventory (**50 codes** after the producer changes below — 47
literal at HEAD + `:unknown_skill` + `:skill_run_failed` + `:skill_cancelled`):

| family | n | codes (anchors) |
| --- | --- | --- |
| pipeline | 4 | `:approval_pending`/`:approval_denied`/`:approval_unavailable` (tool_approval.ex:617/631/643), `:doom_loop` (loop_guard.ex:171/244); cite LoopGuard `@skip_codes` (loop_guard.ex:140) |
| normalization | 11 | error.ex: `:tool_error`, `:validation_error`, `:config_error`, `:execution_error`, `:unknown_error`, `:internal_error`, `:exception`, `:failed`, `:error`, `:still_running`, `:timeout` (error.ex:170-202, 399-403) |
| lua | 12 | 11 `:lua_*` via `envelope/3` (lua/runner.ex:399; :106-:233) + `:unknown_binding` (lua_docs.ex:48) |
| sandbox | 4 | `:sandbox_unavailable`/`:sandbox_command_timeout`/`:sandbox_output_limit`/`:sandbox_deadline_exceeded` (forge_bridge.ex:292-325) |
| host_exec | 2 | `:host_deadline_exceeded`/`:host_command_timeout` (run_command.ex:266-267, via the computed `deadline_error_code/1` at :258) |
| scope | 4 | `:tenant_required` (RuntimeScope + 8 tool literals), `:missing_tenant` (run_skill.ex:76/113), `:missing_scope_tenant`/`:missing_scope_workspace` (store_solution.ex:84/87, find_solution.ex:63/64) |
| lookup | 9 | `:session_not_found`/`:session_id_mismatch`/`:session_not_resolved` (agent_view.ex:280-321), `:not_found` (workflow_view.ex:128/139/184, inspection.ex:132/136), `:unknown_target`/`:unknown_kind` (inspect_agent.ex:78/94, inspection.ex:73/104), NEWLY-TYPED `:absolute_glob_not_allowed`/`:glob_outside_project` (list_directory.ex:177-183), NEW `:unknown_skill` |
| workflow | 4 | `:replay_refused` (replay_workflow.ex:97), `:event_feed_unavailable` (workflow_view.ex:419), NEW `:skill_run_failed` + `:skill_cancelled` (run_skill boundary normalization, below) |

Details-level sub-codes stay excluded (documented): `:foreign`/`:unknown`
(error.ex:249/253 — inside `details.errors[]`), `:dropped_runtime_handle`
(error.ex:332), tool_approval's internal `:cache_unavailable`/
`:invalid_mount_config` (collapsed to `:approval_unavailable` before any
envelope).

**run_skill boundary normalization** (replaces enumerating an open set):
run_skill today forwards EVERY ReactorRunner reason verbatim (run_skill.ex:77
— at least `:cancelled`, `:fenced`, `:already_running`, `:not_a_reactor`,
`:missing_required_opt`, `:exit`, `:already_terminal`, `:unexpected_halt`
(reactor_runner.ex:715), plus arbitrary mid-run Reactor reasons — an open
set no registry can close). Normalize at the tool boundary instead:
`:cancelled` → typed `:skill_cancelled`; every other runner failure → typed
`:skill_run_failed` with the original reason preserved under
`details.reason` — built as **guarded `JsonSafe.encode(reason)` first, then
`Error.sanitize_details(%{reason: safe_reason})`** (error.ex:267 — the 2KB
string + 8KB collection caps with truncation metadata). Both stages are
needed: `sanitize_details/1` alone is not a total arbitrary-reason
sanitizer (a bare atom arg returns `%{}`, improper lists raise, hostile
structs can invoke `Inspect` early), and already-canonical envelopes
bypass `normalize/1`'s sanitization (error.ex:119-122) while a raw Reactor
reason can be aggregate-huge. Fidelity note: `content[0]` shows the
POST-normalization envelope (byte-identity holds against the normalized
legacy arm) — the raw uncapped Reactor term is deliberately not preserved.

**`forwarded_codes()` — the documented forwarded map, first-class**: after
the normalization, the observed forwarded set shrinks to
`:solution_not_found` (network_share catch-all :49-50). It lives in a
code→one-line-doc MAP (where forwarded from; the set derives from the keys
so the every-entry-has-a-doc test holds by construction), deliberately NOT
in `all()`. The boundary logic is unchanged by membership (anything ∉
`all()` collapses to the `:tool_error` + `details.unregistered_code`
fallback); the map exists so the sweep and docs account for these atoms
without contradicting the closed registry. Enforced: `all()` ∩
`forwarded()` == ∅ (unit test), and the wire test pins a forwarded atom
actually collapsing. Promoting one into `all()` later is a deliberate
same-diff-docs addition. `Error.normalize`'s legacy funnel forwards ANY
atom found under `code:`/`status:` keys (error.ex:119-121, 391-403) — the
set is formally open, so the boundary fallback is required by construction.

Moduledoc carries the **#4 kinship paragraph** (`mix jidoclaw run` exit tiers
0–6 classify via `RunFailure`; one contract family, two enforcement points —
this closes the queue's #4↔#16 cross-consume rule) — NO run_command.ex CLI
edit (its file is in ambiguity-clarify.md sources).

### The wire boundary — new `error_boundary.ex` + jido_mcp runtime patch

Today `Jido.MCP.Server.Runtime.handle_tool_call/5`
(deps/jido_mcp/lib/jido_mcp/server/runtime.ex:35-82) executes tools via
`Jido.Exec.run/3` (:47) and its two error arms (:54-58) emit
`Response.tool() |> Response.error(inspect(reason))` — a single verbatim
text item + `isError: true` (anubis response.ex:390-395; `to_protocol`
serializes `content` + `isError`, :656-662).

- **New patch `lib/jido_claw/core/jido_mcp_runtime_patch.ex`**: redefines
  `Jido.MCP.Server.Runtime` (277-line copy — the anubis-patch pattern;
  `ignore_module_conflict` is already project-wide, mix.exs:35) with ONLY the
  two `{:error, …}` arms changed to
  `JidoClaw.MCPServer.ErrorBoundary.error_response(reason, server_module)`
  (`server_module` is already in scope in the arity-5). Register
  `{Jido.MCP.Server.Runtime, :jido_mcp}` in `@patched_modules`
  (dependency_patches.ex:4-10 — boot loading + release BEAM relocation both
  read this list) and update the stale inline inventory comment in mix.exs
  (:15 says "five" and enumerates them). Document beside the anubis patch
  in AGENTS.md known-limitations + the docs page, with a drop-when-upstream
  note.
- **New `lib/jido_claw/core/mcp_server/error_boundary.ex`**
  (`JidoClaw.MCPServer.ErrorBoundary`) — all logic lives here so the patch
  stays a thin copy. **Scoped, not global**: match `JidoClaw.MCPServer` →
  structured + registry-enforced; every OTHER server (the consolidator's
  `JidoClaw.Memory.Consolidator.MCPServer`, the executor's
  `…ForgeExecutor.DepositServer` — all three ride this one Runtime) → the
  byte-identical legacy `Response.error(inspect(reason))` arm.
- **Additive wire shape**: `content[0]` keeps the legacy inspect text
  BYTE-IDENTICAL; a SECOND text content item carries canonical JSON
  `{"code","message","details"}` — build via
  `Response.tool() |> Response.error(legacy) |> Response.text(json)`
  (`text/2` appends; the LoopGuard appended-text-item precedent,
  loop_guard.ex:358-379). No repurposing of `structuredContent` (owned by
  the success path's outputSchema, runtime.ex:205). Genuinely additive →
  **1.3 MINOR is honest**.
- **Exact unwrap** (verified end-to-end): a tool returning
  `{:error, %{code: c, message: m, details: d}}` reaches the arm as
  `%Jido.Action.Error.ExecutionFailureError{message: m·sanitized,
  details: %{code: c, details: d}}` (exec.ex:781-785 →
  `extract_error_fields` binary-message clause :807-808 →
  `Jido.Action.Error.execution_error/2`, jido_action/error.ex:263-268).
  The boundary reconstructs `{details.code, exception.message,
  details.details}`; raw `%{code, message, details}` maps and non-envelope
  reasons (→ `{"code":"tool_error","message":inspect-text,"details":{}}`)
  handled totally. **The entire canonical envelope is normalized through
  `JsonSafe.encode/1` BEFORE `Jason.encode!`** — a raise here would convert
  a tool error into a JSON-RPC execution failure. `JsonSafe` is NOT actually
  total today: short invalid-UTF-8 binaries pass through unchanged
  (json_safe.ex:87) and `<<255>>` produces `Jason.EncodeError`
  (operator-verified), and the list clause (json_safe.ex:64) raises on
  improper lists like `[1 | 2]`. **Harden `JsonSafe.encode/1` as part of
  this item**: binary values AND keys failing `String.valid?/1` get
  scrubbed (`inspect/1` or replacement-char conversion — pick one at build,
  test both paths); improper lists get a detecting walk (convert the
  improper tail rather than crash); tuples/pids/refs/structs/non-string
  keys were already handled. This is a global strengthening of an
  already-lossy normalizer — safe for its existing consumers (bootstrap
  payload et al.). **Belt-and-braces**: totality can't be proven against
  future shapes, so the boundary's ENTIRE structured-item production —
  unwrap, any message rendering the boundary itself performs (its
  `inspect/1` uses included: a hostile custom `Inspect` impl can raise),
  `JsonSafe.encode/1`, and `Jason.encode!` — sits in one guarded region;
  on ANY exception it emits a fully STATIC ASCII envelope
  (`{"code":"tool_error","message":"error serialization failed",
  "details":{}}` — zero interpolation of the term) so a serializer bug can
  never escalate a tool error into a JSON-RPC failure. **The public arm's
  `content[0]` is guarded the same way** — an unguarded legacy
  `inspect(reason)` raising would abort the arm before the structured item
  is ever appended, contradicting never-escalate: render it via a
  `safe_inspect` (plain `inspect/1` in try/rescue → static
  `"[uninspectable error term]"` fallback). Ordinary terms stay
  BYTE-IDENTICAL (the inspect succeeded — same bytes as HEAD); hostile
  terms produced a protocol error at HEAD, so the static text is a strict
  improvement, and the wire test pins the new behavior explicitly. The
  consolidator/deposit arms keep HEAD's raw `inspect` verbatim — their pin
  is byte-identical legacy behavior, raise path included.
- **Registry enforcement at the boundary**: unknown/unregistered codes →
  fallback `:tool_error` + `details.unregistered_code` carrying the original
  + a log line. This is the closure PROOF; the sweep test is supplemental
  lint.

### Hint fields + producers

- `Tools.Error` gains `hint_available(names, details \\ %{})` (list, cap 25
  + `available_truncated` flag) and `hint_expected(expected, got, details \\ %{})`
  (reuse the existing 2KB `truncate_string` machinery, error.ex:355-362) —
  typed details generalizing the LoopGuard-directive precedent.
- `run_skill.ex`: unknown skill (today a plain string from
  `platform/skills.ex:446-451` → `:tool_error`) → typed `:unknown_skill` +
  `hint_available` from `Skills.list/0` (platform/skills.ex:284; map to
  names). Runner failures (the `{:error, reason}` forward at :77-80) →
  the boundary normalization above: `:skill_cancelled` /
  `:skill_run_failed` + `details.reason`.
- `list_directory.ex`: stop string-flattening the already-typed glob atoms
  (`validate_glob/1` :174-188 emits them; :158-161 flattens) → typed
  envelopes + `hint_expected(...)`. Other `"Cannot list …"` strings (:87,
  :99, :114, :141) stay as-is.
- `lua_docs.ex`: **untouched** — it already emits typed `:unknown_binding`
  with a string `available` detail (lua_docs.ex:44-51); that's an existing
  served shape — unify at next MAJOR (residual noted in docs).

### Version + server-level stability sentence

- `mcp_server.ex`: hand-define `server_instructions/0` returning
  `ErrorCodes.stability_sentence()` — anubis's
  `maybe_define_server_instructions` (anubis server.ex:552-558) respects a
  user-defined one. **Build-verify** the def-vs-`use` ordering compiles
  clean (if the hook expands before our def is visible, fall back to
  defining it before the `use` or via the use-opts seam).
- `resources/bootstrap.ex`: additive `"error_contract"` key (stability
  sentence + family→codes map + "canonical JSON rides the final error
  content item" + the fallback rule: unregistered codes arrive as
  `tool_error` with `details.unregistered_code`); payload already flows
  through `JsonSafe.encode` (:77).
- `surface_version.ex`: `@current "1.2"` → `"1.3"` + changelog bullet
  (additive: second error content item, hints, new lookup codes,
  instructions, bootstrap field). Update the golden fixture's
  `surface_version` field (test/fixtures/mcp_surface/served_surface.json);
  tool/resource sets are unchanged. Run `jido_md.check`; regenerate
  `.jido/JIDO.md` if it pins the version.

### Tests

- `error_codes_test.exs` (async: true): family/all/member/family-lookup
  units; every registered code AND every `forwarded_codes()` entry has a
  nonempty doc (the map shape makes this structural); families disjoint;
  **`all()` ∩ `forwarded()` == ∅**.
- **Wire test asserts EXACTNESS, not membership** (new
  `error_boundary_test.exs`, driving the patched
  `Jido.MCP.Server.Runtime.handle_tool_call/5` end-to-end with scripted
  action modules): (a) failing served tool → `content[1]` JSON decodes to
  the EXACT original code + message + inner details; (b) foreign atom AND
  the `forwarded_codes()` member (`:solution_not_found`) → fallback +
  `unregistered_code` carrying the original; (c) `content[0]` bytes
  unchanged vs the unpatched arm (compare against `inspect(reason)`);
  (d) consolidator + deposit `server_module`s → byte-identical single-item
  legacy behavior; (e) success responses untouched (`structuredContent`
  path); (f) non-JSON-safe nested details (tuples, pids, non-string keys,
  **invalid-UTF-8 binaries as both value and key** — the `<<255>>` case —
  **and an improper list** `[1 | 2]`) still produce a decodable envelope;
  (g) the belt-and-braces fallback, driven THROUGH
  `Runtime.handle_tool_call/5` (not only a serializer unit): a reason
  carrying a **deliberately raising `Inspect` implementation** → the reply
  is still a tool response with BOTH items — `content[0]` the static
  `safe_inspect` fallback, `content[1]` a decodable envelope (static ASCII
  when the guarded region tripped) — never a protocol/JSON-RPC error; the
  `content[0]` byte-identity pin (c) is scoped to terms whose inspect
  succeeds; (h) run_skill's `:skill_run_failed` with a large nested
  Reactor reason → the details are capped with truncation metadata (the
  sanitize pipeline pin), never an unbounded content item — plus atom,
  improper-list, and hostile-struct reasons through the RunSkill path.
- **Sweep test — supplemental lint** (`error_codes_sweep_test.exs`,
  async: false, `Code.ensure_loaded` setup): sources =
  `JidoClaw.MCPServer.published_tool_modules()` (mcp_server.ex:109-110)
  compile-info paths + pinned envelope-producer files (tool_approval,
  loop_guard, lua/runner, forge_bridge, error.ex). Quoted-AST walker pruning
  pattern positions (`->` LHS, def heads/guards, `<-` LHS, attributes);
  collects literal `code:`-keyed envelope maps, first-arg atoms of local
  `envelope(...)` calls, literal `{:error, atom}` tuples. Non-literal
  `code:` SITES declared in `@indirect_producers` with their possible atoms
  (run_command's `deadline_error_code/1` → the two host_exec codes;
  network_share's forward → `:solution_not_found`; run_skill's runner arm
  is now a literal-code normalizer, so it needs no declaration);
  view-layer relays in `@relayed_codes` (file:line). Assertions: collected
  ∪ declared ⊆ `all()` ∪ `forwarded()`; `all()` ⊆ collected ∪ declared
  ∪ normalization-family; every declared forwarded atom ∈ `all()` ∪
  `forwarded()` (no third bucket); collector self-tests (map-path,
  envelope-call, bare-tuple each MUST collect).
- Hint-helper unit rows beside the existing `Tools.Error` tests; producer
  tests for run_skill (`:unknown_skill` + hint list) and list_directory
  (typed glob codes + `hint_expected`).

### Docs + reconciliation

- `docs/system/mcp-server-surface.md`: closed-error-contract invariant
  (registry, boundary fallback, dual-content wire shape, the
  never-escalate guarantee incl. the public arm's `safe_inspect`, scoping
  to the public server, hints); the runtime patch documented beside the
  anubis patch; `sources:` += error_codes.ex, error_boundary.ex,
  jido_mcp_runtime_patch.ex, the sweep test; `verified:`/`verified_sha`
  bump. AGENTS.md known-limitations gains the patch line (same commit).
- Status lines: PD-FIRST-WAVE item 2; pad FWB PD1-2 + **OQ-2 re-dated**
  (boundary enforcement beats static enumeration); pre-argus README §16
  (deviations: server-level sentence, 47 not ~25, wire adapter,
  dual-content shape) + **correct §16's stale "#4 consumes this registry"
  sentence + §4 Status addendum** (the kinship paragraph is the landed
  cross-ref).

---

## Item #17 — PD3-1: setup as a state-derived doctor

### Minimal doctor boot (no `app.start`)

Both `mix jidoclaw --setup` (lib/mix/tasks/jidoclaw.ex:65-75 —
`Mix.Task.run("app.start")` at :71) and escript `--setup` (cli/main.ex:48-57
— `ensure_all_started(:jido_claw)` at :53) boot the FULL app today; pending
migrations can crash boot before the doctor speaks, and check-only isn't
read-only. Rework both arms: config-level load (`Mix.Task.run("app.config")`
/ escript `Application.load(:jido_claw)` — the release.ex:35-40 precedent) +
targeted `ensure_all_started([:inets, :ssl])` for probes (yaml_elixir is
library-only and self-starts yamerl lazily — verified). The JidoClaw
supervision tree NEVER starts on these arms. `:first_run_setup_pending`
stays for the REPL flow (BootGuard bypass, boot_guard.ex:47); on the no-boot
mix/escript arms it's moot (note at build). The wizard on these arms uses
the same minimal boot (nothing in it needs the app tree; its httpc probe
gets :inets/:ssl).

**Read-only DB probe**: `Ecto.Migrator.migrations/3` DDLs a cold DB by
default (`lock_for_migrations` → `ensure_schema_migrations_table!`,
migrator.ex:561-565). `Doctor.migration_status(repo)` probes in order:
`SELECT to_regclass('public.schema_migrations')` — absent → report ALL local
migrations pending (file count from `Ecto.Migrator.migrations_path(repo)` =
priv/repo/migrations, 56 files today); present →
`Ecto.Migrator.migrations(repo, [path], skip_table_creation: true)`
(option verified: opts flow through migrated_versions → lock_for_migrations
:555). **Own-start claim, not a whereis branch** (correction to the draft,
twice-refined): Ecto's `with_repo/3` cleanup RESTARTS a repo it found
already running (migrator.ex:846-855), and a `Process.whereis` pre-check
would leave a TOCTOU window (repo starts between check and `with_repo` →
Ecto records `:restart` and cycles the live pool anyway). Instead a small
wrapper CLAIMS atomically via `repo.start_link(pool_size: 2)` on the
SUPPLIED repo (never a hardcoded `JidoClaw.Repo`): `{:ok, pid}` → we own
it — **`Process.unlink(pid)` immediately** (start_link links the temporary
repo to the doctor process; a repo crash must surface as probe errors, not
kill the caller past its rescues) — then probe inside `try/after` whose
`after` stops EXACTLY the claimed pid (cleanup runs on probe raise too);
`{:error, {:already_started, _}}` → probe directly with NO cleanup (pin:
an already-running repo's pid is identical before/after). The wrapper
replicates `with_repo`'s app-start preamble (`:ecto_sql` + adapter apps)
without its restart-child cleanup. Tests: the scratch repo process is
ABSENT after both a successful and a raising probe, and the caller
survives both.
Dynamic repos (`put_dynamic_repo`) are out of scope for this maintenance
probe — document in the `@doc`. DB server/database absent entirely → the
listing raises (verbose_schema_migration reraises) → rescue to
`:unavailable`, never a crash.

### Credentials must survive minimal boot — new `JidoClaw.Config.EnvResolver`

Full boot loads dotenv into System env (application.ex:60 → load_dotenv/0
:639-665) before provider resolution — skipping it would misdiagnose a
healthy persisted-only setup. New `lib/jido_claw/core/config/env_resolver.ex`:

```elixir
@type resolved :: %{value: String.t() | nil,                    # effective (ambient wins)
                    source: :ambient | :persisted | :missing,   # effective origin
                    persisted_value: String.t() | nil,          # first-precedence dotenv resolution
                    persisted_path: String.t() | nil}
@spec resolve(String.t(), [String.t()], keyword()) :: %{String.t() => resolved()}
@spec durable?(resolved()) :: boolean()
# opts: ambient: %{name => value} (default: System snapshot), cwd: (default File.cwd!)
```

Pure core with **injected ambient map + cwd** (defaults read the real
System/cwd via a thin wrapper) — tests stay `async: true` with zero global
mutation. Parses the SAME four-path first-wins chain the boot loader uses
(`project/.jido/.env` → `project/.env` → `cwd/.jido/.env` → `cwd/.env`)
WITHOUT `System.put_env`; **ambient wins persisted** for `value`/`source`.
**Durability is value-compared, not presence-inferred**: `durable?/1` =
the effective `value` is non-blank AND equals `persisted_value` (what the
dotenv chain resolves to at its own first-wins precedence). This is what
"survives a clean restart" actually means — mere file presence does not:
ambient `A` + persisted `B` is NOT durable (next boot flips to `B`; the
doctor's detail names the divergence), a blank higher-precedence file entry
shadowing a real later one is NOT durable, and the full-boot case (dotenv
already copied into System, `source: :ambient`) compares EQUAL and
correctly reads durable. The doctor's durability display + repair-offer
logic key on `durable?/1`, never on `source` or presence alone.
Implementation: split
application.ex's entangled `put_env_if_unset/1` (:683-699) into a pure
parse (line split, `#`/blank skip, `=` split parts: 2, `strip_quotes`,
:673-729) that BOTH the boot loader and the resolver consume — one dotenv
authority, application_test's `load_dotenv/0` suite stays green. All
credential presence/valuation on setup paths flows through the resolver —
the doctor's checks, the wizard's already-set detection (setup.ex:171-173),
and the `check_provider/1` wrapper — so full-boot and minimal-boot agree.

**Effective-provider derivation centralized AND total** (both boot modes
must produce the SAME effective config): `Config.load/1`'s auto-cloud
branch re-reads System env to decide Ollama-Cloud selection
(config.ex:94-111) — passing a credential to the probe alone would not
drive that branch nor preserve whether `base_url` was explicitly
configured. Extract the decision into a pure helper (raw user config + the
resolved credential VALUE → effective provider settings: provider, model,
base_url incl. the auto-cloud override, explicit-base_url preservation):
`load/1` calls it with System-resolved credentials (full-boot behavior
byte-compatible, config_test stays green); the doctor/probe path calls it
with EnvResolver values. The probe consumes the DERIVED effective settings,
never raw config. The helper is **total over malformed raw config** —
today's access paths assume map shapes (config.ex:265 et al.):
`providers: "bad"`, a non-map provider entry, or non-binary
`api_key_env`/`base_url` must degrade to typed absence, never raise; the
doctor's config validation (below) reports them before probing.

### New `lib/jido_claw/cli/setup/doctor.ex` — pure derivation

```elixir
@type step :: :config | :provider_key | :voyage_key | :model | :database
@type status :: :ok | :gap | :error | :unsupported | :unavailable
@type check :: %{step: step(), status: status(), detail: String.t(),
                 reason: atom() | nil,          # machine-readable, e.g. :unparseable | :unknown_provider
                 repairable?: boolean(),
                 source: :persisted | :ambient | :missing | nil,  # credential steps (EnvResolver's union;
                 durable?: boolean() | nil}     # session-ness lives in repair_outcomes, not here
@spec derive(String.t(), keyword()) :: {map(), [check()]}   # probes injected via opts
@spec repairs([check()]) :: [step()]   # :gap/:error AND repairable?; :database always print-only
@spec healthy?([check()]) :: boolean() # :ok/:unsupported pass; :unavailable/:gap/:error FAIL
@spec print([check()]) :: :ok
```

`:unsupported` = expected-absent capability (healthy); `:unavailable` =
indeterminate (fails `--check`). **`repairs/1` returns only repairable
checks** — `repairable?` is set by the check, not inferred from status.
Checks:

- `:config` — dispatch wizard-vs-doctor on **`File.exists?`** of
  `.jido/config.yaml` (`read_user_config` maps missing AND empty to
  `{:ok, %{}}` — core/config.ex:122-150, test-pinned), then
  `read_user_config` + **deterministic validation BEFORE any probe**
  (`Config` accessors return raw values despite string specs, config.ex:161
  — the doctor validates types itself): broken YAML → `:error`, reason
  `:unparseable`, **`repairable?: false`** (the merged writer refuses
  unparseable files by design — the doctor prints the parse error and an
  explicit backup-and-replace suggestion (`mv` + rerun `--setup`), and
  NEVER auto-touches the file); provider missing → `:gap`
  `:missing_provider` (repairable: provider-subset interview); provider ∉
  `Config.available_providers()` → `:gap` `:unknown_provider` (repairable:
  interview); malformed `providers` subtree — non-map container, non-map
  ACTIVE provider entry, non-binary `api_key_env`/`base_url` → `:gap`
  `:invalid_provider_config` (repairable: interview + merged write repair
  the active path). **Model-VALUE problems are emitted as `step: :model`
  checks, not `:config`** (repair dispatch is per-step): model
  non-binary / provider-prefix mismatch (modulo the ollama_cloud→ollama
  normalization) → `:model` `:gap`, reason `:invalid_model` /
  `:provider_model_mismatch` (repairable: `pick_model`). Probes are
  SKIPPED unless config validates.
- `:provider_key` + `:model` — ONE probe pass feeds both (see ProviderProbe;
  openrouter takes two requests), credential + effective settings from
  EnvResolver + the shared derivation; carries `source`/`durable?`. Only
  `auth: :invalid` yields the key-repairable gap; `access: :denied` with
  `auth: :ok` keeps `:provider_key` at `:ok` and sends `:model` to
  non-repairable `:unavailable` (routed on the probe's machine-readable
  fields, never by parsing `detail`).
- `:voyage_key` — EnvResolver presence + `source`/`durable?`
  (presence-only, no probe).
- `:database` — `migration_status/1` (N pending → `:gap` "run
  `mix ecto.migrate`", `repairable?: false` — print-only by decision;
  unreadable → `:unavailable`).

`derive/2` performs zero writes and zero env mutations.

### New `JidoClaw.Config.ProviderProbe` (`lib/jido_claw/core/config/provider_probe.ex`)

```elixir
@spec probe(map(), keyword()) :: %{reachable: boolean(),
                                    auth: :ok | :invalid | :unknown,
                                    access: :ok | :denied | :unknown,   # machine-readable; never parse detail
                                    model: :present | :absent | :unknown | :unsupported,
                                    detail: String.t()}
```

- **Retrieve-by-id, not first-page listing**: GET the provider's
  model-retrieve endpoint for the CONFIGURED model — anthropic
  `GET /v1/models/{id}` (`x-api-key` + `anthropic-version`), openai/groq/xai
  `GET /v1/models/{id}` (Bearer), google `GET /v1beta/models/{name}` with
  **`x-goog-api-key` header** (never query-string creds). 200 → auth ok +
  `:present`; 404 → auth ok + `:absent`; **401 → `auth: :invalid` — but
  403 is NOT a bad key**: anthropic distinguishes 401 `authentication_error`
  from 403 `permission_error`, google likewise uses 403 for insufficient
  permission — a valid key lacking model access must NOT trigger the
  provider-key repair. 403 → `access: :denied` (the machine-readable
  discriminator — the doctor never parses `detail`) with `auth: :ok` where
  the provider documents permission semantics (anthropic, google), else
  `auth: :unknown`; `model: :unknown`. Doctor mapping: with `auth: :ok`
  the `:provider_key` check stays **`:ok`** (the key IS valid) and the
  `:model` check becomes non-repairable `:unavailable` (access denied —
  re-entering a key fixes nothing); with `auth: :unknown` both rows go
  `:unavailable`. Other statuses → `:unknown` (detail carries the status —
  never conflated with unreachable); transport error →
  `reachable: false`. For these providers one request answers BOTH checks;
  an incomplete search can only yield `:unknown`/`:unavailable`, never a
  repairable `:gap`.
- **OpenRouter is the exception — two requests** (operator-verified: its
  model lookup returns 200 with no auth AND with an invalid bearer, so a
  lookup 200 is NEVER auth evidence): auth via authenticated
  **`GET /api/v1/key`** (200 → `:ok`; 401/403 → `:invalid` — this
  key-introspection endpoint's 403 IS about the key itself, per the
  operator-verified behavior; the 403-is-not-a-bad-key rule above is
  per-provider, not blanket); model presence via the public
  **`GET /api/v1/model/{author}/{slug}`** (singular `model` — its ids
  always carry the author/slug slash; test aliases + `:free` variants;
  200 → `:present`, 404 → `:absent`, informing `model` only). The
  per-provider request count is an implementation detail behind the same
  `probe/2` result shape.
- **Canonical id contract**: config stores `provider:model` strings
  (core/config.ex:31-70); the probe derives the provider-native id (strip
  our prefix; google's `models/…` resource naming normalized) and reports
  in canonical form. Per-provider unit rows.
- **Effective-config derivation**: base URL + auth come from the shared
  pure helper introduced above (raw config + resolved credential → the same
  effective settings `load/1` produces — auto-cloud `@cloud_base_url` :77,
  `auth_headers/1` bearer :321-327, `ollama_base_url/1` :315-318); model
  check via `/api/tags` membership (tags listed once for the gap detail).
  Total unknown-provider fallback clause (no function-clause crash) →
  `:unavailable` detail (defense only — the doctor's config validation
  catches unknown providers as a repairable `:gap` before probing).
- HTTP via an injectable adapter with a NORMALIZED contract —
  `request.(method, url, headers) :: {:ok, %{status: non_neg_integer(),
  body: binary()}} | {:error, term()}` — because raw `:httpc.request/4`
  returns nested tagged tuples with a charlist body by default (the shape
  today's `check_api_key` :362-379 pattern-matches). The default adapter
  wraps `:httpc` with `body_format: :binary` (or normalizes iodata) **and
  keeps the bounded deadline** today's checks pin (5s timeout,
  config.ex:353 — injectable for tests): a timed-out request maps to
  `{:error, :timeout}` → `reachable: false` with the timeout named in
  detail, and openrouter's two-request probe has a bounded total (two 5s
  budgets — document it). Adapter GLUE is tested against real
  `:httpc`-shaped results (esp. decoding ollama's JSON `/api/tags` body)
  plus the timeout mapping; the per-provider mapping is unit-tested on
  canned normalized `{status, body}` values for EVERY clause. The
  credential and effective settings arrive explicitly; the probe never
  reads System env.
- `Config.check_provider/1` (core/config.ex:334-346) becomes
  `check_provider(config, opts \\ [])` — a thin wrapper deriving today's
  `:ok | {:error, :unauthorized | :unreachable}`, with `opts` accepting
  `project_dir:` and/or `credential:` so callers pass their known context
  instead of the wrapper guessing from System env + cwd (minimal boot
  deliberately never loads dotenv into System, and `/setup` runs against
  `state.cwd`, commands.ex:496). Both callers updated: the REPL banner
  passes the app's project_dir; the wizard `test_connection` passes its
  project_dir + the freshly-entered credential. Test: a persisted-only
  credential resolves correctly when project_dir ≠ process cwd.
- Adjacent, recorded not built: the web-side
  `JidoClaw.Setup.CredentialValidator` is a shallow presence/byte-size
  check — routing it through ProviderProbe is a follow-up, out of scope.

### `cli/setup.ex` rework

- `run/1` → `run(project_dir, opts \\ [])` returning a **tagged result**:
  `{:ok, %{config: map(), checks: [Doctor.check()], disposition:
  :wizard_completed | :healthy | :repaired | :gaps_remaining | :check_only,
  repair_outcomes: %{Doctor.step() => :persisted | :session_only |
  :declined}}}` — the typed home for repair state the re-derive cannot
  honestly recompute. `opts` also carries an **injectable prompt/IO seam**
  (default: today's IO-based prompts) so repair accept/decline interactions
  are testable. **`Setup` never calls `System.halt` anywhere** — exits are
  owned exclusively by the Mix/escript entrypoints via the
  disposition→code mapping (the REPL never exits). **All four callers
  updated + tested**: repl.ex
  `ensure_config` (:94-100, first-run unwrap), commands.ex `/setup`
  (:496-500) + `/config` alias (:502) — unwrap → `Config.model/1` **and
  refresh `Application.put_env(:jido_ai, :model_aliases, …)` to mirror
  repl.ex:70** (included adjacent fix: today an in-session `/setup` leaves
  aliases stale, so a doctor-repaired model wouldn't resolve), the mix task
  arm, cli/main.ex escript arm. `run_command.ex`'s `ensure_configured`
  refusal (:229-235) is untouched.
- Dispatch — **`check_only` routes FIRST**: derive + print + report only —
  a missing config file is a `:config` gap (provider/model skipped), NEVER
  a wizard launch; zero prompts, zero writes, zero env mutations.
  Otherwise: config file ABSENT → today's full wizard, **then a final
  derivation** — the wizard writes config/credentials but proves nothing
  about migrations or declined keys, and exiting 0 with pending migrations
  is exactly the failure minimal boot exists to expose. Post-wizard derive
  clean → `:wizard_completed`; remaining gaps → `:gaps_remaining` (the
  summary says config was written AND names the gaps; checks always carry
  the final derivation). Config present → doctor: derive → print → repair
  `repairs/1` only → re-derive → closing summary.
- **Credential durability modeled, not inferred**: provider-key and voyage
  checks carry `source:` + `durable?:` from EnvResolver (durability and
  repair-offer logic key on `durable?`, the value-compared predicate).
  Repairs prompt for the key, **install it into the live process FIRST
  (`System.put_env`) in BOTH branches** — dotenv loads only at boot, so an
  in-REPL `/setup` repair must update the running VM's env or the live
  runtime keeps resolving the old/missing value while the resolver's
  file-based re-probe reports green — then **offer persistence via the
  0600 atomic upsert machinery** (setup.ex:304-337), **written to the
  winning PROJECT-OWNED path**: `persist_env_var/3` targets `project/.env`
  today, but the dotenv chain gives `project/.jido/.env` precedence — a
  stale/blank entry there would shadow the accepted repair forever. Rule:
  `persisted_path` ∈ the two project paths → upsert it in place (fixes the
  shadow; add a path-taking variant of the existing atomic upsert);
  `persisted_path` is a cwd FALLBACK outside project_dir → never silently
  mutate the external file — write `project/.env` (which OUTRANKS both cwd
  paths in the chain) and name the external definition in the message; var
  defined nowhere → default `project/.env`.
  Accept → **re-resolve and mark `:persisted` ONLY when `durable?/1`
  confirms**, otherwise honest `:session_only` + a loud message; decline →
  `:session_only` (carried in the RESULT — the re-probe would now succeed
  and lie) → disposition `:gaps_remaining`, summary flags it, standalone
  exits 1. **Persistence FAILURE** (the upsert raises on I/O problems) is
  rescued to the same honest `:session_only` + message — env is set,
  durability is not. The first-run wizard's `configure_api_key` (:161-196,
  today session-only put_env at :184) **reuses the same persist-offer
  flow** (deviation recorded). Voyage keeps
  prompt+persist — but the wizard's `System.halt(1)` on decline (today at
  :121) is REMOVED, not narrowed: a declined voyage key is a `:voyage_key`
  gap ⇒ disposition `:gaps_remaining`, with the BootGuard consequence
  printed; the mix/escript arms exit 1 from the mapping, the REPL first-run
  prints the warning and continues (deviation recorded).
- Other repairs (dispatch is per-step; the reason rides the check for
  messaging): `:model` (`:invalid_model`/`:provider_model_mismatch`/probe
  `:absent`) — `pick_model` (:198-234) + merged write; `:config`
  (`:missing_provider`/`:unknown_provider`) — provider-subset interview +
  merged write; `:config` **`:invalid_provider_config` additionally
  SANITIZES before merging** — `deep_merge` preserves whatever the
  interview doesn't overwrite (config.ex:617-624), so the repair must
  explicitly replace/drop the malformed fields of the ACTIVE provider
  subtree (a plain interview output carries no `providers.<p>` entry and
  would leave `api_key_env: []` in place); `:database` — print-only.
  Repairs END with a re-derive — a repair that doesn't clear its check is
  a `:gaps_remaining` outcome, never a silent success.
- **YAML writing**: promote `{:ymlr, "~> 5.1"}` to a direct dep (in mix.lock
  at 5.1.5 via reactor); `write_config/2` + new `write_config_merged/2` emit
  via `Ymlr.document!/1`, written atomically (tmp + rename + 0-leak cleanup,
  the `persist_env_var` pattern — today's `write_config` :284-293 is a
  non-atomic wholesale `File.write!`); DELETE the hand-rolled `map_to_yaml/2`
  (:386-411 — it only quotes `":"`, `inspect`-fallbacks everything else).
  **Permission invariant** (rename replaces the inode, and this config can
  carry literal MCP headers — endpoint_config.ex:347 — and shell-profile
  env values — profile_manager.ex:22): `chmod` the tmp file BEFORE writing
  content; existing regular destination → preserve its current mode; new
  file → default `0600`; non-regular destination (symlink/dir) → refuse
  loudly (the `persist_env_var` lstat guard, setup.ex:311-314). Merged
  write: `read_user_config` → `Config.deep_merge/2` (:617-624) → encode →
  atomic write; **refuses** when the existing file is unparseable (the
  doctor never routes unparseable configs here — reason `:unparseable` is
  `repairable?: false`). **Accepted residual (recorded in moduledoc +
  Status)**: a merged write is parse→merge→re-emit, so operator comments,
  anchors/aliases, and formatting in `config.yaml` do NOT survive a repair
  write — semantic content is preserved (test-pinned), source layout is
  not. Round-trip tests cover YAML-hostile strings: `"true"`, `"001"`,
  `"2026-07-12"`, leading whitespace, quotes, backslashes, multiline,
  `:`/`#`, list-of-maps.

### `--check` plumbing + exits

- Mix task: the `run(["--setup" | args])` head (pattern-match dispatch, no
  task-level OptionParser) parses `--check` from args; `mix jidoclaw --setup
  --check` exits 0 iff `Doctor.healthy?/1`, else 1; plain `--setup`: 0
  unless `:gaps_remaining` (→ 1).
- Escript twin in cli/main.ex — **`--check` must NOT set `:force_setup`**
  (main.ex:52 sets it today; note the existing mix/escript asymmetry — mix
  never sets it — in the build doc).
- REPL: `/setup check` + `/setup --check` heads above `"/setup"` in
  commands.ex (never exits the REPL); `/config` alias unchanged.
- Moduledocs document flags + exits (they ARE the help). Exit mapping pinned
  by testing the pure disposition→code function (`System.halt` untestable
  directly).

### Tests

- `doctor_test.exs` (async: true; tmp dirs; injected probes — never live
  network): healthy → all `:ok`/`:unsupported`, `repairs == []`, `healthy?`;
  single-gap rows; **reason/repairable rows** — broken YAML → `:config`
  `:error` reason `:unparseable` `repairable?: false`, NOT in `repairs/1`,
  detail carries the parse error + backup-and-replace guidance;
  `:unknown_provider` → `:config` gap; **malformed-subtree rows**
  (`providers: "bad"`, non-map active entry, non-binary
  `api_key_env`/`base_url`) → `:invalid_provider_config` gap, no raise;
  **model-value problems land on `step: :model`** (`:invalid_model`,
  `:provider_model_mismatch`) so repair dispatch routes to `pick_model`,
  never the provider interview; in ALL of these the probe fun is NEVER
  invoked; pending migrations → gap NOT in repairs; `:unavailable` fails
  `healthy?`; derive performs zero writes/env mutations; **no-config
  check-only regression**: fresh tmp dir + `check_only` → `:config` gap
  reported, zero prompts consumed, directory bytes untouched — the wizard
  never launches.
- **Cold-DB probe test** (async: false): `storage_up` a scratch database,
  point a named test-support repo module at it — configured with
  **`priv: "priv/repo"`** (Ecto would otherwise derive
  `priv/scratch_repo/migrations` from the module name and report zero
  pending) — run `migration_status(ScratchRepo)` → all local migrations
  reported pending AND `schema_migrations` REMAINS ABSENT (`to_regclass`
  still null — the probe performed no DDL); `storage_down` in on_exit.
  Running-repo branch: `migration_status(JidoClaw.Repo)` under the test
  app → listing returned AND the repo pid is IDENTICAL before/after (no
  `with_repo` pool cycle).
- `env_resolver_test.exs` (**async: true via injection** — ambient map +
  cwd are opts, zero `System.put_env`/global mutation; tmp `.env` files):
  persisted-only key → `source: :persisted`, `durable?: true`; ambient WINS
  persisted for value/source; **durability rows** — ambient `A` + persisted
  `B` → `durable?: false`; blank first-precedence file entry shadowing a
  real later one → `durable?: false`; duplicate files resolve first-wins
  for `persisted_value`; **full-boot simulation** — ambient value EQUAL to
  the file value → `source: :ambient` AND `durable?: true` (+
  `persisted_path`); the four-path precedence order; missing.
- `provider_probe_test.exs` (async: true): per-provider request shapes
  (anthropic x-api-key, google x-goog-api-key + `models/` normalization,
  Bearer for openai-compat); **openrouter rows**: auth from
  `GET /api/v1/key` statuses ONLY, model from the public
  `/api/v1/model/{author}/{slug}` lookup (incl. alias + `:free` ids), and a
  model-lookup 200 with a bad/absent key must NOT yield `auth: :ok`;
  ollama_cloud bearer + base_url via the shared derivation (explicit
  base_url preserved; same effective settings from raw-config + resolver
  values as full-boot `load/1` produces); canned-status table incl.
  404→`:absent`, 405→`:unknown` (never unreachable), **401 vs 403 split
  rows** — 401 → `auth: :invalid`; 403 on anthropic/google →
  `access: :denied` + `auth: :ok` + `model: :unknown`, NEVER
  `auth: :invalid` (doctor rows: `:provider_key` stays `:ok`, `:model`
  goes non-repairable `:unavailable`); unknown provider total fallback;
  canonical-id round-trips; explicit-credential arg (no System env reads);
  **default-adapter glue rows** on real `:httpc`-shaped nested tuples
  (charlist/binary body normalization, `body_format: :binary`, ollama
  `/api/tags` JSON decode, **timeout → `{:error, :timeout}` →
  `reachable: false`**).
- `setup_test.exs` additions: merged write preserves operator keys
  (verify_cmd list, mcp_servers list-of-maps, nested providers — semantic
  equality via YamlElixir); refuses on unparseable; ymlr round-trip table;
  atomicity (tmp cleaned on rename failure — existing persist_env_var tests
  :22-75 stay green); **mode invariants** — existing `0600` config keeps
  `0600` through a rewrite, existing `0644` preserved, NEW config lands
  `0600`, tmp is chmod'd before content, non-regular destination refused.
- Repair-flow BRANCH tests (async: true — via the injected prompt seam AND
  an injectable env-install seam, default `System.put_env`, so branch logic
  never touches VM-global state): persistence ACCEPT → install called AND
  the winning dotenv path upserted, outcome `:persisted` only after the
  re-resolve confirms `durable?`; **the shadowing row** — stale value in
  `project/.jido/.env` + accepted repair → THAT file is upserted (or the
  outcome honestly refuses `:persisted`); **the external-winner row** — a
  cwd-fallback `.env` outside project_dir defines the var + accepted
  repair → the external file's bytes are UNTOUCHED, `project/.env` gets
  the write, re-resolve confirms durable; DECLINE → install called +
  `:session_only` ⇒ `:gaps_remaining`; **persist failure** (unwritable
  target) → rescued to `:session_only` + loud message; voyage decline →
  `:voyage_key` gap ⇒ `:gaps_remaining`, and the flow RETURNS the tagged
  result (driving decline through the seam proves no halt fires — the
  disposition→exit mapping rows cover the entrypoints); **e2e malformed
  repair rows** — each `:invalid_provider_config` fixture repairs, then
  RE-DERIVES clean (classification alone doesn't prove the merge fixed
  it); **wizard-then-derive row** — absent config + wizard completion with
  pending migrations injected → checks carry the `:database` gap and
  disposition is `:gaps_remaining`, never a clean `:wizard_completed`.
- **Live-environment pins in a separate `async: false` module** (the
  branch seams don't cover real-VM behavior): default env-install actually
  lands in `System.get_env`; the `/setup` handler's `:jido_ai`
  model-aliases refresh actually lands in Application env — both with
  snapshot/restore of the touched System vars + Application keys in
  `on_exit` (existing `setup_test.exs` is `async: true`; it keeps only the
  isolated-tmp-dir persist/write tests).
- Raw IO prompt wrappers stay untested (status quo); repair BRANCHING is
  covered through the injected seams. `migration_status` is exercised via
  the injected probe + the two DB pins above (sandbox constraint:
  migrations can't run under the SQL sandbox).

### Docs + reconciliation

- No docs/system page covers cli/setup.ex — none created; module docs are
  the deliverable. core/config.ex appears in tool-approval.md sources but
  the provider-probe edits don't touch approval semantics — no bump.
  mix.exs ymlr promotion noted in the commit body.
- Status lines: PD-FIRST-WAVE item 3 (deviations: DB print-only,
  minimal-boot doctor, halt removal from the Setup API,
  `:unsupported`/`:unavailable` split + `reason`/`repairable?` modeling,
  ymlr swap with mode-preserving atomic writes + the comment/layout
  residual, retrieve-by-id probes with the openrouter two-request
  exception + the 401/403 auth-vs-permission split (`access:`
  discriminator) + normalized deadline-bounded HTTP adapter,
  value-compared durability (`durable?`) with project-owned winning-path
  persistence, live-env install on both repair branches, wizard
  persist-offer + post-wizard final derivation, unlinked own-start claim
  wrapper on the migration probe, centralized total effective-provider
  derivation); pad FWB PD3-1; pre-argus README
  §17; ades XA2-3 cross-ref re-date (manual provider-check surface landed;
  the scheduled canary — queue #6 — separately tracked; note #6 should
  consume `ProviderProbe`).

---

## Verification

Per item, immediately after building — run its new test files
(`mise exec -- mix test test/...`) plus named regression proofs:

- **#16**: golden surface test + fixture; the wire exactness suite; sweep
  test; `mise exec -- mix jidoclaw.jido_md.check` +
  `jidoclaw.system_docs.check`; existing tool_approval/loop_guard/lua
  suites (their envelopes must be untouched); end-to-end spot drive — a
  served-MCP failing tool call shows content[0] legacy text + content[1]
  decodable JSON, and a consolidator/deposit-server error stays
  single-item.
- **#17**: existing `setup_test.exs` + `config_test.exs` +
  `application_test.exs` (dotenv) green; spot drives —
  `mise exec -- mix jidoclaw --setup --check` on this checkout (must not
  start the app tree; prints the derivation, exits honestly), then corrupt
  `.jido/config.yaml` in a scratch dir and watch the doctor report
  `:config :error` without wizard-launching. **Escript smoke** (precommit
  never builds it and this build reworks its boot path):
  `mise exec -- mix escript.build`, then run `./jidoclaw --setup --check`
  in a scratch directory — pin the printed derivation and the exit status
  (`echo $?`), and confirm no app-tree side effects.

**Final bar**: `mise exec -- mix precommit` bare in background; iterate to
green. Known-flaky singleton suites (MCPServer, Prompt, PipelineStore,
MultiSandbox) verified in isolation before blaming new code. Docs gates
re-run as edited (`system_docs.check`, `jido_md.check`;
`graphql.schema.check` expected no-op).

## Suggested commit slicing (operator commits; nothing staged by the agent)

1. `docs: pre-argus wave E #16+#17 plan` — the materialized
   `docs/plans/pre-argus-wave-e-16-17/README.md`.
2. `feat: served-MCP structured error contract + code registry (PD1-2)` —
   #16 (registry, boundary, patch, hints, 1.3 bump, docs, Status lines).
3. `feat: setup doctor with --check, provider probes, ymlr config writes (PD3-1)` —
   #17 (doctor, EnvResolver, ProviderProbe, setup rework, exits, Status
   lines).

Each item's reconciliation/Status edits ride its own commit.
