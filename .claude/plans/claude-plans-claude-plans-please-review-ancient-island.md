# Plan: post-review fix — tier-1 envelope provenance witnessed through Exec (P1)

## Context

The whimsical-sunrise post-review round (typed WireError split + retry
semantics + bounded-walker clamps) is implemented and sits unstaged. A new
review round reported ONE finding, **verified real** against the working
tree and deps:

**P1 — envelope provenance is inferred from an ambiguous native-error
shape (VALIDATED).** Tier 1
([error_boundary.ex:318-324](lib/jido_claw/core/mcp_server/error_boundary.ex))
treats any `%ExecutionFailureError{details: %{code: atom, details: _}}`
(binary message) as "the exact Jido.Exec wrap of a canonical envelope".
But exec passes exception structs through VERBATIM (deps exec.ex:773-777,
`when is_exception(error)`), and `ExecutionFailureError` is
`defexception [:message, :details]` with an unrestricted details map — so
a hand-built native error whose details happen to carry `:code` +
`:details` mis-tiers into tier 1: the wire reports the nested
`details.code` (e.g. `unknown_skill`) as the domain code and takes `retry`
from a producer hint, instead of tier 3's `execution_error` +
authoritative `Jido.Action.Error.retryable?/1` classification. The wrap
(exec.ex:781-785 → `extract_error_fields` → `Error.execution_error`) is
lossy — post-wrap, a canonical envelope and any shape-colliding term are
byte-identical — so **no shape refinement can fix this**; the reviewer's
prescription ("explicit provenance carried through Exec — an internal
marker or dedicated JidoClaw error type") is correct.

Honest scoping: no in-repo producer emits the colliding shape today (all
26 served tools ride `Tools.Action` normalization into envelope maps;
exec-internal natives — validation, timeout, rescue, unexpected-shape,
compensation — never put `:code`+`:details` into `ExecutionFailureError.details`;
wrap-arm inventory verified exhaustive at deps exec.ex:769 + 784). This is
a latent trust-seam defect — exactly the class the boundary exists to
close, and its tier discrimination is the one thing it currently cannot
actually check.

**Rejected alternatives** (each traced, not speculated):

- *Producer-side envelope marking* (mark in `Tools.Error`/`Tools.Action`):
  narrows the contract from "any `{code, message, details}` map" to "maps
  our pipeline produced" — every non-pipeline envelope (all scripted-test
  envelopes, any future direct producer) silently demotes to tier 4,
  losing its domain code. Silent failure mode; large test-suite churn.
- *Envelope as a dedicated exception type* (rides exec's verbatim
  pass-through): changes the delivered reason's SHAPE, so `content[0]`'s
  operator-pinned byte-identical legacy text breaks for every envelope
  error, and the exec retry gate reclassifies every served tool error
  (the freshly pinned call-count rows flip). Also, a context-borne token
  is readable by every tool (context flows into `action.run`), zeroing
  the anti-forgery property.
- *Telemetry/side-channel correlation instead of a fork*: jido_action 2.x
  has NO seam — the `:error_normalization` opt is accepted-and-ignored
  ("canonical normalization is always used"), span metadata never carries
  the pre-wrap reason, and the wrap happens inside the timeout Task
  across N retry attempts. Nothing sound to correlate.
- *Static marker value instead of a per-call ref*: cannot restore exact
  bytes under marker-key squatting (see the put_new law below) and is
  forgeable by any producer. The ref is load-bearing, not hardening.
- *Document-as-residual*: the finding is validated, the mechanism is
  well-bounded, and the boundary's core discrimination should not rest on
  a forgeable shape. Fix it.

**The fix**: a third dependency patch — fork `Jido.Exec` verbatim
(889 lines, jido_action 2.3.1) with one surgical change: the two map-wrap
arms stamp an opt-provided per-call reference into the wrap's details.
The MCP runtime patch mints the ref for the PUBLIC server only and threads
it to the boundary, which detaches it on exact ref identity and requires
it for tier 1. Every other exec caller in the VM (agent loop, skills,
consolidator, deposit) passes no opt and is byte-identical by
construction. This follows the established patch machinery
(`DependencyPatches.patched_modules/0`: boot force-load + release BEAM
relocation + `ignore_module_conflict`), with two precedent verbatim forks.

**Process decisions** (recorded in the Deviations entry): the fork is a
fidelity-critical external reference port (it must preserve upstream
retry, timeout, telemetry, and compensation semantics byte-for-byte), so
the AGENTS.md port rule applies — a `PORT-*.md` semantics map is written
FIRST and explicitly signed off before any fork code (plan approval does
NOT constitute sign-off; Fix 0 below is the gate). The fork additionally
follows the six existing patches' header convention (provenance +
surgical-change inventory + removal condition). Licensing:
jido_action is Apache-2.0 (© 2026 Mike Hostetler) — the fork header
carries the required modified-file notice, and the license copy must
reach EVERY artifact that bundles the modified BEAM: the committed
`priv/licenses/jido_action-APACHE-2.0.txt` rides source checkouts, Mix
releases, and the Docker image (all bundle `priv/`), while the escript
does NOT (`escript/0` in mix.exs has no `include_priv_for`, whose default
is `[]` — and adding it would drag the built SPA into the binary), so a
tiny `JidoClaw.Core.ThirdPartyLicenses` module embeds the text at compile
time (`@external_resource` + `File.read!`, public accessor) and ships
inside the beam-only escript, surfaced by a `--third-party-licenses` CLI
flag that exits before any app/DB boot — the recipient's supported
route, verified against the BUILT artifact. A license-hygiene sweep for the five
PRE-EXISTING patches is flagged as a follow-up, not silently absorbed
here.

Greenfield: no compat shims. Nothing gets committed; work lands unstaged
and folds into the existing #16 commit-2 slice.

---

## Fix 0 — PORT semantics map + explicit sign-off (BLOCKS Fix 1)

Write `docs/exploration/pms/pad/PORT-PD1-2-EXEC.md` — an amendment map
for the existing **PD1-2** inventory entry (the pad entry this whole
served-MCP error boundary implements; the fork is PD1-2's tier-1
provenance mechanism), per the full anatomy in
`docs/exploration/README.md`: header linking the PD1-2 entry in
`FEATURES-WORTH-BORROWING.md` with both shas pinned + date; side-by-side
source↔planned shapes for the load-bearing pairs; the
preserved/changed/dropped behaviors table; the edge-case table; and the
**sign-off gate** section presenting the open questions as operator
options. Then **pause for explicit operator sign-off before writing any
fork code** — an approved plan is not sign-off. After shipping,
`docs/system/mcp-server-surface.md` cites the map as port provenance and
BOTH corpus surfaces reconcile per the PORT lifecycle: the authoritative
PD1-2 inventory entry in `FEATURES-WORTH-BORROWING.md` gets its status
text updated to link `PORT-PD1-2-EXEC.md` and summarize the provenance
correction (tier-1 wrap identity was shape-inferred; now witnessed
through the forked exec), and the PD1-2 lifecycle entry in
`PD-FIRST-WAVE.md` gets a one-line amendment note on the DONE entry.
The map covers:

- **Pinned source**: jido_action 2.3.1 (hex; mix.lock outer checksum) +
  the `exec.ex` sha256 the generator's compile-time gate pins — AND the SAME regime
  for the pre-existing `Jido.MCP.Server.Runtime` fork this slice
  modifies: jido_mcp's locked version (1.1.0 at plan time; confirm from
  mix.lock) + outer checksum + the upstream `runtime.ex` sha256. The
  runtime fork's copied authorization/resource/prompt/rescue/response
  behavior joins the map's coverage (preserved verbatim; changed:
  exactly the two error arms routing through the boundary + the new
  wrap-provenance minting/threading; dropped: none) so a permitted
  `~> 1.0` jido_mcp bump can no longer leave that fork silently stale
  while the exec guards stay green.
- **Preserved behavior** (the fidelity table): all `handle_action_result`
  arms — exception pass-through (2- and 3-tuple), the two map-wrap arms,
  unexpected-shape; `extract_error_fields`'s six clauses (including the
  non-exception-struct clause that motivates the stamp condition); the
  rescue path; timeout/task-exit mechanics (wrap happens inside the Task,
  opts closure-captured); retry recursion (per-attempt fresh wrap, same
  token, exactly one marker in the returned term); compensation routing;
  opts inertness across Retry/Propagation/Supervisors/Util; no-opt
  byte-identity for every non-served caller.
- **Changed behavior** (the surgical diff spec, exactly): `_opts` → `opts`
  in the two wrap arms; `maybe_mark_wrap/3` + `canonical_envelope?/1`;
  nothing else.
- **Dropped behavior**: none (verbatim port).
- **Edge-case → test mappings**: squatted marker → put_new no-op →
  tier-3 demotion + byte fidelity; forged/stale ref → untouched term +
  wire strip; colliding non-exception struct (both tuple arities) →
  unstamped → `execution_error`; near-envelope maps → unstamped;
  Instruction-borne junk opt → `is_reference` guard; compensation-enabled
  nesting residual → `Compensation.enabled?/1` guard test; retry-gate
  neutrality (marker inert to the `:retry`/`:reason` hint walk).

The fork header, the subsystem doc, and the Deviations entry all cite the
map.

## Fix 1 — `lib/jido_claw/core/jido_exec_patch.ex` (NEW): the `Jido.Exec` fork, GENERATED at compile time

NOT an 889-line committed copy. The file is a small compile-time
GENERATOR (~80 lines) that patches the pinned upstream source in place —
chosen over a committed verbatim copy for two load-bearing reasons:

- **Stacktrace byte fidelity**: `handle_action_exception/4` (deps
  exec.ex:864-875) embeds `__STACKTRACE__` — with `Jido.Exec` file/line
  frames — into the returned error's details, and content[0] renders it.
  A committed copy with a prepended header shifts every frame's
  file+line even with NO opt, breaking raise-path byte identity in a way
  no map-error test catches. The generator compiles the patched source
  under the UPSTREAM file string with upstream line numbers preserved,
  so no-opt raise-path errors render byte-identical to the unpatched
  world.
- **Parity by construction**: a committed copy needs a separate
  reconstruct-and-compare guard; the generator IS the reconstruction —
  an accidental edit elsewhere in the 889 lines (retry, timeout, async,
  compensation) is structurally impossible.

Mechanism:

- `@external_resource "deps/jido_action/lib/jido_action/exec.ex"` +
  compile-time `File.read!`.
- **Compile-time drift gate**: sha256 of the source must equal a pinned
  constant, else `raise` with the re-port message — a jido_action bump
  or local deps edit fails COMPILATION, before any test runs.
- The surgical hunks apply as exact-string replacements, each ASSERTED
  to match exactly once, each LINE-COUNT-PRESERVING (`_opts` → `opts` on
  the two arm heads; the wrap call becomes
  `Error.execution_error(message, maybe_mark_wrap(details, reason, opts))`
  inline on its existing line). The `maybe_mark_wrap/3` +
  `canonical_envelope?/1` helper block appends AFTER the last upstream
  definition, before the terminal `end` — no upstream definition shifts
  lines.
- `Code.compile_string(patched_source, upstream_file_string)` — the file
  string exactly what the dep's own compilation recorded (confirmed at
  implementation from `Jido.Exec.module_info(:compile)` / a raised
  frame), so embedded stacktrace frames keep byte-identical metadata.
- The produced BEAM gets a DURABLE INCREMENTAL-BUILD OWNER — an explicit
  compiler stage, not a hope that the generator's own recompilation
  suffices: the generator emits only when its source recompiles, but a
  deps rebuild can restore the upstream `Jido.Exec` target after
  relocation removed the app-side BEAM, and the existing
  `relocate_patch!/1` accepts ANY existing target without proving it is
  patched (compile.jidoclaw_release_patches.ex:36). The generated module
  therefore exports a small marker (e.g. `__jido_claw_patch_info__/0`
  returning the pinned source sha — appended with the helper block, part
  of the modified-file record), and the compiler stage (extending
  `Mix.Tasks.Compile.JidoclawReleasePatches` or a sibling step that runs
  on EVERY compile) verifies the target BEAM carries the marker with the
  current pins and regenerates/overwrites it when absent or stale — so
  boot force-load, tests, and releases can never silently run upstream
  `Jido.Exec` after an incremental build. The marker carries TWO
  digests: the pinned upstream-source sha AND a digest of the fully
  PATCHED source (equivalently, an explicit patch revision) — the
  upstream sha alone would let an older persisted BEAM pass the owner
  after the hunks or helper implementation change while jido_action
  stays 2.3.1, which is exactly the staleness class the owner exists to
  catch.
- Side benefits: `mix format`/credo/reach see only the small generator —
  no disable-header sprawl over dep idioms — and the dep source is never
  reformatted.

