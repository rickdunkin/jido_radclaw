# Plan: post-review fixes for Wave E #16 (typed WireError split + retry semantics + bounded-walker clamps)

## Context

Wave E #16 (served-MCP error-code registry, PD1-2) is implemented and sits
unstaged in the working tree. Two review rounds reported five defects; **all
five are verified real** against the working tree and deps — no speculation
remains. Round 2's three findings supersede round 1's fix shape for the
collision problem (the canonicalization-table draft is replaced by a typed
split), so this plan is the merged, current design.

**P1a — reserved-key collisions (round 1, VALIDATED both sites).**
Boundary-injected atom keys can coexist with producer string forms of the
same key; both encode to one JSON key, and the bounded walker's collision arm
([json_safe.ex:535-540](lib/jido_claw/core/json_safe.ex)) deliberately
replaces the stored value with the `"[key-collision]"` sentinel. The FULL
envelope tier ships the result as-is, so:

- **Tier-3 native unwrap** ([error_boundary.ex:202-205](lib/jido_claw/core/mcp_server/error_boundary.ex)):
  `Map.put_new(:retry, mapped.retryable?)` beside a producer string `"retry"`
  hint (a *supported jido_action shape* — `extract_retry_value` reads both
  forms, deps error.ex:639-643; the transport sanitizer preserves binary keys,
  sanitizer.ex:134-136) → the wire's required machine-readable retry boolean
  becomes `"[key-collision]"`. Same class for to_map's `maybe_put` injections
  of `:field`/`:value`/`:timeout` (deps error.ex:339-376) and the pseudo-struct
  clause's top-level merge (error.ex:405-423, 577-589 — reachable end-to-end:
  the `%module{}` guard admits exception-shaped maps, and `is_exception/1`
  passes them through exec verbatim, exec.ex:773-777).
- **Registry fallback** ([error_boundary.ex:231-236](lib/jido_claw/core/mcp_server/error_boundary.ex)):
  `Map.put(:unregistered_code, inspect(code))` beside a producer-squatted
  string form → the same collision destroys the advertised closure-proof key.

**P1b — reserved protocol state and the open extension bag share one map
(round 2, architecture).** A fixed canonicalization table repairs today's
collisions but preserves the root cause: `retry` / `unregistered_code` are
boundary-owned protocol state living inside `details`, the producers' open
extension bag, and every future reserved field would need synchronized edits
across canonicalization, reduction, and minimal rendering. Resolution: a
typed internal `WireError` — dedicated fields for boundary-owned state plus
`extra_details`; extras are bounded-encoded separately, then canonical
string-keyed fields are overlaid authoritatively; the reduced/minimal tiers
read the typed fields, never re-parse the extension map.

**P1c — `details.retry` conflated retry eligibility, an executed retry, and
client advice (round 2).** VERIFIED: the exec gate is cap-first —
`should_retry?/4` returns `false` whenever `retry_count >= max_retries`
BEFORE consulting `Error.retryable?/1` (deps retry.ex:72-80) — so every
error that reaches the boundary is one the gate finally refused to retry;
"the wire reports what the gate did" is incoherent (it would be constant
`false`). Resolution: the wire field is defined as **retry-policy
eligibility** — `Error.retryable?/1`, the exact class component the gate
ANDs with its attempt budget — documented as advice ("`false` ⇒ not
eligible for Jido.Exec's immediate automatic retry under the current
failure classification; do not blindly repeat without intervention" —
deliberately NOT a determinism claim: a `config_error` is class-`false`
yet an external configuration fix can make the same call succeed), never
as a record of in-call retry execution or remaining budget. The planned
assertions all survive; their framings change.

