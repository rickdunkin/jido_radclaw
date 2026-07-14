# Plan: Wave E #16 post-review fixes — bounded key inspection, skill-name type invariant, provable static fallback

## Context

A code review of the just-landed Wave E #16 work (served-MCP boundary error-code
registry, `.claude/plans/please-review-docs-plans-pre-argus-do-n-virtual-wind.md`)
returned three findings. **All three are verified real** against the working tree:

1. **[P1] VALID — `bencode_key/3`'s fallback inspects before it budgets.**
   `lib/jido_claw/core/json_safe.ex:529-541`: non-binary, non-atom map keys run
   `safe_inspect(k)` FIRST, then bound/charge. `safe_inspect/1` guards
   raise/throw/exit and scrubs invalid UTF-8, but does nothing about output
   size or nontermination — a struct key (or a tuple/list/map key *containing*
   a struct) with a hostile/buggy `Inspect` impl allocates arbitrarily large
   output (then gets a full O(n) `scrub_binary` scan) or never returns, all
   before `max_key_bytes`/`max_bytes` see a single byte. This breaks the
   walker's own bounded-WORK contract on the MCP error path (boundary details,
   `run_skill` raw Reactor reasons). The same contract is violated a second
   way: the map fold retains ORIGINAL keys and `List.keysort(0)`s them
   (json_safe.ex:428-432) — Erlang term comparison of two large shared-prefix
   composite keys is O(key size), so the sort itself is unbounded traversal
   even when the keys are never rendered. Both legs get fixed. The
   fingerprint walker is NOT affected — `fproject_key/5` (json_safe.ex:662)
   routes non-binary keys through the marker projection, never `inspect/1`,
   and `fproject_pairs` sorts PROJECTED (budget-bounded) pairs only. The
   unbounded `encode/1` path (`do_encode_key/1`:222, term-order fold :151-166)
   also stays as-is: its contract is totality, not bounded work — it walks
   every key fully regardless — and its consumers are trusted payloads.

2. **[P2] VALID — non-binary skill names bypass the loader invariant.**
   `lib/jido_claw/platform/skills.ex:509-536`: `build_skill/2` rejects only
   `is_binary(name) and byte_size(name) > 256`; YAML `name: 123`,
   `name: [a, b]`, `name: {a: 1}`, and explicit `name:`/`name: null` (→ `nil`,
   since the key is present `Map.get` never falls back to the basename) are
   cached as valid skills — as is `name: !!binary /w==` (→ `<<255>>`), a
   BINARY that passes the size check yet carries invalid UTF-8 into prompt
   interpolation and every downstream JSON encode. Verified crash sites: the system-prompt skills list
   `"  - #{s.name}: #{s.description}"` (`lib/jido_claw/agent/prompt.ex:231` —
   map/list names raise `Protocol.UndefinedError`, OUTSIDE the rescue at
   :424-431, propagating into session-prompt assembly) and the `/skills` CLI
   renderer (`lib/jido_claw/cli/commands.ex:1543`). `load_skill/2` (replay)
   shares `load_from_disk → parse_skill_file → build_skill`, so one fix covers
   cache load, reload, and the fresh-disk path.

3. **[P2] VALID — the static-fallback test is a tautology.**
   `test/jido_claw/core/mcp_server/error_boundary_test.exs:352-361` decodes a
   JSON literal duplicated from `error_boundary.ex`'s `@static_fallback` and
   compares it to itself — `ErrorBoundary` is never invoked. If
   `structured_item/1` (error_boundary.ex:141-152) lost its rescue/catch or
   returned the wrong fallback, the test stays green. The neighboring hostile-
   `Inspect` tests exercise `safe_inspect/1`'s INTERNAL guard (unwrap tier 4
   succeeds normally), never the guarded region's escape path — which is
   unreachable by input today precisely because the production is total. An
   injection seam is required; the project deliberately has no mocking library
   (no mimic/mox/meck in mix.exs or mix.lock; `lease_telemetry_test.exs:157`:
   "Mox, which the project lacks"). The seam must be compiled only in test —
   the house precedent is `lib/jido_claw/mcp/endpoint_config.ex:263-280`
   (`if Mix.env() == :test do … end` around the mutation seam) — so
   production is structurally unable to trip the fallback on configuration
   junk.

Greenfield — no compat shims. Nothing committed by the agent; done means
`mise exec -- mix precommit` green. Run mix via `mise exec -- mix`; gates bare
(never piped), in background, read the tail.

---

## Fix 1 (P1): bounded key encoding — no user `Inspect`, no original-key comparison

**File: `lib/jido_claw/core/json_safe.ex`**, two coordinated changes.