The generator carries the patch-header convention from
`jido_mcp_runtime_patch.ex:1-35` extended for Apache-2.0 §4(b):
provenance ("compile-time patched build of jido_action 2.3.1
`Jido.Exec`, portions © 2026 Mike Hostetler, Apache-2.0 — see
`priv/licenses/jido_action-APACHE-2.0.txt`; modified by JidoClaw: the
two map-wrap arms of `handle_action_result/4` + `maybe_mark_wrap/3` +
`canonical_envelope?/1`" — the generator's hunk strings ARE the
prominent modified-file record), the WHY (the wrap is lossy; envelope
provenance is unrecoverable post-hoc — the boundary needs a witness),
and the removal condition ("remove once jido_action stamps wrap
provenance natively or exposes a result-normalization seam").

The surgical change (the shape the generator's exact-string replacements
produce) — upstream arms 766-770 (3-tuple) and 781-785 (2-tuple) change
`_opts` → `opts` (opts are ALREADY threaded to `handle_action_result`;
the seam is parameter-ready) and mark the wrap —
**only when the ORIGINAL pre-wrap reason itself matched the raw
canonical-envelope contract**. Stamping every map-wrap would prove only
"exec wrapped something": `extract_error_fields/1`'s non-exception-struct
clause (exec.ex:798-801, `Map.from_struct |> Map.drop([:__exception__,
:message])`) converts a colliding struct like
`%NativeError{message: "boom", code: :unknown_skill, details: %{}}` into
the same `%{code:, details:}` details map — it would carry an authentic
token and still mis-tier into tier 1. The witness must attest the
ENVELOPE, so the guard runs on `reason`, mirroring boundary tier 2's
guard exactly (non-struct map, atom `code`, binary `message`, map
`details`):

```elixir
defp handle_action_result({:error, reason, other}, action, log_level, opts) do
  Telemetry.cond_log_error(log_level, action, reason)
  {message, details} = extract_error_fields(reason)
  {:error, Error.execution_error(message, maybe_mark_wrap(details, reason, opts)), other}
end

# ... 2-tuple twin identical sans `other` ...

# PATCH: stamp the caller's per-call wrap-provenance ref into the wrap's
# details — the served-MCP boundary's tier-1 witness (it detaches the key
# on exact ref identity; see JidoClaw.MCPServer.ErrorBoundary). Stamped
# ONLY when the pre-wrap reason matched the raw canonical-envelope
# contract — the witness attests "exec wrapped a canonical envelope",
# never merely "exec wrapped a map" (a non-exception struct with
# colliding message/code/details fields extracts to the same details
# shape and must stay unstamped → native tier). Map.put_new, NEVER
# Map.put: a producer squatting the key must keep its junk value so the
# boundary's identity check refuses, the term stays byte-identical to
# the unpatched world, and the error falls to the native tier (mis-tier
# DOWN, the safe direction). No opt (every non-served exec caller) ⇒
# byte-identical behavior by construction.
defp maybe_mark_wrap(details, reason, opts) do
  case Keyword.get(opts, :jido_claw_wrap_provenance) do
    token when is_reference(token) ->
      if canonical_envelope?(reason) do
        Map.put_new(details, :__jido_claw_exec_wrapped__, token)
      else
        details
      end

    _absent_or_junk ->
      details
  end
end

defp canonical_envelope?(%{code: code, message: message, details: details} = reason)
     when not is_struct(reason) and is_atom(code) and is_binary(message) and
            is_map(details),
     do: true

defp canonical_envelope?(_reason), do: false
```

Wire-visible deltas beyond the fixed collisions (all junk-input-only,
each in the safe mis-tier-DOWN direction, each pinned by a test):
colliding NON-EXCEPTION structs and NEAR-envelope maps (non-binary
`message`, message-less `%{code:, details:}` maps) previously hit tier 1
via the shape match; they now wrap unstamped → tier 3 →
`execution_error` with authoritative retry. Well-formed canonical
envelopes are byte-identical end-to-end.

Pinned facts the port relies on (all verified):

- These two arms are the ONLY sites whose details can carry a producer's
  `:code`+`:details` (task-exit, rescue, timeout, unexpected-shape,
  validation, and all five compensation constructors build structurally
  different details). Exception pass-through arms (760-764, 773-777) stay
  verbatim — natives remain unmarked and tier-3-bound.
- `run/4` does not validate/reject unknown opts (`apply_compat_opts` only
  warns on a deprecated key), and opts consumers everywhere
  (Retry/Propagation/Supervisors/Util) are named-key reads — the new opt
  is inert to all of them.
- The wrap+mark happens inside the timeout Task (opts closure-captured);
  ref identity survives message passing within the node. Each retry
  attempt freshly wraps+marks with the same per-call token; the returned
  term carries exactly one marker.
- The token never reaches tool code: exec calls `action.run(params,
  context)` — opts never flow in; telemetry metadata carries neither opts
  nor details; compensation's opts subset is `Keyword.take`-allowlisted.
  Ref forgery by a tool is therefore impossible.
- `is_reference/1` guard: Instruction-borne opts (`run(%Instruction{})`)
  can carry arbitrary junk under any key — junk never marks.
- Exec has runtime-only config reads, no `Mix.env`/`@external_resource`/
  macros beyond `require Logger`; all aliases resolve inside jido_action
  — the source compiles standalone through `Code.compile_string`, with
  its `@dialyzer` attributes and specs riding verbatim (the generator
  never reformats the source; byte fidelity is the point).

Also commit `priv/licenses/jido_action-APACHE-2.0.txt` — a copy of
`deps/jido_action/LICENSE`, upstream copyright line intact — AND
`priv/licenses/jido_action-NOTICE.txt` (NEW): the §4(b) modification
notice, artifact-visible (the generator's source header ships in NO
binary artifact — release, Docker image, and escript all need the
notice alongside the license): "This distribution includes a modified
build of jido_action 2.3.1's `Jido.Exec` (Apache-2.0, © 2026 Mike
Hostetler): the two map-wrap arms of `handle_action_result/4` stamp an
opt-gated wrap-provenance marker (`maybe_mark_wrap/3` +
`canonical_envelope?/1`). Unmodified license text:
jido_action-APACHE-2.0.txt." Both files ride releases/Docker via
`priv/`. Plus `lib/jido_claw/core/third_party_licenses.ex` (NEW):
`JidoClaw.Core.ThirdPartyLicenses`, embedding BOTH files at compile time
(`@external_resource Path.join(...)` + module-attribute `File.read!`) with
a public accessor (@doc/@spec), so the Apache-2.0 text reaches escript
recipients inside the binary — the escript excludes `priv/` by default
and `include_priv_for: [:jido_claw]` is rejected (it would bundle the
built SPA and resource snapshots into the CLI binary). An embedded copy
alone gives recipients no supported way to READ it, so the escript's
main module (`JidoClaw.CLI.Main`) gains a `--third-party-licenses` flag:
handled as an EARLY EXIT before any application boot (no PostgreSQL, no
setup wizard — the license must be obtainable from the bare binary),
printing the embedded NOTICE followed by the unmodified license text to
stdout and returning cleanly. For that
clause to actually precede boot, `escript/0` in `mix.exs` gains
`app: nil` — Mix's default `:app` is `:jido_claw`, which auto-starts
the whole application (Repo included) BEFORE `main/1` runs. The flip is
NOT free: today Mix's pre-`main/1` startup fails the binary loudly, but
the setup, REPL, and MCP branches DISCARD `ensure_all_started/1`'s
return (main.ex:53, 63, 80) — under `app: nil` a failed start would
fall through (worst case: the MCP branch reaching its
`Process.sleep(:infinity)`-style wait with no server running). So every
branch gets CHECKED startup: a shared `start_app_or_halt!/0` in
`JidoClaw.CLI.Main` — `Application.ensure_all_started(:jido_claw)`,
and on `{:error, reason}` print the reason to stderr and terminate with
a non-zero exit (code chosen consistent with the documented `run` exit
table) — replacing the three discarded calls; the `run` path keeps its
existing checked handling through `RunCommand`'s boot callback. One more boot-order fact makes the flag genuinely bare-binary:
`config/runtime.exs`'s prod branch RAISES at config-evaluation time on
unset `SECRET_KEY_BASE`/`TOKEN_SIGNING_SECRET` — and a prod-built
escript evaluates runtime.exs BEFORE `main/1` even under `app: nil`, so
with secrets unset the license flag could never run. `runtime.exs`
therefore becomes TOTAL — configure-only, never raising: the two
missing-secret raises AND every fallible parse move behind application
startup. The full pre-main raise inventory (audited):
`String.to_integer(FORGE_SANDBOX_TIMEOUT_MS)` (line ~12, any non-test
env with `FORGE_SANDBOX=docker`), `Base.decode64!(CLOAK_KEY)` and
`String.to_integer(POOL_SIZE)` (prod branch) — a recipient with any
malformed value could otherwise never run the license flag. The forge
timeout is DEAD CONFIG — `default_timeout_ms` has no consumer (Docker
sandbox calls without an explicit timeout use `:infinity`,
docker.ex:240) — so it is REMOVED from runtime.exs outright rather
than relocated (relocating would either preserve dead configuration or
silently activate a new 120s limit on existing no-timeout calls;
activating it is a separate behavioral change needing a call-site
inventory — out of scope, noted in the Deviations entry). The `CLOAK_KEY` cipher block is DELETED outright, never raw-passed:
`VaultConfig.ensure_configured!/0` ALREADY reads and decodes
`CLOAK_KEY`/`CLOAK_KEY_FILE` at app startup whenever no cipher is
configured (vault_config.ex:31-48) — the runtime.exs block is redundant
today and hazardous under raw passthrough (`configured_cipher?/1`
accepts ANY 16/24/32-byte binary as an already-decoded key, and base64
encodings of 16/24-byte AES keys are themselves 24/32 bytes — a raw
value in the cipher tuple would silently select a DIFFERENT key and
make existing ciphertext unreadable). That leaves `POOL_SIZE` as the
one relocated parse: the raw string passes through config and parses in
`JidoClaw.Repo.init/2` — CHAINING `super(type, config)` and parsing
from the config super returns, never replacing the callback outright
(`AshPostgres.Repo`'s `init/2` injects extension/migration-path/prefix
configuration that an overriding clause would silently discard;
deps ash_postgres repo.ex:200) — raising on a malformed value with a
clear message;
`SECRET_KEY_BASE`/`TOKEN_SIGNING_SECRET` presence enforcement joins
`JidoClaw.Security.RuntimeSecrets`' existing quality checks. For releases this is
timing-equivalent — a release boots the app immediately, so fail-fast
holds. Implementation confirms each consumer's config shape tolerates
the raw/absent value up to its startup raise.
Additionally, the escript MCP branch redirects Logger to stderr BEFORE
`start_app_or_halt!/0` (the `mix jidoclaw --mcp` task already does
exactly this before `app.start` — jidoclaw.ex:38): under `app: nil`,
`ensure_all_started/1` boots dependency applications before
`JidoClaw.Application.start/2` runs, and any dep startup log reaching
stdout would corrupt the JSON-RPC stream.
The
starter/halter injection seam is COMPILED ONLY under `MIX_ENV=test`
(the error boundary's chaos-seam idiom — `if Mix.env() == :test` around
the seam-reading clause, production compiled to direct
`Application.ensure_all_started/1` + `System.halt/1` calls, structurally
unable to consult config), and the failure arm is structurally
NON-RETURNING: after invoking the test halter, unconditionally
raise/exit if it returns — a stale or malformed injected callback must
never recreate the fall-through bug the seam exists to test. The flip
also makes the `run` path's "redirect logger BEFORE app start" comment
true inside the escript for the first time.