**P1d — tier 4's `safe_inspect(reason)` rendered unbounded inside the
structured branch, and the served call is not end-to-end bounded (round
2).** VALIDATED: tier 4 ([error_boundary.ex:211-213](lib/jido_claw/core/mcp_server/error_boundary.ex))
calls `JsonSafe.safe_inspect(reason)` before any budget — `inspect` limits
never bound integer digit rendering, so a foreign exception (verbatim
through exec) carrying a bignum field renders its full decimal a SECOND
time inside `content[1]` production (`content[0]` already renders it — the
pinned byte-identical legacy arm). Resolution: `error_response/2` computes
the legacy render ONCE and threads it in; tier 4's message reuses those
bytes — the structured branch performs no term render beyond the one the
pinned contract already mandates — and the end-to-end guarantee is
narrowed and DECLARED (the reviewer's "declare and narrow" option): the
served call is not resource-bounded against hostile reasons (one full
inspect render + the dep's `:full`-telemetry `to_map` walk always run);
the boundary's own machinery adds only budgeted work on top. The
alternative (static tier-4 message + unpinning legacy/telemetry) is
rejected: `content[0]` byte-identity is the operator-pinned v1.3 contract,
and a static tier-4 message alone buys nothing while content[0] still
renders — reuse is strictly better (same work, real diagnostics for
structured-only consumers).

**P2 — bounded-walker prefix draws ignore the caller's cap (round 1,
VALIDATED both sites).** `encode_bounded/2`'s `:max_key_bytes` is a public,
documented option, but both truncation helpers draw an unconditional
256-byte prefix: [`bounded_key_form/1` (json_safe.ex:636-644)](lib/jido_claw/core/json_safe.ex)
is reached whenever `byte_size(k) > limits.max_key_bytes` (with
`max_key_bytes: 10` and a 20-byte key, `binary_part(k, 0, 256)` raises), and
[`bencode_rendered_key/3` (json_safe.ex:618-628)](lib/jido_claw/core/json_safe.ex)
does the same on inspect-rendered float/pid/ref/port/fun/bitstring keys.
The `try` catches only the budget throw, so the raise escapes the documented
total `bounded_result` contract. Latent (all in-repo callers use the 1024
default), but the option is public and the moduledoc promises totality.

Plus two plan-review finds of the same budget-contract class, both in the
bounded walker's leaf handling (Fix 3): **bignum leaf width is uncharged**
(`bencode_value` passes numbers through with no `spend_bytes`, so
`Jason.encode!` materializes a huge decimal the budget never saw), and
**calendar structs convert BEFORE any charge**
([json_safe.ex:398-405, 492-495](lib/jido_claw/core/json_safe.ex) — the
ISO converter runs inside `guard_leaf` ahead of `spend_bytes`, so a
hand-built `%Date{year: huge_bignum}` renders that integer unbounded, and
a non-ISO `calendar:` field would dispatch arbitrary calendar callbacks
inside the structured branch).

Greenfield: no compat shims, fix in place. Nothing gets committed; work
lands unstaged and folds into the existing #16 suggested commit slicing.

---

## Fix 1 — `error_boundary.ex`: typed `WireError` — reserved wire state split from the extension bag

The internal pipeline stops threading `{code, message, details}` tuples +
an `unregistered?` boolean and threads one struct:

```elixir
# Boundary-internal typed wire error (PD1-2 review round): boundary-owned
# reserved wire state rides dedicated fields; extra_details is the open
# producer extension bag, reserved-key-free by construction. Serialization
# encodes extras through the budgeted walker, then overlays the canonical
# string-keyed reserved fields authoritatively — a producer twin of a
# reserved key can never collide into the walker's sentinel, on any tier.
defmodule WireError do
  @moduledoc false
  defstruct code: nil,
            message: nil,
            retry: nil,
            truncated: nil,
            unregistered_code: nil,
            extra_details: %{}
end
```

nested in the boundary module (`@moduledoc false` — internal). Fields:
`retry :: boolean() | nil` (nil ⇒ absent from the wire),
`truncated :: boolean() | nil` (the producer-side truncation signal —
boundary reduction ORs over it, below), `unregistered_code :: String.t() | nil`
(non-nil ⇔ the registry fallback fired), `extra_details :: map()`.

1. **One build site, every tier** — the unwrap tiers construct WireErrors
   through a single normalize helper:

   ```elixir
   @boundary_owned_keys [
     :unregistered_code, "unregistered_code",
     :original_byte_size, "original_byte_size",
     :observed_at_least, "observed_at_least"
   ]

   defp build_wire_error(code, message, details) do
     details = ensure_map(details)
     {retry, details} = extract_reserved_boolean(details, :retry, "retry")
     {truncated, details} = extract_reserved_boolean(details, :truncated, "truncated")

     details =
       details
       |> Map.drop(@boundary_owned_keys)
       |> canonicalize_extra_keys()

     %WireError{
       code: code,
       message: message,
       retry: retry,
       truncated: truncated,
       extra_details: details
     }
   end
   ```

   - `extract_reserved_boolean/3` (shared by `retry` and `truncated`):
     atom-first lookup (the same precedence `allowlisted_value/3` applies
     and the dep's own `extract_retry_value` uses); a BOOLEAN lifts into
     the typed field; both key forms are ALWAYS dropped from extras; a
     non-boolean value yields `nil` (dropped from the wire on every tier —
     the reduced/minimal tiers' existing `is_boolean` disposition, now
     uniform; the boundary abstains rather than inventing advice).
     Atom-first stops at the atom form even when it holds junk beside a
     boolean string twin — precedence means precedence, matching the
     reduction tiers.
   - `truncated` is TYPED protocol state, not an extras exemption: it is
     both a legitimate producer signal (`Tools.Error.sanitize_details/1`
     emits it) and boundary reduction metadata, so leaving it in the
     extension bag would let `%{:truncated => true, "truncated" => false}`
     hit the collision sentinel and non-booleans squat the protocol key.
     A producer boolean lifts and ships on the full tier; the boundary's
     reduction tiers OR their own `true` over it (the `available_truncated`
     OR-merge precedent — a producer `false` can never mask a real
     boundary reduction, and provenance beyond the OR is deliberately not
     encoded: the wire key means "something in this envelope's details
     was truncated", whoever did it).
   - Boundary-owned keys are stripped unconditionally (both key forms):
     `unregistered_code` (advertised contract: "present exactly when the
     fallback produced it" — now structurally true; today an
     inactive-fallback squatter leaks through the full AND reduced tiers
     but not minimal) and the two size-measurement keys
     `original_byte_size` / `observed_at_least` (documented as boundary
     measurements — "appears ONLY on fully-traversed over-cap values" /
     budget trips — which a full-tier producer squatter could otherwise
     counterfeit).
   - `canonicalize_extra_keys/1`: for the remaining reserved keys that stay
     DATA in the extension bag — the hint allowlist (`field`, `expected`,
     `got`, `available`, `available_truncated`) plus to_map's injected
     `value`/`timeout` — delete the string twin when the atom form is
     present. Fixed list, direct lookups, never a key sweep (`Map.keys/1`
     grouping would walk a hostile-size key list BEFORE `encode_bounded`'s
     O(1) preflights — hostile cardinality stays the walker's problem, as
     designed):

     ```elixir
     @hint_allowlist [
       {:field, "field"}, {:expected, "expected"}, {:got, "got"},
       {:available, "available"}, {:available_truncated, "available_truncated"}
     ]
     @canonical_extra_keys @hint_allowlist ++ [{:value, "value"}, {:timeout, "timeout"}]
     ```

     (the existing `@detail_allowlist` splits: `retry`/`unregistered_code`
     become typed fields; the five hint pairs remain the reduction
     allowlist, still matched in both key forms by `allowlisted_value/3` —
     now unambiguous since twins can't survive the build site.)
   - **Why hint keys stay in extras rather than becoming typed fields**:
     their values are arbitrary-size producer data (`available` can be a
     huge list) that must ride the single envelope walk under ONE budget —
     lifting them would mean a separate bounded pass per field
     (budget-multiplication) for no gain, since nothing injects them after
     canonicalization. Atom-first, not merge provenance, is deliberate:
     provenance would ship one value on the full tier while an over-cap
     reduction's `allowlisted_value` ships the other — the same envelope
     flipping values between tiers.
   - **Uniform tier scope is deliberate** (supersedes round 1's tier-3-only
     draft): tiers 1/2 producer-authored dual forms now canonicalize
     identically instead of sentineling — reserved keys never hit the
     sentinel on ANY tier and never flip values across tiers. Residual
     (document): NON-reserved wire twins (junk atom/string pairs, numeric
     `1` beside `"1"`) keep the walker's documented collision sentinel —
     canonicalizing them would require exactly the unbounded key sweep this
     design refuses, and no contract key lives outside the reserved list.

2. **Tier 3 (native errors)** — keep the `to_map/1` adaptation (the #16 pin
   holds — bounded-work note below), build through the same site, then set
   `retry` authoritatively from the class predicate:

   ```elixir
   mapped = error |> bound_native_message() |> JidoActionError.to_map()

   error
   # retryable?/1 runs on the ORIGINAL error (hints live in its details).
   |> then(fn _ -> build_wire_error(translate_native(mapped.type), mapped.message, mapped.details) end)
   |> Map.put(:retry, JidoActionError.retryable?(error))
   ```

   (sketch — implementation words it as a plain pipeline; the point is:
   `build_wire_error` first, then the struct's `retry` overridden with
   `retryable?(error)` computed on the original error.)

   **`retry` semantics (P1c) — retry-policy eligibility, defined once**:
   the gate is `should_retry?/4` = `retry_count < max_retries` AND
   `Error.retryable?/1` (cap-first, deps retry.ex:72-80). The wire field
   reports the CLASS component — the exact predicate the gate ANDs with
   its attempt budget — as downstream advice: `false` ⇒ **not eligible for
   Jido.Exec's immediate automatic retry under the current failure
   classification; do not blindly repeat without intervention** (NOT a
   determinism claim — a `config_error` is class-`false` yet succeeds
   after an external configuration fix); `true` ⇒ the classification
   treats the failure as transient. It is NEVER a record of whether an
   in-call retry ran or remains available (the boundary only ever sees
   final errors). Producer-pinned `retry: false` envelopes (tiers 1/2)
   carry the same policy-eligibility semantics. `to_map/1`'s own
   `retryable?` field is NOT used — it diverges from the gate's class
   predicate: `to_map(%InternalError{})` hardcodes `false` (deps
   error.ex:387-393) while `retryable?(%InternalError{})` hint-defaults
   `true` (error.ex:465), and `ExecutionFailureError` diverges on the
   `:retryable` details-key spelling `normalize_retryable` reads but
   `retryable?/1` doesn't. The predicate returns a boolean by construction
   — explicit clauses for the six `@native_errors` (error.ex:461-466), and
   key-missing pseudo shapes fall to the total map clauses (468-484).
   Producer hints still win exactly where jido_action honors them — inside
   `retryable?/1`'s own hint-folding (`retryable_hint/2`: explicit hint
   wins over the type default; `InvalidInputError`/`ConfigurationError`/
   `TimeoutError` are type-hardcoded). This supersedes the #16 plan's
   `Map.put_new` pin (Deviations entry), which could both contradict the
   gate's class answer (`%InvalidInputError{details: %{retry: true}}`
   would advertise `true`) and leak non-boolean junk onto the wire.

   **The predicate's own traversal is a documented dep-parity residual**:
   `retryable?/1`'s hint extraction follows nested `details.reason` chains
   with no depth budget (deps error.ex:619-637) — a SINGLE-PATH O(depth)
   walk of `:details`/`:reason` map reads, strictly smaller than
   `to_map/1`'s full-tree transport-sanitizer walk running beside it on
   the same input (which visits that same chain and everything else). A
   bounded boundary-local eligibility reimplementation was considered and
   rejected: it would reintroduce exactly the gate-divergence risk that
   choosing the dep predicate eliminates (the to_map-replacement lesson).
   Tier-3's dep-parity adaptation (`to_map` + `retryable?`) is therefore
   ONE named unbounded-traversal residual; the boundedness claim is scoped
   to the boundary's own machinery and to RENDERING (Fix 3), and the (o)
   promptness row gains a deep-chain input.

   Bare-atom compatibility verified: exec wraps `{:error, Enum}` with
   `details: %{reason: Enum, retry: Error.retryable?(Enum)}` (exec.ex:818-819
   — the wrap EMBEDS the hint), so `retryable?/1` on the wrapped error reads
   that hint → `false`; the existing (b) row's `retry == false` stays green.

   **`bound_native_message/1`** — shallow message projection BEFORE the
   adapter: `to_map`'s `normalize_message` fallback inspects
   non-binary/non-atom messages with `limit: :infinity` (deps
   error.ex:554-556 + sanitizer.ex:48), so a struct smuggling a bignum
   `message` would render its full decimal inside the structured branch:

   ```elixir
   # to_map's message fallback inspects unbounded (limit: :infinity); a
   # non-binary/non-atom message (bignum, composite) would render in full
   # inside the structured branch. Replace ONLY that arm with a static
   # placeholder — binary, atom, nil, and missing messages keep to_map's
   # exact behavior, and the raw message stays visible in content[0]'s
   # pinned legacy inspect. retryable?/1 runs on the ORIGINAL error.
   defp bound_native_message(%{message: m} = error)
        when not is_binary(m) and not is_atom(m) do
     %{error | message: "[unrenderable message]"}
   end

   defp bound_native_message(error), do: error
   ```

   (map-update syntax preserves struct-ness and only fires when `:message`
   exists — key-missing pseudo shapes pass through, preserving to_map's
   missing-message behavior.)

   **Bounded-work note (investigated across rounds; keep `to_map`)**: its
   transport sanitizer walks the details map unbounded (deps
   sanitizer.ex:120-132) — but on this exact path the SAME walk already
   happened upstream: the MCP runtime calls `Jido.Exec.run/3` with no opts,
   telemetry defaults to `:full` (exec.ex:730-733), and the `:full` span's
   stop metadata calls `Error.to_map(error)` on every error result. A
   boundary-side replacement cannot change the call path's complexity — a
   fixed-field re-implementation was drafted and REVERTED (it also broke
   `to_map` parity: keyword/struct details normalization, sanitizer
   pid/ref renders, pseudo-message defaults). Recorded as an inherent
   residual; the boundary's OWN work stays budgeted.

3. **Tier 4 + the shared legacy render (P1d)**: `error_response/2` computes
   `legacy = JsonSafe.safe_inspect(reason)` ONCE; `content[0]` uses it and
   `structured_item(reason, legacy)` threads it through `unwrap/2`; tier 4
   becomes `%WireError{code: :tool_error, message: legacy, extra_details: %{}}`
   — byte-identical to today's tier-4 message by construction (same
   function, same input), with the second render deleted. The structured
   branch now performs NO term render beyond the one the pinned content[0]
   contract already mandates. Tiers 1–3 ignore the threaded text. The
   chaos seam stays first in `structured_item`; `safe_inspect/1` is itself
   total, and it already ran outside the guarded region for content[0] at
   HEAD — no escape-surface change.

4. **`enforce_registry/1`** takes and returns the struct — no map surgery
   (squatters already stripped at the build site):

   ```elixir
   defp enforce_registry(%WireError{code: code} = wire) do
     if ErrorCodes.member?(code) do
       wire
     else
       Logger.warning(...)
       # Stringified BEFORE JsonSafe: module atoms as map values are
       # otherwise dropped. Bounded: atom names cap at 255 chars.
       %{wire | code: :tool_error, unregistered_code: inspect(code)}
     end
   end
   ```

   The `unregistered?` 4-tuple boolean disappears (field non-nil ⇔ fallback
   active).

5. **Serialization: encode extras, overlay reserved — one helper, all
   tiers**:

   ```elixir
   # Reserved wire fields are overlaid AFTER the bounded walk, straight
   # onto encoded string keys — authoritative by construction (a producer
   # twin was stripped at the build site; nothing can collide). Values are
   # bounded: booleans and an inspect-rendered atom (≤ ~262 bytes).
   defp overlay_reserved(encoded_details, %WireError{} = wire) do
     encoded_details
     |> put_if(is_boolean(wire.retry), "retry", wire.retry)
     |> put_if(is_boolean(wire.truncated), "truncated", wire.truncated)
     |> put_if(is_binary(wire.unregistered_code), "unregistered_code", wire.unregistered_code)
   end
   ```

   - **Full tier**: `encode_bounded(%{code: wire.code, message: wire.message,
     details: wire.extra_details})` → on `{:ok, safe, _}`, overlay onto
     `safe["details"]`, then `Jason.encode!` and the 16 KiB check measures
     the POST-overlay JSON (the item as shipped). On `{:budget_exceeded, …}`
     → reduced tier with `observed_at_least` meta, as today.
   - **Reduced tier**: `take_allowlisted/1` now iterates `@hint_allowlist`
     only (five pairs) over `extra_details`, values re-bounded by the
     existing `rebound_values/1` machinery (unchanged: shared 8 KiB budget,
     element-wise `available`, per-field small pass → `"[truncated]"`),
     then `overlay_reserved` and the trunc-meta merge LAST — its
     `"truncated" => true` wins over any producer boolean (the OR: a
     reduction happened, so the wire says truncated regardless).
     `retry`/`truncated`/`unregistered_code` no longer ride
     `bound_retained` — they come from the typed fields (bounded by
     construction).
   - **Minimal tier**: `%{} |> overlay_reserved(wire) |> Map.merge(trunc_meta)`
     — the SAME order as the reduced tier: overlay FIRST, `trunc_meta`
     merged LAST, so its mandatory `"truncated" => true` wins over a
     producer `false` (reaching this tier proves a reduction happened; the
     reverse order would let the producer mask it). `put_retry`,
     `put_unregistered`, and their `allowlisted_value` reads are DELETED.
     This is the reviewer's "reduced/minimal tiers read the typed fields".
   - The static fallback and both non-public server arms are untouched.
   - Wire-visible deltas beyond the fixed collisions (all junk-input-only,
     each pinned by a test): non-boolean `retry`/`truncated` no longer
     ship on the full tier (typed fields abstain); inactive-fallback
     `unregistered_code` squatters no longer ship on full/reduced tiers;
     producer-squatted `original_byte_size`/`observed_at_least` no longer
     ship on any tier (boundary measurements can't be counterfeited),
     while a producer BOOLEAN `truncated` still passes through on the
     full tier (via the typed field). Well-formed envelopes are
     byte-identical (walker charge accounting shifts by the few reserved
     entries no longer walked — no pinned behavior sits within that
     margin).

6. **Moduledoc rewrite**: the tier list's (3) sentence — `to_map/1`
   adaptation kept, `details.retry` set from `Jido.Action.Error.retryable?/1`,
   defined as retry-policy eligibility (the class component the exec gate
   ANDs with its attempt budget; cap-first, so the boundary never sees a
   gate-approved error; not a determinism claim), producer hints honored
   inside the predicate — replaces "via `Map.put_new/3` — an explicit
   producer hint wins". New paragraph for the reserved/extension split:
   typed `WireError`, the single build site (boolean-only extraction for
   `retry` AND `truncated` — the latter a legitimate producer signal the
   boundary's reduction ORs its own `true` over; the boundary-owned key
   strip — `unregistered_code` + `original_byte_size` +
   `observed_at_least`, both forms; fixed-lookup twin canonicalization
   for hint + `value`/`timeout` keys), post-encode authoritative overlay,
   reduced/minimal reading typed fields; non-reserved twins keep the
   walker's sentinel (bounded-work residual).
   Registry paragraph: the fallback sets the typed field; squatters are
   stripped at the build site so the key is present exactly when the
   fallback fired and size measurements can't be counterfeited.
   Tier-4/(4) sentence: message reuses the content[0] legacy render
   (computed once). Residuals paragraph: the narrowed end-to-end
   statement (see Fix 3).

7. **Serve the retry definition to clients** — repo docs alone leave
   remote clients unable to distinguish policy eligibility from an
   executed retry (the exact ambiguity P1c removes), so the definition
   joins the MACHINE-SERVED contract:
   - `error_codes.ex`: a new `@retry_semantics` string + public
     `retry_semantics/0` (@doc/@spec — credo) — all THREE wire states
     defined, absence included (tier 4 ships empty details, and
     missing/non-boolean hints abstain, so omission is a real state a
     client must not guess about): "details.retry is retry-policy
     eligibility: false means the failure class is not eligible for the
     runtime's immediate automatic retry (do not blindly repeat without
     intervention); true means the classification treats it as
     transient; ABSENT means eligibility was not reported — do not infer
     retryability or automatically repeat. It never records whether an
     in-call retry ran or remains available." — and `@stability_sentence`
     gains that sentence (compile-time concat of the same attribute —
     single-sourced), so `server_instructions/0` (mcp_server.ex:110
     delegates) serves it automatically.
   - `resources/bootstrap.ex` `error_contract/0` (~line 87): add
     `"retry_semantics" => ErrorCodes.retry_semantics()` beside the
     existing three wire rules (comment: three → four).
   - Tests: `bootstrap_test.exs`'s error_contract wiring pin (~line 123)
     gains `contract["retry_semantics"] == ErrorCodes.retry_semantics()`
     plus content asserts covering all three states (`=~ "eligibility"`,
     `=~ "never records"`, `=~ "absent"` / "do not infer");
     `error_codes_test.exs` pins `stability_sentence() =~` the same
     three-state definition (the instructions surface).
   - `surface_version.ex`: amend the (unstaged) v1.3 changelog bullet to
     name the served retry-semantics definition — same 1.3 bump, nothing
     has shipped.

## Fix 2 — `lib/jido_claw/core/json_safe.ex`: normalize budget options + clamp prefix draws to the caller's cap

Chosen over "validate and document a minimum": the module's stated contract
is totality, and normalization + clamping keep `bounded_result` total for
every option value while staying **byte-identical at defaults** (both
truncation helpers are only reached when `byte_size > max_key_bytes`, and
`min(256, 1024) = 256`).

1. **Option normalization at both public entry points** (`encode_bounded/2`
   and `fingerprint_projection/2` build their `limits`/`st` from the same
   four options): each of `:max_nodes`/`:max_depth`/`:max_key_bytes`/
   `:max_bytes` is accepted only as a non-negative integer; anything else
   falls back to the pinned module default. Without this, the clamp alone
   is not total — `max_key_bytes: 0.5` survives `min(256, 0.5)` and raises
   in `binary_part/3`, and a non-numeric cap (`:infinity`) defeats the
   over-cap comparison via Erlang term ordering (`20 > :infinity` is
   false), sending an oversized key into the full `String.valid?/1` scan
   the per-key budget exists to prevent. A tiny shared
   `limit_opt(opts, key, default)` helper (integer + `>= 0` guard, else
   default) keeps it one idiom.

2. New private helper (near the other budget primitives):

   ```elixir
   # The tagged/truncated key forms draw at most @invalid_key_prefix_bytes,
   # clamped to the caller's per-key budget and the key's own size — a
   # sub-256 max_key_bytes must keep binary_part in range (the bounded-total
   # contract); junk negative caps floor at zero rather than raise.
   defp prefix_draw(bin, limits) do
     @invalid_key_prefix_bytes
     |> min(limits.max_key_bytes)
     |> min(byte_size(bin))
     |> max(0)
   end
   ```

3. `bencode_rendered_key/3` (~line 618):
   `binary_part(rendered, 0, prefix_draw(rendered, limits))` inside the
   existing over-cap branch (suffix `":trunc-#{byte_size(rendered)}"`
   unchanged). `OutputLimit.valid_utf8_prefix/1` is safe on the empty
   string (verified: `String.valid?("")` short-circuits).

4. `bounded_key_form/1` → **`bounded_key_form/2`**, gaining `limits`;
   `prefix = binary_part(k, 0, prefix_draw(k, limits))`; update its single
   caller ([json_safe.ex:553](lib/jido_claw/core/json_safe.ex)). Both
   branches (valid prefix / tagged Base64) keep their existing suffix forms.

5. **Doc touch-ups**: the `@invalid_key_prefix_bytes` constant comment and
   the `encode_bounded/2` @doc gain the clamp note ("draws are clamped to
   the smaller of the caller's `:max_key_bytes` and 256, and to the key
   size") plus the option-domain note (non-negative integers; junk option
   values fall back to the pinned defaults). `tag_invalid_key/1` (shared
   with the unbounded `encode/1` path) is internally consistent (its own
   ≤ 256 guard) and stays untouched; `bound_identifier/1` and the
   `fproject_*` key path are likewise already safe — **no other
   `binary_part` site in the module is affected** (swept).

## Fix 3 — bounded-walker leaf gaps (bignum width + calendar preflight) + the narrowed end-to-end guarantee

Same budget-contract class as P2: `bencode_value` passes numbers through
UNCHARGED ([json_safe.ex:484-486](lib/jido_claw/core/json_safe.ex)),
`bound_retained/1` charges every number 8 bytes
([error_boundary.ex:388-389](lib/jido_claw/core/mcp_server/error_boundary.ex)),
so an arbitrary-precision integer's full decimal render is materialized by
`Jason.encode!` BEFORE any cap fires — and the calendar clauses convert
before any charge. Targeted fixes, preserving the #16 Deviations'
deliberate IN-RANGE numeric undercount (the minimal-tier test's mechanism —
15-digit ints — survives untouched):

1. **`json_safe.ex`**: split the number leaf clause — integers OUTSIDE the
   existing `@min_exact_int_key`/`@max_exact_int_key` bounds (O(1) magnitude
   guard, already defined) charge
   `2 * max(:erlang.external_size(value) - 8, 0)` via `spend_bytes/3`
   before passing through; in-range integers and floats stay as today.
   **The charge must be a provable LOWER bound of the decimal render,
   because a budget trip reports the accumulated charge as
   `observed_at_least`** — and it must track the render within a SMALL
   CONSTANT FACTOR for moderate bignums too, or aggregates slip: a
   `− 16` header allowance charges `10^30` (external_size 17, 31 digits)
   only 2 bytes, so 40k of them would pass the 128 KiB budget while Jason
   materializes ~1.2 MB. Provable with the tight allowance: both bignum
   external formats carry ≤ 8 header bytes (version + tag + arity + sign;
   LARGE_BIG's 4-byte arity included), so magnitude bytes
   B ≥ external_size − 8, digits ≥ (B−1) × log₁₀256 ≈ 2.408 × (B−1) ≥
   `2 × (external_size − 8)` for external_size ≥ 14, and the smallest
   out-of-range cases hold by hand-check: 8-byte magnitudes
   (external_size 12, charge 8) render 19–21 JSON chars — the global
   worst ratio is `-(2^64 − 1)` at 21/8 = **2.625×** (the ratio strictly
   decreases as magnitudes grow: 9 bytes → 23/10, large bigs → ~1.2×).
   Consequences, stated in a comment + a moduledoc line in the
   bounded-walkers section, scoped precisely: **unbounded-width
   integers** (out of int64 range) receive a lower-bound charge — a
   single huge integer trips the budget BEFORE Jason ever runs (the
   200,000-digit case charges ~166 KB > 128 KiB), anything admitted
   renders at most 2.625× its charge, so total bignum materialization is
   capped at ≤ 2.625× the byte budget (the same small-constant-slip
   class binaries already allow) — and `observed_at_least` never exceeds
   the true observable width. **Finite-width numerics** (floats and
   int64-range integers — each renders ≤ a small constant, ~20–24 bytes)
   deliberately stay byte-uncharged: their materialization is
   NODE-bounded (≤ max_nodes × that constant), the pre-existing
   documented undercount the minimal-tier test relies on.
2. **`error_boundary.ex` `bound_retained/1`**: keep `{value, 8}` for
   booleans/nil/floats/in-range integers; out-of-range integers fall
   through to the existing fresh small bounded JsonSafe pass, whose own
   `@field_pass_bytes` trip yields the constant `"[truncated]"` — bounded
   by construction.

3. **`json_safe.ex` calendar preflight (bounded walker only)**: the three
   calendar clauses ([json_safe.ex:398-405](lib/jido_claw/core/json_safe.ex))
   gain an O(1) fast-path gate before `bencode_calendar/4` — the struct's
   `calendar` field must be exactly `Calendar.ISO` AND its temporal
   integer fields (year/month/day; plus hour/minute/second and both
   microsecond tuple components for the time-bearing structs; plus
   `utc_offset`/`std_offset` for DateTime) must be in-int64-range integers
   (the existing `@min_exact_int_key`/`@max_exact_int_key` guards —
   `Integer.to_string` on an in-range field is ≤ 20 bytes, so the
   ISO render is bounded; `guard_leaf` keeps catching conversion raises
   on residually-invalid shapes). **Anything else falls through to the
   generic struct branch** — `Map.from_struct` + the normal budgeted walk,
   where a bignum `year` is charged by item 1's rule and a non-ISO
   `calendar` module atom is dropped as a map value — so **non-ISO
   calendar callbacks are never invoked by the bounded walker** (they are
   arbitrary user code: unbounded allocation, nontermination — the same
   reasoning as composite-key Inspect). This is a new documented
   `encode_bounded`-vs-`encode/1` divergence (the moduledoc's
   bounded-walker divergence list grows to three: key markers, collision
   sentinel, calendar fast-path — `encode/1` keeps converting arbitrary
   calendars; totality, not bounded work, is its contract). Wire effect:
   well-formed ISO calendar values are byte-identical; hostile/exotic ones
   become structural maps or budget trips instead of renders/dispatches.

**The guarantee, stated honestly (P1d)** — this wording goes in the
moduledoc, the surface page, and the Deviations entry:

- *Boundary-owned machinery — no uncharged UNBOUNDED-WIDTH render*: the
  walkers, reducers, and overlay never render an unbounded-width value
  uncharged — a single huge integer trips the budget before Jason runs,
  admitted out-of-int64 integers render within 2.625× of their charge
  (total bignum materialization ≤ 2.625× the byte budget), finite-width
  numerics (floats, int64 integers) keep the documented node-bounded
  byte undercount (each ≤ a ~24-byte constant render), the calendar
  fast-path gate refuses before conversion, `bound_retained` falls
  through to the small pass, and `bound_native_message` stops `to_map`'s
  `limit: :infinity` MESSAGE inspect. Tier 4's message reuses the ONE
  legacy render; every structured-branch `Jason.encode!` input is
  walker-budget-bounded.
- *Named dep-parity residual (tier 3) — traversal AND rendering*: the
  adaptation runs `to_map/1` — an unbounded full-tree transport-sanitizer
  walk that ALSO renders at `limit: :infinity` in two places: sanitized
  map KEYS (deps sanitizer.ex:125 — for a bignum detail key the render is
  derived as a transient SORT key and discarded; `Map.new` keeps the
  original bignum key, which the walker then maps to its constant
  `"<<key:bigint>>"` marker) and UNSUPPORTED detail values via
  `safe_inspect/1` (sanitizer.ex:118 — e.g. a large non-byte-aligned
  bitstring renders in full, after which the walker byte-charges the
  resulting string) — plus `retryable?/1`'s single-path nested-reason
  hint walk (dominated by the former). Message projection is the one arm
  the boundary CAN bound without parity loss (a static placeholder is
  parity-exact; pre-bounding keys/values would require the unbounded walk
  this design refuses). A replacement for each dep call was considered
  and rejected (parity/gate-divergence).
- *End-to-end, declared*: a public served error call is NOT
  resource-bounded against hostile reasons — `content[0]`'s pinned
  byte-identical legacy inspect renders the term in full (once per call),
  the dep's `:full`-telemetry span runs `Error.to_map/1`'s unbounded
  transport sanitizer on every error result, AND, when error logging is
  enabled, the dep's per-attempt `cond_log_error` renders
  `safe_inspect(error)` with unbounded inspect options on EVERY failed
  attempt (deps telemetry.ex:223-226 — a retried hostile error renders
  once per attempt before the boundary ever runs). All inherent to
  jido_action on this path; a boundary-side replacement was drafted and
  reverted — it cannot change path complexity. The boundary's structured
  machinery adds only budgeted work ON TOP of those pinned/inherent arms;
  the single-render pin ("exactly once") is scoped strictly to boundary
  CONTENT PRODUCTION. Promptness tests are therefore boundary-scoped
  (direct `error_response/2`) by design and say so.

## Regression tests

**`test/jido_claw/core/mcp_server/error_boundary_test.exs`** (existing
harness: scripted tools through `Runtime.handle_tool_call/5`;
`error_response/2` direct where noted):

Retry-semantics rows — assertions framed as *class eligibility + the
call-count proving the gate consulted the same class predicate*:

- *(j)* `{:error, %ExecutionFailureError{message: "boom", details: %{"retry" => false}}}`
  → wire `details["retry"] == false` (the boolean — never
  `"[key-collision]"`), code `"execution_error"`, `Scripts.count(key) == 1`
  (the string hint fed the same predicate the gate consulted — no retry).
- *(j)* `{:error, %InvalidInputError{message: "bad", field: :key, value: "v", details: %{retry: true}}}`
  → wire `details["retry"] == false` and count 1 — the class is
  type-hardcoded non-retryable; hints are honored only where the type
  allows, and the wire matches the gate's class answer, not the stale hint.
- *(j)* `{:error, %ExecutionFailureError{message: "boom", details: %{retry: "junk"}}}`
  → wire `details["retry"] == true` (a BOOLEAN — the predicate's
  `value != false` hint-folding, never the raw junk) and count 2 (the gate
  retried on the same truthy fold).
- *(j) the eligibility pin*: `{:error, %InternalError{message: "boom", details: %{}}}`
  → wire `details["retry"] == true` AND count 2 (under `capture_log`) —
  the class hint-defaults retryable (where `to_map`'s `retryable?` field
  hardcodes `false` — the divergence that forced choosing the predicate);
  the gate retried once BECAUSE of that class answer, then stopped at the
  attempt cap. The wire reports the class, deliberately not the cap.
- *(j) junk abstention (tier 1)*: a canonical envelope
  `%{code: :unknown_skill, message: "m", details: %{retry: "junk"}}` →
  wire details has NO `"retry"` key (boolean-only typed field — junk never
  rides a reserved key on any tier) and count 2 (the gate's own hint-fold
  read `"junk" != false` → retried; the wire abstains rather than
  inventing advice).

Reserved-key split rows:

- *(j) adapter-owned string twins*:
  `{:error, %InvalidInputError{message: "bad", field: :key, value: "v", details: %{"field" => "old", "value" => "old-v"}}}`
  → wire `details["field"] == "key"`, `details["value"] == "v"` (struct
  values — never the sentinel, never the squatted strings); and
  `{:error, %TimeoutError{message: "slow", timeout: 100, details: %{"timeout" => 5}}}`
  → `details["timeout"] == 100` plus `details["retry"] == true` with
  count 2 (type-hardcoded retryable; under `capture_log`).
- *(j) tier-3 dual forms resolve atom-first*:
  `{:error, %InvalidInputError{message: "bad", field: nil, value: nil, details: %{:field => "atom", "field" => "string"}}}`
  → wire `details["field"] == "atom"` — never the sentinel.
- *(a-class) tier-2 uniform-scope pin (direct `error_response/2` — through
  the runtime, exec wraps a raw map into `ExecutionFailureError` at
  exec.ex:781-785 and it becomes a TIER-1 case; only a direct call
  exercises the raw-map tier-2 branch)*:
  `ErrorBoundary.error_response(%{code: :unknown_skill, message: "m", details: %{:field => "atom", "field" => "string"}}, @public)`
  → wire `details["field"] == "atom"` — the build site canonicalizes every
  tier, not just to_map output.
- *(a-class) dual-form retry, both tiers*: through the RUNTIME (a tier-1
  case after the exec wrap):
  `%{code: :unknown_skill, message: "m", details: %{:retry => false, "retry" => true}}`
  → wire `details["retry"] == false` (typed extraction, atom precedence)
  and count 1 (the dep's `extract_retry_value` read the same atom-first
  hint); plus the same envelope via direct `error_response/2` (the
  tier-2 branch) → wire `details["retry"] == false`.
- *(j) partial pseudo-struct shape*:
  `{:error, %{__struct__: InvalidInputError, __exception__: true, message: "bad", field: :key, details: %{"field" => "old"}}}`
  (no `:value` key → to_map's PSEUDO clause merges `field: :key` beside the
  preserved `"field"` string key) → wire `details["field"] == "key"`,
  never the sentinel, never `"old"`; plus `details["retry"] == false`
  (`retryable?/1`'s `%InvalidInputError{}` clause pattern-matches pseudo
  shapes too). Exact wire `code` confirmed at implementation time from
  to_map's type derivation.
- *(j) string-keyed top-level field via the pseudo merge (tier-consistency
  pin)*: all-`=>` form —
  `{:error, %{:__struct__ => InvalidInputError, :__exception__ => true, :message => "bad", "field" => "top", :details => %{field: "base"}}}`
  (pseudo merge yields `%{:field => "base", "field" => "top"}`) → wire
  `details["field"] == "base"` — atom precedence, the same value an
  over-cap reduction retains, so values never flip between tiers.
- *(j) non-reserved twins keep the sentinel (bounded-work residual pin)*: a
  native error with `details: %{1 => "a", "1" => "b"}` (wire key `"1"` is
  NOT reserved) → `details["1"] == "[key-collision]"` — canonicalization is
  fixed-lookup-bounded, reserved keys only.
- *(b)/(n) squatter under the fallback*:
  `%{code: :zorb_squat, message: "m", details: %{"unregistered_code" => "squatter", retry: false}}`
  → `details["unregistered_code"] == ":zorb_squat"` (authoritative
  overlay — never the sentinel, never `"squatter"`) and
  `details["retry"] == false`, under `capture_log`.
- *(b-class) squatter WITHOUT the fallback*: a REGISTERED envelope
  `%{code: :unknown_skill, message: "m", details: %{"unregistered_code" => "squatter"}}`
  → wire details LACKS `"unregistered_code"` entirely — the key is present
  exactly when the fallback fired, now structurally.
- *(b-class) size-metadata squatters*: a registered full-tier envelope with
  `details: %{"original_byte_size" => 5, observed_at_least: 7, truncated: true, skill: "s"}`
  → wire details LACKS `"original_byte_size"` and `"observed_at_least"`
  (boundary measurements can't be counterfeited — both key forms
  stripped at the build site) while `"truncated" => true` and the skill
  pass through (a producer's own `Tools.Error.sanitize_details/1`
  truncation signal is legitimate — lifted through the typed field).
- *(b-class) truncated dual form + junk (the typed-field pin)*: a
  registered envelope with
  `details: %{:truncated => true, "truncated" => false, skill: "s"}` →
  wire `details["truncated"] == true` (atom-first boolean extraction —
  never `"[key-collision]"` on the protocol key); and
  `details: %{truncated: "junk"}` → wire details has NO `"truncated"` key
  (non-boolean junk never squats typed state).
- *(k)-class — the truncation OR on forced reduction*: the existing
  minimal-tier forcing shape (wide-number structures + oversized filler)
  with `truncated: false` added to the producer details → the minimal
  envelope's `details["truncated"] == true` — a producer `false` can
  never mask the boundary's mandatory reduction signal (`trunc_meta`
  merges last on BOTH reduction tiers); an over-cap (reduced-tier)
  variant with producer `truncated: false` likewise reads `true`.

Tier-4 / shared-render rows (P1d):

- *(j) small foreign exception through the RUNTIME*: a scripted tool
  returns `{:error, %RuntimeError{message: "kaboom"}}` (foreign exception —
  verbatim through exec, not in `@native_errors` → tier 4) → `content[1]`
  decodes with code `"tool_error"` and `message` EXACTLY equal to
  `content[0]`'s text (the shared-render pin), `details == %{}` bar nothing.
- *(j) the single-render COUNTER pin*: text equality and timing bounds
  would also pass under a second render, so the removal is locked
  directly — a `HostileInspect.Counting` fixture joins
  `test/support/hostile_inspect.ex` (protocols consolidate in test env;
  the support-tree impls are the ones that dispatch): a struct carrying an
  `:atomics` ref in a field whose `Inspect` impl increments it and returns
  constant valid text. Drive `error_response(%Counting{ref: ref}, @public)`
  (non-exception, non-envelope → tier 4) → both content items present,
  `content[1]` decodes to `tool_error` with the counted text as message,
  and `:atomics.get(ref, 1) == 1` — the reason was inspected EXACTLY once
  across both items (nothing else on the path dispatches value Inspect:
  the walker's struct branch is `Map.from_struct`, and the reason itself
  never enters the walker on tier 4).
- *(o) bignum-bearing foreign exception (direct `error_response/2`,
  deliberately NOT the runtime)*: a test-local
  `defexception [:message, :big]` with binary message and
  `big: Integer.pow(10, 200_000)` → a decodable dual-content reply within
  the existing 5s (o)-row bound; `content[1]`'s code is `"tool_error"`,
  its (reduced-tier) message is a prefix of `content[0]`'s text ending
  `"... (truncated)"` — ONE render, reused, then budget-tripped into the
  reduced tier. Driven directly because the runtime path would ALSO
  render the decimal once per attempt via the dep's `cond_log_error`
  (retryable class → two attempts → two log renders) plus the telemetry
  `to_map` walk — the named upstream residuals the row's comment cites;
  the boundary-scoped drive is what the guarantee actually claims.

Bignum-bounds rows (Fix 3, structured-branch scope):

- *(k)/(o)*: `%{retry: false, expected: Integer.pow(10, 200_000)}` through
  `error_response/2` → decodable `content[1]` with
  `details["expected"] == "[truncated]"` and `retry` intact, produced
  promptly (`:timer.tc` like the existing (o) rows) — the boundary's own
  machinery never renders the decimal uncharged (`content[0]` renders it
  once — the declared residual).
- *(j) native huge-integer detail KEY (the tier-3 dep-parity rendering
  residual, pinned)*: `%ExecutionFailureError{message: "boom", details: %{Integer.pow(10, 200_000) => "v", retry: false}}`
  via `error_response/2` → a decodable reply, promptly, with wire
  `details["<<key:bigint>>"] == "v"` and `retry` intact — `to_map`'s
  sanitizer renders the key once at `limit: :infinity` solely as a
  transient SORT key and discards it (deps sanitizer.ex:123-130;
  `Map.new` retains the original bignum key), so the walker receives the
  bignum and emits its constant marker — the unbounded render is the
  dep's, exactly once, and the boundary side stays O(1).
- *(j) native unsupported detail VALUE (the sanitizer's other
  `limit: :infinity` render, pinned)*: `%ExecutionFailureError{message: "boom", details: %{blob: <<0::size(1_048_577)>>, retry: false}}`
  (a large non-byte-aligned bitstring — an unsupported sanitizer class)
  via `error_response/2` → a decodable reply, promptly, `retry` intact —
  `to_map`'s sanitizer `safe_inspect`s the value in full
  (sanitizer.ex:118, the named residual), after which the walker
  byte-charges the resulting string and budget-trips into the reduced
  tier.
- *(j) huge non-binary native message*:
  `%ExecutionFailureError{message: Integer.pow(10, 200_000), details: %{retry: false}}`
  through `error_response/2` → `content[1]` decodes with
  `message == "[unrenderable message]"` and `details["retry"] == false`,
  promptly — the projection fires before `to_map`'s `limit: :infinity`
  inspect; a binary-message control keeps its exact text.
- *(o) native-error promptness (boundary-scoped, and says so)*: a native
  `ExecutionFailureError` whose details carry 30 scalar keys plus
  `zzz: Enum.to_list(1..500_000)`, via `error_response/2` → decodable
  dual-content within the 5s bound; a second input nests a 100_000-deep
  `%{reason: %{reason: …}}` chain in details (exercising BOTH dep
  traversals the residual names — `retryable?/1`'s hint walk and
  `to_map`'s sanitizer — plus the walker's depth trip) → decodable
  promptly. Comment pins the scope: on the runtime path the dep's
  `:full`-telemetry span walks the same reason unbounded upstream
  regardless — the rows prove the boundary adds no unbounded work of its
  own beyond the named tier-3 dep-parity residual.
- *(o) hostile calendar values (Fix 3 item 3, boundary level; direct
  `error_response/2`)*: a canonical envelope whose details carry
  `%{when: %{__struct__: Date, calendar: Calendar.ISO, year: Integer.pow(10, 200_000), month: 1, day: 1}}`
  → a decodable reduced envelope, promptly — the fast-path gate refuses,
  the generic walk charges the bignum year, the budget trips; the decimal
  is never rendered by the boundary's own machinery.

**`test/jido_claw/core/json_safe_test.exs`**:

- Fix 2 (in the budget-contract describe): one test, four assertions, all
  pinning `{:ok, …}` (never a raise) under small caps — 20-byte valid key
  with `max_key_bytes: 10` → `"kkkkkkkkkk:trunc-20"`; 20-byte invalid key
  (`:binary.copy(<<255>>, 20)`) with `max_key_bytes: 10` → tagged
  `"<<invalid-utf8:…:trunc-20>>"`; pid key with `max_key_bytes: 4` →
  rendered-key clamp, key matches `~r/:trunc-\d+$/`; `max_key_bytes: 0`
  edge → still `{:ok, …}` (draw floors at the empty prefix). Plus a
  junk-option row: the SAME oversized-key input under
  `max_key_bytes: 0.5` and `max_key_bytes: :infinity` returns exactly the
  default-option result (`{:ok, …}` with the default-cap tagged form —
  junk budget options normalize to the pinned defaults; no raise, no
  full-key scan).
- Fix 3: `encode_bounded(%{big: Integer.pow(10, 200_000)})` →
  `{:budget_exceeded, %{observed_at_least: n}}` with `n <= 200_001` (the
  lower-bound contract holds — the charge never exceeds the actual decimal
  width); `encode_bounded(%{n: 12345})` still returns the number
  uncharged-exact; a BELOW-THRESHOLD bignum `%{m: Integer.pow(10, 30)}` →
  `{:ok, value-unchanged, bytes}` with `bytes >= 18` (2 × (17 − 8) — the
  moderate case is genuinely charged, not near-zero); the NEGATIVE
  threshold `%{t: -9_223_372_036_854_775_809}` (first out-of-range
  negative, charge 8) → `{:ok, value-unchanged, bytes}` with `bytes >= 8`;
  the WORST-RATIO case `%{w: -(Integer.pow(2, 64) - 1)}` (8-byte
  magnitude, external_size 12, charge 8 vs a 21-char JSON render —
  exactly the documented 2.625× slip cap) → `{:ok, value-unchanged, bytes}`
  with `bytes >= 8`; an AGGREGATE of 40_000 × `Integer.pow(10, 30)` in a
  list → `{:budget_exceeded, …}` under the DEFAULT budget (≈ 720 KB
  charged > 128 KiB — the aggregate-slip regression the `− 16` allowance
  would have passed straight to Jason).
- Fix 3 calendar rows: a well-formed `Date`/`DateTime` control keeps its
  byte-identical ISO-8601 string; a hostile-year
  `%{__struct__: Date, calendar: Calendar.ISO, year: Integer.pow(10, 200_000), month: 1, day: 1}`
  → `{:budget_exceeded, …}` under the default budget (charged via the
  generic walk + the bignum rule — never rendered), promptly; a
  custom-calendar `%{__struct__: Date, calendar: NotACalendar, year: 1, month: 1, day: 1}`
  (the module defines NO calendar callbacks) → `{:ok, …}` with the
  STRUCTURAL map shape — proof by construction that no callback was
  dispatched (a conversion attempt would have raised into `guard_leaf`'s
  `"[unencodable]"`, which the assertion excludes).

## Docs + reconciliation (same change)

- **`docs/system/mcp-server-surface.md`**:
  - Rewrite the native-adaptation bullet (~line 90): `details.retry` is
    **retry-policy eligibility** via `Jido.Action.Error.retryable?/1` —
    the class component the exec gate ANDs with its attempt budget
    (cap-first; the boundary only sees finally-refused errors), producer
    hints honored inside the predicate; `false` means "not eligible for
    the immediate automatic retry under the current classification — do
    not blindly repeat without intervention", never a determinism claim
    and never a record of in-call retry execution — and the definition is
    SERVED (bootstrap `error_contract.retry_semantics` + the
    `server_instructions` stability sentence), not repo-docs-only.
  - New reserved/extension sentence(s): the boundary's typed `WireError`
    split — reserved wire state (`retry`, `truncated`,
    `unregistered_code`) as typed fields overlaid authoritatively
    post-encode (`truncated` lifts the legitimate
    `Tools.Error.sanitize_details/1` producer boolean and the boundary's
    reduction ORs its own `true` over it); boundary-owned keys
    (`unregistered_code`, `original_byte_size`, `observed_at_least` —
    both key forms) stripped from producer details at the build site so
    boundary measurements can't be counterfeited; hint + `value`/`timeout`
    twins canonicalized atom-first by fixed direct lookups at one build
    site, every tier; reduced/minimal tiers read the typed fields;
    reserved keys never hit the collision sentinel and never flip values
    between tiers; non-reserved twins keep the walker's sentinel
    (bounded-work residual).
  - Registry-fallback bullet (~lines 56-58): squatters stripped at the
    build site; the key is present exactly when the fallback fired.
  - "Bounded" paragraph: the bignum width charge (out-of-int64 integers
    charge `2 × max(external_size − 8, 0)` — a provable LOWER bound of the
    decimal render preserving `observed_at_least`'s contract, tight enough
    that a single huge integer trips before Jason and admitted
    unbounded-width values render within 2.625× of their charge — total
    bignum materialization ≤ 2.625× the byte budget; finite-width numerics
    keep the documented node-bounded undercount), the calendar fast-path
    gate (ISO-only, in-int64 temporal fields; anything else takes the
    generic budgeted struct walk — non-ISO calendar callbacks never
    dispatch), and tier 4's message reusing the single legacy render.
  - Residuals: the narrowed end-to-end statement from Fix 3 verbatim in
    spirit — the dep's `:full`-telemetry `to_map` walk upstream (inherent;
    replacement drafted and reverted); tier 3's dep-parity adaptation
    running the same `to_map` — an unbounded traversal that ALSO renders
    at `limit: :infinity` twice over: detail KEYS as transient sort keys
    (discarded — a bignum key reaches the walker intact and takes the
    constant `<<key:bigint>>` marker) and UNSUPPORTED detail values via
    `safe_inspect` (the walker then byte-charges the resulting string) —
    plus `retryable?/1`'s single-path nested-reason hint walk (dominated
    by the former); the dep's per-attempt `cond_log_error`
    rendering `safe_inspect(error)` unbounded on every failed attempt when
    error logging is enabled; and `content[0]`'s pinned legacy inspect
    rendering hostile terms in full once per call (shared by tier 4's
    message; the structured machinery adds only budgeted work, and the
    single-render pin is scoped to boundary content production) — the
    served error call is NOT end-to-end resource-bounded, and the
    promptness tests are boundary-scoped by design.
  - Add `lib/jido_claw/core/json_safe.ex` and
    `test/jido_claw/core/json_safe_test.exs` to BOTH the frontmatter
    `sources:` list and `## Source map` (the page documents JsonSafe's
    bounded-error guarantees; the sources list is the doc-reconcile scope).
  - `verified: 2026-07-13` is current; **`verified_sha` must be refreshed
    to the actual HEAD** (currently `fdf361b4`, not the stale `86442901` —
    re-derive with `git rev-parse --short HEAD` at implementation time).
