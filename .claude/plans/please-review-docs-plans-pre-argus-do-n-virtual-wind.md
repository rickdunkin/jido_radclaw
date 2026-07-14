# Plan: pre-argus Wave E #16 — served-MCP boundary error-code registry (PD1-2)

## Context

Executes **#16 only** from
[the pre-argus do-now queue](../../docs/plans/pre-argus-do-now/README.md):
the served-MCP boundary error-code registry (pad PD1-2) — camus C1-3's
closed-contract posture applied to the tool surface. Scope history: the
six-item Wave E plan proved too large, then the #16+#17 cut did too; **#17
is now deferred** alongside #18–#21 (the prior drafts remain their
references: `.claude/plans/please-review-docs-plans-pre-argus-do-no-generic-popcorn.md`
for #17, `…-tranquil-hoare.md` for #18–#21). #16 is independent of all of
them — no dependency is severed by the split. Greenfield — no compat shims.

The #16 design below carries **binding operator decisions** (interview
2026-07-12 + three same-day review rounds inherited from the prior drafts,
plus thirteen further review rounds on this reduced cut, same day):
errors
become machine-readable on the wire via an **additive** second content
item (legacy inspect text byte-identical → honest 1.3 MINOR); the
canonical envelope's wire position is **`content[1]` — the second
raw-wire item, never "the final item"** (downstream relays may append);
registry membership is enforced at the boundary, scoped to the PUBLIC
server only; the exact `Jido.Exec` unwrap is pinned, and **native Jido
typed errors are preserved through `Jido.Action.Error.to_map/1`**
(`retryable?` merged into `details.retry`), not collapsed to
`:tool_error`; every NEW producer envelope carries `details.retry: false`
(the in-call retry gate is real — §2); known domain outcomes normalize at
their producers (`:solution_not_found` → registered `:not_found`; no
forwarded-codes side registry); the boundary guards catch **raise AND
throw/exit**; the structured item gets an **aggregate byte cap** whose
reduction preserves `retry` + bounded hints; `JsonSafe` becomes
genuinely total via a guarded recursive wrapper, its policies **decided
in-plan**; the AST sweep is supplemental lint, the boundary fallback is
the closure proof.

**Re-verified against HEAD `91e355ee` (2026-07-12)** — two-reader sweep +
spot reads; drift from the prior verification sha `656e6889` is ui/-only.
Corrections found this round and folded in below:

- **Inventory grows by one**: `:handoff_not_found` (inspection.ex:87/:469,
  forwarded verbatim by inspect_agent.ex:71) was missed by the prior sweep
  → **48 literal codes at HEAD, 51 registered** after the producer changes
  (original spec said ~25 — record in Status).
- Paths: tool approval lives at `lib/jido_claw/security/tool_approval.ex`
  (its internal `:cache_unavailable`/`:invalid_mount_config` in
  `security/tool_approval/mount_config_cache.ex`, collapsed to a
  fail-closed boolean at tool_approval.ex:455 — never an envelope);
  forge_bridge at `lib/jido_claw/tools/run_command/forge_bridge.ex`;
  `Tools.Error` wire tests at `test/jido_claw/error/tools_wire_format_test.exs`.
- `:unknown_kind` exists only in inspect_agent.ex:94 (inspection.ex :73
  AND :104 are both `:unknown_target`); reactor_runner's
  `:already_terminal` is at :717, `:unexpected_halt` at :774-775.
- mix.exs:15-34's patch comment is currently ACCURATE ("five", full
  enumeration) — it becomes stale the moment this adds the sixth entry;
  update count + enumeration + the "all five patches" tail line.
- `server_instructions/0` mechanism VERIFIED: anubis's
  `maybe_define_server_instructions` (anubis server.ex:552-559) runs in
  `__before_compile__` via `Module.defines?/2`, so a hand-defined
  `server_instructions/0` wins regardless of position relative to the
  `use` line (jido_mcp passes no `:instructions`; today's fallback is
  `nil`). The prior draft's ordering contingency is resolved — plain def.
- Runtime shape: `deps/jido_mcp/lib/jido_mcp/server/runtime.ex` is **276
  lines**, ONE `handle_tool_call/5` (:37; the arity-3 is generated
  per-server by `Jido.MCP.Server.__using__`, jido_mcp server.ex:126-134,
  and delegates); `Jido.Exec.run/3` at :47; the two error arms at :54-55
  and :57-58 both `Response.tool() |> Response.error(inspect(reason))`.
- Test-pin findings: the ONLY end-to-end test through the real runtime
  error arm is `test/jido_claw/memory/consolidator/run_server_test.exs:772-780`
  (consolidator server; asserts `isError` + inspect text, no
  content-length pin) — stays green since that arm stays byte-identical.
  `loop_guard_integration_test.exs`'s single-item content matches are on
  synthetic fixtures, never the runtime — unaffected. LoopGuard's
  signature hashing joins all content text, and served responses DO reach
  it on one supported path: an external-MCP proxy consuming another
  JidoClaw's served surface re-surfaces the raw domain `isError` result
  map (proxy_generator.ex:534-546), after which LoopGuard may APPEND a
  directive item (loop_guard.ex:371-379). Consequence: the canonical
  envelope is specified as `content[1]` — the second raw-wire item — and
  the contract is tested through that composition (§6). Signature drift
  for proxied served errors (the second item joins the hashed text) is an
  accepted, documented effect of the additive shape.
- `.jido/JIDO.md` carries no surface-version string, so the 1.3 bump
  alone wouldn't touch it — but §2's skill-format constraint edits the
  Custom Skills section, so the committed file regenerates and
  `jido_md.check` is live for this change.

**Hard gates:**

- **No PORT map** (posture/contract lift — docs/exploration/README.md rule).
- **Step 0**: materialize this plan as
  `docs/plans/pre-argus-wave-e-16/README.md` (Wave A shape; `## Deviations`
  maintained as work proceeds; operator-confirmed name).
- **Queue discipline**: dated Status lines on every source entry, falsified
  claims corrected, cross-refs updated same session.
- Run mix via `mise exec -- mix`. Gates bare (never piped), run in
  background, read the tail. Known-flaky singleton suites (MCPServer,
  Prompt, PipelineStore, MultiSandbox) verified in ISOLATION before
  blaming new code.
- **Nothing committed by the agent**; work lands unstaged, ending with
  files-to-stage + suggested commit slicing. Completion bar:
  `mise exec -- mix precommit` green.
- New public functions need `@moduledoc`/`@spec` (credo strict); watch the
  known precommit gotchas for new code (Specs/AliasUsage/ImplTrue/ExSlop
  step-comment wrap/ExDNA-dup; Zoi.schema not Zoi.t). The Elixir LSP is
  available for reference checks (callers, definitions) — use it.

---

## 1. New `lib/jido_claw/core/mcp_server/error_codes.ex`

`JidoClaw.MCPServer.ErrorCodes` beside SurfaceVersion (served-MCP scope by
construction; interior stays open). Families as **code → one-line-doc
maps** (a code cannot join without its doc):

```elixir
@type family :: :pipeline | :normalization | :lua | :sandbox | :host_exec | :scope | :lookup | :workflow
@spec families() :: %{family() => %{atom() => String.t()}}
@spec all() :: MapSet.t(atom())
@spec member?(atom()) :: boolean()
@spec family(atom()) :: {:ok, family()} | :error
@spec stability_sentence() :: String.t()
```

Verified inventory (**51 codes** = 48 literal at HEAD + `:unknown_skill` +
`:skill_run_failed` + `:skill_cancelled`):