## Fix 2 — `lib/jido_claw/core/dependency_patches.ex`: inventory entry

Add `{Jido.Exec, :jido_action}` to `@patched_modules`. Boot force-load and
`Mix.Tasks.Compile.JidoclawReleasePatches` relocation both read this single
source — no other change. (Loud-failure note: `load_module!` prefers the
app ebin but falls back to the dep BEAM; the membership pin + the new
end-to-end tier-1 rows make a missing/uncompiled fork fail the suite, not
silently regress.)

## Fix 3 — `lib/jido_claw/core/jido_mcp_runtime_patch.ex`: mint + thread

In `handle_tool_call/5` (the exec call at line 81 and the two error arms
at 92/95) — policy lives in the boundary, the patch just threads:

```elixir
token = ErrorBoundary.mint_wrap_token(server_module)

case Jido.Exec.run(module, arguments, build_action_context(frame), ErrorBoundary.exec_opts(token)) do
  ...
  {:error, reason} ->
    {:reply, ErrorBoundary.error_response(reason, server_module, token), frame}

  {:error, reason, _directives} ->
    {:reply, ErrorBoundary.error_response(reason, server_module, token), frame}
```

Update the header comment's change inventory ("ONE surgical change" → the
error-boundary routing AND the wrap-provenance threading, listed).
Public-only minting is REQUIRED, not an optimization: unconditional
minting would put marker keys into the consolidator/deposit servers'
byte-pinned single-item `inspect` arms.

## Fix 4 — `lib/jido_claw/core/mcp_server/error_boundary.ex`: detach + guard

1. **New public helpers** (@doc + @spec — credo Specs):
   `mint_wrap_token/1` → `make_ref()` for `@public_server`, else `nil`;
   `exec_opts/1` → `[]` for nil, `[jido_claw_wrap_provenance: token]` for
   a ref. The opt atom and marker atom live here as module attributes with
   a cross-reference comment to the fork (the literal is duplicated in the
   fork by necessity — two module trees — and the end-to-end tests pin the
   coupling).

