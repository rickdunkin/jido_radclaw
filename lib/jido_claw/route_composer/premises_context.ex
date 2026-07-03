defmodule JidoClaw.RouteComposer.PremisesContext do
  @moduledoc """
  Renders the composer's seed premises (`state.premises`) into the markdown
  block worker waves receive at the head of their `:extra_context` (AR-9
  rider — alp-river unadopted #3, "hand premises to stage agents").

  Premises are the front door's launch assumptions (`path`, `est_size`,
  `graduated_from`, operator extras). Handing them to every stage worker lets
  a worker *notice* a contradiction instead of self-reporting blind — the
  rendered block ends with the one actionable instruction: contradiction ⇒
  include `scope-shift` in the typed `signals` output (the topic every stage
  already publishes; the emit mapper turns it into the live signal the router
  reacts to).

  `render/1` is **total over any term**: `create_parent_run/1` persists
  `:premises` through `json_safe/1` and recovery hands the durable value
  straight back, so a malformed/legacy value must degrade to `""` (no premises
  block — today's blind behavior), never crash the wave. Only a non-empty map
  renders. Output is deterministic (key-sorted) and **bounded by
  construction**: rendered keys and values are byte-clipped UTF-8-safe (values
  bounded at the source via `inspect/2` limits for non-binaries), the entry
  count is capped, and the whole block is held under `@block_byte_budget`
  structurally — overflow drops whole trailing (sort-order) entries behind one
  `- …[N premises omitted]` marker line, never a tail byte-clip, so the header
  and the actionable `scope-shift` instruction always survive. A hostile or
  huge premises map cannot flood a stage prompt (the block prepends to *every*
  worker wave); premises that fit render byte-identically to the unbounded
  form, with no marker.

  Gate waves intentionally receive **no** premises block (`run_gate_wave/5`) —
  a human gate doesn't self-report `scope-shift`.
  """

  @header "### Premises"
  @instruction "If any of your findings or work contradicts a premise, " <>
                 "include `scope-shift` in your `signals` output."

  # Source bounds for non-binary values: `limit` caps collection elements,
  # `printable_limit` caps embedded strings — the inspect output is bounded
  # BEFORE the byte clip, never built huge first.
  @inspect_limit 25
  @inspect_printable_limit 500
  @value_byte_budget 600
  # Keys are markdown labels; the front door's real keys are ~15 chars.
  @key_byte_budget 120
  # Realistic premises maps hold <10 entries.
  @max_entries 32
  # Whole-block cap incl. header, omission marker, and instruction
  # (proportionate to `ArtifactContext`'s 16_000 total cap). A max-fat line is
  # <800 bytes (clipped key + clipped value + markup), so at least 7 entries
  # always fit — the header/instruction can never be squeezed out.
  @block_byte_budget 6_000
  @elision "…[premise truncated]"
  # Omission-marker line: `- …[N premises omitted]`, appended whenever the
  # entry-count cap or the block byte budget dropped entries.
  @omitted_marker_prefix "…["

  @doc """
  Render `premises` into the worker-facing markdown block.

  A non-empty map renders as `### Premises` + sorted `- **key**: value` lines
  + the `scope-shift` instruction. Anything else (nil, empty map, or any
  non-map term — e.g. a malformed durable value) renders as `""`.
  """
  @spec render(term()) :: String.t()
  def render(premises) when is_map(premises) and map_size(premises) > 0 do
    lines =
      premises
      |> Enum.map(fn {key, value} -> {key_text(key), value} end)
      # Sorted on the FULL key text (ordering is unaffected by the key clip),
      # then count-capped.
      |> Enum.sort_by(fn {key_string, _value} -> key_string end)
      |> Enum.take(@max_entries)
      |> Enum.map(fn {key_string, value} ->
        IO.iodata_to_binary([
          "- **",
          clip(key_string, @key_byte_budget),
          "**: ",
          value_text(value)
        ])
      end)

    total = map_size(premises)
    block = assemble(lines, 0)

    # Two-pass total cap: a block that fits whole (nothing count-capped)
    # emits as-is — reserving marker space can never cause the omission it
    # would mark. Otherwise re-fold under the budget, dropping whole trailing
    # entries (a tail byte-clip would amputate the instruction line).
    if total == length(lines) and byte_size(block) <= @block_byte_budget do
      block
    else
      fold_within_budget(lines, total)
    end
  end

  def render(_absent_or_malformed), do: ""

  defp key_text(key) when is_binary(key), do: key
  defp key_text(key) when is_atom(key), do: Atom.to_string(key)
  defp key_text(key), do: inspect(key, limit: 5, printable_limit: 100)

  defp value_text(value) when is_binary(value), do: clip(value, @value_byte_budget)

  defp value_text(value) do
    value
    |> inspect(limit: @inspect_limit, printable_limit: @inspect_printable_limit)
    |> clip(@value_byte_budget)
  end

  # Byte-budgeted, UTF-8-safe clip (values at @value_byte_budget, rendered
  # keys at @key_byte_budget). Deliberately a single self-recursive helper —
  # the recursive call walks the boundary back off a partial codepoint (vs
  # `ArtifactContext`'s two-arity cap/truncate pair, distinct shape).
  defp clip(text, budget) when byte_size(text) <= budget, do: text

  defp clip(text, budget) do
    prefix = binary_part(text, 0, budget)

    if String.valid?(prefix),
      do: prefix <> @elision,
      else: clip(text, budget - 1)
  end

  # Keep the longest sorted prefix of `lines` whose assembled block — with the
  # omission marker for everything left out — fits the byte budget. Reached
  # only when the count cap or the budget forces an omission, so the final
  # assemble always carries a marker (omitted >= 1: if all lines fit with no
  # count-capped remainder, the marker-less pass already emitted).
  defp fold_within_budget(lines, total) do
    kept =
      Enum.reduce_while(lines, [], fn line, kept ->
        candidate = [line | kept]
        omitted = total - length(candidate)

        if byte_size(assemble(Enum.reverse(candidate), omitted)) <= @block_byte_budget,
          do: {:cont, candidate},
          else: {:halt, kept}
      end)

    assemble(Enum.reverse(kept), total - length(kept))
  end

  defp assemble(lines, 0) do
    IO.iodata_to_binary([@header, "\n", Enum.intersperse(lines, "\n"), "\n\n", @instruction])
  end

  defp assemble(lines, omitted) do
    IO.iodata_to_binary([
      @header,
      "\n",
      Enum.intersperse(lines, "\n"),
      "\n- ",
      @omitted_marker_prefix,
      Integer.to_string(omitted),
      " premises omitted]",
      "\n\n",
      @instruction
    ])
  end
end