| family | n | codes (anchors) |
| --- | --- | --- |
| pipeline | 4 | `:approval_pending`/`:approval_denied`/`:approval_unavailable` (security/tool_approval.ex:617/631/643), `:doom_loop` (agent/loop_guard.ex:171/244); cite LoopGuard `@skip_codes` (loop_guard.ex:140) |
| normalization | 11 | tools/error.ex: `:tool_error`, `:validation_error`, `:config_error`, `:execution_error`, `:unknown_error`, `:internal_error`, `:exception`, `:failed`, `:error`, `:still_running`, `:timeout` (:170-202, :399-403) |
| lua | 12 | 11 `:lua_*` via `envelope/3` (tools/lua/runner.ex:399; :106-:233) + `:unknown_binding` (lua_docs.ex:48) |
| sandbox | 4 | `:sandbox_unavailable`/`:sandbox_command_timeout`/`:sandbox_output_limit`/`:sandbox_deadline_exceeded` (tools/run_command/forge_bridge.ex:292-325) |
| host_exec | 2 | `:host_deadline_exceeded`/`:host_command_timeout` (tools/run_command.ex:266-267, via `deadline_error_code/1` at :258) |
| scope | 4 | `:tenant_required` (runtime_scope.ex:11 + 8 tool emitters + view-module relays), `:missing_tenant` (run_skill.ex:76/113), `:missing_scope_tenant`/`:missing_scope_workspace` (store_solution.ex:84/87, find_solution.ex:63/64) |
| lookup | 10 | `:session_not_found`/`:session_id_mismatch`/`:session_not_resolved` (agent_view.ex:280-321), `:not_found` (workflow_view.ex:128/139/184, inspection.ex:132/136, + network_share's normalized solution miss — §4), `:unknown_target` (inspect_agent.ex:78, inspection.ex:73/104), `:unknown_kind` (inspect_agent.ex:94), `:handoff_not_found` (inspection.ex:87/469 → forwarded by inspect_agent.ex:71), NEWLY-TYPED `:absolute_glob_not_allowed`/`:glob_outside_project` (list_directory.ex:177/180-183), NEW `:unknown_skill` |
| workflow | 4 | `:replay_refused` (replay_workflow.ex:97), `:event_feed_unavailable` (workflow_view.ex:419), NEW `:skill_run_failed` + `:skill_cancelled` (run_skill boundary normalization, §2) |

Details-level sub-codes stay excluded (documented): `:foreign`/`:unknown`
(tools/error.ex:249/253 — inside `details.errors[]`),
`:dropped_runtime_handle` (error.ex:332), tool_approval's internal
`:cache_unavailable`/`:invalid_mount_config` (never reach an envelope).

**Known forwarded atoms get normalized at their producers, not a side
registry**: `:solution_not_found` (originates network/node.ex:247, rides
network_share.ex's :49-50 catch-all today) is a NORMAL domain outcome —
letting it hit the boundary's unregistered-code fallback would emit a
false-positive drift log on every miss and lose specificity. Add an
explicit clause in network_share.ex ahead of the catch-all mapping it to
the registered `:not_found` with `details` carrying the solution
identifier/kind + `retry: false` (the prior drafts' `forwarded_codes()` /
`forwarded()` side registry is DROPPED — with its only member normalized
it would be dead machinery; deviation recorded in Status). The catch-alls
that remain (network_share.ex's residual forward; run_skill.ex:80's
Skills.get/Compiler forward after §2) are documented as
`@open_forwarders` sites in the sweep test — genuinely unforeseen atoms
are exactly what the boundary fallback + drift log are FOR.
`Error.normalize`'s legacy funnel forwards ANY atom found under
`code:`/`status:` keys (error.ex:119-121, 391-403) — the set is formally
open, so the boundary fallback is required by construction.

Moduledoc carries the **#4 kinship paragraph** (`mix jidoclaw run` exit
tiers 0–6 classify via `RunFailure`; one contract family, two enforcement
points — this closes the queue's #4↔#16 cross-consume rule) — NO
run_command.ex CLI edit (that file is in ambiguity-clarify.md sources).

## 2. run_skill boundary normalization (replaces enumerating an open set)

run_skill today forwards EVERY ReactorRunner reason verbatim
(run_skill.ex:78 — at least `:cancelled`, `:fenced`, `:already_running`,
`:not_a_reactor`, `:missing_required_opt`, `:exit`, `:already_terminal`
(reactor_runner.ex:717), `:unexpected_halt` (:774-775), plus arbitrary
mid-run Reactor reasons — an open set no registry can close). Normalize at
the tool boundary instead: `:cancelled` → typed `:skill_cancelled`; every
other runner failure → typed `:skill_run_failed` with the original reason
preserved under `details.reason` — built as **budgeted
`JsonSafe.encode_bounded(reason)` first (§3's walker; a tripped budget
yields a constant truncation marker + `observed_at_least`, never a full
walk), then `Error.sanitize_details(%{reason: safe_reason})`**
(error.ex:267 — the 2KB string + 8KB collection caps with truncation
metadata). Both stages are
needed: `sanitize_details/1` alone is not a total arbitrary-reason
sanitizer (a bare atom arg returns `%{}` (error.ex:285), improper lists
raise, hostile structs can invoke `Inspect` early), and already-canonical
envelopes bypass `normalize/1`'s sanitization (error.ex:119-122) while a
raw Reactor reason can be aggregate-huge. Fidelity note: `content[0]`
shows the POST-normalization envelope (byte-identity holds against the
normalized legacy arm) — the raw uncapped Reactor term is deliberately not
preserved.

**Both envelopes are non-retryable in-call**: force
`Map.put(:retry, false)` AFTER `sanitize_details` (the truncation rewrite
at error.ex:274-279 replaces the map and could otherwise drop the flag).
The gate is real and verified: the MCP runtime invokes `Jido.Exec.run/3`
with no opts (runtime.ex:47); jido_action's retry loop defaults to ONE
retry (`Retry.default_retry_config/0`, retry.ex:136-141) gated by
`Retry.should_retry?` (exec.ex:405) → `Error.retryable?/1`, which reads
the details-level `:retry` hint in both wrap states — pre-wrap via the
`%{code: _}` clause (jido_action error.ex:475-477), post-wrap via
`extract_retry_hint`'s one-`:details`-level dig (:618-623, :637-643) —
and an UNFLAGGED envelope defaults retryable
(`default_retryable_type?/1` is false only for validation/configuration,
:603-606). `run_skill` supplies no idempotency key and `ReactorRunner`
mints a fresh run per call (run_skill.ex:63, reactor_runner.ex:244), so an
unflagged failure envelope would re-launch a cancelled or partially-failed
workflow inside the same MCP call. Call-count regression test in §6.

**Failure identity is structural and INTERNAL to LoopGuard — messages
stay human-readable and hash-free**: LoopGuard derives ordinary error
signatures from `message` alone, first 100 characters (loop_guard.ex:276,
:590), and run_skill is a registered agent-pipeline tool too — a
CONSTANT `:skill_run_failed` message would collapse distinct failures
into one repeated signature and could trip a false staged recovery or
halt, while long shared-prefix subjects can still collide inside the
window. A message-embedded digest is REJECTED on security grounds: the
producer and LoopGuard run BEFORE `OutputRedaction` (action.ex:76), so
hashing the unredacted reason into public text would plant an unsalted
correlation/dictionary oracle that later redaction cannot remove (and a
short hex prefix is only ~32 bits of identity anyway). Instead: (a)
producer messages lead with the human SUBJECT — skill name here; §4's
requested name / offending glob / solution identifier — bounded, no
hashes, and both run_skill envelopes carry `details.skill` (exact) plus
**`details.reason_head`** — a bounded dot-joined path of the reason's
LEADING ATOMS computed PRE-JsonSafe (`{:exit, :timeout}` →
`"exit.timeout"`; cap: depth 4 / 128 bytes via the **UTF-8-safe
`OutputLimit.valid_utf8_prefix`** — atoms can carry multibyte text, and
a split character would plant invalid UTF-8 ahead of
`OutputRedaction`'s regex path, ansi.ex:29) — non-sensitive by
construction (atoms are code-level identifiers, never user data) beside
`details.reason` — **all three discriminators (`retry`, `skill`,
`reason_head`) inserted AFTER `sanitize_details/1`**, since its
truncation rewrite's keep-list (error.ex:61) would otherwise drop them,
and the projection's identifier bound never clips a legitimate name
because **skill-name length (≤ 256 bytes) is enforced at the Skills
parse/load boundary with a PINNED posture** — the current loader
flattens parse failures to `[]`, reload always returns `:ok`, and
replay maps an omitted definition to `:not_found`
(skills.ex:410/:453/:466), so a naive local check would silently drop
or misclassify: instead an overlong-name definition is EXCLUDED with a
loud per-file error log naming the file + the violated bound, at BOTH
startup load and reload (no crash, no stale-cache retention — matching
the malformed-YAML exclusion posture but never silent), and downstream
calls honestly yield `:unknown_skill` / replay `:not_found`; the
constraint joins the documented skill format **operator-facing**: the
Skills moduledoc, the Custom Skills documentation source that renders
into `.jido/JIDO.md` (locate the section text in `JidoClaw.JidoMd` /
its inputs; regenerate the committed file), and the README-facing
skill-format docs — with load/reload exclusion tests. Because
`JidoMd.Check.problems/2` validates only version/names/frameworks/paths
(check.ex:31) and cannot see prose drift, **extend the check with a
generator-vs-committed comparison scoped to the generated Custom
Skills FRAGMENT only** (byte-level over that section, the
`system_prompt.check` precedent — NEVER whole-file: the generator
emits the whole document but explicitly permits operator edits to the
Architecture/Conventions sections, jido_md.ex:59, which whole-file
equality would reject; tested — an unrelated editable-section edit
still passes) so a generator prose change fails precommit until the
committed file regenerates — making `skill` exact by invariant;
(b) **LoopGuard's failure-signature derivation is
extended**: beside the code + 100-char message prefix it folds in a
FULL `CanonicalHash.sha256_term/1` (single-hash rule,
canonical_hash.ex:14 — LoopGuard already rejected phash2,
loop_guard.ex:322) over a **FIELD-AWARE structural projection** of the
envelope's details, built by §3's budgeted walker (budget trip → a
constant sentinel component), **total over every BEAM term class**:
lists keep shape; **projected maps become deterministically sorted
tagged lists of `{projected_key, projected_value}` pairs, the term
policy applied to KEYS too** (BEAM map keys can be pids/refs — keeping
them raw would reintroduce per-attempt drift, while collapsing several
marker-projected keys into one map entry would lose shape; the pair
LIST keeps every entry, sorted by Erlang term order of the projected
pairs); tuples projected as shape-kept lists; structs as their module
atom + projected field pairs; atom/boolean leaves kept exact;
**NUMBERS map to a constant class marker** — existing envelopes carry
volatile per-attempt numeric metadata (lua's `call_count`,
runner.ex:162), and exact numbers would mint a fresh identity per
attempt, evading staged recovery where today's message-only signatures
correctly repeat (loop_guard.ex:526); numeric keys join the exact-value
allowlist only by deliberate future edit; every binary leaf replaced by
ONE CONSTANT marker —
EXCEPT values under the pinned non-sensitive key allowlist (`skill`,
`reason_head`, `field`), kept exact and bounded (the 256-byte
identifier bound); **runtime identities — pids, refs, ports, functions,
non-binary bitstrings — each map to one CONSTANT per-class marker**
(`:pid`, `:ref`, …), never their value: at HEAD a pid living only in
`details` never influenced the message-only signature
(loop_guard.ex:276), and keeping pid VALUES would introduce brand-new
per-attempt drift. A naive binary→length projection fails BOTH identity
invariants (run_skill's `details.reason` is already JsonSafe'd — tuple
atoms became strings, json_safe.ex:68 — so equal-length skills/values
would collide while different-length secrets would split). **Plumbing
pin — identity separated from display**: today classification keeps
only message text (loop_guard.ex:216) and the Store takes that same
text for both comparison and directive rendering (store.ex:51); the
extension makes classification produce an explicit `{identity,
display}` pair — `identity` = `CanonicalHash.sha256_term/1` over
`{code, message_prefix, details_fingerprint}` (what the Store
compares and counts; the CODE is an explicit component), `display` =
the bounded human text directives render. The identity is held
INTERNALLY in LoopGuard's signature state, never emitted in messages,
halt directives, telemetry text, or logs. `reason_head` + exact `skill` split `{:exit, :timeout}` from
`{:exit, :killed}` and equal-length skill names even when message
prefixes collide; secrets of ANY length hit the constant marker —
same failure class. The fingerprint only ADDS distinction beside the
message component, so no previously-distinct signatures merge.
Identical failures keep identical signatures (the determinism genuine
loop detection needs): pids/refs in details contribute class markers,
never values — no new drift — and message-embedded pid TEXT was already
unstable at HEAD, so signature stability strictly does not regress. §6
pins distinctness, determinism, runtime-identity stability, and the
secret regression; loop-guard.md gets the same-change docs bump (§7).

## 3. The wire boundary — new `error_boundary.ex` + jido_mcp runtime patch

Today `Jido.MCP.Server.Runtime.handle_tool_call/5` executes tools via
`Jido.Exec.run/3` (:47) and its two error arms (:54-55, :57-58) emit
`Response.tool() |> Response.error(inspect(reason))` — a single text item
+ `isError: true` (anubis response.ex:391-395 appends via `text/2`
:144-148 / `add_content` :690; `to_protocol` :656-662 serializes
`content` + `isError`).

- **New patch `lib/jido_claw/core/jido_mcp_runtime_patch.ex`**: redefines
  `Jido.MCP.Server.Runtime` (276-line full copy — the
  anubis_tools_handler_patch.ex pattern: `#`-comment header naming
  upstream package+version, verbatim-port note, numbered surgical changes,
  retirement condition) with ONLY the two `{:error, …}` arms changed to
  `JidoClaw.MCPServer.ErrorBoundary.error_response(reason, server_module)`
  (`server_module` is the 5th arg, in scope). Register
  `{Jido.MCP.Server.Runtime, :jido_mcp}` in `@patched_modules`
  (dependency_patches.ex:4-10 — boot loading via
  `DependencyPatches.ensure_loaded!/0` (application.ex:48) and the
  `Mix.Tasks.Compile.JidoclawReleasePatches` BEAM relocation both read
  this list). Update the mix.exs:15-34 comment (five→six, enumeration,
  tail line); `ignore_module_conflict: true` is already global (mix.exs:35).
  Document beside the anubis patch in AGENTS.md known-limitations + the
  docs page, with a drop-when-upstream note.
- **New `lib/jido_claw/core/mcp_server/error_boundary.ex`**
  (`JidoClaw.MCPServer.ErrorBoundary`) — all logic lives here so the patch
  stays a thin copy. **Scoped, not global**: match `JidoClaw.MCPServer` →
  structured + registry-enforced; every OTHER server
  (`JidoClaw.Memory.Consolidator.MCPServer`,
  `JidoClaw.Skills.Steps.ForgeExecutor.DepositServer` — all three ride
  this one Runtime via their generated arity-3 delegates) → the
  byte-identical legacy `Response.error(inspect(reason))` arm, raw-inspect
  raise path included.
- **Additive wire shape**: `content[0]` keeps the legacy inspect text
  BYTE-IDENTICAL; a SECOND text content item carries canonical JSON
  `{"code","message","details"}` — build via
  `Response.tool() |> Response.error(legacy) |> Response.text(json)`
  (`text/2` appends; the LoopGuard appended-text-item precedent,
  loop_guard.ex:371-379). No repurposing of `structuredContent` (owned by
  the success path's `Response.structured/2`, runtime.ex:205). Genuinely
  additive → **1.3 MINOR is honest**.
- **Exact unwrap, in pinned order — native typed errors preserved**
  (verified end-to-end): a tool returning
  `{:error, %{code: c, message: m, details: d}}` reaches the arm as
  `%Jido.Action.Error.ExecutionFailureError{message: m·sanitized,
  details: %{code: c, details: d}}` — exec.ex:781-785
  (`handle_action_result`) → `extract_error_fields` binary-message clause
  :807-809 (message = `Telemetry.extract_safe_error_message(reason)`,
  telemetry.ex:135-152 → `Sanitizer.sanitize_telemetry`; details =
  `Map.delete(reason, :message)`) →
  `Jido.Action.Error.execution_error/2` (jido_action error.ex:263-268;
  `defexception [:message, :details]` :174). The boundary unwraps:
  **(1)** the exact nested canonical envelope — an
  `ExecutionFailureError` whose `details` carries both `:code` (atom) and
  `:details` → reconstruct `{details.code, exception.message,
  details.details}`; **(2)** a raw `%{code, message, details}` envelope
  map; **(3)** native Jido typed errors — the patched tools handler
  delegates validation to `Jido.Exec` (anubis_tools_handler_patch.ex:138),
  so `InvalidInputError`, `TimeoutError`, `ConfigurationError`,
  `InternalError`/`Internal.UnknownError`, and plain (non-envelope)
  `ExecutionFailureError`s reach the arms; adapt these six struct types
  through `Jido.Action.Error.to_map/1` (the documented cross-package
  adapter — jido_action error.ex:21, clauses :339-403) which yields
  `type ∈ {:validation_error, :timeout, :configuration_error,
  :internal_error, :execution_error}` with normalized message + sanitized
  details (an explicitly-constructed `InvalidInputError` contributes
  `details.field`/`details.value`; NimbleOptions schema failures format
  the message only — schema.ex:150 never populates `field`) **plus the
  SEPARATE `retryable?` field (error.ex:304-326), which the projection
  must not drop — merge it as `details.retry` via `Map.put_new/3`** (an
  explicit producer hint wins); translate `:configuration_error` → the
  registry's `:config_error`, take the rest as-is — downstream registry
  enforcement then applies uniformly;
  **(4)** everything else →
  `{"code":"tool_error","message":inspect-text,"details":{}}`. Handled
  totally; order matters — (1) before (3), or our envelopes would collapse
  to a generic `:execution_error`.
- **The entire canonical envelope is normalized through the budgeted
  `JsonSafe.encode_bounded/2` BEFORE `Jason.encode!`** — pinned branch:
  `{:ok, value, _encoded_bytes}` proceeds to `Jason.encode!`;
  `{:budget_exceeded, %{observed_at_least: n}}` skips STRAIGHT to the
  reduced envelope (the cap bullet below) with `observed_at_least`
  metadata — the unbounded `encode/1` never runs on this path. A raise
  here would convert a tool error into a JSON-RPC execution failure. `JsonSafe` is
  NOT total today (verified): invalid-UTF-8 binaries pass through the
  binary clause (json_safe.ex:87-89) and `<<255>>` produces
  `Jason.EncodeError` (operator-verified); binary map KEYS likewise pass
  unchanged (`encode_key/1` :95-97); the list clause (:64) raises on
  improper lists like `[1 | 2]`; and beyond the two `inspect/1` sites
  (the value fallback :93, `encode_key/1`'s non-atom/binary arm), the
  special struct clauses can raise or throw on MALFORMED structs —
  `DateTime.to_iso8601/1` on a hand-built `%{__struct__: DateTime}` with
  garbage fields, `MapSet.to_list/1` likewise (:33-41) — despite the
  moduledoc's accepts-every-term promise (:8). Note: a hostile-`Inspect`
  STRUCT as a value takes the generic struct clause (:43-47,
  `Map.from_struct` + recurse), never `inspect/1` — leaf-site guards
  alone can't make the module total. **Harden `JsonSafe` as part of this
  item — policies decided now, not at build**: (a) **total wrapper
  shape** — the public `encode/1` becomes a rescue+catch wrapper around a
  private `do_encode/1`, and ALL recursion re-enters the guarded public
  entry point, so any escape (raise, throw, exit — malformed calendar
  struct, hostile impl, future clause bug) degrades ONLY that leaf/subtree
  to a static `"[unencodable]"` placeholder, never the payload;
  `encode_key/1` gets the same rescue+catch treatment; (b) binary VALUES
  failing `String.valid?/1` are scrubbed by replacement-char conversion
  (`String.chunk(bin, :valid)`; invalid chunks → `"�"`) — valid text
  stays readable; (c) binary KEYS failing `String.valid?/1` use a
  **tagged Base64 encoding** —
  `"<<invalid-utf8:" <> Base.encode64(bin) <> ">>"` — deterministic, and
  exact/distinct per binary UP TO `invalid_key_prefix_bytes` (256 —
  distinct from the walker's `max_key_bytes: 1024` traversal budget;
  plain `inspect(bin)` would truncate unpredictably under default
  limits; oversized keys take the bounded `:trunc-<size>` form — a
  deliberate LOSSY normalization); ALL residual collisions (a VALID key
  whose text equals a tagged form; two oversized keys sharing prefix +
  length) are resolved deterministically by folding entries in Erlang
  term order of the ORIGINAL keys (later wins, documented in the
  moduledoc) — never an unordered-map accident; (d)
  improper lists get a detecting walk — `[1 | 2]` encodes as `[1, 2]`,
  the improper tail becoming the final element (documented); (e) one
  shared **public `JsonSafe.safe_inspect/1`** — plain `inspect/1` under
  rescue+catch (static `"[uninspectable]"` on escape) **whose SUCCESSFUL
  result is then UTF-8-validated and replacement-char-scrubbed**: a
  custom `Inspect` impl can successfully RETURN invalid bytes like
  `<<255>>` — no guard fires, yet the invalid text would blow up final
  protocol serialization; it backs the module's own value/key fallbacks
  AND §3's boundary rendering (`content[0]`, messages). The moduledoc's
  totality claim becomes TRUE; unit rows in `json_safe_test.exs` (§6).
  Global strengthening of an already-lossy normalizer — safe for its
  existing consumers (bootstrap payload et al.).
- **Bounded WORK, not just bounded output — a shared budgeted walker**:
  checking 16 KiB after materializing the full `JsonSafe` tree + full
  Jason binary would leave the failure path resource-unbounded — huge
  maps, deep terms, or oversized invalid binary keys (map keys are not
  capped by `OutputLimit`, and tagged-Base64 encoding adds ~4/3
  expansion) can exhaust CPU/heap BEFORE any cap fires. A deterministic
  budgeted walker (`JsonSafe.encode_bounded/2`-class) with **pinned,
  distinctly-named constants** — `max_nodes: 50_000`, `max_depth: 64`,
  `max_key_bytes: 1024` (per-key traversal budget, pre-tagging),
  `max_bytes: 128 KiB` cumulative, and the separate
  `invalid_key_prefix_bytes: 256` (how much of an invalid key the
  tagged encoding draws) —
  and a **pinned result contract**:
  `{:ok, value, encoded_bytes}` (full traversal; exact size known) |
  `{:budget_exceeded, %{observed_at_least: n}}` (short-circuited; only a
  LOWER BOUND is knowable — computing an exact total would require the
  full walk the budget exists to prevent). **Container preflights are
  O(1) and precede ANY materialization**: `map_size`/`tuple_size`/
  `MapSet.size` are checked against the REMAINING node budget BEFORE
  any `Map.to_list`/`Tuple.to_list`/`MapSet.to_list` — a straight
  to_list-then-sort would materialize a 10M-entry container before the
  counters ever ran (the existing MapSet clause, json_safe.ex:37,
  inherits the same preflight) — so only a preflight-passing container
  converts, making materialization + term-order sort cost
  budget-bounded by construction; per-entry KEY sizes are checked
  during iteration, before sorting, oversized keys taking the bounded
  marker path. It backs every
  unbounded-input site: the boundary's envelope production trips →
  straight to the reduced envelope (which extracts only allowlisted
  keys — bounded by construction, no full walk); run_skill's reason
  encoding (§2) trips → a constant truncation marker +
  `observed_at_least`; LoopGuard's structural projection (§2) trips → a
  constant budget-exceeded sentinel component. **Size-metadata
  semantics**: `original_byte_size` appears ONLY on fully-traversed
  over-cap values; budget-tripped reductions carry
  `%{"truncated" => true, "observed_at_least" => n}` instead — the two
  are never conflated. Invalid binary KEYS' tagged encoding draws from
  AT MOST `invalid_key_prefix_bytes` (256)
  (`"<<invalid-utf8:" <> Base.encode64(prefix) <> ":trunc-<total
  size>>>"` when oversized) — a deliberate LOSSY normalization:
  equal-length oversized keys sharing that prefix collide, and the
  deterministic term-order winner policy resolves them (tested).
- **Aggregate byte cap on the structured item**: `JsonSafe` ensures
  encodability, never bounded size — canonical envelopes bypass
  `sanitize_details/1` (error.ex:119-122) and `OutputLimit` caps
  individual leaves, not map/list cardinality (output_limit.ex:29), so a
  many-key `details` map would mint an unbounded second item duplicating
  an already-large legacy item. The boundary caps the ENCODED canonical
  JSON at **16 KiB**; over-cap → a reduced envelope, built defensively —
  the allowlisted values are NOT assumed bounded (canonical details
  bypass sanitization entirely, error.ex:114-122, and `OutputLimit` is
  per-leaf-only — 32 KiB per binary — and not universal: published-tool
  envelopes DO traverse it in the Tools.Action pipeline, but it cannot
  bound aggregate size, and native Jido errors + raw reasons reach the
  boundary without ever passing it): same
  `code`; message through a **boundary-local UTF-8-safe 2KB truncator**
  built on `OutputLimit.valid_utf8_prefix` (already consumed
  cross-module by error.ex:357 — `Tools.Error.truncate_string/1` is
  private and stays private); `details` reduced to the **fixed
  allowlist `retry`, `field`, `expected`, `got`, `available`,
  `available_truncated`, and `unregistered_code`** (the last present
  exactly when the registry fallback produced it — the advertised
  fallback contract promises it, so no reduction tier may drop it; it
  is a bounded stringified atom) (matched in BOTH atom and string key
  forms —
  first found wins; `retry` is the downstream-retry signal — the in-call
  gate consumed the producer flag before the boundary ran — and the
  `available` pair is the whole point of a hint envelope), **each
  retained value re-bounded under a shared budget** (strings through the
  2KB truncator; the `available` list dropped element-wise once the
  shared ~8 KiB retained-values budget is spent, flipping
  `available_truncated`) — and, since a budget-tripped abort leaves NO
  normalized value (the reducer reads the RAW details), **each retained
  value passes through its own fresh small bounded JsonSafe pass**
  before joining the envelope — a retained pid, tuple, or hostile
  struct would otherwise blow `Jason.encode!` and needlessly escalate
  to the static fallback. That per-field pass has its OWN pinned
  budget-exceeded branch: a value whose small pass trips (deeply
  nested / oversized) is replaced by the CONSTANT marker string
  `"[truncated]"` — bounded by construction, never a fall-through to
  the static fallback, and never reachable for the boolean `retry` —
  merged with
  `%{"truncated" => true, "original_byte_size" => n}`. Then **re-encode
  and re-check**: if the reduction still exceeds 16 KiB, fall back to
  the minimal envelope — code + truncated message + the truncation
  metadata **+ the effective retry boolean + a bounded
  `unregistered_code` whenever the registry fallback is active** (a
  boolean and a truncated atom string cost bytes, never the cap) —
  bounded by construction. Machine-readable code and
  retry always survive every reduction tier. (At this stage `retry` is
  wire/downstream metadata — the in-call Jido retry already ran before
  the boundary; the producer-side flag in §2/§4 is what gates that.)
- **Belt-and-braces — rescue AND catch**: totality can't be proven against
  future shapes, so the boundary's ENTIRE structured-item production —
  unwrap, any message rendering the boundary itself performs (its
  `inspect/1` uses included), `JsonSafe.encode_bounded/2`, and
  `Jason.encode!` —
  sits in one guarded region; on ANY escape it emits a fully STATIC ASCII
  envelope
  (`{"code":"tool_error","message":"error serialization failed","details":{"retry":false}}`
  — zero interpolation of the term, and the retry bit is IN the static
  text: `tool_error` with empty details reads retryable under Jido's
  default policy, jido_action error.ex:604, and a deterministic
  serialization failure must not be laundered into a retryable-looking
  error) so a serializer bug can never escalate a tool error into a
  JSON-RPC failure. `try/rescue` alone does NOT
  satisfy this: a hostile `Inspect` impl can `throw` or `exit`, which
  escapes `rescue` and lands in the runtime's outer handlers
  (runtime.ex:67-81 — rescue AND catch both convert to a JSON-RPC
  execution error). Every guard here — the region and every inspect
  rendering — therefore pairs `rescue` with `catch` (throw + exit), with
  runtime-driven tests for all three escape kinds. **The public arm's
  `content[0]` is guarded the same way** — an unguarded legacy
  `inspect(reason)` escaping would abort the arm before the structured
  item is ever appended: render it via the shared
  `JsonSafe.safe_inspect/1` (§ JsonSafe (e): rescue+catch → static
  `"[uninspectable error term]"`-class fallback, AND UTF-8
  validation/scrub of successful output — an `Inspect` impl can succeed
  while returning invalid bytes).
  Ordinary terms stay BYTE-IDENTICAL (the inspect succeeded — same bytes
  as HEAD); hostile terms produced a protocol error at HEAD, so the static
  text is a strict improvement, and the wire test pins the new behavior
  explicitly. The consolidator/deposit arms keep HEAD's raw `inspect`
  verbatim — their pin is byte-identical legacy behavior, escape path
  included.
- **Registry enforcement at the boundary**: unknown/unregistered codes →
  fallback `:tool_error` + `details.unregistered_code` carrying the
  original **stringified explicitly (atom → `inspect/1`, total for
  atoms) BEFORE `JsonSafe`** — `Tools.Error` forwards ANY atom as a code,
  including module atoms, and JsonSafe deliberately DROPS module atoms
  used as map values (json_safe.ex:49-56), which would silently delete
  the promised key — **and RETAINING the envelope's normalized retry
  boolean** (an unregistered canonical envelope carrying `retry: false`
  already suppressed the in-call retry, but a details-replacing fallback
  would present a retryable-looking `tool_error` to downstream
  consumers) + a log line. This is the closure PROOF; the sweep test is
  supplemental lint.

## 4. Hint fields + producers

- `Tools.Error` gains `hint_available(names, details \\ %{})` and
  `hint_expected(expected, got, details \\ %{})` (reuse the existing 2KB
  `truncate_string` machinery, error.ex:355-362) — typed details
  generalizing the LoopGuard-directive precedent. `hint_available`
  **canonicalizes before capping**: stringify each name, dedupe, sort
  ascending, THEN cap at 25 with `available_truncated` derived from the
  pre-cap count — `Skills.list/0` inherits unsorted `File.ls/1` order
  (platform/skills.ex:466), so an uncanonicalized cap would produce
  nondeterministic hints and flaky tests.
- `run_skill.ex`: unknown skill (today a plain string from
  platform/skills.ex:448 → `:tool_error`) → typed `:unknown_skill` +
  `hint_available` from `Skills.list/0` (platform/skills.ex:283-286 —
  already returns name strings), **`retry: false`** on the envelope
  (deterministic lookup — §2's retry gate applies to every new producer
  envelope), and **`details.skill` = the REQUESTED name** (truncated to
  the 256-byte identifier bound via the UTF-8-safe
  `valid_utf8_prefix` — it's request input, not a registry name, and a
  split multibyte character must not plant invalid text ahead of
  redaction) so the identity projection covers this producer too. ReactorRunner failures — the THREE-tuple arm
  `{:error, reason, _run}` at :78, the only arm `ReactorRunner.run/3`
  feeds — get §2's normalization; the TWO-tuple arm at :80
  (Skills.get/Compiler failures) special-cases the unknown skill into
  `:unknown_skill` and otherwise stays an open forwarder (§1's
  `@open_forwarders`).
- `list_directory.ex`: stop string-flattening (:158-161) the already-typed
  glob atoms (`validate_glob/1` :174-188 emits them) → typed envelopes +
  `hint_expected(...)` + **`retry: false`** (deterministic validation — a
  retry re-fails identically). Other `"Cannot list …"` strings (:87, :99,
  :114, :141) stay as-is.
- `network_share.ex`: an explicit clause ahead of the :49-50 catch-all
  maps `{:error, :solution_not_found}` → registered `:not_found` with
  `details` carrying the solution identifier/kind + `retry: false` (§1's
  normalize-at-the-producer decision — a normal domain outcome must never
  trip the boundary's drift log). The residual catch-all stays for
  genuinely unforeseen atoms.
- `lua_docs.ex`: **untouched** — it already emits typed `:unknown_binding`
  with a string `available` detail (lua_docs.ex:44-51); existing served
  shape — unify at next MAJOR (residual noted in docs).

## 5. Version + server-level stability sentence

- `mcp_server.ex`: hand-define `server_instructions/0` returning
  `ErrorCodes.stability_sentence()` — mechanism verified (§ Context), no
  ordering contingency needed. The sentence itself **scopes the contract
  to TOOL-RESULT errors** (`isError: true` tool responses): the boundary
  covers only the two `Jido.Exec` error arms — unknown tools,
  authorization refusals, and escaped runtime failures remain plain
  MCP/JSON-RPC protocol errors with no `content[1]` (runtime.ex:60-81),
  and clients must not infer that every served-MCP failure carries the
  registry envelope.
- `resources/bootstrap.ex`: additive `"error_contract"` key (stability
  sentence + family→codes map + the location rule: "the canonical JSON is
  `content[1]`, the second content item of the raw error response" —
  NEVER "the final item"; downstream relays like the external-MCP
  proxy → LoopGuard path may append items — + the same tool-result-only
  scope statement + the fallback rule: unregistered codes arrive as
  `tool_error` with `details.unregistered_code`); payload already flows
  through `JsonSafe.encode` (:77) — today's keys `app_version`,
  `surface_version`, `tool_count`, `tool_names`, `tenant`.
- `surface_version.ex`: `@current "1.2"` (:43) → `"1.3"` + moduledoc
  changelog bullet (additive: second error content item, hints, new
  lookup/workflow codes, instructions, bootstrap field). **The error
  contract joins the committed surface golden**: the fixture
  (test/fixtures/mcp_surface/served_surface.json) gains an
  **`error_codes_by_family`** block with one exactly-defined shape —
  `%{family_string => [sorted code strings]}`, i.e.
  `ErrorCodes.families()` with each family's code KEYS stringified and
  sorted, docs deliberately EXCLUDED (membership is the wire contract;
  doc-wording edits are registry-internal and must not read as surface
  drift) — beside the `surface_version` field update, and the golden
  test compares the LIVE registry's derivation against it. Without this
  pin a future code/family change could ship silently at v1.3 with
  every test green (the bootstrap assertion compares against the same
  source — wiring proof, not stability proof). Extend the golden test's
  drift instructions + the SurfaceVersion bump rules to classify
  error-code changes: **additions = MINOR; removals, renames, refamilies
  = MAJOR** — always a deliberate bump + fixture regen in the same diff.
  Tool/resource sets are unchanged. Run `jido_md.check` — **no longer a
  no-op**: the version string still doesn't appear in JIDO.md, but §2's
  skill-format constraint edits the Custom Skills section, so
  `.jido/JIDO.md` regenerates in the same change.

## 6. Tests

- `error_codes_test.exs` (async: true): family/all/member/family-lookup
  units; every registered code has a nonempty doc (the map shape makes
  this structural); families disjoint.
- **Wire test asserts EXACTNESS, not membership** (new
  `error_boundary_test.exs`, driving the patched
  `Jido.MCP.Server.Runtime.handle_tool_call/5` end-to-end with scripted
  action modules): (a) failing served tool → `content[1]` JSON decodes to
  the EXACT original code + message + inner details; (b) a foreign
  unregistered atom → fallback + `unregistered_code` carrying the
  original, and a module-atom CODE **via a canonical producer path** — a
  scripted action returning the explicit envelope
  `{:error, %{code: Some.Module, message: …, details: %{}}}` →
  `details.unregistered_code == "Some.Module"` (the pre-JsonSafe
  stringification pin — module atoms as map values are otherwise
  dropped). A PLAIN `{:error, Some.Module}` from a bare action is
  wrapped by `Jido.Exec` with the atom under `details.reason`
  (exec.ex:818-819) and correctly maps to `execution_error` via case
  (3) — pin that too; it is NOT the fallback path, and no extra unwrap
  arm for raw atoms may be added to force it there; (c) `content[0]`
  bytes unchanged vs the unpatched arm (compare against
  `inspect(reason)`);
  (d) consolidator + deposit `server_module`s → byte-identical single-item
  legacy behavior; (e) success responses untouched (`structuredContent`
  path); (f) non-JSON-safe nested details (tuples, pids, non-string keys,
  **invalid-UTF-8 binaries as both value and key** — the `<<255>>` case —
  **and an improper list** `[1 | 2]`) still produce a decodable envelope;
  (g) the belt-and-braces fallback, driven THROUGH
  `Runtime.handle_tool_call/5` (not only a serializer unit): hostile
  `Inspect` implementations that **raise, throw, and exit** (three
  separate rows — throw/exit escape `rescue` and would otherwise hit the
  runtime's outer handlers, runtime.ex:67-81) → the reply is still a tool
  response with BOTH items — `content[0]` the static `safe_inspect`
  fallback, `content[1]` a decodable envelope (the static ASCII form,
  carrying `"retry": false`, when the guarded region tripped) — never a
  protocol/JSON-RPC error; PLUS an
  `Inspect` impl that SUCCEEDS but returns invalid bytes (`<<255>>` in
  its doc) → both items are valid UTF-8 and the full
  `Jason.encode(Response.to_protocol(response))` round-trip succeeds
  (the final-serialization pin — no guard fires on a successful
  inspect); the `content[0]` byte-identity pin (c) is scoped to terms
  whose inspect succeeds with valid output; (h) run_skill's
  `:skill_run_failed` with a large nested
  Reactor reason → details capped with truncation metadata (the sanitize
  pipeline pin), never an unbounded content item — plus atom,
  improper-list, and hostile-struct reasons through the RunSkill path;
  (i) **retry regression (call-count)**: a scripted counting action
  returning a new-style `retry: false` envelope through
  `handle_tool_call/5` executes EXACTLY once, and the control WITHOUT the
  flag executes twice (default `max_retries: 1` + unknown codes default
  retryable) — pins that every new producer envelope actually suppresses
  the in-call retry; (j) **native typed errors**: schema-violating
  arguments → `content[1]` decodes to `validation_error` with the
  formatted message (NimbleOptions failures never populate `field`,
  schema.ex:150 — do NOT assert it there); an explicitly-constructed
  `InvalidInputError` returned by a scripted action → `field`/`value`
  preserved in details + `details.retry == false` (the `to_map`
  `retryable?` merge); an exec-level timeout (sleeping scripted action
  under a lowered `:jido_action` default-timeout app env, restored in
  on_exit) → `timeout`; a `ConfigurationError` reason → `config_error`
  (the translation row); (k) **aggregate cap**: a details map of
  thousands of short fields (per-leaf caps can't catch it) → `content[1]`
  ≤ 16 KiB carrying the reduced-envelope truncation metadata, the
  original code, AND the preserved allowlist — an oversized envelope with
  `retry: false` + `expected`/`got` keeps all three through the
  reduction (string-keyed detail variants too); an oversized `available`
  list survives element-wise-bounded with `available_truncated` flipped;
  a single ~32 KiB `expected` binary is re-bounded by the shared budget;
  a reduction STILL over the cap falls to the minimal envelope, which
  still carries the effective retry boolean (the every-tier pin);
  (l) **proxy/LoopGuard composition**: a patched two-item wire
  result shaped as the external-proxy re-surface map
  (proxy_generator.ex:534-546) with a LoopGuard directive appended
  (loop_guard.ex:371-379) keeps the canonical envelope at `content[1]`
  and the directive at `content[2]` — the `content[1]` contract survives
  the supported relay path; (m) **protocol-error scope row**: an unknown
  tool name → the JSON-RPC `invalid_params` protocol error
  (runtime.ex:61-62), no tool response, no envelope — the registry
  contract is tool-result-scoped and clients must not infer more;
  (n) an unregistered code whose envelope carries `retry: false` → the
  fallback `tool_error` still exposes the retry boolean beside
  `unregistered_code` (the drift fallback never launders non-retryable
  into retryable-looking), and an unregistered envelope that is ALSO
  over-cap (huge details) or budget-tripped still carries
  `unregistered_code` through the reduced AND minimal tiers (the
  advertised fallback contract survives every reduction);
  (o) **resource-bound rows**: a details map
  with an extreme key count, a deeply-nested term, and an oversized
  invalid binary key — each driven through the boundary AND through the
  Tools.Action pipeline with LoopGuard enabled — terminate promptly via
  the budget short-circuits (reduced envelope / sentinel signature
  component), never an unbounded walk; a budget-triggering envelope
  whose retained allowlist values include `expected: self()` +
  `retry: false` → a DECODABLE reduced envelope with the retry bit
  (the fresh small bounded JsonSafe pass on retained values — never a
  needless static-fallback escalation); a retained `expected` value
  that is itself deeply nested / oversized (its own small pass trips)
  → `expected == "[truncated]"` with code + retry intact, still never
  the static fallback.
- **Wiring pins** (the golden pins names/URIs/version + §5's new
  `error_codes_by_family` block — the assertions here are separate and
  explicit): `{Jido.MCP.Server.Runtime, :jido_mcp}` ∈
  `DependencyPatches.patched_modules()` (beside the existing STDIO pin,
  dependency_patches_test.exs:14); `MCPServer.server_instructions/0 ==
  ErrorCodes.stability_sentence()` plus an initialize-level instructions
  assertion where the anubis test harness exposes it (function-level
  equality is the floor); the bootstrap resource read decodes with
  `error_contract` matching **the wire representation
  `JsonSafe.encode(ErrorCodes.families())`** (the payload is JsonSafe'd +
  JSON round-tripped — string keys and code strings; comparing against
  the atom-keyed `families()` directly can never match) + the stability
  sentence + the `content[1]` location rule + the unregistered-code
  fallback rule. These are WIRING pins (same-source comparisons); the
  independent STABILITY pin is the committed golden fixture's
  `error_codes_by_family` block (§5 — that name is the fixture's;
  `error_contract` is the bootstrap payload's).
- **Sweep test — supplemental lint** (`error_codes_sweep_test.exs`,
  async: false, `Code.ensure_loaded` setup): sources =
  `JidoClaw.MCPServer.published_tool_modules()` (mcp_server.ex:109-110)
  compile-info paths + pinned envelope-producer files
  (security/tool_approval.ex, agent/loop_guard.ex, tools/lua/runner.ex,
  tools/run_command/forge_bridge.ex, tools/error.ex). Quoted-AST walker
  pruning pattern positions (`->` LHS, def heads/guards, `<-` LHS,
  attributes); collects literal `code:`-keyed envelope maps, first-arg
  atoms of local `envelope(...)` calls, literal `{:error, atom}` tuples.
  Non-literal `code:` SITES declared in `@indirect_producers` with their
  possible atoms (run_command's `deadline_error_code/1` → the two
  host_exec codes; run_skill's runner arm and network_share's known
  branch are now literal-code normalizers, so they need no declaration);
  residual open catch-all forwards (network_share.ex's post-normalization
  catch-all, run_skill.ex:80's Skills.get/Compiler forward) documented in
  `@open_forwarders` (file:line, site-level — no atoms to enumerate;
  boundary fallback covers them); view-layer relays in `@relayed_codes`
  (file:line — e.g. the agent_view/workflow_view/inspection codes riding
  served tools); and **known NON-envelope literals in a pinned
  `@non_envelope_literals` exclusion inventory** — the walker's
  pattern-position pruning cannot exclude expression-side internal
  tuples like tool_approval's
  `:mount_config_unreadable`/`:mount_config_not_regular` (internal tags,
  collapsed before any envelope) or details-only `code:` maps like
  error.ex's `:foreign`/`:unknown` (:242-253, inside `details.errors[]`
  construction), and those must not be forced into the registry. The
  collector therefore keeps **occurrence provenance** —
  `{file, enclosing function/AST path, collection kind, atom}` — and
  exclusion entries name exact occurrences (file + function + kind +
  atom) **with a pinned expected COUNT**, filtered node-wise BEFORE
  projecting to code sets: a bare file-scoped atom subtraction would
  also swallow a FUTURE genuine envelope of the same atom in that file,
  and count pinning makes a duplicated or moved literal fail loudly
  instead of false-greening. Staleness rule: every exclusion entry must
  match exactly its declared count. Assertions — both directions run on
  ONE post-filtering binding (`kept_codes` = occurrences surviving
  exclusion filtering, projected to codes; raw `collected` appears in no
  assertion, else an excluded details-only occurrence like `:foreign`
  could justify registering a code no envelope emits): `kept_codes` ∪
  declared ⊆ `all()`; `all()` ⊆ `kept_codes` ∪ declared ∪
  normalization-family; collector self-tests (map-path, envelope-call,
  bare-tuple each MUST collect).
- Hint-helper unit rows beside `test/jido_claw/error/tools_wire_format_test.exs`
  (the existing `Tools.Error` contract suite), incl. canonicalization:
  unsorted duplicated input → sorted deduped capped output, >25 names →
  `available_truncated: true` from the pre-cap count. Producer tests for
  run_skill (`:unknown_skill` + hint list, `:skill_cancelled`,
  `:skill_run_failed` — each asserting `details.retry == false`),
  list_directory (typed glob codes + `hint_expected` + the retry flag),
  and network_share (`:solution_not_found` → registered `:not_found` +
  identifier details + retry flag; a residual-catch-all foreign atom
  still reaches the boundary fallback + drift log). Plus the
  **LoopGuard-identity rows** (LoopGuard unit tests for the extended
  signature derivation + run_skill producer rows): `:skill_run_failed`
  envelopes from two different skills, from the SAME skill with
  same-head/different-tail reasons (`{:exit, :timeout}` vs
  `{:exit, :killed}` — split by `reason_head`), with long shared-prefix
  skill names whose 100-char message prefixes COLLIDE, and with
  **EQUAL-LENGTH skill names** (the exact-value allowlist splits what a
  length projection could not) all produce DISTINCT signatures; the
  SAME failure twice produces the SAME signature; **same tool + same
  message + same details but DIFFERENT codes → distinct signatures**
  (the identity's explicit code component — classification today
  discards everything but message text, loop_guard.ex:216); a
  previously-distinct message-only pair stays distinct (fingerprint
  only adds distinction); the **secret regression** — a reason
  embedding a secret value → the secret appears in NO message, halt
  directive, or emitted text, and NO digest of it is emitted anywhere
  (identity is internal); two reasons differing ONLY in that secret's
  value — **including secrets of DIFFERENT lengths** → the SAME
  signature (constant-marker projection; the documented same-class
  coalescing); otherwise-identical errors whose details differ only in
  pids/refs → the SAME signature (per-class constant markers — runtime
  identities contribute no drift); same code + message with a CHANGING
  volatile numeric field (`call_count`-style) in details → the SAME
  signature (numbers are class-marked — repeated equivalent failures
  must keep hitting staged recovery); including pids/refs **as map KEYS**
  (the sorted projected-pair representation), and two distinct keys
  projecting to the same marker preserve BOTH entries (shape survives
  the pair list); a multibyte skill name / atom truncated at the
  byte-bound boundary stays valid UTF-8 (the `valid_utf8_prefix` pin).
  **Skills-loader rows**: an
  overlong-name skill YAML is EXCLUDED at load AND at reload with the
  loud per-file error log (never silent, never a crash); calling it
  yields `:unknown_skill`; replay yields `:not_found`.
- `json_safe_test.exs` rows for the §3 hardening — **split by entry
  point**, since a struct VALUE takes the generic struct branch
  (json_safe.ex:43-47) and never invokes its `Inspect` impl through
  `encode/1`: through **`safe_inspect/1` directly** — hostile impls that
  raise, throw, and successfully return invalid bytes (escapes → the
  EXACT pinned static string `"[uninspectable]"`; invalid successful
  output → scrubbed to valid UTF-8); through **`encode/1`** — malformed
  `%{__struct__: DateTime}` and MapSet values nested beside healthy
  siblings (wrapper catches; ONLY the poisoned leaf degrades to the
  EXACT pinned `"[unencodable]"`), hostile-`Inspect` structs as map KEYS
  (`encode_key` → `safe_inspect`), `<<255>>` as value (replacement-char
  `"�"`) and as key (the exact tagged form `"<<invalid-utf8:/w==>>"`),
  a valid string key EQUAL to that tagged form colliding with the
  invalid `<<255>>` key (deterministic term-order winner), and
  `[1 | 2]` → `[1, 2]`. Budget rows for the `encode_bounded/2`-class
  walker: node-count, depth, per-key-byte, and cumulative-byte trips
  each short-circuit deterministically with the
  `{:budget_exceeded, %{observed_at_least: n}}` contract; an oversized
  invalid key produces the bounded `:trunc-<size>` tagged form; two
  oversized invalid keys sharing the 256-byte prefix AND total length →
  the deterministic term-order winner (the documented
  lossy-normalization collision).

## 7. Docs + reconciliation

- `docs/system/mcp-server-surface.md`: closed-error-contract invariant
  (registry, boundary fallback, dual-content wire shape with the envelope
  pinned at `content[1]` — second raw-wire item, appendable downstream —
  the never-escalate guarantee incl. rescue+catch and the public arm's
  `safe_inspect`, the 16 KiB structured-item cap, native Jido typed-error
  adaptation, new-producer envelopes non-retryable in-call, the
  tool-result-only scope (protocol-level failures carry no envelope),
  scoping to the public server, hints); the runtime patch documented beside the
  anubis patch; `sources:` += error_codes.ex, error_boundary.ex,
  jido_mcp_runtime_patch.ex, the sweep test; `verified:`/`verified_sha`
  bump. AGENTS.md known-limitations gains the patch line (same commit).
- `docs/system/loop-guard.md`: the extended failure-signature derivation
  (the internal structural details fingerprint beside the code +
  message-prefix components; never emitted) — loop_guard.ex is its
  source, so the same-change docs rule applies; `verified:` bump.
- Status lines: PD-FIRST-WAVE item 2; pad FWB PD1-2 + **OQ-2 re-dated**
  (boundary enforcement beats static enumeration); pre-argus README §16
  (deviations: server-level sentence, 48 literal not ~25, wire adapter,
  dual-content shape, the `:handoff_not_found` recovery,
  `:solution_not_found` normalized at its producer instead of a
  forwarded-codes side registry) + **correct §16's stale "#4 consumes
  this registry" sentence + §4 Status addendum** (the kinship paragraph
  is the landed cross-ref).

---

## Verification

Immediately after building: the new test files
(`mise exec -- mix test test/...`), the golden surface test + fixture, the
wire exactness suite, the sweep test,
`mise exec -- mix jidoclaw.jido_md.check` + `jidoclaw.system_docs.check`;
existing tool_approval/loop_guard/lua suites (their envelopes must be
untouched) and `run_server_test.exs` (the consolidator's e2e isError pin —
byte-identical legacy arm). End-to-end spot drive: a served-MCP failing
tool call shows content[0] legacy text + content[1] decodable JSON, and a
consolidator/deposit-server error stays single-item.

**Final bar**: `mise exec -- mix precommit` bare in background; iterate to
green. Known-flaky singleton suites verified in isolation before blaming
new code. Docs gates re-run as edited (`system_docs.check`,
`jido_md.check`; `graphql.schema.check` expected no-op).

## Suggested commit slicing (operator commits; nothing staged by the agent)

1. `docs: pre-argus wave E #16 plan` — the materialized
   `docs/plans/pre-argus-wave-e-16/README.md`.
2. `feat: served-MCP structured error contract + code registry (PD1-2)` —
   everything else (registry, run_skill normalization, boundary, patch,
   JsonSafe hardening, hints, 1.3 bump, docs, Status lines).

Reconciliation/Status edits ride commit 2.