2. **`error_response/3`**: one default-argument function head covering
   BOTH clauses — `def error_response(reason, server_module, token \\ nil)`
   — so arity-2 calls (the whole existing direct-call test surface)
   behave exactly as today AND the runtime's uniform arity-3 call
   matches every server. The non-public clause becomes
   `def error_response(reason, _server_module, _token)` — token ignored,
   the byte-identical legacy single-item arm untouched (without this
   clause change, a non-public tool failure would raise
   `FunctionClauseError` into the runtime rescue and emerge as a
   JSON-RPC protocol error instead of the pinned tool response). @spec
   covers both arities. The public head detaches BEFORE the legacy
   render:

   ```elixir
   def error_response(reason, @public_server, token) do
     {reason, exec_wrapped?} = detach_wrap_marker(reason, token)
     legacy = JsonSafe.safe_inspect(reason)
     ...
     |> Response.text(structured_item(reason, legacy, exec_wrapped?))
   ```

   `detach_wrap_marker/2` fires ONLY on
   `%ExecutionFailureError{details: %{__jido_claw_exec_wrapped__: v} = d}`
   with `is_reference(token) and v === token` → rebuild the struct with
   the key deleted, return `{clean, true}`; EVERY other case (nil token,
   absent key, forged/stale/junk value) returns the term untouched with
   `false`. Total by pattern match + catch-all — it runs outside
   `structured_item`'s guarded region, same posture as the existing
   `safe_inspect` head. Consequences, each pinned by a test:
   - Real traffic: the detached term is byte-identical to what the
     unpatched world delivers (the marker never existed there) —
     `content[0]`'s byte pin holds BY CONSTRUCTION.
   - Forged/squatted markers stay IN the term (content[0] stays faithful
     to the delivered reason), fail the tier-1 guard → tier 3.

3. **Tier 1 requires the witness**: thread `exec_wrapped?` through
   `unwrap/3`; the tier-1 clause guard adds it. An unmarked (or
   forged-marker) `ExecutionFailureError` carrying `:code`+`:details` now
   falls to tier 3 — `execution_error`, `retry` from `retryable?/1` — the
   finding's fix. Tier 2 (raw non-struct envelope maps) stays shape-matched
   and token-free: a raw map cannot be a native error; its duck-typed
   contract is unchanged, and the entire direct-call test surface rides it.

4. **`@boundary_owned_keys`** gains `:__jido_claw_exec_wrapped__` +
   `"__jido_claw_exec_wrapped__"` — producer squatters never ride wire
   details on any tier (the build site already strips this list).

5. **Moduledoc**: rewrite the tier-1 sentence — the wrap OF A CANONICAL
   ENVELOPE is witnessed by a per-call reference stamped by the forked
   exec (stamped only when the pre-wrap term matched the raw envelope
   contract — non-struct map, atom code, binary message, map details;
   an exec wrap of anything else stays unstamped and native) under an
   opt only the public runtime path passes, detached on exact ref
   identity before the legacy render; shape alone no longer selects
   tier 1 (the pre-fix ambiguity and why shape matching could not close
   it, one sentence).
   Note the marker key in the boundary-owned list. Residuals paragraph
   gains: enabled Jido compensation would nest a marked error inside a
   NEW unmarked `ExecutionFailureError` beyond detach's reach —
   unreachable today because compensation is opt-in ACTION METADATA and
   no published tool enables it (`use Jido.Action` defines a default
   `on_error/4` for EVERY action, so the callback's existence is NOT the
   gate; `Jido.Exec.Compensation.enabled?/1` reading the action's
   compensation metadata is) — pinned by the guard test; and the
   retry-gate neutrality fact (the marker is inert to `retryable?/1`'s
   `:retry`/`:reason` walk).

6. **`surface_version.ex`**: amend the (unstaged) v1.3 changelog bullet —
   tier-1 wrap provenance is now witnessed, junk-shaped native errors
   classify as `execution_error` (junk-input-only delta; nothing has
   shipped, same bump).

## Regression tests

**`test/jido_claw/core/mcp_server/error_boundary_test.exs`** (existing
harness; runtime rows go through the REAL patched runtime + forked exec):

- *THE regression (runtime)*: scripted tool returns
  `{:error, %ExecutionFailureError{message: "boom", details: %{code: :unknown_skill, details: %{sneaky: true}}}}`
  → `content[1]` code == `"execution_error"` (NEVER `"unknown_skill"`),
  `details["retry"] == true` with the matching gate call-count (class
  hint-defaults retryable; `capture_log`), and the nested `code`/`details`
  ride the extras bag as DATA (`details["code"] == "unknown_skill"`).
- *Direct twin*: same struct via `error_response/2` → `"execution_error"`
  (pre-fix this hit tier 1 — the crispest pin of the finding).
- *Envelope still tier 1, end-to-end + content[0] fidelity*: scripted
  `{:error, envelope}` → canonical wire code, and `content[0]` byte-equal
  to `inspect(Error.execution_error(msg, Map.delete(envelope, :message)))`
  (sanitize-neutral plain-ASCII message) — the detach restored the
  unpatched bytes; also assert the marker text is ABSENT from both items.
- *3-tuple arm*: scripted `{:error, envelope, directive}` → tier 1 — the
  second wrap arm's marking proven independently.
- *Colliding non-exception struct, BOTH wrap arms (the stamp-condition
  pin)*: a test-local `defstruct [:message, :code, :details]` (NOT an
  exception) with `message: "boom", code: :unknown_skill, details: %{}`,
  driven through the runtime as `{:error, struct}` AND
  `{:error, struct, directive}` → both yield wire code
  `"execution_error"` (never `"unknown_skill"`) — exec's struct clause
  extracts the colliding `%{code:, details:}` shape, but the pre-wrap
  term was no envelope, so the wrap stays unstamped and tier 3 holds.
- *Near-envelope demotion pins*: runtime rows for
  `%{code: :unknown_skill, message: 123, details: %{}}` (non-binary
  message) and `%{code: :unknown_skill, details: %{}}` (message-less) →
  `"execution_error"` — the stamp condition is the raw envelope
  contract, exactly tier 2's guard.
- *Squatted marker (put_new law)*: scripted envelope carrying
  `__jido_claw_exec_wrapped__: :junk` at top level → tier 3
  (`execution_error`), `content[0]` CONTAINS the squat (term untouched —
  byte fidelity), wire details LACK the marker key (boundary-owned strip).
- *Forged ref*: hand-built `%ExecutionFailureError{details: %{code: :unknown_skill, details: %{}, __jido_claw_exec_wrapped__: make_ref()}}`
  through the runtime (verbatim pass-through) → tier 3 + marker stripped
  from wire details.
- *Non-public byte rows (public-only minting pin)*: scripted envelope
  error through `Runtime.handle_tool_call/5` for the consolidator AND
  deposit servers → the COMPLETE response equals the single-item legacy
  shape with `inspect` of the UNMARKED wrap, byte-for-byte — fails loudly
  if minting ever goes unconditional.
