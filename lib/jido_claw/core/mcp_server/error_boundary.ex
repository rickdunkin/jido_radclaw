defmodule JidoClaw.MCPServer.ErrorBoundary do
  # The {code, message, details} map is the LLM-facing wire-error contract
  # (shared with JidoClaw.Tools.Error) — an explicit API surface, not
  # incidental duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  The served-MCP wire error boundary (pad PD1-2): renders every
  `Jido.Exec.run/3` error arm of the patched `Jido.MCP.Server.Runtime` into
  a tool error response.

  **Scoped, not global**: only the PUBLIC server (`JidoClaw.MCPServer`) gets
  the structured, registry-enforced shape; every other server riding the
  same runtime (the memory consolidator's MCP server, the Forge deposit
  server) keeps the byte-identical legacy single-item
  `Response.error(inspect(reason))` arm — raw-inspect raise path included.

  **Additive wire shape** (surface v1.3, MINOR): `content[0]` keeps the
  legacy inspect text byte-identical (rendered via `JsonSafe.safe_inspect/1`
  — same bytes whenever `inspect/1` succeeds with valid UTF-8; hostile
  `Inspect` impls degrade to a static placeholder instead of aborting the
  arm); `content[1]` — the second content item of the RAW error response;
  downstream relays may append further items — carries the canonical JSON
  envelope `{"code","message","details"}`.

  **Typed reserved wire state (`WireError`)**: boundary-owned protocol state
  rides dedicated struct fields — `retry`, `truncated`, `unregistered_code`
  — while `extra_details` is the producers' open extension bag,
  reserved-key-free by construction. One build site (`build_wire_error/3`)
  serves every tier: boolean-only extraction lifts `retry` and `truncated`
  (atom form first, both key forms always dropped; a non-boolean value
  yields an ABSENT wire key on every tier — the boundary abstains rather
  than inventing advice; `truncated` is a legitimate producer signal —
  `Tools.Error.sanitize_details/1` emits it — and the reduction tiers OR
  their own `true` over it, so a producer `false` can never mask a real
  boundary reduction); boundary-owned keys are stripped unconditionally in
  both key forms (`unregistered_code` plus the measurement keys
  `original_byte_size`/`observed_at_least` — a squatter can never
  counterfeit the fallback or the boundary's size metadata); the remaining
  reserved DATA keys (the hint allowlist plus to_map's `value`/`timeout`)
  canonicalize atom-first by fixed direct lookups, never a key sweep.
  Serialization encodes `extra_details` through the budgeted walker, then
  overlays the canonical string-keyed reserved fields authoritatively — a
  producer twin of a reserved key can never collide into the walker's
  sentinel on any tier, and reserved values never flip between tiers.
  NON-reserved wire twins (junk atom/string pairs, numeric `1` beside
  `"1"`) keep the walker's documented collision sentinel: canonicalizing
  them would take exactly the unbounded key sweep this design refuses, and
  no contract key lives outside the reserved list.

  **Unwrap tiers, pinned order**: (1) the exact `Jido.Exec` wrap of a
  canonical envelope — WITNESSED, never shape-inferred: the forked exec
  (`lib/jido_claw/core/jido_exec_patch.ex`, port map
  `docs/exploration/pms/pad/PORT-PD1-2-EXEC.md`) stamps an opt-provided
  per-call reference into the wrap's details (`Map.put_new` under
  `:__jido_claw_exec_wrapped__`), stamped ONLY when the pre-wrap term
  matched the raw envelope contract (non-struct map, atom code, binary
  message, map details — exactly tier 2's guard; an exec wrap of anything
  else, including a colliding non-exception struct whose fields extract to
  the same details shape, stays unstamped and native). The opt rides only
  the public runtime path (`mint_wrap_token/1` + `exec_opts/1`); the
  boundary detaches the marker on exact ref identity BEFORE the legacy
  render, and tier 1 REQUIRES the witness. Shape alone no longer selects
  tier 1 — pre-fix, any `ExecutionFailureError` whose unrestricted details
  happened to carry `:code`+`:details` mis-tiered here, and no shape
  refinement could close that (the wrap is lossy; post-wrap a canonical
  envelope and a shape-colliding native are byte-identical). An unmarked or
  forged-marker collision now falls to tier 3 (`execution_error`,
  authoritative retry — mis-tier DOWN, the safe direction);
  (2) a raw `%{code, message, details}` envelope map — token-free by
  design, a raw map cannot be a native error; (3) the
  six native jido_action typed errors adapted through
  `Jido.Action.Error.to_map/1`, with `details.retry` set from
  `Jido.Action.Error.retryable?/1` on the ORIGINAL error —
  **retry-policy ELIGIBILITY**, the exact class component the exec gate
  ANDs with its attempt budget (`should_retry?/4` is cap-first, so the
  boundary only ever sees finally-refused errors; the field is downstream
  advice — `false` ⇒ not eligible for Jido.Exec's immediate automatic
  retry under the current failure classification, do not blindly repeat
  without intervention — never a record of in-call retry execution, and
  deliberately not a determinism claim: a class-`false` `config_error` can
  succeed after an external configuration fix). Producer hints are honored
  exactly where the predicate honors them (its own hint-folding;
  `InvalidInputError`/`ConfigurationError`/`TimeoutError` are
  type-hardcoded). `to_map/1`'s separate `retryable?` field is NOT used —
  it diverges from the gate's predicate (`InternalError` hardcodes `false`
  where the predicate hint-defaults `true`). Non-binary/non-atom native
  MESSAGES project to a static placeholder BEFORE `to_map/1`
  (`bound_native_message/1` — the dep's message fallback inspects at
  `limit: :infinity`); `:configuration_error` translates to the registry's
  `:config_error`. (4) everything else → `tool_error`, message REUSING the
  `content[0]` legacy render (computed once in `error_response/2` and
  threaded through — the structured branch performs no term render beyond
  the one the pinned contract already mandates). Tier (1) must precede (3)
  or our envelopes would collapse to a generic `execution_error`.

  **Registry enforcement**: an unregistered code is re-coded to
  `:tool_error` with the typed `unregistered_code` field carrying the
  original (stringified via `inspect/1` BEFORE JsonSafe — module atoms as
  map values are otherwise dropped; bounded — atom names cap at 255
  chars), plus a drift log. Producer squatters were stripped at the build
  site, so the wire key is present EXACTLY when the fallback fired. This
  fallback is the registry's closure proof.

  **Bounded (boundary machinery)**: the extension bag normalizes through
  the budgeted `JsonSafe.encode_bounded/2` (never the unbounded
  `encode/1`), and the encoded JSON — reserved fields overlaid, the item
  as shipped — is capped at 16 KiB. Over-cap or budget-tripped envelopes
  reduce to the fixed hint allowlist (`field`, `expected`, `got`,
  `available`, `available_truncated` — atom and string key forms), each
  retained value re-bounded (strings via the 2 KB UTF-8-safe truncator;
  out-of-int64-range integers and other values via a fresh small bounded
  JsonSafe pass whose own trip yields the constant `"[truncated]"`); a
  reduction still over the cap falls to the minimal envelope (code +
  truncated message + truncation metadata + the reserved overlay). The
  reduced/minimal tiers read the TYPED fields — machine-readable code and
  the reserved wire state survive every tier. The boundary's walkers,
  reducers, and overlay never render an unbounded-width value uncharged
  (JsonSafe's bignum width charge + calendar fast-path gate do the leaf
  work), and tier 4's message reuses the ONE legacy render — every
  structured-branch `Jason.encode!` input is walker-budget-bounded.

  **Never escalates**: the entire structured-item production sits in one
  rescue+catch guarded region (a hostile `Inspect` impl can throw or exit,
  which escapes `rescue` alone); any escape yields a fully static ASCII
  envelope carrying `"retry": false` — a serializer bug can never turn a
  tool error into a JSON-RPC failure, and a deterministic serialization
  failure must not read as retryable. The guarantee is provable end-to-end
  via the `:error_boundary_chaos` app-env seam, compiled only in
  MIX_ENV=test — production builds carry a constant no-op.

  **Boundedness scope, declared**: a public served error call is NOT
  resource-bounded end-to-end against hostile reasons. `content[0]`'s
  pinned byte-identical legacy inspect renders the term in full (once per
  call — tier 4's message shares those bytes); the dep's default
  `:full`-telemetry span runs `Error.to_map/1`'s unbounded transport
  sanitizer on every error result upstream; with error logging enabled the
  dep's per-attempt `cond_log_error` renders `safe_inspect(error)`
  unbounded on every failed attempt; and tier 3's dep-parity adaptation
  runs the same `to_map/1` — an unbounded traversal that ALSO renders at
  `limit: :infinity` twice over (detail KEYS as transient sort keys,
  discarded — a bignum key reaches the walker intact and takes its
  constant marker — and UNSUPPORTED detail values via the sanitizer's
  `safe_inspect`, after which the walker byte-charges the resulting
  string) — plus `retryable?/1`'s single-path nested-reason hint walk
  (dominated by the former). All inherent to jido_action on this path (a
  boundary-side replacement was drafted and reverted — it cannot change
  path complexity, and it broke to_map parity). The boundary's own
  machinery adds only budgeted work ON TOP of those pinned/inherent arms;
  the single-render pin is scoped strictly to boundary CONTENT PRODUCTION,
  and the promptness tests are boundary-scoped by design.

  **Wrap-provenance residuals**: the marker key rides the boundary-owned
  list in both key forms — stripped from wire details on every tier, so a
  producer squatter never rides the wire (its junk value DOES stay in
  `content[0]`'s legacy render: `Map.put_new` left the delivered term
  byte-identical to the unpatched world, and `content[0]` stays faithful to
  it). Enabled Jido compensation would nest a marked error inside a NEW
  unmarked `ExecutionFailureError` beyond detach's reach — unreachable
  today because compensation is opt-in ACTION METADATA and no published
  tool enables it (`use Jido.Action` defines a default `on_error/4` for
  EVERY action, so the callback's existence is NOT the gate;
  `Jido.Exec.Compensation.enabled?/1` reading the action's compensation
  metadata is) — pinned by the served-inventory guard test. And the marker
  is inert to the exec retry gate: `retryable?/1`'s hint walk reads only
  `retry`/`reason` keys, so marked and unmarked wraps classify identically.

  Contract scope: TOOL-RESULT errors only — unknown tools, authorization
  refusals, and escaped runtime failures remain plain JSON-RPC protocol
  errors with no envelope (see `JidoClaw.MCPServer.ErrorCodes` and
  `docs/system/mcp-server-surface.md`).
  """

  require Logger

  alias Anubis.Server.Response
  alias Jido.Action.Error, as: JidoActionError
  alias Jido.Action.Error.ExecutionFailureError
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.MCPServer.ErrorCodes
  alias JidoClaw.Tools.OutputLimit

  # Boundary-internal typed wire error (PD1-2 review round): boundary-owned
  # reserved wire state rides dedicated fields; extra_details is the open
  # producer extension bag, reserved-key-free by construction. Serialization
  # encodes extras through the budgeted walker, then overlays the canonical
  # string-keyed reserved fields authoritatively — a producer twin of a
  # reserved key can never collide into the walker's sentinel, on any tier.
  defmodule WireError do
    @moduledoc false

    @type t :: %__MODULE__{
            code: atom(),
            message: String.t() | nil,
            retry: boolean() | nil,
            truncated: boolean() | nil,
            unregistered_code: String.t() | nil,
            extra_details: map()
          }

    defstruct code: nil,
              message: nil,
              retry: nil,
              truncated: nil,
              unregistered_code: nil,
              extra_details: %{}
  end

  @public_server JidoClaw.MCPServer

  # Wrap-provenance literals (PORT-PD1-2-EXEC): the exec opt carrying the
  # per-call token and the details key the forked wrap arms stamp under.
  # Both literals are duplicated in the fork's helper block
  # (lib/jido_claw/core/jido_exec_patch.ex) by necessity — two module
  # trees; the end-to-end tier-1 rows pin the coupling.
  @wrap_provenance_opt :jido_claw_wrap_provenance
  @exec_wrap_marker :__jido_claw_exec_wrapped__

  # Aggregate cap on the ENCODED canonical JSON item (distinct from
  # JsonSafe's work budgets and OutputLimit's per-leaf 32 KiB cap).
  @max_structured_bytes 16 * 1024
  # Boundary-local message truncator bound (mirrors Tools.Error's private
  # @max_string_bytes; that helper deliberately stays private).
  @max_message_bytes 2 * 1024
  # Shared byte budget across the reduced envelope's retained values.
  @retained_values_budget 8 * 1024
  # Per-field fresh small bounded JsonSafe pass (reduced tier only).
  @field_pass_nodes 1_000
  @field_pass_bytes 2 * 1024

  @truncated_marker "[truncated]"

  # Fully static — zero interpolation of the failing term. `retry: false`
  # is IN the text: `tool_error` with empty details reads retryable under
  # jido_action's default policy, and a deterministic serialization failure
  # must not be laundered into a retryable-looking error.
  @static_fallback ~s({"code":"tool_error","message":"error serialization failed","details":{"retry":false}})

  # The six jido_action typed error structs the patched tools handler can
  # deliver to the error arms (validation is delegated to Jido.Exec).
  @native_errors [
    Jido.Action.Error.InvalidInputError,
    Jido.Action.Error.TimeoutError,
    Jido.Action.Error.ConfigurationError,
    Jido.Action.Error.InternalError,
    Jido.Action.Error.Internal.UnknownError,
    Jido.Action.Error.ExecutionFailureError
  ]

  # Boundary-owned reserved keys, stripped from producer details at the
  # build site in BOTH key forms: unregistered_code (advertised contract —
  # present exactly when the fallback produced it) and the two size
  # measurement keys ("appears ONLY on fully-traversed over-cap values" /
  # budget trips — documented boundary measurements a full-tier squatter
  # could otherwise counterfeit).
  @boundary_owned_keys [
    :unregistered_code,
    "unregistered_code",
    :original_byte_size,
    "original_byte_size",
    :observed_at_least,
    "observed_at_least",
    # The exec wrap-provenance marker, both key forms — a real witness was
    # detached before the build site ever runs; anything still here is a
    # producer squatter and never rides wire details on any tier.
    @exec_wrap_marker,
    "__jido_claw_exec_wrapped__"
  ]

  # Fixed reduced-envelope hint allowlist: {atom_form, wire_form} — atom
  # form wins when both are present. Fold order is the list order; the
  # `available` pair is handled specially (element-wise bounding). Hint
  # values are arbitrary-size producer DATA riding the single envelope walk
  # under ONE budget — they stay in the extension bag, never typed fields
  # (lifting them would mean a separate bounded pass per field for no gain,
  # since nothing injects them after canonicalization).
  @hint_allowlist [
    {:field, "field"},
    {:expected, "expected"},
    {:got, "got"},
    {:available, "available"},
    {:available_truncated, "available_truncated"}
  ]

  # The reserved DATA keys canonicalized at the build site: the hint
  # allowlist plus to_map's injected value/timeout. Fixed list, direct
  # lookups, never a key sweep (a Map.keys/1 grouping would walk a
  # hostile-size key list BEFORE encode_bounded's O(1) preflights — hostile
  # cardinality stays the walker's problem, as designed).
  @canonical_extra_keys @hint_allowlist ++ [{:value, "value"}, {:timeout, "timeout"}]

  # Mirrors JsonSafe's exact-int64 render bounds: in-range integers render
  # ≤ 20 bytes (the flat 8-byte retained charge stands); anything wider
  # falls to the fresh small bounded pass, whose own budget charges the
  # decimal width and trips into the constant "[truncated]" marker.
  @min_exact_int -9_223_372_036_854_775_808
  @max_exact_int 9_223_372_036_854_775_807

  @doc """
  Mint the per-call wrap-provenance token: a fresh reference for the PUBLIC
  server, `nil` for every other server (public-only minting is REQUIRED —
  unconditional minting would put marker keys into the consolidator/deposit
  servers' byte-pinned single-item `inspect` arms). The runtime patch calls
  this once per tool call and threads the same token to `exec_opts/1` and
  `error_response/3`.
  """
  @spec mint_wrap_token(module()) :: reference() | nil
  def mint_wrap_token(@public_server), do: make_ref()
  def mint_wrap_token(_server_module), do: nil

  @doc """
  The `Jido.Exec.run/4` opts for a minted token: `[]` for `nil` (every
  non-public server — exec behavior byte-identical by construction), the
  wrap-provenance opt for a reference.
  """
  @spec exec_opts(reference() | nil) :: keyword()
  def exec_opts(token) when is_reference(token), do: [{@wrap_provenance_opt, token}]
  def exec_opts(_nil_or_junk), do: []

  @doc """
  Render one `Jido.Exec` error-arm `reason` into the tool error response for
  `server_module`. Public server → dual-content structured shape (the legacy
  inspect text is computed ONCE — `content[0]` ships it and tier 4's message
  reuses the same bytes), with the wrap-provenance marker detached BEFORE
  the legacy render on exact `token` identity — real traffic's delivered
  term is byte-identical to the unpatched world's, and tier 1 fires only
  with the witness; every other server → the byte-identical legacy
  single-item arm (raw `inspect/1`, escape path included — that pin is
  deliberate), token ignored. Arity-2 calls (the direct-call test surface)
  behave exactly as before: no token, nothing detaches, tier 1 unreachable.
  """
  @spec error_response(term(), module(), reference() | nil) :: Response.t()
  def error_response(reason, server_module, token \\ nil)

  def error_response(reason, @public_server, token) do
    {reason, exec_wrapped?} = detach_wrap_marker(reason, token)
    legacy = JsonSafe.safe_inspect(reason)

    Response.tool()
    |> Response.error(legacy)
    |> Response.text(structured_item(reason, legacy, exec_wrapped?))
  end

  def error_response(reason, _server_module, _token) do
    Response.error(Response.tool(), inspect(reason))
  end

  # Fires ONLY on the exact wrap shape carrying the exact minted ref —
  # rebuild the struct with the key deleted and report the witness. EVERY
  # other case (nil token, absent key, forged/stale/junk value) returns the
  # term untouched with false: content[0] stays faithful to the delivered
  # reason, and the tier-1 guard refuses. Total by pattern match +
  # catch-all; runs OUTSIDE structured_item's guarded region, same posture
  # as the legacy safe_inspect head.
  defp detach_wrap_marker(
         %ExecutionFailureError{details: %{@exec_wrap_marker => value} = details} = error,
         token
       )
       when is_reference(token) and value === token do
    {%{error | details: Map.delete(details, @exec_wrap_marker)}, true}
  end

  defp detach_wrap_marker(reason, _token), do: {reason, false}

  # ── Structured item (one guarded region — rescue AND catch) ─────────────

  defp structured_item(reason, legacy_text, exec_wrapped?) do
    maybe_chaos!()

    reason
    |> unwrap(legacy_text, exec_wrapped?)
    |> enforce_registry()
    |> encode_envelope()
  rescue
    # The never-escalate guarantee IS the contract: ANY escape from the
    # structured-item production yields the static envelope, never a
    # JSON-RPC failure.
    # reach:disable-next-line bare_rescue
    _ -> @static_fallback
  catch
    _, _ -> @static_fallback
  end

  # This chaos seam is compiled only in MIX_ENV=test (the app-env seam idiom
  # — the project deliberately has no mocking library): it lets the suite
  # prove the never-escalate fallback through the REAL runtime path for all
  # three escape kinds. Production gets a constant no-op — structurally
  # unable to trip the fallback on configuration junk — and the catch-all
  # clause keeps the test seam inert on any non-kind value (`false`, a typo,
  # leftover junk).
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

  # ── Unwrap tiers (pinned order) ──────────────────────────────────────────

  # (1) The exact Jido.Exec wrap of a canonical tool envelope — WITNESSED:
  # exec_wrapped? is true only when detach_wrap_marker/2 found the minted
  # ref the forked exec stamped (and the fork stamps only when the pre-wrap
  # reason matched the raw envelope contract). The shape guard stays as
  # belt-and-braces, but shape alone — an unmarked or forged-marker
  # ExecutionFailureError whose details happen to carry :code + :details —
  # no longer reaches this tier; it falls to (3), execution_error with
  # authoritative retry.
  defp unwrap(
         %ExecutionFailureError{message: message, details: %{code: code, details: details}},
         _legacy_text,
         true = _exec_wrapped?
       )
       when is_atom(code) and is_binary(message) do
    build_wire_error(code, message, details)
  end

  # (2) A raw canonical envelope map (defensive — reachable if a future
  # exec path stops wrapping). Token-free by design: a raw non-struct map
  # cannot be a native error, so its duck-typed contract is unchanged (the
  # direct-call test surface rides it).
  defp unwrap(%{code: code, message: message, details: details} = raw, _legacy_text, _witness)
       when not is_struct(raw) and is_atom(code) and is_binary(message) and is_map(details) do
    build_wire_error(code, message, details)
  end

  # (3) Native jido_action typed errors, adapted through the documented
  # cross-package adapter, then `retry` set authoritatively from the exec
  # gate's class predicate. retryable?/1 runs on the ORIGINAL error (hints
  # live in its details; the message projection touches :message only).
  defp unwrap(%module{} = error, _legacy_text, _witness) when module in @native_errors do
    mapped =
      error
      |> bound_native_message()
      |> JidoActionError.to_map()

    wire = build_wire_error(translate_native(mapped.type), mapped.message, mapped.details)
    %{wire | retry: JidoActionError.retryable?(error)}
  end

  # (4) Everything else: tool_error, the message REUSING content[0]'s
  # legacy render — the one term render the pinned contract already
  # mandates; the structured branch performs no second render.
  defp unwrap(_reason, legacy_text, _witness) do
    %WireError{code: :tool_error, message: legacy_text}
  end

  # to_map's message fallback inspects unbounded (limit: :infinity); a
  # non-binary/non-atom message (bignum, composite) would render in full
  # inside the structured branch. Replace ONLY that arm with a static
  # placeholder — binary, atom, nil, and missing messages keep to_map's
  # exact behavior, and the raw message stays visible in content[0]'s
  # pinned legacy inspect. Map-update syntax preserves struct-ness and
  # fires only when :message exists (key-missing pseudo shapes pass
  # through, preserving to_map's missing-message behavior).
  defp bound_native_message(%{message: m} = error)
       when not is_binary(m) and not is_atom(m) do
    %{error | message: "[unrenderable message]"}
  end

  defp bound_native_message(error), do: error

  defp translate_native(:configuration_error), do: :config_error
  defp translate_native(type), do: type

  defp ensure_map(value) when is_map(value) and not is_struct(value), do: value
  defp ensure_map(_value), do: %{}

  # ── The single WireError build site (every tier) ─────────────────────────

  defp build_wire_error(code, message, raw_details) do
    details = ensure_map(raw_details)
    {retry, sans_retry} = extract_reserved_boolean(details, :retry, "retry")
    {truncated, sans_reserved} = extract_reserved_boolean(sans_retry, :truncated, "truncated")

    extra_details =
      sans_reserved
      |> Map.drop(@boundary_owned_keys)
      |> canonicalize_extra_keys()

    %WireError{
      code: code,
      message: message,
      retry: retry,
      truncated: truncated,
      extra_details: extra_details
    }
  end

  # Boolean-only reserved-state extraction, atom form first (the same
  # precedence allowlisted_value/3 applies and the dep's own
  # extract_retry_value uses — precedence means precedence, even when the
  # atom form holds junk beside a boolean string twin). Both key forms are
  # ALWAYS dropped; a non-boolean value yields nil — absent from the wire
  # on every tier, the boundary abstaining rather than inventing advice.
  defp extract_reserved_boolean(details, atom_key, wire_key) do
    extracted =
      case allowlisted_value(details, atom_key, wire_key) do
        {:ok, value} when is_boolean(value) -> value
        _absent_or_non_boolean -> nil
      end

    {extracted, Map.drop(details, [atom_key, wire_key])}
  end

  # Reserved DATA keys: delete the string twin when the atom form is
  # present, by direct lookup over the fixed pair list — a producer twin
  # can never reach the walker's collision sentinel, and the full tier
  # ships the SAME value an over-cap reduction's allowlisted_value retains
  # (values never flip between tiers).
  defp canonicalize_extra_keys(details) do
    Enum.reduce(@canonical_extra_keys, details, fn {atom_key, wire_key}, acc ->
      if Map.has_key?(acc, atom_key) do
        Map.delete(acc, wire_key)
      else
        acc
      end
    end)
  end

  # ── Registry enforcement (the closure proof) ─────────────────────────────

  defp enforce_registry(%WireError{code: code} = wire) do
    if ErrorCodes.member?(code) do
      wire
    else
      Logger.warning(
        "MCP error boundary: unregistered error code #{inspect(code)} re-coded to :tool_error"
      )

      # Stringified BEFORE JsonSafe: module atoms as map values are
      # otherwise dropped, which would silently delete the promised key.
      # Bounded: atom names cap at 255 chars. Producer squatters were
      # stripped at the build site — the typed field is non-nil exactly
      # when this fallback fired.
      %{wire | code: :tool_error, unregistered_code: inspect(code)}
    end
  end

  # ── Envelope encoding: full → reduced → minimal ──────────────────────────

  defp encode_envelope(%WireError{} = wire) do
    envelope = %{code: wire.code, message: wire.message, details: wire.extra_details}

    case JsonSafe.encode_bounded(envelope) do
      {:ok, safe, _bytes} ->
        # Reserved fields overlay POST-encode, straight onto encoded string
        # keys; the 16 KiB check measures the POST-overlay JSON — the item
        # as shipped.
        shipped = Map.update!(safe, "details", &overlay_reserved(&1, wire))
        json = Jason.encode!(shipped)

        if byte_size(json) <= @max_structured_bytes do
          json
        else
          meta = %{"truncated" => true, "original_byte_size" => byte_size(json)}
          reduced_envelope(wire, meta)
        end

      {:budget_exceeded, %{observed_at_least: observed}} ->
        meta = %{"truncated" => true, "observed_at_least" => observed}
        reduced_envelope(wire, meta)
    end
  end

  # The reduced tier reads the RAW extension bag (a budget-tripped abort
  # leaves no normalized value), so every retained value is re-bounded
  # defensively. Reserved state comes from the TYPED fields (bounded by
  # construction), and trunc_meta merges LAST so its mandatory
  # "truncated" => true wins over a producer boolean — the OR: a reduction
  # happened, so the wire says truncated regardless of who set it first.
  defp reduced_envelope(%WireError{} = wire, trunc_meta) do
    reduced =
      wire.extra_details
      |> take_allowlisted()
      |> rebound_values()
      |> overlay_reserved(wire)
      |> Map.merge(trunc_meta)

    envelope = %{
      "code" => Atom.to_string(wire.code),
      "message" => truncate_message(wire.message),
      "details" => reduced
    }

    case bounded_json(envelope) do
      {:ok, json} when byte_size(json) <= @max_structured_bytes ->
        json

      _over_cap_or_tripped ->
        minimal_envelope(wire, trunc_meta)
    end
  end

  # Minimal tier: bounded by construction — the reserved overlay (booleans
  # plus an inspect-rendered atom ≤ ~262 bytes) and the truncation
  # metadata, merged in the SAME order as the reduced tier (overlay first,
  # trunc_meta last, so the mandatory "truncated" => true wins — reaching
  # this tier proves a reduction happened, and the reverse order would let
  # a producer `false` mask it). The advertised fallback contract
  # (unregistered_code) survives every reduction tier.
  defp minimal_envelope(%WireError{} = wire, trunc_meta) do
    detail =
      %{}
      |> overlay_reserved(wire)
      |> Map.merge(trunc_meta)

    envelope = %{
      "code" => Atom.to_string(wire.code),
      "message" => truncate_message(wire.message),
      "details" => detail
    }

    case bounded_json(envelope) do
      {:ok, json} -> json
      _tripped -> @static_fallback
    end
  end

  # Reserved wire fields are overlaid AFTER the bounded walk, straight onto
  # encoded string keys — authoritative by construction (a producer twin
  # was stripped at the build site; nothing can collide). Values are
  # bounded: booleans and an inspect-rendered atom (≤ ~262 bytes).
  defp overlay_reserved(encoded_details, %WireError{} = wire) do
    encoded_details
    |> put_if(is_boolean(wire.retry), "retry", wire.retry)
    |> put_if(is_boolean(wire.truncated), "truncated", wire.truncated)
    |> put_if(is_binary(wire.unregistered_code), "unregistered_code", wire.unregistered_code)
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp bounded_json(envelope) do
    case JsonSafe.encode_bounded(envelope) do
      {:ok, safe, _bytes} -> {:ok, Jason.encode!(safe)}
      {:budget_exceeded, _info} -> :budget_exceeded
    end
  end

  # ── Reduced-tier detail selection + re-bounding ──────────────────────────

  defp take_allowlisted(details) do
    Enum.flat_map(@hint_allowlist, fn {atom_key, wire_key} ->
      case allowlisted_value(details, atom_key, wire_key) do
        {:ok, value} -> [{wire_key, value}]
        :error -> []
      end
    end)
  end

  defp allowlisted_value(details, atom_key, wire_key) do
    cond do
      Map.has_key?(details, atom_key) -> {:ok, Map.get(details, atom_key)}
      Map.has_key?(details, wire_key) -> {:ok, Map.get(details, wire_key)}
      true -> :error
    end
  end

  defp rebound_values(pairs) do
    {reduced, _budget} =
      Enum.reduce(pairs, {%{}, @retained_values_budget}, fn
        {"available", list}, {acc, budget} when is_list(list) ->
          {kept, truncated?, budget} = bound_available(list, budget)
          acc = Map.put(acc, "available", kept)
          acc = if truncated?, do: flip_available_truncated(acc), else: acc
          {acc, budget}

        {"available_truncated", value}, {acc, budget} ->
          # OR-merge: an element-wise drop above must never be flipped back
          # by the producer's own (earlier, pre-reduction) flag.
          acc =
            Map.update(acc, "available_truncated", value == true, fn existing ->
              existing == true or value == true
            end)

          {acc, budget}

        {key, value}, {acc, budget} ->
          {bounded, cost} = bound_retained(value)
          {Map.put(acc, key, bounded), max(budget - cost, 0)}
      end)

    reduced
  end

  defp flip_available_truncated(acc), do: Map.put(acc, "available_truncated", true)

  # Finite-width scalars pass as-is; strings take the 2 KB truncator;
  # out-of-int64-range integers and everything else get a fresh small
  # bounded JsonSafe pass — its budget charges an out-of-range integer's
  # decimal width, and a trip yields the constant marker, never a
  # fall-through to the static fallback.
  defp bound_retained(value)
       when is_boolean(value) or is_nil(value) or is_float(value) or
              (is_integer(value) and value >= @min_exact_int and value <= @max_exact_int),
       do: {value, 8}

  defp bound_retained(value) when is_binary(value) do
    bounded = truncate_message(value)
    {bounded, byte_size(bounded)}
  end

  defp bound_retained(value) do
    case JsonSafe.encode_bounded(value,
           max_nodes: @field_pass_nodes,
           max_bytes: @field_pass_bytes
         ) do
      {:ok, safe, bytes} -> {safe, bytes}
      {:budget_exceeded, _info} -> {@truncated_marker, byte_size(@truncated_marker)}
    end
  end

  # Element-wise bounding under the shared budget: elements after the budget
  # spends out are never touched (bounded work); any drop flips the flag.
  defp bound_available(list, budget) do
    {kept, truncated?, budget} =
      Enum.reduce_while(list, {[], false, budget}, fn element, {acc, _flag, budget} ->
        {bounded, cost} = bound_retained(element)

        if budget - cost >= 0 do
          {:cont, {[bounded | acc], false, budget - cost}}
        else
          {:halt, {acc, true, budget}}
        end
      end)

    {Enum.reverse(kept), truncated?, budget}
  end

  # Boundary-local UTF-8-safe truncator (the Tools.Error idiom; that
  # module's helper deliberately stays private). Every unwrap tier yields a
  # binary message, so no non-binary head is needed.
  defp truncate_message(message) when is_binary(message) do
    if byte_size(message) > @max_message_bytes do
      message
      |> binary_part(0, @max_message_bytes)
      |> OutputLimit.valid_utf8_prefix()
      |> Kernel.<>("... (truncated)")
    else
      message
    end
  end
end