- **`docs/plans/pre-argus-wave-e-16/README.md`** `## Deviations` — four
  entries in the established format:
  1. `**Post-review round: reserved wire state split from the extension
     bag (typed WireError)** (forced; 2026-07-13)` — the collision class
     (both sites), why a canonicalization table was insufficient (round-2
     architecture finding: every future reserved field would need three
     synchronized edits), the split (typed fields + post-encode overlay +
     single build site with boolean-only extraction for `retry` and
     `truncated` — the latter lifting the legitimate producer signal,
     boundary reduction OR-ing its `true` over it — the boundary-owned
     key strip (`unregistered_code` plus the
     `original_byte_size`/`observed_at_least` measurement keys, both
     forms), and fixed-lookup twin canonicalization for
     hint/`value`/`timeout` keys, uniform across tiers 1–3),
     reduced/minimal reading typed fields, the junk-input-only wire
     deltas, and the non-reserved-twin sentinel residual. Flags the ONE superseded #16 pin: §3's `Map.put_new` merge
     replaced by `retry: Error.retryable?(error)`; also records the
     investigated-and-kept `to_map` pin (fixed-field replacement drafted
     and REVERTED — the dep's default `:full`-telemetry span runs the same
     unbounded walk upstream; parity broke).
  2. `**Post-review round: details.retry defined as retry-policy
     eligibility** (forced; 2026-07-13)` — the gate is cap-first
     (retry.ex:72-80), so "reports what the gate did" was incoherent; the
     field now documents the class component the gate ANDs with its
     budget, as downstream advice ("not eligible for the immediate
     automatic retry under the current classification" — deliberately not
     a determinism claim; a class-`false` `config_error` can succeed
     after external intervention); the definition SERVED to clients via
     `ErrorCodes.retry_semantics/0` — a new `error_contract.retry_semantics`
     bootstrap key and the extended stability sentence riding
     `server_instructions` (single-sourced; v1.3 changelog bullet
     amended); assertions unchanged, framing + moduledoc + surface page
     rewritten; `to_map.retryable?` divergences recorded; `retryable?/1`'s
     own unbounded nested-reason hint walk folded into the tier-3
     dep-parity traversal residual (a bounded local reimplementation
     rejected — gate-divergence risk).
  3. `**Post-review round: budget options normalized; key-prefix draws
     clamped under caller max_key_bytes** (forced; 2026-07-13)` — what
     the review found (sub-256 integer caps raised in `binary_part`;
     float caps survived the clamp's `min/2` and still raised; non-numeric
     caps defeated the over-cap comparison via term ordering, permitting
     the full-key validity scan), the two mechanisms (non-negative-integer
     option normalization at both public entry points, junk → pinned
     defaults; the prefix draw clamped to the caller's cap and the key
     size), defaults byte-identical.
  4. `**Post-review round: bounded-walker leaf gaps closed (bignum width,
     calendar preflight); tier-4 reuses the single legacy render;
     end-to-end boundedness declared, not claimed** (forced; 2026-07-13)`
     — the uncharged-bignum mechanism + the tight lower-bound charge
     (`2 × max(external_size − 8, 0)`: a single huge integer trips before
     Jason, admitted out-of-int64 values render within 2.625× of charge —
     `-(2^64 − 1)` is the worst ratio, 21 chars on an 8-byte charge —
     while the `− 16` draft was rejected in review because moderate
     bignums charged near-zero and aggregates slipped ~15× past the
     budget;
     finite-width numerics keep the node-bounded undercount);
     `bound_native_message`; the calendar fast-path gate (ISO-only +
     in-int64 temporal fields, else the generic budgeted struct walk —
     non-ISO calendar callbacks never dispatch; a new documented
     `encode_bounded`-vs-`encode/1` divergence); tier 4's second
     unbounded render deleted by threading content[0]'s bytes (pinned by
     the counting-Inspect row — exactly one render, scoped to boundary
     content production); the narrowed guarantee (boundary machinery
     never renders unbounded-width values uncharged; tier-3 dep-parity
     `to_map` named as a traversal-AND-rendering residual — transient
     sort-key renders for keys, `safe_inspect` for unsupported values —
     beside `retryable?/1`'s hint walk; the call itself unbounded via
     the pinned legacy arm, dep telemetry, and per-attempt dep error
     logging — the reviewer's declare-and-narrow option chosen over
     unpinning the v1.3 content[0] byte-identity contract); the IN-RANGE
     numeric undercount deviation stands.