- *Compensation guard (residual pin)*: the served tool inventory asserts
  `Jido.Exec.Compensation.enabled?/1 == false` for every module — no
  published tool has compensation ENABLED in its action metadata (the
  callback itself exists on every `use Jido.Action` module by default,
  so metadata, not callback presence, is the invariant), keeping the
  documented nesting residual unreachable.

**`test/jido_claw/core/dependency_patches_test.exs`**: add the membership
pin `{Jido.Exec, :jido_action} in DependencyPatches.patched_modules()`
beside the existing per-patch pins.

**`test/jido_claw/core/jido_exec_patch_test.exs`** (NEW):

- *Package drift guards (BOTH forked packages)*: parse `mix.lock` —
  `jido_action` version `== "2.3.1"` AND its outer package checksum, and
  `jido_mcp` version (locked value confirmed at implementation) AND its
  outer checksum, each against pinned constants with a failure message
  pointing at the respective fork's re-port procedure. Package-scoped
  deliberately: the forks delegate at runtime to sibling dep modules —
  a collaborator-only dep change must also fail loud. (The jido_mcp pin
  retrofits the drift guard the pre-existing runtime fork never had —
  this slice modifies that fork, so its staleness risk is in scope.)
- *Source anchors*: sha256 of
  `deps/jido_mcp/lib/jido_mcp/server/runtime.ex` against a pinned
  constant — the runtime fork's re-port diff anchor (the exec source
  sha is enforced even earlier: the generator's COMPILE-TIME gate, whose
  presence a test row pins by asserting the pinned constant exists and
  matches the current deps file).
- *Runtime-fork parity guard (exec parity is by construction; the
  committed runtime fork still needs one)*: reconstruct the expected
  `jido_mcp_runtime_patch.ex` in-test from the pinned upstream
  `runtime.ex` — apply the enumerated exact-string transformations (the
  header comment block, the disable headers, the `ErrorBoundary` alias,
  the token mint + `exec_opts` threading in `handle_tool_call/5`, the
  two error arms) — normalize both sides through `Code.format_string!/1`
  and assert equality with the committed file. An accidental local edit
  anywhere else in the ~300-line copy (authorization, resource/prompt
  handling, rescue conversion) fails this row while the targeted
  provenance tests stay green.
- *Raise-path stacktrace fidelity (the generator's reason for
  existing)*: a no-opt scripted RAISING action through `Jido.Exec.run`
  → the returned `execution_error`'s `details.stacktrace` frames for
  `Jido.Exec` functions carry the UPSTREAM file string (never
  `jido_exec_patch.ex`) and upstream line numbers; plus a runtime-path
  row asserting content[0] for a raising tool renders that upstream
  path — pinning no-opt raise-path byte fidelity end-to-end.
- *Incremental-build regression (the compiler-stage ownership proof)*:
  the stage's verify/regenerate core is exposed as a PATH-PARAMETERIZED
  function (explicit source + target paths), and the row runs entirely
  under an ExUnit temporary directory — copy the UPSTREAM dep BEAM in
  as the target, invoke verify/regenerate, assert the target now
  carries the patch marker with the current pins; a stale-marker
  variant (wrong upstream sha) regenerates; AND a stale-PATCH variant —
  upstream sha CURRENT but patched-source digest stale — also
  regenerates (hunk/helper edits at an unchanged jido_action version
  must never be served from an old BEAM). NEVER against the live
  `_build/test` BEAM: precommit runs four partitions against one shared
  build dir (`scripts/test-partitioned.sh`), so mutating the suite's
  active `Elixir.Jido.Exec.beam` would let another partition load the
  upstream copy and a failed row leave the shared build corrupted.
- *Repo pool-size seam*: `JidoClaw.Repo.init/2` rows for BOTH `:runtime`
  and `:supervisor` contexts — a raw `pool_size` string parses to the
  integer while the `super`-injected AshPostgres fields
  (extension/migration-path/prefix configuration) SURVIVE in the
  returned config; a malformed value raises with the clear message.
- *Vault key integrity (the CLOAK_KEY block deletion)*: for EACH valid
  decoded key length (16, 24, 32 bytes), drive
  `VaultConfig.ensure_configured!/0` from a base64 `CLOAK_KEY` env and
  assert the configured cipher key's EXACT bytes equal the decoded key
  (a raw base64 string silently accepted as a key — the 24/32-byte
  collision — must be impossible); malformed `CLOAK_KEY` raises at
  startup with the loader's message.
- *No-opt parity*: a test-local map-error action through `Jido.Exec.run/3`
  (no opts) → the wrap's details carry NO marker key — protects every
  agent-side caller.
- *With-opt marking*: same action with
  `exec_opts(make_ref())` → the wrap carries exactly that ref under the
  marker key.
- *Stamp-condition negative*: a NON-envelope map error (e.g.
  `%{foo: 1}`) and a colliding non-exception struct, each WITH the opt →
  the wrap carries NO marker key — the witness attests envelopes only.
- *License artifacts*: `Path.join(:code.priv_dir(:jido_claw), "licenses/jido_action-APACHE-2.0.txt")`
  is byte-equal to `deps/jido_action/LICENSE` (upstream is the truth —
  a truncated committed copy carrying the copyright line must fail, and
  a dep-bump license change surfaces here); the NOTICE file exists and
  names the modified `Jido.Exec` behavior;
  `JidoClaw.Core.ThirdPartyLicenses`'s license accessor returns text
  byte-equal to the priv license file and its notice accessor byte-equal
  to the priv NOTICE file (the embedded copies can never silently drift
  from the served ones — the equalities chain artifact output to
  upstream bytes); AND a `capture_io` row on
  `JidoClaw.CLI.Main`'s `--third-party-licenses` handling asserting the
  flag prints the modification NOTICE followed by the byte-identical
  license text, without booting the application (the escript
  recipient's supported route for BOTH §4(a) and §4(b)); AND
  failure-path rows for `start_app_or_halt!/0` — an injected failing
  starter must terminate with the documented non-zero exit and a
  stderr message for EACH checked branch class (setup/REPL/MCP), never
  fall through to the branch body (the `app: nil` equivalence proof:
  a start failure is terminal, exactly as Mix's pre-main bootstrap
  was); PLUS a returning-halter regression row — an injected halter
  that RETURNS instead of halting must still not fall through (the
  unconditional raise/exit after the halter call fires), pinning the
  seam's structurally non-returning failure arm.
- *Escript-config pin (permanent — the one-time artifact check cannot
  guard later regressions)*: a test row beside the existing Mix-project
  assertions reading `JidoClaw.MixProject.project()[:escript]` and
  asserting `main_module: JidoClaw.CLI.Main` AND `app: nil` — removing
  `app: nil` would silently restore pre-`main/1` application boot and
  break the bare-binary license guarantee while every other test stays
  green.

## Docs + reconciliation (same change)

- **`mix.exs`**: the `ignore_module_conflict` comment — "six upstream
  modules" → "seven", add the `jido_exec_patch.ex` bullet (jido_action
  2.3.1 `Jido.Exec` — opt-gated wrap-provenance marker for the served-MCP
  error boundary's tier-1 witness), and "all six patches above" → seven in
  the removal note; plus `app: nil` in `escript/0` (with a comment: main/1
  paths self-start the app; the pre-boot license flag depends on it).
- **`AGENTS.md`** Known-limitations: widen the heading to
  "(anubis_mcp 1.6.2 + jido_mcp + jido_action — patched in
  `lib/jido_claw/core/`)" and add the fork bullet: why (the exec wrap is
  lossy; tier-1 provenance was shape-inferred and forgeable), the contract
  in one line (opt-gated `Map.put_new` ref marker stamped only for
  pre-wrap canonical envelopes, detached only on ref identity, tier 1
  requires the witness, public server only), the
  package-pinned drift guard, the Apache-2.0 attribution pointer, and the
  removal condition — pointing at `docs/system/mcp-server-surface.md`.
