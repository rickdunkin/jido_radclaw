# PORT-PD1-2-EXEC — tier-1 wrap provenance through a `Jido.Exec` fork (semantics map)

Amendment map for
[PD1-2 — Closed-at-the-boundary error codes + typed self-correction hints](FEATURES-WORTH-BORROWING.md#pd1-2-closed-at-the-boundary-error-codes--typed-self-correction-hints)
— the pad entry the served-MCP error boundary implements. This map covers the
boundary's **tier-1 provenance mechanism**: a post-review round validated that
tier 1 ("the exact `Jido.Exec` wrap of a canonical envelope") is inferred from
a forgeable native-error *shape*, and the fix forks `Jido.Exec` so the wrap
carries an explicit witness. Because the fork must preserve upstream retry,
timeout, telemetry, and compensation semantics byte-for-byte, it is a
fidelity-critical external port under the AGENTS.md port rule — this map
precedes any fork code and its sign-off is the gate (plan approval is not
sign-off).

Sources (hex packages, not git checkouts — pins are the mix.lock version +
outer package checksum + the sha256 of the one forked file, all firsthand
reads of the vendored `deps/` trees):

- **jido_action 2.3.1** (Apache-2.0, © 2026 Mike Hostetler; mix.lock outer
  checksum `bf186bef7068da63267b1d6a45e6905a729aeedc2d4d0c735835911e346032c4`)
  — `lib/jido_action/exec.ex`, 889 lines, sha256
  `1eab8f18204b605038a87932edc34903c9149a5ef57cf5382749432ceb640752`. The NEW
  fork.
- **jido_mcp 1.1.0** (mix.lock outer checksum
  `20c7aea003990e2e641483b24f829c91ae60d93f5b5376a7eb24fd1118ff1dc0`) —
  `lib/jido_mcp/server/runtime.ex`, 276 lines, sha256
  `b360554be943b3b9d02eb4c62d6579449aa70aca27c8668392876c0899b86941`. The
  PRE-EXISTING fork (`lib/jido_claw/core/jido_mcp_runtime_patch.ex`) this
  slice modifies; its pinning regime joins this map so a permitted `~> 1.0`
  bump can no longer leave it silently stale.

Target: jido_radclaw @ `fdf361b4` + the unstaged whimsical-sunrise round
(typed WireError split + retry semantics + bounded-walker clamps) + this
change. Date: 2026-07-13.

## What the source actually does

### The defect this port closes

`Jido.Exec.run/4` normalizes tool errors in `handle_action_result/4`
(exec.ex:750-796). Exception structs pass through **verbatim**
(`when is_exception(error)`, `:760-764` 3-tuple / `:773-777` 2-tuple);
everything else wraps: `extract_error_fields/1` (`:798-824`) splits the
reason into `{message, details}` and `Error.execution_error(message,
details)` builds an `ExecutionFailureError` — `defexception [:message,
:details]` (error.ex:172-174), an unrestricted details map. The wrap is
**lossy**: post-wrap, "exec wrapped our canonical `{code, message, details}`
envelope" and "a producer hand-built a native error whose details happen to
carry `:code` + `:details`" are byte-identical terms. The boundary's tier 1
currently discriminates on that shape alone (error_boundary.ex:318-324), so
a colliding native error mis-tiers into tier 1: the wire reports the nested
`details.code` as the domain code and takes `retry` from a producer hint,
instead of tier 3's `execution_error` + authoritative
`Jido.Action.Error.retryable?/1`. No shape refinement can fix this — the
witness must be attached *at the wrap*, which means forking exec.

### Exec's mechanism, in their terms

1. **Entry** (`run/4`, `:156-211`): Instruction destructuring, param/context
   normalization, action + param validation (failures return typed errors
   *before* any wrap — never marked), then `do_run_with_retry/4`. Opts are
   accepted without validation: `apply_compat_opts/1` (`:660-685`) only
   warns-once on the deprecated `:error_normalization` key and returns opts
   unchanged. There is **no result-normalization seam**: the
   `:error_normalization` opt is accepted-and-ignored ("canonical
   normalization is always used", `:672`).
2. **Retry loop** (`do_run_with_retry/7` + `maybe_retry/8`, `:344-420`):
   each failed attempt re-enters `do_run/4`, so each attempt freshly
   normalizes its own error. `Retry.should_retry?/4` gates on attempt count
   and error class; the class hint walk reads only `retry`/`reason` keys
   (error.ex:612-651).
3. **Timeout task** (`do_run/4` → `execute_action_with_timeout/5`,
   `:422-606`): with a positive timeout, `execute_action/4` runs inside a
   `Task.Supervisor.start_child` closure (`:508-518`) — **opts are
   closure-captured**, and the result (including the wrapped error term)
   returns to the caller by message send. Task exit and timeout build
   structurally distinct error details (`%{reason, action}` `:555-562`,
   `%{timeout, action}` `:565-572`); deadline exhaustion pre-dispatch builds
   `%{deadline_ms, now_ms}` (`:637-641`).
4. **Result normalization** (`handle_action_result/4`, `:750-796`): two
   success arms; two exception pass-through arms; the **two map-wrap arms**
   (`:766-770` 3-tuple, `:781-785` 2-tuple) — the only sites whose produced
   details can carry a producer's `:code` + `:details`; the unexpected-shape
   arm (`:788-796`, fresh message-only `execution_error`).
5. **Field extraction** (`extract_error_fields/1`, `:798-824`): six clauses.
   The non-exception-struct clause (`:798-801` →
   `struct_error_details/1` `:826-830`, `Map.from_struct |>
   Map.drop([:__exception__, :message])`) is load-bearing for this port: a
   colliding struct like `%NativeError{message: "boom", code:
   :unknown_skill, details: %{}}` extracts to the same `%{code:, details:}`
   details map a canonical envelope does.
6. **Raise path** (`execute_action/4` rescue → `handle_action_exception/4`,
   `:744-747`, `:864-875`): embeds `__STACKTRACE__` — with `Jido.Exec`
   file/line frames — into the error's details. The served surface's
   `content[0]` renders those frames, which is why the fork's file/line
   metadata must match upstream byte-for-byte.
7. **Compensation** (`handle_action_error/5` → `Compensation.handle_error/5`,
   `:475-477`, compensation.ex:82-96): `TimeoutError` bypasses (`:456-457`);
   disabled compensation returns the original error **verbatim**; enabled
   compensation runs `action.on_error/4` in a task with a
   `Keyword.take`-allowlisted opts subset (compensation.ex:112-121) and
   rebuilds a NEW error around the original. `enabled?/1` requires the
   action's compensation **metadata** `enabled: true` AND the exported
   callback (compensation.ex:41-53) — `use Jido.Action` defines a default
   `on_error/4` on every action, so metadata is the real gate.
8. **Telemetry** (`do_run/4` span, `:436-447`; telemetry.ex:47-86): span
   metadata carries only `action`/`jido` at start and
   `outcome`/`error_type`/`retryable?`(+`directive?`) at stop — never opts,
   never the details map. Span metadata cannot carry (or leak) a wrap
   witness, and there is nothing sound to correlate post-hoc — the wrap
   happens inside the timeout task across N retry attempts.

### The jido_mcp runtime fork (pre-existing, modified by this slice)

`Jido.MCP.Server.Runtime.handle_tool_call/5` (runtime.ex:44-119 upstream)
authorizes, finds the tool, calls `Jido.Exec.run(module, arguments,
build_action_context(frame))` **with no opts**, and renders the two error
arms as `Response.tool() |> Response.error(inspect(reason))`. The committed
fork (`jido_mcp_runtime_patch.ex`) currently diverges from upstream by
exactly: the header comment block, the four disable-header lines, the
`ErrorBoundary` alias, a 3-line PATCH comment, and the two error arms
rerouted through `ErrorBoundary.error_response(reason, server_module)`
(verified by direct diff, 2026-07-13). Everything else — registration,
resource/prompt handling, the outer rescue/catch protocol-error conversion,
response/prompt helpers, `authorize/3` — is verbatim upstream.

## Side-by-side shapes

| Source (upstream, pinned) | jido_radclaw (planned) | Divergence note |
| --- | --- | --- |
| 3-tuple map-wrap arm (exec.ex:766-770): `defp handle_action_result({:error, reason, other}, action, log_level, _opts) do … {:error, Error.execution_error(message, details), other}` | Same arm with `_opts` → `opts` and the wrap call becoming `Error.execution_error(message, maybe_mark_wrap(details, reason, opts))`, inline on its existing line | The ONLY behavioral hunk (with its 2-tuple twin). Opts are already threaded to `handle_action_result/4` (`:743`) — the seam is parameter-ready; no signature changes anywhere. |
| 2-tuple map-wrap arm (exec.ex:781-785) | Identical treatment sans `other` | Twin hunk. |
| (no source analogue) | `maybe_mark_wrap(details, reason, opts)`: reads opt `:jido_claw_wrap_provenance`; when the value `is_reference/1` AND `canonical_envelope?(reason)`, `Map.put_new(details, :__jido_claw_exec_wrapped__, token)`; otherwise details unchanged. `canonical_envelope?/1` mirrors boundary tier 2's guard exactly: non-struct map, atom `code`, binary `message`, map `details`. Appended AFTER the last upstream definition with `__jido_claw_patch_info__/0` (returns the pinned upstream sha + patched-source digest — the incremental-build owner's marker and part of the Apache-2.0 §4(b) modified-file record) | The witness attests "exec wrapped a canonical envelope", never merely "exec wrapped a map": `extract_error_fields`'s struct clause converts a colliding non-exception struct into the same `%{code:, details:}` details shape — stamping every map-wrap would hand it an authentic token. `Map.put_new`, never `Map.put`: a producer squatting the marker key keeps its junk value, the boundary's identity check refuses, the term stays byte-identical to the unpatched world, and the error falls to the native tier (mis-tier DOWN, the safe direction). |
| Exception pass-through arms (exec.ex:760-764, 773-777) | Verbatim | Natives remain unmarked and tier-3-bound. |
| The whole remaining 889 lines | Verbatim — the fork is a compile-time GENERATOR (`lib/jido_claw/core/jido_exec_patch.ex`, ~80 lines): `@external_resource` + `File.read!` of the pinned dep source, sha256 compile-time drift gate (mismatch **raises** with the re-port message), exact-string line-count-preserving hunks each asserted to match exactly once, helper block appended before the terminal `end`, `Code.compile_string(patched_source, upstream_file_string)` under the dep's own recorded file string | Generator over committed copy for two load-bearing reasons: (a) **stacktrace byte fidelity** — `handle_action_exception/4` embeds `__STACKTRACE__` with `Jido.Exec` file/line frames into details that `content[0]` renders; a committed copy with a prepended header shifts every frame even with NO opt; (b) **parity by construction** — an accidental edit anywhere else in the 889 lines is structurally impossible, where a committed copy needs a separate reconstruct-and-compare guard. |
| Boundary tier 1 (error_boundary.ex:318-324): shape-only match on `%ExecutionFailureError{details: %{code:, details:}}` | `error_response/3` (default-arg head; non-public clause ignores the token) detaches the marker BEFORE the legacy render — `detach_wrap_marker/2` fires ONLY on exact `v === token` ref identity, returning `{clean, true}`; every other case (nil token, absent key, forged/stale/junk value) returns the term untouched with `false`. Tier 1's guard additionally requires the witness | Real traffic's detached term is byte-identical to the unpatched world's delivery — `content[0]`'s operator-pinned bytes hold BY CONSTRUCTION. Tier 2 (raw non-struct envelope maps) stays shape-matched and token-free: a raw map cannot be a native error. |
| Runtime fork exec call (runtime.ex:81 upstream): `Jido.Exec.run(module, arguments, build_action_context(frame))`, error arms arity-2 into the boundary | Mint `token = ErrorBoundary.mint_wrap_token(server_module)` (a `make_ref()` for the public server, else `nil`); call `Jido.Exec.run(module, arguments, build_action_context(frame), ErrorBoundary.exec_opts(token))` (`[]` for nil); thread `token` as the boundary's third argument | Policy lives in the boundary; the patch just threads. Public-only minting is REQUIRED, not an optimization: unconditional minting would put marker keys into the consolidator/deposit servers' byte-pinned single-item `inspect` arms. |
| Marker + opt literals | Opt `:jido_claw_wrap_provenance`, marker `:__jido_claw_exec_wrapped__` — module attributes in the boundary with a cross-reference comment to the fork; duplicated in the fork by necessity (two module trees), the end-to-end tests pin the coupling. Both marker key forms join `@boundary_owned_keys` (wire-stripped on every tier) | A context-borne token was rejected: context flows into `action.run(params, context)`, so any tool could read (and forge) it. Exec opts never reach tool code (`:742`), telemetry, or compensation's `on_error/4` (the `Keyword.take` allowlist) — non-forgeable by construction. |

## Behaviors table

**Preserved exactly** (the fidelity table — "verbatim" means the generator
leaves the source bytes untouched)

| Behavior | Source | Reason / note |
| --- | --- | --- |
| `run/4` opts acceptance without validation; `apply_compat_opts/1` warns only on `:error_normalization` | exec.ex:165-211, 660-685 | The new opt rides through unvalidated, like every unknown key today. |
| Opts threading to `handle_action_result/4` | exec.ex:743 | Parameter-ready seam; the hunks change `_opts` → `opts` on two heads, no signatures. |
| Exception pass-through, both arities | exec.ex:760-764, 773-777 | Natives (including hand-built colliding `ExecutionFailureError`s) pass verbatim, unmarked → tier 3. |
| All six `extract_error_fields/1` clauses + `struct_error_details/1` | exec.ex:798-830 | The struct clause's collision is exactly why the stamp condition runs on the pre-wrap `reason`, not the extracted details. |
| Unexpected-shape arm | exec.ex:788-796 | Message-only `execution_error`; never carries producer `:code`+`:details`. |
| Raise path: `__STACKTRACE__` embedded with upstream file/line frames | exec.ex:744-747, 864-875 | `Code.compile_string` under the dep's own file string with unshifted lines ⇒ no-opt raise-path `content[0]` bytes identical to the unpatched world. Pinned by test. |
| Retry recursion: per-attempt fresh normalization; `should_retry?/4` classification | exec.ex:344-420; error.ex:612-651 | Each retry attempt freshly wraps+marks with the SAME per-call token; the returned term carries exactly one marker. The marker key is inert to the hint walk (it reads only `retry`/`reason`, both key forms) — retry-gate neutrality, pinned by test. |
| Timeout-task mechanics; task-exit / timeout / deadline error shapes | exec.ex:486-606, 636-641 | Wrap+mark happens inside the task (opts closure-captured); ref identity survives node-local message passing. Exec-internal error details are structurally distinct — never stamped, never tier-1-shaped. |
| Telemetry spans: metadata = `action`/`jido` + `outcome`/`error_type`/`retryable?` | exec.ex:436-447; telemetry.ex:47-86 | Neither opts nor details ride span metadata — the witness cannot leak to telemetry consumers. |
| Compensation routing: `TimeoutError` bypass; disabled ⇒ verbatim; enabled ⇒ allowlisted opts into `on_error/4` | exec.ex:456-477; compensation.ex:41-53, 82-121 | The new opt is NOT in the `Keyword.take` list — compensation callbacks never see the token. Enabled compensation rebuilding a NEW error around a marked one is the documented nesting residual (below). |
| `action.run(params, context)` — opts never reach tool code | exec.ex:742 | The anti-forgery property: no tool can read or replay the token. |
| Opts inertness across Retry / Propagation / Supervisors / Util | named-key reads throughout `Jido.Exec.*` | Every opts consumer reads named keys; the new key is invisible to all of them. |
| No-opt byte identity for every non-served caller (agent loop, skills, consolidator, deposit) | whole file | No opt ⇒ `maybe_mark_wrap/3` hits the `_absent_or_junk` arm ⇒ details unchanged ⇒ byte-identical behavior by construction. Pinned by the no-opt parity test. |
| Runtime fork: authorization, resource/prompt handling, rescue/catch conversion, response/prompt helpers | runtime.ex:44-313 | Verbatim upstream in the committed fork (diff-verified 2026-07-13); the parity-reconstruction test keeps it that way. |

**Deliberately changed**

| Behavior | Source → ours | Reason |
| --- | --- | --- |
| (A) The two map-wrap arms' details | `Error.execution_error(message, details)` → `Error.execution_error(message, maybe_mark_wrap(details, reason, opts))` | The wrap is lossy; provenance must attach at the wrap. Stamped ONLY when the opt carries a reference AND the pre-wrap `reason` matched the raw canonical-envelope contract. `Map.put_new` — the squat law. |
| (B) Boundary tier-1 selection | shape-only → shape AND witness (detached on exact ref identity before the legacy render) | The finding's fix: an unmarked (or forged-marker) `ExecutionFailureError` carrying `:code`+`:details` now falls to tier 3 — `execution_error`, `retry` from `retryable?/1`. |
| (C) `error_response` arity | `/2` → `/3` via one default-argument head; non-public clause ignores the token | Arity-2 direct calls (the whole existing test surface) behave exactly as today; the runtime's uniform arity-3 call matches every server. Without the non-public clause change, a non-public tool failure would `FunctionClauseError` into the runtime rescue and emerge as a JSON-RPC protocol error instead of the pinned tool response. |
| (D) Runtime fork `handle_tool_call/5` | no-opt exec call → mint + thread (public server only) | The only caller that passes the opt; every other exec caller in the VM stays no-opt. Header inventory updated ("ONE surgical change" → the error-boundary routing AND the wrap-provenance threading). |
| (E) Wire classification of junk shapes: colliding non-exception structs (both tuple arities) and near-envelope maps (non-binary `message`; message-less `%{code:, details:}`) | previously tier 1 via shape → wrap unstamped → tier 3 `execution_error` with authoritative retry | Junk-input-only deltas, each in the safe mis-tier-DOWN direction, each pinned by a test. Well-formed canonical envelopes are byte-identical end-to-end. |
| (F) Marker keys wire-stripped | `@boundary_owned_keys` gains `:__jido_claw_exec_wrapped__` + `"__jido_claw_exec_wrapped__"` | Producer squatters never ride wire details on any tier (the build site already strips the list); `content[0]` stays faithful (the squat remains in the legacy render — byte fidelity to the delivered reason). |

**Dropped**

None — verbatim port. (The generator adds definitions; it removes or
reorders nothing.)

## Edge cases

jido_action's own suite pins the wrap arms only at the "map errors become
`ExecutionFailureError`" level (no provenance dimension exists upstream), so
rows anchor to our planned tests.

| Case | Planned test | Expected behavior |
| --- | --- | --- |
| No opt (every non-served caller) | `jido_exec_patch_test`: map-error action via `Jido.Exec.run/3` | Wrap details carry NO marker key; byte-identical to upstream. |
| With opt, canonical envelope | same, with `exec_opts(make_ref())` | Wrap carries exactly that ref under the marker key; one marker even across retries. |
| With opt, NON-envelope map (`%{foo: 1}`) / colliding non-exception struct | stamp-condition negative rows | NO marker — the witness attests envelopes only. |
| Colliding non-exception struct through the runtime, `{:error, struct}` AND `{:error, struct, directive}` | boundary test, both wrap arms | Wire code `"execution_error"`, never the struct's `:code` — the crispest pin of the finding, plus the 3-tuple arm proven independently. |
| Hand-built `%ExecutionFailureError{details: %{code:, details:}}` (THE regression) | runtime row + direct `error_response/2` twin | `content[1]` code `"execution_error"` (never `"unknown_skill"`), `retry` from `retryable?/1`, nested code/details ride the extras bag as DATA. |
| Canonical envelope end-to-end | runtime rows, 2- and 3-tuple | Tier 1; `content[0]` byte-equal to `inspect(Error.execution_error(msg, Map.delete(envelope, :message)))` — the detach restored the unpatched bytes; marker text absent from both items. |
| Producer squats the marker key | envelope carrying `__jido_claw_exec_wrapped__: :junk` | put_new no-op ⇒ identity check refuses ⇒ tier 3; `content[0]` CONTAINS the squat (term untouched); wire details LACK the key (boundary-owned strip). |
| Forged/stale ref | `%ExecutionFailureError{details: %{code:, details:, __jido_claw_exec_wrapped__: make_ref()}}` through the runtime | Verbatim pass-through arm delivers it; `v === token` fails ⇒ untouched term, tier 3, marker stripped from wire details. |
| Instruction-borne junk under the opt key | `run(%Instruction{opts: [jido_claw_wrap_provenance: "junk"]})`-class row | `is_reference/1` guard ⇒ never marks. |
| Non-public servers (consolidator, deposit) | complete-response byte rows | Single-item legacy shape with `inspect` of the UNMARKED wrap, byte-for-byte — fails loudly if minting ever goes unconditional. |
| Compensation nesting residual | served-inventory guard: `Jido.Exec.Compensation.enabled?/1 == false` for every published tool | Enabled compensation would nest a marked error inside a NEW unmarked `ExecutionFailureError` beyond detach's reach — unreachable today (metadata, not callback presence, is the gate); the guard test keeps the residual pinned. |
| Retry-gate neutrality | marked error through `retryable?/1` / the gate's classification | The marker is inert to the `retry`/`reason` hint walk — retry behavior identical to the unpatched world. |
| Raise path, no opt | raising action via exec + a runtime `content[0]` row | `details.stacktrace` frames for `Jido.Exec` carry the UPSTREAM file string and upstream line numbers — never `jido_exec_patch.ex`. |
| jido_action / jido_mcp drift | package pins (version + outer checksum) + `runtime.ex` sha row + the exec generator's compile-time sha gate | Any bump or local dep edit fails compilation (exec) or the suite (both), pointing at the re-port procedure. |
| Stale patched BEAM after an incremental/deps rebuild | path-parameterized compiler-stage rows under a temp dir (upstream-BEAM copy, stale-upstream-sha variant, stale-patched-digest variant) | The every-compile owner verifies `__jido_claw_patch_info__/0` carries BOTH current digests and regenerates otherwise — boot force-load, tests, and releases can never silently run upstream (or an outdated fork) `Jido.Exec`. |
| Accidental edit elsewhere in the committed runtime fork | parity reconstruction: apply the enumerated transformations to pinned upstream `runtime.ex`, `Code.format_string!/1` both sides, assert equality | Any drift outside the enumerated hunks fails this row while the targeted provenance tests stay green. |

## Sign-off gate

Decisions this map pins (flagging any reopens it):

1. **Fork mechanism — compile-time generator, not a committed copy**: the
   generator patches the pinned upstream source via exact-string,
   line-count-preserving hunks and compiles under the upstream file string.
   Rationale: raise-path stacktrace byte fidelity + parity by construction
   (a committed copy shifts every embedded stack frame and needs a separate
   parity guard). Alternative (committed 889-line copy) rejected.
2. **Stamp condition — canonical envelopes only**: the witness is stamped
   only when the pre-wrap `reason` matches the raw envelope contract
   (non-struct map, atom `code`, binary `message`, map `details` — tier 2's
   guard exactly). Stamping every map-wrap would let colliding non-exception
   structs carry an authentic token through `extract_error_fields`'s struct
   clause.
3. **The put_new law**: a producer squatting the marker key keeps its junk
   value; the boundary's exact-ref identity check refuses; the term stays
   byte-identical to the unpatched world; the error demotes to the native
   tier. Mis-tiering is always DOWN (toward `execution_error`), never up.
4. **Public-only minting**: only the public server's runtime path mints and
   threads the token; consolidator/deposit keep unmarked wraps and their
   byte-pinned legacy arms. Every other exec caller in the VM passes no opt.
5. **Junk-shape wire deltas accepted**: colliding non-exception structs and
   near-envelope maps demote from tier 1 to tier 3 (`execution_error`,
   authoritative retry). Junk-input-only; well-formed envelopes byte-stable.
6. **Literals**: opt `:jido_claw_wrap_provenance`, marker
   `:__jido_claw_exec_wrapped__` (both key forms boundary-owned on the
   wire); per-call `make_ref()` — a static marker value cannot restore
   exact bytes under squatting and is forgeable, so the ref is load-bearing.
7. **Durable BEAM ownership**: `__jido_claw_patch_info__/0` carries the
   pinned upstream sha AND a patched-source digest; an every-compile
   compiler stage verifies/regenerates the target BEAM (the upstream sha
   alone would let an old fork BEAM pass after hunk/helper edits at an
   unchanged jido_action version).
8. **jido_mcp fork joins the pin regime**: version + outer checksum +
   `runtime.ex` sha256 + the format-normalized parity reconstruction; its
   preserved/changed/dropped coverage is recorded above (changed: exactly
   the two error arms + the new minting/threading; dropped: none).
9. **Licensing (Apache-2.0 §4)**: the generator header carries the
   modified-file notice; `priv/licenses/jido_action-APACHE-2.0.txt` (byte
   copy of the dep's LICENSE) + `jido_action-NOTICE.txt` ride every
   `priv/`-bundling artifact; `JidoClaw.Core.ThirdPartyLicenses` embeds both
   for the escript, surfaced by the pre-boot `--third-party-licenses` CLI
   flag. The five pre-existing patches' license hygiene is a flagged
   follow-up, not absorbed here.
10. **Removal condition**: remove the fork once jido_action stamps wrap
    provenance natively or exposes a result-normalization seam (the current
    `:error_normalization` opt is accepted-and-ignored, so no seam exists
    at 2.3.1).

Sign-off: **granted by the operator 2026-07-13** (explicit sign-off act on
this map, separate from implementation-plan approval, ratifying decisions
1–10 above). Code follows this map. After shipping, `docs/system/mcp-server-surface.md` cites this
map as port provenance, the PD1-2 inventory entry's status text links it,
and the PD-FIRST-WAVE lifecycle entry gains a one-line amendment note.