- No AGENTS.md change (its bullet's "dual-content structured envelope"
  wording remains true; the to_map adaptation held). No `loop-guard.md`
  change (`fingerprint_projection`'s key path never calls the affected
  helpers).

## Verification

1. Targeted first:
   `mise exec -- mix test test/jido_claw/core/mcp_server/error_boundary_test.exs test/jido_claw/core/json_safe_test.exs`
   — new rows green, zero regressions in the existing tiers/budget/chaos
   rows (the WireError refactor must keep every existing wire assertion
   byte-for-byte).
2. **Final bar**: `mise exec -- mix precommit` — bare (never piped), run in
   background, read the tail; iterate to green. Known-flaky singleton
   suites (MCPServer, Prompt, PipelineStore, MultiSandbox) verified in
   ISOLATION before blaming this change. Docs gates ride precommit
   (`system_docs.check`; `jido_md.check` expected no-op — no skill/tool
   surface touched). Precommit-gotcha watch items: nested `WireError` gets
   `@moduledoc false`; no comment line may start with the word "step"
   (ExSlop); the atom-first cond idiom repeats across
   `allowlisted_value`/`extract_reserved_retry` — if ExDNA flags the pair,
   reshape the new helper rather than pragma.

## Files to stage (fold into the existing #16 commit-2 slice; nothing committed by the agent)

- `lib/jido_claw/core/mcp_server/error_boundary.ex`
- `lib/jido_claw/core/json_safe.ex`
- `lib/jido_claw/core/mcp_server/error_codes.ex` (`retry_semantics/0` + the
  extended stability sentence)
- `lib/jido_claw/core/mcp_server/resources/bootstrap.ex` (the
  `retry_semantics` error-contract key)
- `lib/jido_claw/core/mcp_server/surface_version.ex` (v1.3 changelog bullet
  amended)
- `test/jido_claw/core/mcp_server/error_boundary_test.exs`
- `test/jido_claw/core/json_safe_test.exs`
- `test/jido_claw/core/mcp_server/resources/bootstrap_test.exs` (the
  `retry_semantics` wiring pin)
- `test/jido_claw/core/mcp_server/error_codes_test.exs` (the stability
  sentence pin)
- `test/support/hostile_inspect.ex` (the `Counting` single-render fixture)
- `docs/system/mcp-server-surface.md`
- `docs/plans/pre-argus-wave-e-16/README.md`

Suggested commit slicing is unchanged from the #16 plan (these fixes ride
commit 2, `feat: served-MCP structured error contract + code registry
(PD1-2)`).