- **`docs/system/mcp-server-surface.md`** (already modified unstaged by
  the whimsical-sunrise round — these edits layer on): document the
  provenance contract (opt name, marker key + both forms boundary-owned,
  the canonical-envelope stamp condition — the witness attests "exec
  wrapped a canonical envelope", never merely "exec wrapped a map";
  colliding non-exception structs and near-envelopes wrap unstamped →
  native tier — put_new/squat semantics, detach-only-on-ref-identity,
  tier-1 guard, public-only minting, the compensation-nesting residual
  and its guard test, retry-gate neutrality); add to BOTH the frontmatter `sources:`
  list and `## Source map`: `lib/jido_claw/core/jido_exec_patch.ex`,
  `test/jido_claw/core/jido_exec_patch_test.exs`,
  `lib/mix/tasks/compile.jidoclaw_release_patches.ex` + `mix.exs` (the
  every-compile verification/regeneration owner and its compiler
  ordering — the mechanism that determines which `Jido.Exec` BEAM
  actually ships belongs in the reconcile scope), and (if absent)
  `lib/jido_claw/core/dependency_patches.ex` +
  `test/jido_claw/core/dependency_patches_test.exs` — the fork's install
  authority belongs in the page's reconcile scope. Refresh `verified:` and
  `verified_sha` (re-derive from actual HEAD at implementation time —
  coordinates with the whimsical plan's identical instruction).
- **`docs/system/gateway-runtime-security.md`** (its reconcile scope
  already includes `config/runtime.exs`): document the new secret
  enforcement contract — presence + quality validated by
  `RuntimeSecrets` at APPLICATION STARTUP (after dotenv loading), never
  at config evaluation; runtime.exs is total/configure-only; the
  bare-escript behavior (`app: nil`, checked `start_app_or_halt!/0`,
  the no-boot `--third-party-licenses` route) and the CLOAK_KEY
  single-loader fact (`VaultConfig`, the runtime.exs cipher block
  deleted). Add the touched source/test files to its source map and
  refresh `verified:`/`verified_sha`.
- **`docs/plans/pre-argus-wave-e-16/README.md`** `## Deviations` — one new
  entry: `**Post-review round: tier-1 wrap provenance witnessed through a
  Jido.Exec fork** (forced; 2026-07-13)` — the finding (shape-inferred
  provenance, verbatim exception pass-through), why shape matching could
  not close it, the mechanism (per-call ref through the forked wrap arms,
  stamped only for pre-wrap canonical envelopes — a plan-review round
  caught that stamping every map-wrap would let colliding non-exception
  structs carry an authentic token through `extract_error_fields`'s
  struct clause — put_new law, detach-on-identity, public-only scope,
  the junk-input-only near-envelope demotions), the rejected
  alternatives (producer marking = silent tier-4 demotion; envelope
  exception type = content[0] + retry-gate breakage; no dep seam exists),
  the process decisions (the signed `PORT-PD1-2-EXEC.md` amendment map —
  plan review overruled the initial header-convention-only reading of the
  port rule, and anchored the map to the PD1-2 corpus entry;
  Apache-2.0 header notice + committed license file; the five
  pre-existing patches' license hygiene flagged as follow-up), the
  drift-guard design (package pins + the runtime-fork parity
  reconstruction; the exec fork is a compile-time GENERATOR patching the
  pinned upstream source — a plan-review round showed a committed copy
  shifts `handle_action_exception`'s embedded stacktrace frames and
  breaks no-opt raise-path byte identity, so parity and frame fidelity
  hold by construction), and the escript boot-order chain the license
  route forced (`app: nil` + checked startup + total runtime.exs — the
  redundant CLOAK_KEY cipher block deleted in favor of the existing
  `VaultConfig` startup loader after review flagged the raw-passthrough
  key-collision hazard; the dead `FORGE_SANDBOX_TIMEOUT_MS` config
  removed rather than relocated — activating it is a separate
  behavioral change).
- No bootstrap/error-contract change (provenance is internal, not
  wire-visible). No `jido_md.check` / `system_prompt.check` impact (no
  tool/template/skill surface change).

## Verification

1. Targeted first:
   `mise exec -- mix test test/jido_claw/core/jido_exec_patch_test.exs test/jido_claw/core/dependency_patches_test.exs test/jido_claw/core/mcp_server/error_boundary_test.exs`
   — new rows green, zero regressions in the existing tier/byte/chaos/
   call-count rows (every existing wire assertion must hold byte-for-byte;
   the fork without the opt must be behavior-invisible).
2. Artifact-level license check (one-time, after the code lands):
   `MIX_ENV=prod mise exec -- mix escript.build` — the env must be
   EXPLICIT (mise.toml sets no MIX_ENV, so a bare build produces a dev
   escript that never evaluates the prod runtime.exs branch these
   probes exist to prove out), against a clean/isolated prod build dir
   — and run `./jidoclaw --third-party-licenses` — assert the
   DISTRIBUTED binary emits the modification NOTICE (§4(b)) followed by
   a license section byte-identical to
   `priv/licenses/jido_action-APACHE-2.0.txt` (§4(a) — e.g. split on
   the notice/license boundary and `diff` the license section) — on a
   `MIX_ENV=prod`-built escript with BOTH secrets COMPLETELY UNSET
   — the honest bare-binary claim: config evaluation no longer raises
   (runtime.exs is total) and the pre-boot clause runs with zero
   environment. Repeat the license invocation with each formerly
   config-time parser fed a MALFORMED value — with its GUARD CONDITION
   armed, or the probe exercises nothing: `CLOAK_KEY=not-base64`; a
   VALID `DATABASE_URL` plus `POOL_SIZE=abc` (the pool-size parse runs
   only inside runtime.exs's `if database_url` branch); and separately
   `FORGE_SANDBOX=docker` plus `FORGE_SANDBOX_TIMEOUT_MS=abc` (the
   forge parser fired only under that flag — the license must still
   print BECAUSE the dead setting was removed; a missed deletion fails
   here instead of false-greening). The flag must print the license in
   every case (config stays total). The boot-exercising FAILURE probes
   start from ONE fully VALID baseline environment (valid secrets,
   CLOAK key, database) and mutate ONLY the variable under test —
   otherwise the probe stops at an earlier validator and false-greens
   the relocated one — asserting the failure SOURCE in stderr: the
   `CLOAK_KEY=not-base64` probe fails in `VaultConfig` (its
   invalid-key message), and the valid-`DATABASE_URL` + `POOL_SIZE=abc`
   probe fails in the Repo pool-size parse at Repo startup, each
   terminal and non-hanging. Then smoke one BOOT-EXERCISING escript
   path end-to-end (a usage-error run proves nothing — it never reaches
   the boot callback): with a valid env, start `./jidoclaw --mcp`,
   confirm the application + server come up, and assert stdout carries
   ONLY valid JSON-RPC during the initialization exchange (the pre-boot
   stderr redirect holds — dep startup logs must not corrupt the
   stream). Then, over the SAME stdio session, drive a real `tools/call`
   that fails with a canonical envelope (e.g. an unknown-skill case) and
   assert the reply carries the dual-content shape with the DOMAIN code
   in `content[1]` and a marker-free `content[0]` — MCP initialization
   alone cannot prove the artifact contains the forks: the release
   relocation's `relocate_patch!/1` accepts an already-existing dep
   target when the app-side patched BEAM is absent, so a prod binary
   could initialize fine yet classify envelopes with UPSTREAM
   `Jido.Exec`; this probe proves relocation + runtime wiring in the
   actual artifact. Terminate the session; with the
   secrets-unset env, confirm the SAME path fails at startup — and
   isolate the probe from dotenv restoration: MCP startup calls
   `load_dotenv/0` BEFORE RuntimeSecrets (application.ex:60), so
   unsetting shell variables alone can be silently undone by the
   working directory's `.env`/`.jido/.env`. Run the failure probe from
   a FRESH temporary directory containing neither file, under a minimal
   scrubbed environment (`env -i` plus only PATH/HOME-class basics),
   and assert the exit status IS the intended startup-failure code —
   explicitly NOT the shell timeout's code — with stderr naming
   `RuntimeSecrets`. (NOT "database down": `DATABASE_URL` is consumed
   only on runtime.exs's prod branch, and the MCP scope initializer
   downgrades DB failures to warnings, so a DB-down smoke can boot
   "successfully" into the wait loop.) This is the artifact-level twin
   of the `start_app_or_halt!/0` failure rows. Run every artifact
   invocation under a shell timeout (e.g. `timeout 30`) so a hang fails
   the check rather than blocking it.
3. **Final bar**: `mise exec -- mix precommit` — bare (never piped), run in
   background, read the tail; iterate to green. Known-flaky singleton
   suites (MCPServer, Prompt, PipelineStore, MultiSandbox) verified in
   ISOLATION before blaming this change. Watch items: the fork file's
   credo/reach/ExSlop disables mirror the runtime-patch precedent and are
   justified inline; `compile_check` stays warning-clean with NO allowlist
   entry (`ignore_module_conflict` already global); new public boundary
   helpers carry @doc/@spec; no comment line starts with the word "step";
   `system_docs.check` passes with the surface-page edits landing in the
   same change.

## Files to stage (fold into the existing #16 commit-2 slice; nothing committed by the agent)

- `docs/exploration/pms/pad/PORT-PD1-2-EXEC.md` (NEW — the signed
  amendment map, Fix 0)
- `docs/exploration/pms/pad/FEATURES-WORTH-BORROWING.md` (PD1-2 inventory
  status linking the map + provenance-correction summary; already
  modified unstaged)
- `docs/exploration/pms/pad/PD-FIRST-WAVE.md` (PD1-2 lifecycle amendment
  note; already modified unstaged)
- `lib/jido_claw/core/jido_exec_patch.ex` (NEW — the fork)
- `priv/licenses/jido_action-APACHE-2.0.txt` (NEW)
- `priv/licenses/jido_action-NOTICE.txt` (NEW — artifact-visible §4(b)
  modification notice)
- `lib/jido_claw/core/third_party_licenses.ex` (NEW — escript-reaching
  embedded license copy)
- `lib/jido_claw/cli/main.ex` (the `--third-party-licenses` early-exit
  flag + `start_app_or_halt!/0`; exact file confirmed at implementation
  from the escript `main_module`)
- `config/runtime.exs` (total — secret raises, the redundant CLOAK_KEY
  cipher block, the dead forge-timeout setting, and the POOL_SIZE parse
  all removed; raw values pass through where still needed)
- `lib/jido_claw/security/runtime_secrets.ex` (presence enforcement
  joins the existing quality checks at app startup)
- `lib/jido_claw/repo.ex` (the POOL_SIZE parse in `init/2`, chaining
  `super/2`)
- `lib/mix/tasks/compile.jidoclaw_release_patches.ex` (the compiler
  stage gains patched-target verification/regeneration for the
  generated fork)
- vault/key-length + stacktrace-fidelity + parity test files (homes
  confirmed at implementation — likely `test/jido_claw/security/` and
  the new `jido_exec_patch_test.exs`)
- `lib/jido_claw/core/dependency_patches.ex`
- `lib/jido_claw/core/jido_mcp_runtime_patch.ex`
- `lib/jido_claw/core/mcp_server/error_boundary.ex`
- `lib/jido_claw/core/mcp_server/surface_version.ex` (v1.3 bullet amended)
- `mix.exs` (patch-inventory comment)
- `test/jido_claw/core/jido_exec_patch_test.exs` (NEW)
- `test/jido_claw/core/dependency_patches_test.exs`
- `test/jido_claw/core/mcp_server/error_boundary_test.exs`
- `AGENTS.md`
- `docs/system/mcp-server-surface.md`
- `docs/system/gateway-runtime-security.md`
- `docs/plans/pre-argus-wave-e-16/README.md`

Suggested commit slicing is unchanged from the #16 plan (these fixes ride
commit 2, `feat: served-MCP structured error contract + code registry
(PD1-2)`).