**(1a) Replace the `bencode_key/3` fallback clause (:529-541)** with a total,
class-split ladder. Existing `is_binary` (:509) and `is_atom` (:524) heads
stay untouched. New clauses, in order:

1. **Int64-range integers render exactly** (the common real case — step
   indices): guard `is_integer(k) and k >= @min_exact_int_key and
   k <= @max_exact_int_key` (new attrs, the int64 range — an O(1) magnitude
   precheck; bignum-vs-fixnum comparison is size-first) →
   `Integer.to_string(k)` (≤ 20 bytes) + `spend_bytes`.
2. **Out-of-range integers** → constant marker `"<<key:bigint>>"` — the
   decimal render is digit-count work proportional to the bignum's size,
   spent BEFORE the budget could charge (and `inspect/2`'s `limit`/
   `printable_limit` do not bound integer rendering).
3. **Floats + runtime identities + non-binary bitstrings**
   (`is_float or is_pid or is_reference or is_port or is_function or
   is_bitstring`) → `safe_inspect(k)` then the EXISTING bounded-prefix
   truncation arm (current :532-538 body, kept as a helper). Safe: these are
   consolidated stdlib `Inspect` impls — bounded output, terminating, not
   user-overridable post-consolidation; the comment says exactly that.
4. **Structs** — `%module{} when is_atom(module)` (guard matters: a hand-built
   map with a non-atom `__struct__` must fall through to the map marker) →
   `"<<key:struct:" <> inspect(module) <> ">>"` (atom inspect: built-in,
   bounded ≤ 255 chars, no user dispatch).
5. **Maps / tuples / lists** → `"<<key:map>>"` / `"<<key:tuple>>"` /
   `"<<key:list>>"`.
6. **Total fallback** (future term classes) → `"<<key:unknown>>"` — mirrors
   `fproject_value`'s `:unknown` clause precedent (json_safe.ex:620-622).

Every marker charges `spend_bytes(st, byte_size(marker), limits)`. The
comment block above the clauses states the rule: composite keys are never
rendered because rendering runs user `Inspect` impls (unbounded allocation /
nontermination) before any budget charge — a deliberate lossy normalization.

**(1b) Collision policy WITHOUT retaining originals** — rewrite the
`bencode_value/4` map clause (:407-435): drop the `{orig, ek, ev}` entry list,
`List.keysort(0)`, and `Map.new` entirely. Fold entries straight into the
result map during iteration, carrying a SEPARATE `collided :: MapSet` of
encoded keys in the accumulator (`{acc, collided, st}`):

