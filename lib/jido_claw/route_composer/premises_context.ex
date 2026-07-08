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

  ## Typed sections (item 9 — OB1-2)

  The typed premises keys (`JidoClaw.RouteComposer.Premises`) render as
  dedicated sections between the generic bullet list and the instruction —
  `### Acceptance criteria` as `AC1.`-numbered lines (the stable id contract
  consumers cite), plus legible `### Evaluation principles` /
  `### Exit conditions` lists — and are EXCLUDED from the generic
  `- **key**:` lines. Absent typed keys render **byte-identically** to the
  pre-item-9 output (pinned by test); a malformed typed value (tolerant
  accessors read it as empty) renders nowhere.

  `render/1` is **total over any term**: `create_parent_run/1` persists
  `:premises` through `json_safe/1` and recovery hands the durable value
  straight back, so a malformed/legacy value must degrade to `""` (no premises
  block — today's blind behavior), never crash the wave. Only a non-empty map
  renders. Output is deterministic (key-sorted) and **bounded by
  construction**: rendered keys and values are byte-clipped UTF-8-safe (values
  bounded at the source via `inspect/2` limits for non-binaries), entry and
  section counts are capped, and the whole block is held under
  `@block_byte_budget` structurally — typed sections fold first into their own
  `@typed_byte_budget` (dropping whole trailing sections behind a marker; the
  count-capped acceptance-criteria section always fits), then generic overflow
  drops whole trailing (sort-order) entries behind one `- …[N premises
  omitted]` marker line, never a tail byte-clip, so the header and the
  actionable `scope-shift` instruction always survive. A hostile or huge
  premises map cannot flood a stage prompt (the block prepends to *every*
  worker wave); premises that fit render byte-identically to the unbounded
  form, with no marker.

  Gate waves intentionally receive **no** premises block (`run_gate_wave/5`) —
  a human gate doesn't self-report `scope-shift` (its premises-lint payload
  rides the gate details instead).
  """

  alias JidoClaw.RouteComposer.Premises

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
  # (proportionate to `ArtifactContext`'s 16_000 total cap). With no typed
  # sections a max-fat generic line is <800 bytes, so at least 7 entries
  # always fit; a max-fat typed block (≤ @typed_byte_budget) still leaves
  # room for the header, marker, and instruction — they can never be
  # squeezed out.
  @block_byte_budget 6_000
  @elision "…[premise truncated]"
  # Omission-marker line: `- …[N premises omitted]`, appended whenever the
  # entry-count cap or the block byte budget dropped entries.
  @omitted_marker_prefix "…["

  # Typed-section bounds (item 9): the acceptance-criteria section is
  # structurally under the typed budget at its caps (12 lines × ~270B — id +
  # clipped value + elision marker — plus header and count marker ≈ 3.3k), so
  # section-folding only ever drops the trailing principles/exit sections.
  @typed_byte_budget 3_600
  @typed_value_budget 240
  @max_criteria 12
  @max_principles 6
  @max_exit_conditions 6
  @principle_name_budget 60
  @principle_desc_budget 160
  @typed_sections_marker "…[further premises sections omitted]"

  # The typed keys never render as generic bullets (even when malformed —
  # the tolerant accessors decide whether they render at all).
  @typed_keys Premises.typed_keys()

  @doc """
  Render `premises` into the worker-facing markdown block.

  A non-empty map renders as `### Premises` + sorted `- **key**: value` lines
  + the typed sections (when present) + the `scope-shift` instruction.
  Anything else (nil, empty map, or any non-map term — e.g. a malformed
  durable value) renders as `""`.
  """
  @spec render(term()) :: String.t()
  def render(premises) when is_map(premises) and map_size(premises) > 0 do
    typed_block = typed_block(premises)

    entries =
      premises
      |> Enum.map(fn {key, value} -> {key_text(key), value} end)
      |> Enum.reject(fn {key_string, _value} -> key_string in @typed_keys end)
      # Sorted on the FULL key text (ordering is unaffected by the key clip),
      # then count-capped.
      |> Enum.sort_by(fn {key_string, _value} -> key_string end)

    lines =
      entries
      |> Enum.take(@max_entries)
      |> Enum.map(fn {key_string, value} ->
        IO.iodata_to_binary([
          "- **",
          clip(key_string, @key_byte_budget),
          "**: ",
          value_text(value)
        ])
      end)

    total = length(entries)
    block = assemble(lines, 0, typed_block)

    # Two-pass total cap: a block that fits whole (nothing count-capped)
    # emits as-is — reserving marker space can never cause the omission it
    # would mark. Otherwise re-fold under the budget, dropping whole trailing
    # entries (a tail byte-clip would amputate the instruction line).
    if total == length(lines) and byte_size(block) <= @block_byte_budget do
      block
    else
      fold_within_budget(lines, total, typed_block)
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
  defp fold_within_budget(lines, total, typed_block) do
    kept =
      Enum.reduce_while(lines, [], fn line, kept ->
        candidate = [line | kept]
        omitted = total - length(candidate)

        if byte_size(assemble(Enum.reverse(candidate), omitted, typed_block)) <=
             @block_byte_budget,
           do: {:cont, candidate},
           else: {:halt, kept}
      end)

    assemble(Enum.reverse(kept), total - length(kept), typed_block)
  end

  # No typed block: byte-identical to the pre-item-9 assembly.
  defp assemble(lines, omitted, "") do
    IO.iodata_to_binary([@header, "\n", bullet_region(lines, omitted), "\n\n", @instruction])
  end

  # All-typed premises (no generic bullets survive/exist): the bullet region
  # and its separator drop out entirely.
  defp assemble([], 0, typed_block) do
    IO.iodata_to_binary([@header, "\n\n", typed_block, "\n\n", @instruction])
  end

  defp assemble(lines, omitted, typed_block) do
    IO.iodata_to_binary([
      @header,
      "\n",
      bullet_region(lines, omitted),
      "\n\n",
      typed_block,
      "\n\n",
      @instruction
    ])
  end

  defp bullet_region(lines, 0), do: Enum.intersperse(lines, "\n")

  defp bullet_region(lines, omitted) do
    [
      Enum.intersperse(lines, "\n"),
      "\n- ",
      @omitted_marker_prefix,
      Integer.to_string(omitted),
      " premises omitted]"
    ]
  end

  # ---------------------------------------------------------------------------
  # Typed sections (item 9)
  # ---------------------------------------------------------------------------

  defp typed_block(premises) do
    sections =
      Enum.reject(
        [criteria_section(premises), principles_section(premises), exits_section(premises)],
        &(&1 == "")
      )

    fold_typed(sections)
  end

  defp fold_typed([]), do: ""

  defp fold_typed(sections) do
    joined = Enum.join(sections, "\n\n")

    if byte_size(joined) <= @typed_byte_budget do
      joined
    else
      fold_typed_sections(sections)
    end
  end

  # Drop whole trailing sections (exit conditions first, then principles —
  # the AC section is structurally within the budget at its caps) behind one
  # marker line.
  defp fold_typed_sections(sections) do
    kept =
      Enum.reduce_while(sections, [], fn section, kept ->
        candidate = [section | kept]
        block = Enum.join(Enum.reverse(candidate, [@typed_sections_marker]), "\n\n")

        if byte_size(block) <= @typed_byte_budget,
          do: {:cont, candidate},
          else: {:halt, kept}
      end)

    Enum.join(Enum.reverse(kept, [@typed_sections_marker]), "\n\n")
  end

  # `AC1.`-numbered lines — the stable identity contract (orca OQ-2):
  # consumers (reviewer lenses, `verify_certificate`) cite these ids.
  defp criteria_section(premises) do
    case Premises.criteria_with_ids(premises) do
      [] ->
        ""

      pairs ->
        shown = Enum.take(pairs, @max_criteria)

        lines =
          Enum.map(shown, fn {id, text} -> [id, ". ", clip(text, @typed_value_budget)] end)

        IO.iodata_to_binary([
          "### Acceptance criteria\n",
          Enum.intersperse(lines, "\n"),
          count_marker(length(pairs) - length(shown), "acceptance criteria")
        ])
    end
  end

  defp principles_section(premises) do
    case Premises.principles(premises) do
      [] ->
        ""

      principles ->
        shown = Enum.take(principles, @max_principles)

        lines =
          Enum.map(shown, fn principle ->
            [
              "- ",
              clip(principle["name"], @principle_name_budget),
              " (weight ",
              weight_text(principle["weight"]),
              ")",
              description_part(principle["description"])
            ]
          end)

        IO.iodata_to_binary([
          "### Evaluation principles\n",
          Enum.intersperse(lines, "\n"),
          count_marker(length(principles) - length(shown), "principles")
        ])
    end
  end

  defp exits_section(premises) do
    case Premises.exit_conditions(premises) do
      [] ->
        ""

      conditions ->
        shown = Enum.take(conditions, @max_exit_conditions)
        lines = Enum.map(shown, fn condition -> ["- ", clip(condition, @typed_value_budget)] end)

        IO.iodata_to_binary([
          "### Exit conditions\n",
          Enum.intersperse(lines, "\n"),
          count_marker(length(conditions) - length(shown), "exit conditions")
        ])
    end
  end

  defp count_marker(0, _label), do: ""
  defp count_marker(omitted, label), do: "\n- …[#{omitted} #{label} omitted]"

  defp description_part(""), do: ""
  defp description_part(description), do: [": ", clip(description, @principle_desc_budget)]

  defp weight_text(weight), do: :erlang.float_to_binary(weight, decimals: 2)
end
