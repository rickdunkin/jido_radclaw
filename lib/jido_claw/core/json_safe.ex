defmodule JidoClaw.Core.JsonSafe do
  @moduledoc """
  Recursively normalize a term into a JSON-safe shape for MCP output.

  This is the shared normalizer consumed by `JidoClaw.AgentView.to_mcp_map/1`,
  `JidoClaw.Tools.InspectAgent`, and the served-MCP error boundary
  (`JidoClaw.MCPServer.ErrorBoundary`) so every surface stringifies the same
  way.

  The transformation is **total**: every term maps to something
  `Jason.encode/1` accepts, so callers never have to pre-sanitize input.
  Totality is enforced structurally — `encode/1` is a rescue+catch wrapper
  and all recursion re-enters it, so any escape (a malformed calendar
  struct, a hostile `Inspect` impl that raises/throws/exits, a future clause
  bug) degrades ONLY that leaf/subtree to the static `"[unencodable]"`
  placeholder, never the whole payload.

    * `nil`, booleans, and numbers pass through unchanged,
    * binaries pass through when valid UTF-8; invalid binaries are scrubbed
      chunk-wise (`String.chunk(bin, :valid)`) with each invalid chunk
      replaced by `"�"` — valid text stays readable,
    * atoms (besides `nil` / booleans) become strings; module (`Elixir.*`)
      atoms become `nil`,
    * `DateTime` / `NaiveDateTime` / `Date` become ISO-8601 strings,
    * `MapSet` becomes a list,
    * other structs are converted to plain maps and walked,
    * lists are recursively encoded element-by-element; an improper list is
      detected and its improper tail becomes the final element
      (`[1 | 2]` → `[1, 2]`),
    * tuples are encoded as lists (`{:ok, 1}` → `["ok", 1]`),
    * map keys are stringified — valid-UTF-8 binaries pass through, atoms
      via `Atom.to_string/1`, invalid-UTF-8 binaries take the deterministic
      tagged form `"<<invalid-utf8:" <> Base.encode64(key) <> ">>"` (drawing
      at most #{256} bytes of the key; oversized invalid keys append
      `:trunc-<total size>` — a deliberate LOSSY normalization), and any
      other key (integer, tuple, …) via `safe_inspect/1`,
    * map entries are folded in Erlang term order of the ORIGINAL keys, so
      any encoded-key collision (two oversized invalid keys sharing prefix
      and length; a valid key equal to a tagged form) resolves
      deterministically — the later (greater) original key wins,
    * pids / refs / functions / ports are not JSON-encodable: as a map value
      the entry is dropped entirely; anywhere else (list element, top-level
      term, nested leaf) they become `nil`,
    * anything left (e.g. a non-binary bitstring) is rendered with
      `safe_inspect/1`.

  ## Bounded walkers

  `encode_bounded/2` is the budgeted variant for unbounded inputs (the
  served-MCP error boundary, `run_skill`'s raw Reactor reasons): same
  policy, but the WORK is bounded — node count, depth, per-key bytes, and
  cumulative bytes — with O(1) container preflights (`map_size` /
  `tuple_size` / `MapSet.size` checked against the remaining node budget
  BEFORE any `to_list` materialization). `fingerprint_projection/2` is the
  budgeted structural projection backing `JidoClaw.Agent.LoopGuard`'s
  failure-signature identity (see that moduledoc for the policy rationale).
  Both short-circuit to `{:budget_exceeded, %{observed_at_least: n}}` —
  only a LOWER BOUND of the term's size is knowable at the trip, since the
  exact total would require the full walk the budget exists to prevent.

  `encode_bounded/2` diverges from `encode/1`'s documented policy in three
  deliberate ways, because bounded WORK is its contract: composite keys
  (tuples, lists, maps, structs) and out-of-int64-range integers take
  constant `<<key:*>>` class markers — rendering them would run user
  `Inspect` impls (unbounded allocation, nontermination) or bignum
  digit-count work BEFORE any budget could charge; encoded-key
  collisions resolve to the constant `"[key-collision]"` sentinel,
  order-independently, instead of `encode/1`'s term-order fold (comparing
  or retaining arbitrary original keys is itself unbounded traversal); and
  the calendar leaf conversions run only behind an O(1) fast-path gate —
  exactly `Calendar.ISO` with in-int64-range temporal integer fields —
  everything else taking the generic budgeted struct walk, so non-ISO
  calendar callbacks (arbitrary user code) are never invoked by the
  bounded walker, while `encode/1` keeps converting arbitrary calendars
  (totality, not bounded work, is its contract).

  Bounded-walker VALUE width accounting: out-of-int64-range integers charge
  `2 * max(:erlang.external_size/1 - 8, 0)` bytes before passing through —
  a provable LOWER bound of the decimal render (`observed_at_least` never
  exceeds the true width) that still tracks it within a small constant
  factor (worst ratio 2.625x, so admitted bignums materialize at most
  2.625x the byte budget in `Jason.encode!`). Finite-width numerics
  (floats, int64-range integers) deliberately stay byte-uncharged: each
  renders at most ~24 bytes, so their materialization is NODE-bounded —
  the documented undercount.
  """

  alias JidoClaw.Tools.OutputLimit

  # Budgeted-walker constants (pinned, distinctly named — see the plan doc
  # docs/plans/pre-argus-wave-e-16/README.md §3):
  #   * @max_nodes — total visited terms per walk
  #   * @max_depth — nesting depth
  #   * @max_key_bytes — per-map-key traversal budget (pre-tagging)
  #   * @max_bytes — cumulative accounted bytes (binaries + rendered leaves)
  #   * @invalid_key_prefix_bytes — how much of an invalid/oversized key the
  #     tagged encoding draws (distinct from @max_key_bytes; bounded-walker
  #     draws additionally clamp to the caller's max_key_bytes and the key
  #     size — see prefix_draw/2)
  @max_nodes 50_000
  @max_depth 64
  @max_key_bytes 1024
  @max_bytes 128 * 1024
  @invalid_key_prefix_bytes 256

  # Bounded exact-value cap for `fingerprint_projection/2` allowlisted keys
  # (the 256-byte identifier bound).
  @identifier_bytes 256

  # Bounded-walker key policy constants: integers inside the int64 range
  # render exactly (≤ 20 bytes); anything wider takes the bigint marker.
  # The range guard is an O(1) magnitude precheck — bignum-vs-fixnum
  # comparison is size-first — so no digit-count work precedes the charge.
  # The same bounds gate the calendar fast path and the out-of-range VALUE
  # width charge below.
  @min_exact_int_key -9_223_372_036_854_775_808
  @max_exact_int_key 9_223_372_036_854_775_807

  # Calendar fast-path field sets (bounded walker only): conversion runs
  # ONLY when the struct's calendar is exactly Calendar.ISO and every
  # temporal integer field is in int64 range (Integer.to_string on an
  # in-range field is ≤ 20 bytes, so the ISO render is bounded); the
  # microsecond tuple checks both components. Anything else falls through
  # to the generic budgeted struct walk — a bignum year gets charged by
  # the out-of-range integer rule and a non-ISO calendar module atom is
  # dropped as a map value, so non-ISO calendar callbacks never dispatch.
  @date_temporal_fields [:year, :month, :day]
  @naive_temporal_fields @date_temporal_fields ++ [:hour, :minute, :second, :microsecond]
  @datetime_temporal_fields @naive_temporal_fields ++ [:utc_offset, :std_offset]

  # Encoded-key collision sentinel for the bounded walker (a rendered leaf:
  # it rides the same cumulative byte accounting as every other leaf).
  @collision_marker "[key-collision]"

  @unencodable "[unencodable]"
  @uninspectable "[uninspectable]"

  # Internal short-circuit tag for the bounded walkers. Never escapes:
  # encode_bounded/2 and fingerprint_projection/2 catch it at their entry
  # points, and the leaf guards rethrow it so a guarded leaf can never
  # swallow a budget trip.
  @budget_tag :jido_claw_json_safe_budget_exceeded

  @typedoc "Result of a bounded walk: full traversal or a budget trip."
  @type bounded_result ::
          {:ok, term(), non_neg_integer()}
          | {:budget_exceeded, %{observed_at_least: non_neg_integer()}}

  @doc """
  Recursively encode `term` into a JSON-safe value. See the moduledoc for
  the full transformation rules. Total: any escape degrades the offending
  leaf/subtree to `"[unencodable]"`.
  """
  @spec encode(term()) :: term()
  def encode(value) do
    do_encode(value)
  rescue
    # The totality wrapper IS the contract: ANY escape (malformed calendar
    # struct, hostile impl, future clause bug) degrades this leaf/subtree.
    # reach:disable-next-line bare_rescue
    _ -> @unencodable
  catch
    _, _ -> @unencodable
  end

  @doc """
  `inspect/1` under rescue+catch: a hostile `Inspect` impl that raises,
  throws, or exits yields the static `"[uninspectable]"`; a SUCCESSFUL
  inspect whose output carries invalid UTF-8 bytes is scrubbed to valid
  UTF-8 (replacement characters), so the result is always safe to embed in
  wire text. Shared by this module's key/value fallbacks and the served-MCP
  error boundary's legacy-text rendering.
  """
  @spec safe_inspect(term()) :: String.t()
  def safe_inspect(term) do
    scrub_binary(inspect(term))
  rescue
    # Hostile Inspect impls can raise anything; totality is the contract.
    # reach:disable-next-line bare_rescue
    _ -> @uninspectable
  catch
    _, _ -> @uninspectable
  end

  defp do_encode(value) when is_struct(value, DateTime), do: DateTime.to_iso8601(value)
  defp do_encode(value) when is_struct(value, NaiveDateTime), do: NaiveDateTime.to_iso8601(value)
  defp do_encode(value) when is_struct(value, Date), do: Date.to_iso8601(value)

  defp do_encode(%MapSet{} = set) do
    set
    |> MapSet.to_list()
    |> Enum.map(&encode/1)
  end

  defp do_encode(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> encode()
  end

  # Entries fold in Erlang term order of the ORIGINAL keys so encoded-key
  # collisions resolve deterministically (later/greater original key wins) —
  # never an unordered-map accident.
  defp do_encode(map) when is_map(map) do
    map
    |> Map.to_list()
    |> List.keysort(0)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      cond do
        is_pid(v) or is_reference(v) or is_function(v) or is_port(v) ->
          acc

        is_atom(v) and not is_nil(v) and not is_boolean(v) and module?(v) ->
          acc

        true ->
          Map.put(acc, encode_key(k), encode(v))
      end
    end)
  end

  defp do_encode(list) when is_list(list), do: encode_list(list)

  # Tuples have no JSON representation; encode them as lists so keyword lists,
  # `{:ok, _}` / `{:error, _}` shapes, etc. don't leak un-encodable terms.
  defp do_encode(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&encode/1)
  end

  defp do_encode(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    if module?(atom), do: nil, else: Atom.to_string(atom)
  end

  # Runtime types are not JSON-encodable. The map reducer above drops them
  # entirely when they're a map value; this leaf clause catches every other
  # position (list element, top-level term, nested leaf) and yields `nil` —
  # parallel to how a module atom becomes `nil` outside a map value.
  defp do_encode(value)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
       do: nil

  # Binary leaves: valid UTF-8 passes through; invalid bytes are scrubbed.
  defp do_encode(value) when is_binary(value), do: scrub_binary(value)

  # Remaining JSON leaves pass through unchanged.
  defp do_encode(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value

  # Total fallback: anything left (e.g. a non-binary bitstring) is rendered to
  # a string so encode/1 never emits a term `Jason.encode/1` would reject.
  defp do_encode(value), do: safe_inspect(value)

  # Improper lists get a detecting walk: the improper tail becomes the final
  # element (`[1 | 2]` → `[1, 2]`).
  defp encode_list([]), do: []
  defp encode_list([head | tail]) when is_list(tail), do: [encode(head) | encode_list(tail)]
  defp encode_list([head | tail]), do: [encode(head), encode(tail)]

  defp encode_key(k) do
    do_encode_key(k)
  rescue
    # Same totality contract as encode/1, applied to key rendering.
    # reach:disable-next-line bare_rescue
    _ -> @unencodable
  catch
    _, _ -> @unencodable
  end

  defp do_encode_key(k) when is_binary(k) do
    if String.valid?(k), do: k, else: tag_invalid_key(k)
  end

  defp do_encode_key(k) when is_atom(k), do: Atom.to_string(k)
  defp do_encode_key(k), do: safe_inspect(k)

  # Deterministic tagged form for invalid-UTF-8 binary keys, drawing at most
  # @invalid_key_prefix_bytes of the key. Oversized keys are a deliberate
  # LOSSY normalization (prefix + total size only); collisions resolve via
  # encode/1's term-order fold, or the bounded walker's collision sentinel.
  defp tag_invalid_key(k) when byte_size(k) <= @invalid_key_prefix_bytes do
    "<<invalid-utf8:" <> Base.encode64(k) <> ">>"
  end

  defp tag_invalid_key(k) do
    prefix = binary_part(k, 0, @invalid_key_prefix_bytes)
    "<<invalid-utf8:" <> Base.encode64(prefix) <> ":trunc-#{byte_size(k)}>>"
  end

  defp scrub_binary(bin) do
    if String.valid?(bin) do
      bin
    else
      bin
      |> String.chunk(:valid)
      |> Enum.map_join(fn chunk ->
        if String.valid?(chunk), do: chunk, else: "�"
      end)
    end
  end

  defp module?(atom) when is_atom(atom) do
    match?("Elixir." <> _, Atom.to_string(atom))
  end

  # ── Bounded walkers ──────────────────────────────────────────────────────

  @doc """
  Budgeted `encode/1`: same JSON policy, bounded WORK. Returns
  `{:ok, value, accounted_bytes}` on a full traversal (the byte counter's
  final value — accounted binary/rendered-leaf bytes, not the final JSON
  length) or `{:budget_exceeded, %{observed_at_least: n}}` on a trip.

  Options (defaults are the pinned module constants): `:max_nodes`,
  `:max_depth`, `:max_key_bytes`, `:max_bytes` — each accepted only as a
  non-negative integer; any other value falls back to the pinned default
  (`bounded_result` is total over every option value, never a raise or a
  defeated comparison). Container sizes are preflighted O(1) against the
  REMAINING node budget before any materialization; per-entry key sizes
  are checked during iteration, with oversized keys taking the bounded
  tagged/truncated form — prefix draws are clamped to the smaller of the
  caller's `:max_key_bytes` and 256 bytes, and to the key size.
  """
  @spec encode_bounded(term(), keyword()) :: bounded_result()
  def encode_bounded(term, opts \\ []) do
    limits = %{
      max_depth: limit_opt(opts, :max_depth, @max_depth),
      max_key_bytes: limit_opt(opts, :max_key_bytes, @max_key_bytes),
      max_bytes: limit_opt(opts, :max_bytes, @max_bytes)
    }

    st = %{nodes: limit_opt(opts, :max_nodes, @max_nodes), bytes: 0}

    try do
      {value, st} = bencode(term, 0, st, limits)
      {:ok, value, st.bytes}
    catch
      {@budget_tag, observed} -> {:budget_exceeded, %{observed_at_least: observed}}
    end
  end

  @doc """
  Budgeted FIELD-AWARE structural projection for failure fingerprinting
  (`JidoClaw.Agent.LoopGuard`). Deterministic and total over every BEAM term
  class:

    * atoms and booleans stay exact,
    * numbers map to the constant class marker `:num` (volatile per-attempt
      numeric metadata must not mint fresh identities),
    * binaries map to the constant marker `:bin` — EXCEPT values (and binary
      keys) under the `:exact_keys` allowlist, kept exact and bounded to the
      #{256}-byte identifier bound (UTF-8-safe truncation),
    * runtime identities map to per-class constant markers — `:pid`, `:ref`,
      `:port`, `:fun`, `:bits` — never their value,
    * lists keep shape (improper tails become the final element),
    * tuples project as `{:tuple, [projected...]}`,
    * maps project as `{:map, pairs}` where `pairs` is the list of
      `{projected_key, projected_value}` pairs sorted by Erlang term order
      of the PROJECTED pairs — every entry is kept, so two keys projecting
      to the same marker still contribute two entries,
    * structs project as `{:struct, Module, pairs}` (same pair policy).

  Options: `:exact_keys` (list of key NAMES as strings; matched against
  both atom and string key forms), plus the budget options of
  `encode_bounded/2` (same non-negative-integer domain; junk values fall
  back to the pinned defaults). Returns `{:ok, projection, accounted_bytes}`
  or `{:budget_exceeded, %{observed_at_least: n}}` — callers fold a trip
  into a constant sentinel component.
  """
  @spec fingerprint_projection(term(), keyword()) :: bounded_result()
  def fingerprint_projection(term, opts \\ []) do
    limits = %{
      max_depth: limit_opt(opts, :max_depth, @max_depth),
      max_key_bytes: limit_opt(opts, :max_key_bytes, @max_key_bytes),
      max_bytes: limit_opt(opts, :max_bytes, @max_bytes),
      exact_keys: MapSet.new(Keyword.get(opts, :exact_keys, []))
    }

    st = %{nodes: limit_opt(opts, :max_nodes, @max_nodes), bytes: 0}

    try do
      {value, st} = fproject(term, 0, st, limits, false)
      {:ok, value, st.bytes}
    catch
      {@budget_tag, observed} -> {:budget_exceeded, %{observed_at_least: observed}}
    end
  end

  # ── Budget primitives ────────────────────────────────────────────────────

  # Budget options accept ONLY non-negative integers; anything else falls
  # back to the pinned module default. The clamp alone is not total: a
  # float cap survives min/2 and raises in binary_part/3, and a
  # non-numeric cap (:infinity) defeats the over-cap comparison via Erlang
  # term ordering, sending an oversized key into the full String.valid?/1
  # scan the per-key budget exists to prevent.
  defp limit_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _junk -> default
    end
  end

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

  @spec trip!(map()) :: no_return()
  defp trip!(st), do: throw({@budget_tag, st.bytes})

  defp spend_node(%{nodes: 0} = st), do: trip!(st)
  defp spend_node(st), do: %{st | nodes: st.nodes - 1}

  defp preflight!(st, size) when is_integer(size) do
    if size > st.nodes, do: trip!(st), else: st
  end

  defp spend_bytes(st, count, limits) do
    st = %{st | bytes: st.bytes + count}
    if st.bytes > limits.max_bytes, do: trip!(st), else: st
  end

  defp check_depth!(depth, st, limits) do
    if depth > limits.max_depth, do: trip!(st), else: :ok
  end

  # Guard for leaf conversions that touch potentially-malformed structs
  # (DateTime.to_iso8601 on a hand-built %{__struct__: DateTime}, MapSet
  # internals). Contains NO walker recursion, so the only throw it must
  # rethrow is the budget tag — everything else degrades to the static
  # placeholder.
  defp guard_leaf(fun) do
    fun.()
  rescue
    # Malformed-struct conversions can raise anything; totality is the
    # contract (the budget rethrow keeps trips first-class).
    # reach:disable-next-line bare_rescue
    _ -> @unencodable
  catch
    :throw, {@budget_tag, _} = trip -> throw(trip)
    _, _ -> @unencodable
  end

  # ── encode_bounded walk (JSON policy) ────────────────────────────────────

  defp bencode(value, depth, st, limits) do
    check_depth!(depth, st, limits)
    st = spend_node(st)
    bencode_value(value, depth, st, limits)
  end

  # The three calendar clauses run their converter ONLY behind the O(1)
  # fast-path gate (@date_temporal_fields comment); a refused struct takes
  # the generic budgeted struct walk instead — never a conversion, never a
  # non-ISO calendar dispatch. guard_leaf still catches conversion raises
  # on residually-invalid ISO shapes (month: 99 and friends).
  defp bencode_value(value, depth, st, limits) when is_struct(value, DateTime) do
    if iso_calendar_bounded?(value, @datetime_temporal_fields) do
      bencode_calendar(value, &DateTime.to_iso8601/1, st, limits)
    else
      bencode_value(Map.from_struct(value), depth, st, limits)
    end
  end

  defp bencode_value(value, depth, st, limits) when is_struct(value, NaiveDateTime) do
    if iso_calendar_bounded?(value, @naive_temporal_fields) do
      bencode_calendar(value, &NaiveDateTime.to_iso8601/1, st, limits)
    else
      bencode_value(Map.from_struct(value), depth, st, limits)
    end
  end

  defp bencode_value(value, depth, st, limits) when is_struct(value, Date) do
    if iso_calendar_bounded?(value, @date_temporal_fields) do
      bencode_calendar(value, &Date.to_iso8601/1, st, limits)
    else
      bencode_value(Map.from_struct(value), depth, st, limits)
    end
  end

  defp bencode_value(%MapSet{} = set, depth, st, limits) do
    case guard_leaf(fn -> MapSet.size(set) end) do
      size when is_integer(size) ->
        st = preflight!(st, size)
        list = guard_leaf(fn -> MapSet.to_list(set) end)

        if is_list(list) do
          bencode_elements(list, depth + 1, st, limits)
        else
          bencode_leaf_string(list, st, limits)
        end

      _malformed ->
        bencode_leaf_string(@unencodable, st, limits)
    end
  end

  defp bencode_value(%_{} = struct, depth, st, limits) do
    bencode_value(Map.from_struct(struct), depth, st, limits)
  end

  # Entries fold straight into the result map — the bounded walker never
  # retains or compares ORIGINAL keys (Erlang term comparison of two large
  # shared-prefix composite keys is O(key size), unbounded work even when
  # the keys are never rendered). Collisions resolve to the constant
  # sentinel, order-independently: one entry → its encoded value; two or
  # more entries sharing an encoded key → the sentinel, charged once.
  defp bencode_value(map, depth, st, limits) when is_map(map) do
    st0 = preflight!(st, map_size(map))

    {encoded, _collided, st_out} =
      Enum.reduce(map, {%{}, MapSet.new(), st0}, fn {k, v}, {acc, collided, st_acc} ->
        cond do
          is_pid(v) or is_reference(v) or is_function(v) or is_port(v) ->
            {acc, collided, st_acc}

          is_atom(v) and not is_nil(v) and not is_boolean(v) and module?(v) ->
            {acc, collided, st_acc}

          true ->
            {ek, st_key} = bencode_key(k, st_acc, limits)
            bencode_map_entry(ek, v, depth, acc, collided, st_key, limits)
        end
      end)

    {encoded, st_out}
  end

  defp bencode_value(list, depth, st, limits) when is_list(list) do
    bencode_list(list, depth + 1, st, limits, [])
  end

  defp bencode_value(tuple, depth, st, limits) when is_tuple(tuple) do
    st = preflight!(st, tuple_size(tuple))
    bencode_elements(Tuple.to_list(tuple), depth + 1, st, limits)
  end

  defp bencode_value(atom, _depth, st, limits)
       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    if module?(atom) do
      {nil, st}
    else
      bencode_leaf_string(Atom.to_string(atom), st, limits)
    end
  end

  defp bencode_value(value, _depth, st, _limits)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
       do: {nil, st}

  # Bytes are spent BEFORE the validity scan: scrub_binary is O(size), so an
  # over-budget binary must trip on byte_size alone, never get scanned.
  defp bencode_value(value, _depth, st, limits) when is_binary(value) do
    st = spend_bytes(st, byte_size(value), limits)
    {scrub_binary(value), st}
  end

  # Out-of-int64-range integers: Jason.encode! materializes the full
  # decimal render, so its width is charged BEFORE pass-through. The
  # charge — 2 * max(external_size - 8, 0) — must be a provable LOWER
  # bound of the render (a budget trip reports the accumulated charge as
  # observed_at_least, which must never exceed the true observable width)
  # while tracking it within a small constant factor: both bignum external
  # formats carry ≤ 8 header bytes, so magnitude bytes B ≥ external_size
  # - 8 and digits ≥ 2.408 × (B - 1); the global worst ratio is
  # -(2^64 - 1) at 21 rendered chars on an 8-byte charge (2.625x, ratio
  # strictly decreasing with magnitude). A single huge integer trips the
  # budget before Jason runs; total admitted-bignum materialization is
  # capped at ≤ 2.625x the byte budget.
  defp bencode_value(value, _depth, st, limits)
       when is_integer(value) and (value < @min_exact_int_key or value > @max_exact_int_key) do
    charge = 2 * max(:erlang.external_size(value) - 8, 0)
    {value, spend_bytes(st, charge, limits)}
  end

  # Finite-width numerics (floats, int64-range integers) deliberately stay
  # byte-uncharged: each renders ≤ ~24 bytes, so their materialization is
  # NODE-bounded — the documented undercount.
  defp bencode_value(value, _depth, st, _limits)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: {value, st}

  defp bencode_value(value, _depth, st, limits) do
    bencode_leaf_string(safe_inspect(value), st, limits)
  end

  defp bencode_calendar(value, converter, st, limits) do
    rendered = guard_leaf(fn -> converter.(value) end)
    bencode_leaf_string(rendered, st, limits)
  end

  # O(1) fast-path gate for the calendar clauses: exactly Calendar.ISO and
  # every temporal integer field in int64 range (the microsecond tuple
  # checks both components). See the field-set constants for the policy.
  defp iso_calendar_bounded?(value, fields) do
    case value do
      %{calendar: Calendar.ISO} -> Enum.all?(fields, &bounded_temporal_field?(value, &1))
      _non_iso_or_missing -> false
    end
  end

  defp bounded_temporal_field?(value, :microsecond) do
    case value do
      %{microsecond: {us, precision}} -> exact_int?(us) and exact_int?(precision)
      _malformed -> false
    end
  end

  defp bounded_temporal_field?(value, field) do
    case value do
      %{^field => field_value} -> exact_int?(field_value)
      _missing -> false
    end
  end

  defp exact_int?(value),
    do: is_integer(value) and value >= @min_exact_int_key and value <= @max_exact_int_key

  defp bencode_leaf_string(string, st, limits) when is_binary(string) do
    {string, spend_bytes(st, byte_size(string), limits)}
  end

  # Improper-list detecting walk with per-element node spending.
  defp bencode_list([], _depth, st, _limits, acc), do: {Enum.reverse(acc), st}

  defp bencode_list([head | tail], depth, st, limits, acc) when is_list(tail) do
    {eh, st} = bencode(head, depth, st, limits)
    bencode_list(tail, depth, st, limits, [eh | acc])
  end

  defp bencode_list([head | improper_tail], depth, st, limits, acc) do
    {eh, st_head} = bencode(head, depth, st, limits)
    {et, st_tail} = bencode(improper_tail, depth, st_head, limits)
    {Enum.reverse([et, eh | acc]), st_tail}
  end

  defp bencode_elements(elements, depth, st, limits) do
    {encoded, st_out} =
      Enum.reduce(elements, {[], st}, fn element, {acc, st_acc} ->
        {ev, st_value} = bencode(element, depth, st_acc, limits)
        {[ev | acc], st_value}
      end)

    {Enum.reverse(encoded), st_out}
  end

  # The `collided` set — never a value comparison — is the collision
  # authority: a GENUINE value that happens to equal the sentinel can never
  # suppress charging or misread state.
  defp bencode_map_entry(ek, v, depth, acc, collided, st, limits) do
    cond do
      MapSet.member?(collided, ek) ->
        # The sentinel is already stored and charged (the key encode above
        # still charged its own bytes); the colliding value is never walked.
        {acc, collided, st}

      Map.has_key?(acc, ek) ->
        # First collision for ek: the sentinel replaces the stored value and
        # is charged exactly once — it is a rendered leaf and must ride the
        # same cumulative accounting as every other leaf.
        st = spend_bytes(st, byte_size(@collision_marker), limits)
        {Map.put(acc, ek, @collision_marker), MapSet.put(collided, ek), st}

      true ->
        {ev, st_value} = bencode(v, depth + 1, st, limits)
        {Map.put(acc, ek, ev), collided, st_value}
    end
  end

  # Key encoding under the per-key traversal budget: an oversized key never
  # traverses/copies beyond the bounded prefix forms.
  defp bencode_key(k, st, limits) when is_binary(k) do
    cond do
      byte_size(k) > limits.max_key_bytes ->
        encoded = bounded_key_form(k, limits)
        {encoded, spend_bytes(st, byte_size(encoded), limits)}

      String.valid?(k) ->
        {k, spend_bytes(st, byte_size(k), limits)}

      true ->
        encoded = tag_invalid_key(k)
        {encoded, spend_bytes(st, byte_size(encoded), limits)}
    end
  end

  defp bencode_key(k, st, limits) when is_atom(k) do
    encoded = Atom.to_string(k)
    {encoded, spend_bytes(st, byte_size(encoded), limits)}
  end

  # Int64-range integers render exactly (the common real key case — step
  # indices); the range guard is an O(1) magnitude precheck.
  defp bencode_key(k, st, limits)
       when is_integer(k) and k >= @min_exact_int_key and k <= @max_exact_int_key do
    encoded = Integer.to_string(k)
    {encoded, spend_bytes(st, byte_size(encoded), limits)}
  end

  # An out-of-range integer's decimal render is digit-count work
  # proportional to the bignum's size, spent BEFORE the budget could charge
  # (inspect/2's limit/printable_limit do not bound integer rendering).
  defp bencode_key(k, st, limits) when is_integer(k),
    do: bencode_marker_key("<<key:bigint>>", st, limits)

  # Floats, runtime identities, and non-binary bitstrings render via
  # consolidated stdlib Inspect impls — bounded output, terminating, not
  # user-overridable post-consolidation — then the bounded-prefix arm.
  defp bencode_key(k, st, limits)
       when is_float(k) or is_pid(k) or is_reference(k) or is_port(k) or is_function(k) or
              is_bitstring(k) do
    bencode_rendered_key(safe_inspect(k), st, limits)
  end

  # Composite keys are NEVER rendered: rendering runs user Inspect impls
  # (unbounded allocation, nontermination) before any budget charge — a
  # deliberate lossy normalization (see the moduledoc's bounded-walker
  # divergences). The module-name guard matters: a hand-built map whose
  # __struct__ is not an atom must fall through to the map marker, never
  # dispatch on junk (atom inspect is built-in and bounded).
  defp bencode_key(%module{}, st, limits) when is_atom(module),
    do: bencode_marker_key("<<key:struct:" <> inspect(module) <> ">>", st, limits)

  defp bencode_key(k, st, limits) when is_map(k),
    do: bencode_marker_key("<<key:map>>", st, limits)

  defp bencode_key(k, st, limits) when is_tuple(k),
    do: bencode_marker_key("<<key:tuple>>", st, limits)

  defp bencode_key(k, st, limits) when is_list(k),
    do: bencode_marker_key("<<key:list>>", st, limits)

  # Total fallback for future term classes (mirrors fproject_value's
  # :unknown clause).
  defp bencode_key(_k, st, limits), do: bencode_marker_key("<<key:unknown>>", st, limits)

  defp bencode_marker_key(marker, st, limits),
    do: {marker, spend_bytes(st, byte_size(marker), limits)}

  defp bencode_rendered_key(rendered, st, limits) do
    bounded =
      if byte_size(rendered) > limits.max_key_bytes do
        OutputLimit.valid_utf8_prefix(binary_part(rendered, 0, prefix_draw(rendered, limits))) <>
          ":trunc-#{byte_size(rendered)}"
      else
        rendered
      end

    {bounded, spend_bytes(st, byte_size(bounded), limits)}
  end

  # Oversized (> max_key_bytes) binary keys: bounded prefix + total size —
  # deliberately lossy; the collision sentinel resolves residual collisions.
  # Validity is judged on the PREFIX only (whole-key String.valid? would be
  # O(key size), defeating the per-key budget); a valid key whose multibyte
  # character splits exactly at the cut therefore takes the tagged form —
  # deterministic, and documented as part of the lossy normalization.
  defp bounded_key_form(k, limits) do
    prefix = binary_part(k, 0, prefix_draw(k, limits))

    if String.valid?(prefix) do
      prefix <> ":trunc-#{byte_size(k)}"
    else
      "<<invalid-utf8:" <> Base.encode64(prefix) <> ":trunc-#{byte_size(k)}>>"
    end
  end

  # ── fingerprint_projection walk ──────────────────────────────────────────

  # `exact?` marks a value reached through an allowlisted key: binary leaves
  # under it stay exact (bounded) instead of collapsing to :bin.
  defp fproject(value, depth, st, limits, exact?) do
    check_depth!(depth, st, limits)
    st = spend_node(st)
    fproject_value(value, depth, st, limits, exact?)
  end

  defp fproject_value(value, _depth, st, _limits, _exact?)
       when is_atom(value),
       do: {value, st}

  defp fproject_value(value, _depth, st, _limits, _exact?) when is_number(value), do: {:num, st}

  defp fproject_value(value, _depth, st, limits, true) when is_binary(value) do
    bounded = bound_identifier(value)
    {bounded, spend_bytes(st, byte_size(bounded), limits)}
  end

  defp fproject_value(value, _depth, st, _limits, false) when is_binary(value), do: {:bin, st}

  defp fproject_value(value, _depth, st, _limits, _exact?) when is_pid(value), do: {:pid, st}

  defp fproject_value(value, _depth, st, _limits, _exact?) when is_reference(value),
    do: {:ref, st}

  defp fproject_value(value, _depth, st, _limits, _exact?) when is_port(value), do: {:port, st}
  defp fproject_value(value, _depth, st, _limits, _exact?) when is_function(value), do: {:fun, st}

  defp fproject_value(%module{} = struct, depth, st, limits, _exact?) do
    {pairs, st} = fproject_pairs(Map.from_struct(struct), depth, st, limits)
    {{:struct, module, pairs}, st}
  end

  defp fproject_value(map, depth, st, limits, _exact?) when is_map(map) do
    {pairs, st} = fproject_pairs(map, depth, st, limits)
    {{:map, pairs}, st}
  end

  defp fproject_value(list, depth, st, limits, _exact?) when is_list(list) do
    fproject_list(list, depth + 1, st, limits, [])
  end

  defp fproject_value(tuple, depth, st, limits, _exact?) when is_tuple(tuple) do
    st0 = preflight!(st, tuple_size(tuple))

    {projected, st_out} =
      Enum.reduce(Tuple.to_list(tuple), {[], st0}, fn element, {acc, st_acc} ->
        {pv, st_value} = fproject(element, depth + 1, st_acc, limits, false)
        {[pv | acc], st_value}
      end)

    {{:tuple, Enum.reverse(projected)}, st_out}
  end

  # Non-binary bitstrings (is_binary/is_list/... all failed above).
  defp fproject_value(value, _depth, st, _limits, _exact?) when is_bitstring(value),
    do: {:bits, st}

  # Every BEAM term class is covered above; this clause is unreachable but
  # keeps the projection structurally total against future term classes.
  defp fproject_value(_value, _depth, st, _limits, _exact?), do: {:unknown, st}

  defp fproject_list([], _depth, st, _limits, acc), do: {Enum.reverse(acc), st}

  defp fproject_list([head | tail], depth, st, limits, acc) when is_list(tail) do
    {ph, st} = fproject(head, depth, st, limits, false)
    fproject_list(tail, depth, st, limits, [ph | acc])
  end

  defp fproject_list([head | improper_tail], depth, st, limits, acc) do
    {ph, st_head} = fproject(head, depth, st, limits, false)
    {pt, st_tail} = fproject(improper_tail, depth, st_head, limits, false)
    {Enum.reverse([pt, ph | acc]), st_tail}
  end

  # Map/struct entries: every entry kept as a {projected_key, projected_value}
  # pair, the term policy applied to KEYS too (allowlisted key names stay
  # exact), sorted by term order of the PROJECTED pairs.
  defp fproject_pairs(map, depth, st, limits) do
    st0 = preflight!(st, map_size(map))

    {pairs, st_out} =
      Enum.reduce(map, {[], st0}, fn {k, v}, {acc, st_acc} ->
        exact? = exact_key?(k, limits)
        {pk, st_key} = fproject_key(k, depth, st_acc, limits, exact?)
        {pv, st_value} = fproject(v, depth + 1, st_key, limits, exact?)
        {[{pk, pv} | acc], st_value}
      end)

    {Enum.sort(pairs), st_out}
  end

  defp fproject_key(k, _depth, st, limits, exact?) when is_binary(k) do
    cond do
      byte_size(k) > limits.max_key_bytes -> {:bin, st}
      exact? -> {bound_identifier(k), spend_bytes(st, byte_size(k), limits)}
      true -> {:bin, st}
    end
  end

  defp fproject_key(k, depth, st, limits, _exact?), do: fproject(k, depth + 1, st, limits, false)

  defp exact_key?(k, limits) when is_atom(k),
    do: MapSet.member?(limits.exact_keys, Atom.to_string(k))

  defp exact_key?(k, limits) when is_binary(k), do: MapSet.member?(limits.exact_keys, k)
  defp exact_key?(_k, _limits), do: false

  defp bound_identifier(value) when byte_size(value) > @identifier_bytes do
    value
    |> binary_part(0, @identifier_bytes)
    |> OutputLimit.valid_utf8_prefix()
  end

  defp bound_identifier(value), do: value
end