- Per entry, after the drop-checks (pid/module values) and `bencode_key/3`:
  - `MapSet.member?(collided, ek)` → skip entirely (the sentinel is already
    present and charged; the key encode above still charged its own bytes);
  - `Map.has_key?(acc, ek)` (first collision for `ek`) → replace the stored
    value with the constant sentinel `@collision_marker "[key-collision]"`,
    **charge it exactly once** via
    `spend_bytes(st, byte_size(@collision_marker), limits)` — the sentinel
    is a rendered leaf and must ride the same cumulative accounting as every
    other leaf (json_safe.ex:343) — add `ek` to `collided`, and SKIP walking
    the colliding value;
  - otherwise → walk the value and store it (today's path).
- The `collided` set — not a value comparison — is the collision authority: a
  GENUINE value that happens to equal `"[key-collision]"` can never suppress
  charging or misread state.
- Order-independent by construction: one entry → its encoded value; two or
  more entries sharing an encoded key → the sentinel — no dependence on map
  iteration order, no comparison or retention of original keys, ever.
- Deterministic: equal maps are the same canonical term, so iteration order
  (and therefore budget spends) is stable per input.
- Replace the fold comment (:428-430): the bounded walker resolves collisions
  by sentinel, never term order — bounded work is the contract, and the
  sentinel bytes are charged once per collided key.

**Moduledoc**: extend the "Bounded walkers" section (json_safe.ex:47-59) with
the two bounded-walker divergences from `encode/1`'s documented policy:
composite keys (tuple/list/map/struct) and out-of-int64 integers take
constant `<<key:*>>` markers, and encoded-key collisions resolve to the
constant `"[key-collision]"` sentinel (order-independent) instead of the
term-order fold — rendering or comparing arbitrary originals is unbounded
work. `encode/1`'s own bullets (:31-40) stay true for `encode/1` and are
untouched.

**Tests — `test/jido_claw/core/json_safe_test.exs`**:

- integer keys render exactly (`%{1 => "a", -42 => "b"}` → `"1"`, `"-42"`);
  a bignum key (`Integer.pow(2, 64)`) → `"<<key:bigint>>"`.
- composite keys take per-class markers (`{:a, 1}` / `[1]` / `%{x: 1}` keys →
  `"<<key:tuple>>"` / `"<<key:list>>"` / `"<<key:map>>"`; distinct classes in
  one map coexist as distinct keys).
- **the no-dispatch proof**: `%{%HostileInspect.Throwing{x: 1} => "s"}` →
  key `== "<<key:struct:#{inspect(HostileInspect.Throwing)}>>"` — under the
  old code this would have been `"[uninspectable]"` (throw swallowed by
  `safe_inspect`), so the marker proves `Inspect` never ran.
- **large shared-prefix composite-key collision regression** (replaces any
  term-order-winner row for the bounded path): two large list keys sharing a
  long prefix (e.g. `prefix = Enum.to_list(1..100_000)`; `prefix ++ [:a]` /
  `prefix ++ [:b]`) → `{:ok, %{"<<key:list>>" => "[key-collision]"}, _}`
  under DEFAULT budgets — the originals are never walked, rendered, or
  compared (marker encoding is O(1) per key; no sort exists).
- a pid key keeps its bounded built-in render (key `=~ "#PID<"`).
- **sentinel accounting rows**: (a) exact charge — `%{1 => 0, "1" => 0}`
  (integer and string originals both encode to `"1"`) accounts key bytes
  (1 + 1) plus the sentinel (15) exactly: `max_bytes: 16` →
  `{:budget_exceeded, _}`, `max_bytes: 17` → `{:ok, %{"1" =>
  "[key-collision]"}, 17}` (numbers cost no bytes, so the totals are exact);
  (b) charge-once — the triple collision `%{1 => 0, "1" => 0, :"1" => 0}`
  charges the sentinel ONCE (total 18, not 33): trips at `max_bytes: 17`,
  passes at 18; (c) bulk trip — thousands of colliding integer/string pairs
  under a tight `max_bytes` → `{:budget_exceeded, _}`, never unaccounted
  sentinel output.
- **UPDATE** the existing "two oversized invalid keys sharing prefix AND
  length" row (:225-236): same single-entry outcome, but the value is now
  `"[key-collision]"`, not the term-order winner `"b"`. (The UNBOUNDED
  `encode/1` collision test at :166-172 stays as-is — term-order folding
  remains `encode/1`'s documented policy.)

**Test — `test/jido_claw/core/mcp_server/error_boundary_test.exs`**: extend
the (f) unsafe-details envelope with a composite key and a hostile-struct key
(`{:step, 3} => "at"`, `%HostileInspect.Throwing{x: 1} => "under-hostile-key"`)
and assert both arrive under their marker keys in `content[1]` — the wire
path never dispatches key `Inspect`.

## Fix 2 (P2): reject every non-binary skill name at the loader boundary

**File: `lib/jido_claw/platform/skills.ex`** — restructure `build_skill/2`
(:509-536) into a `cond` with the non-binary arm FIRST, same loud posture.
The log names the offending file and the rejected value's TERM CLASS — never
the value itself (`inspect/2` cannot bound integer rendering, and a huge
map/list name would bloat the line even bounded):

```elixir
cond do
  not is_binary(name) ->
    Logger.error(
      "[Skills] Excluding #{path}: skill name must be a string " <>
        "(got: #{name_type(name)}) — quote the `name:` field"
    )
    []

  byte_size(name) > @max_skill_name_bytes ->
    # existing overlong log + []

  not String.valid?(name) ->
    # YamlElixir's !!binary tag can deliver raw bytes (`name: !!binary /w==`
    # → <<255>>) — invalid UTF-8 that would poison prompt interpolation and
    # every JSON encode downstream. Deliberately AFTER the byte-size arm so
    # the validity scan is bounded at 256 bytes. Constant message — never
    # render the bytes:
    Logger.error(
      "[Skills] Excluding #{path}: skill name must be valid UTF-8 — " <>
        "re-encode the `name:` field"
    )
    []

  true ->
    # existing struct build
end
```

with a small total classifier beside it (constant output by construction):

```elixir
defp name_type(nil), do: "null"
defp name_type(v) when is_boolean(v), do: "boolean"
defp name_type(v) when is_integer(v), do: "integer"
defp name_type(v) when is_float(v), do: "float"
defp name_type(v) when is_list(v), do: "list"
defp name_type(v) when is_map(v), do: "map"
defp name_type(_v), do: "non-string"
```

Covers integers, floats, booleans, lists, maps, the explicit-`name:` nil
case (YamlElixir's whole scalar surface), AND `!!binary`-tagged raw bytes.
No behavior change for the missing-key default (`Path.basename` is always a
binary). One choke point covers startup load, `reload`, and replay's
`load_skill/2` (all via `load_from_disk/1`).

**Docs (constraint tightens to "must be a valid UTF-8 string, ≤ 256 bytes")**:

- `lib/jido_claw/platform/skills.ex:19-26` moduledoc: "**Skill names must be
  valid UTF-8 strings of at most 256 bytes**" + extend the exclusion sentence
  to cover non-binary names (integer/list/map/explicit-null) and invalid
  UTF-8 alongside overlong ones.
- `lib/jido_claw/platform/jido_md.ex:286-288` (`custom_skills_section/0`
  fragment): "The `name` field must be a valid UTF-8 string of at most 256
  bytes — a skill whose name violates the rule is excluded at load with a
  per-file error log, and lookups report it as unknown."
- `.jido/JIDO.md:246-248`: update to the generator's new fragment
  BYTE-IDENTICALLY — `mix jidoclaw.jido_md.check` byte-compares
  `JidoClaw.JidoMd.custom_skills_section()` against the committed section
  (check task :71). Print the new fragment (Tidewave `project_eval` of
  `JidoClaw.JidoMd.custom_skills_section()`) and splice it in; verify with
  the check task.
- README.md: no skill-name-bound text exists (verified) — no edit.

**Tests — `test/jido_claw/skills_test.exs`** (async: false), new rows in the
existing `describe "skill-name byte bound"` (:375, or a sibling
"skill-name type invariant" describe) mirroring the overlong row (:378-407)
exactly — same `start_skills!`/`capture_log` shape. `write_skill!/4`
interpolates the name into quoted YAML, so these rows write raw YAML directly
(`File.write!(Path.join(dir, file), "name: 123\n…")`) or via a small raw
variant of the helper:

- `name: 123` (integer), `name: {a: 1}` (map), `name:` (explicit nil): each
  EXCLUDED at load AND reload with the loud log (`=~ file`,
  `=~ "must be a string"`, and the class marker — `"got: integer"` /
  `"got: map"` / `"got: null"`); `Skills.list()` omits them; `Skills.get/1`
  misses; `Skills.load_skill/2` → `{:error, :not_found}`.
- **invalid-UTF-8 regression**: `name: !!binary /w==` (→ `<<255>>`) EXCLUDED
  at load AND reload with the constant log (`=~ "must be valid UTF-8"`,
  `=~` the file); `Skills.list()` omits it.
- a valid quoted numeric name (`name: "123"`) still loads (the rejection is
  about TYPE, not digits).

## Fix 3 (P2): drive the static fallback through the real runtime

**File: `lib/jido_claw/core/mcp_server/error_boundary.ex`** — add the chaos
seam INSIDE the guarded region, first line of `structured_item/1` (:141),
**compiled only in test** (the endpoint_config.ex:263-280 precedent), with a
production no-op and a catch-all so no configuration value — `false`, a typo,
leftover junk — can ever force real errors into the static fallback:

```elixir
defp structured_item(reason) do
  maybe_chaos!()
  {code, message, details, unregistered?} = enforce_registry(unwrap(reason))
  encode_envelope(code, message, details, unregistered?)
rescue
  …
end

# This chaos seam is compiled only in MIX_ENV=test (the app-env seam idiom —
# the project deliberately has no mocking library): it lets the suite prove
# the never-escalate fallback through the REAL runtime path for all three
# escape kinds. Production gets a constant no-op — structurally unable to
# trip the fallback on configuration junk.
if Mix.env() == :test do
  defp maybe_chaos! do
    case Application.get_env(:jido_claw, :error_boundary_chaos) do
      :raise -> raise "error boundary chaos armed"
      :throw -> throw(:error_boundary_chaos)
      :exit -> exit(:error_boundary_chaos)
      _ -> :ok
    end
  end
else
  defp maybe_chaos!, do: :ok
end
```

One moduledoc sentence documenting the seam (test-compiled only, default
inert).

**Tests — `test/jido_claw/core/mcp_server/error_boundary_test.exs`** (file is
already `async: false`). App-env hygiene, specified exactly — do NOT copy the
(j) exec-timeout restore (:428-435), whose truthiness check would DELETE an
original `false` value, and the junk-config row below stores a literal
`false`. Instead, in each chaos test, BEFORE any mutation:

```elixir
original = Application.fetch_env(:jido_claw, :error_boundary_chaos)

on_exit(fn ->
  case original do
    {:ok, value} -> Application.put_env(:jido_claw, :error_boundary_chaos, value)
    :error -> Application.delete_env(:jido_claw, :error_boundary_chaos)
  end
end)
```

then arm per row:

- **REPLACE the tautology test (:352-361)** with: for each
  `kind <- [:raise, :throw, :exit]`, arm
  `Application.put_env(:jido_claw, :error_boundary_chaos, kind)`, drive
  `call_tool(key, {:error, %{code: :unknown_skill, message: "m", details: %{retry: false}}})`
  and assert: the reply is still `{:reply, response, _}` (never a protocol
  error), `isError == true`, TWO content items, `content[0]` a nonempty
  legacy inspect text (rendered OUTSIDE the region — unaffected by the trip),
  and `content[1]` `==` the EXACT static bytes
  `~s({"code":"tool_error","message":"error serialization failed","details":{"retry":false}})`,
  plus its decoded shape. This is the reviewer's ask: the fallback
  IMPLEMENTATION proven through `Runtime.handle_tool_call/5`, for the two
  escape kinds `rescue` alone would miss.
- **Junk-config row**: with `:error_boundary_chaos` set to garbage (e.g.
  `false`), a failing tool still produces the NORMAL structured envelope —
  the catch-all keeps the seam inert.
- **Scoping row**: while armed, a consolidator-server `call_tool` still
  returns the single-item legacy shape — `structured_item/1` (and the seam)
  never runs for non-public servers.

## Docs + reconciliation

- `docs/system/mcp-server-surface.md`: `error_boundary.ex` is in its
  `sources:` (:8), so the seam edit requires the same-change bump — add one
  sentence to the never-escalate paragraph (the region is provable end-to-end
  via the test-compiled `:error_boundary_chaos` app-env seam; production
  builds carry a constant no-op) and refresh `verified:`/`verified_sha`.
  `json_safe.ex`/`skills.ex` are in NO system page's sources (verified) — no
  other page fires.
- `docs/plans/pre-argus-wave-e-16/README.md` `## Deviations`: three short
  entries (post-review round, forced corrections): bounded-walker key markers
  + collision sentinel; loader name-type invariant; test-compiled chaos seam
  replacing the tautology.

## What deliberately does NOT change

- No surface-version bump, no golden fixture change: the registry, tool set,
  and wire contract are untouched; marker keys and the collision sentinel
  inside `details` values fall under the already-documented lossy
  normalization.
- `fproject_*` (LoopGuard fingerprint), the unbounded `encode/1`/
  `do_encode_key/1` (term-order fold included), binary/atom key handling, and
  all reduction tiers stay byte-identical.
- `hint_available/2` needs no change — but for the right reason: after Fix 2
  the loader guarantees `Skills.list/0` returns only binaries, which take
  `hint_string/1`'s binary head. Its fallback is UNGUARDED `inspect/1`
  (error.ex:234), so it is the loader invariant — not `hint_string/1`
  totality — that protects this path.

## Verification

1. Targeted: `mise exec -- mix test test/jido_claw/core/json_safe_test.exs
   test/jido_claw/core/mcp_server/error_boundary_test.exs
   test/jido_claw/skills_test.exs` — new rows green, no regressions.
2. Gates as edited: `mise exec -- mix jidoclaw.jido_md.check` (fragment sync),
   `mise exec -- mix jidoclaw.system_docs.check` (surface page bump).
3. Adjacent suites that must stay green: loop_guard tests (fingerprint
   untouched), run_skill/wire-format tests, served-surface golden (no drift).
4. **Final bar**: `mise exec -- mix precommit` bare, in background, read the
   tail. Known-flaky singleton suites (MCPServer, Prompt, PipelineStore,
   MultiSandbox) verified in isolation before blaming new code. Watch the
   known new-code credo/dialyzer gotchas; the ExSlop step-comment wrap trap.

## Files to stage (nothing committed by the agent)

- `lib/jido_claw/core/json_safe.ex`
- `lib/jido_claw/core/mcp_server/error_boundary.ex`
- `lib/jido_claw/platform/skills.ex`
- `lib/jido_claw/platform/jido_md.ex`
- `.jido/JIDO.md`
- `docs/system/mcp-server-surface.md`
- `docs/plans/pre-argus-wave-e-16/README.md`
- `test/jido_claw/core/json_safe_test.exs`
- `test/jido_claw/core/mcp_server/error_boundary_test.exs`
- `test/jido_claw/skills_test.exs`

Suggested commit (rides with / immediately after Wave E #16's commit 2):
`fix: post-review hardening — budget-safe key markers, skill-name type invariant, provable static fallback`
