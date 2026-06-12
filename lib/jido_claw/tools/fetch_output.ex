defmodule JidoClaw.Tools.FetchOutput do
  @moduledoc """
  Retrieve the full stored output behind an `output_ref` produced by
  `JidoClaw.Tools.OutputShaper`.

  Shaped tool results (e.g. a compressed `mix test` run) carry a footer
  like `[full output: 184320 bytes — fetch_output ref=out_a1b2c3d4e5f6]`.
  This tool fetches that stored text — tenant-scoped — and slices it so
  the agent can drill into detail without re-running the command.

  Built with `use JidoClaw.Tools.Action`, so the shared markers and
  pipeline come free; the shaper's allowlist keeps it from shaping its
  own results. A greedy fetch is clipped *here*, not by the wrapper's
  `OutputLimit` backstop: the clip is byte-aware and direction-aware
  (tail slices keep the **last** lines), appends a refine-hint note
  (dropped when the cap is too small to hold it), and the result's
  `returned_lines`/`selected_lines`/`clipped` keys report what the
  content actually holds — the backstop cutting after the counts were
  computed would make the metadata lie.
  """

  use JidoClaw.Tools.Action,
    name: "fetch_output",
    description:
      "Fetch the full stored output behind an output_ref from a shaped tool result " <>
        "(e.g. run_command/git_diff). Slice with grep, tail, head, or offset+limit " <>
        "instead of fetching everything.",
    category: "shell",
    tags: ["shell", "read"],
    output_schema: [
      content: [type: :string, required: true],
      total_lines: [type: :integer, required: true],
      returned_lines: [type: :integer, required: true],
      selected_lines: [type: :integer],
      clipped: [type: :boolean],
      truncated: [type: :boolean],
      captured_bytes: [type: :integer]
    ],
    schema: [
      ref: [
        type: :string,
        required: true,
        doc: "The output ref from a shaped tool result, e.g. \"out_a1b2c3d4e5f6\"."
      ],
      grep: [
        type: :string,
        required: false,
        doc:
          "Regex; returns matching lines prefixed with their line numbers. " <>
            "Highest precedence — overrides tail/head/offset/limit."
      ],
      tail: [
        type: :pos_integer,
        required: false,
        doc: "Return the last N lines. Precedence: grep > tail > head > offset/limit."
      ],
      head: [
        type: :pos_integer,
        required: false,
        doc: "Return the first N lines. Precedence: grep > tail > head > offset/limit."
      ],
      offset: [
        type: :non_neg_integer,
        default: 0,
        doc: "Start line (0-indexed) for the offset/limit window (lowest precedence)."
      ],
      limit: [
        type: :non_neg_integer,
        default: 2000,
        doc: "Max lines for the offset/limit window (lowest precedence)."
      ]
    ]

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.ToolOutput
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.Tools.OutputLimit
  alias JidoClaw.Tools.OutputShaper.Generic

  # Reserved for the clip-note line (~120 bytes incl. counts) plus its
  # join newline when a selection must be cut to the inline cap. Also
  # the threshold below which the note is dropped entirely — a cap that
  # cannot hold note + content spends every byte on content.
  @clip_note_allowance 160

  @impl Jido.Action
  def run(%{ref: ref} = params, context) do
    MCPScope.wrap(:fetch_output, params, context, fn enriched ->
      tool_context = Map.get(enriched, :tool_context) || %{}

      with {:ok, tenant_id} <- require_tenant(tool_context),
           {:ok, row} <- lookup(ref, tenant_id, tool_context),
           {:ok, slicer} <- build_slicer(params) do
        lines = String.split(row.content || "", "\n")
        {selected, direction} = slicer.(lines)
        {content, returned, clipped?} = clip(selected, direction)

        {:ok,
         %{
           content: content,
           total_lines: length(lines),
           returned_lines: returned,
           selected_lines: length(selected),
           clipped: clipped?,
           truncated: row.truncated,
           captured_bytes: row.byte_size
         }}
      end
    end)
  end

  # -- Private ----------------------------------------------------------------

  defp require_tenant(tool_context) do
    case Map.get(tool_context, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" ->
        {:ok, tenant_id}

      _ ->
        {:error, "fetch_output requires a tenant scope (no tenant_id in tool_context)"}
    end
  end

  defp lookup(ref, tenant_id, tool_context) do
    actor = Map.get(tool_context, :actor) || Actor.system(tenant_id)

    case ToolOutput.by_ref(ref, tenant: tenant_id, actor: actor) do
      {:ok, row} -> {:ok, row}
      {:error, _} -> {:error, "no stored output for ref #{ref} (expired or unknown)"}
    end
  end

  # Precedence: grep > tail > head > offset/limit. Slicers return the
  # rendered line list plus the keep-direction the clip step honors when
  # the selection exceeds the inline cap: `:tail` keeps the LAST lines
  # (that's what tail means), everything else keeps the first.
  defp build_slicer(params) do
    cond do
      is_binary(grep_param(params)) -> grep_slicer(grep_param(params))
      is_integer(Map.get(params, :tail)) -> {:ok, tail_slicer(Map.get(params, :tail))}
      is_integer(Map.get(params, :head)) -> {:ok, head_slicer(Map.get(params, :head))}
      true -> {:ok, window_slicer(Map.get(params, :offset, 0), Map.get(params, :limit, 2000))}
    end
  end

  defp grep_param(params), do: Map.get(params, :grep)

  defp grep_slicer(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {:ok,
         fn lines ->
           matches =
             lines
             |> Enum.with_index(1)
             |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
             |> Enum.map(fn {line, n} -> "#{n}: #{line}" end)

           {matches, :head}
         end}

      {:error, {reason, at}} ->
        {:error, "invalid grep regex: #{reason} (at position #{at})"}
    end
  end

  defp tail_slicer(n), do: fn lines -> {Enum.take(lines, -n), :tail} end

  defp head_slicer(n), do: fn lines -> {Enum.take(lines, n), :head} end

  defp window_slicer(offset, limit) do
    fn lines -> {Enum.slice(lines, offset, limit), :head} end
  end

  # -- Clip to the inline cap ---------------------------------------------------

  # Self-cap instead of letting the wrapper's OutputLimit backstop cut
  # the joined content AFTER the line counts were computed (that made
  # `returned_lines` lie). Budget math runs on the rendered lines (a
  # grep line's number prefix counts), and the counts describe what the
  # content actually holds.
  defp clip(selected, direction) do
    joined = Enum.join(selected, "\n")

    if byte_size(joined) <= OutputLimit.max_bytes() do
      {joined, length(selected), false}
    else
      do_clip(selected, direction, OutputLimit.max_bytes())
    end
  end

  defp do_clip(selected, direction, max_bytes) when max_bytes > @clip_note_allowance do
    budget = max_bytes - @clip_note_allowance
    kept = clip_lines(selected, direction, budget)
    returned = length(kept)
    note = clip_note(direction, returned, length(selected))

    content =
      case direction do
        :head -> IO.iodata_to_binary([Enum.join(kept, "\n"), "\n", note])
        :tail -> IO.iodata_to_binary([note, "\n", Enum.join(kept, "\n")])
      end

    {content, returned, true}
  end

  # Cap too small to hold the note plus any content: the note is only a
  # hint — the structured clipped/selected_lines keys carry the real
  # signal — so drop it and spend the whole cap on content. The self-cap
  # must be absolute; emitting an oversized note here would hand the
  # result back to OutputLimit's marker, the exact lie this module's
  # clipping exists to prevent.
  defp do_clip(selected, direction, max_bytes) do
    kept = clip_lines(selected, direction, max_bytes)

    {Enum.join(kept, "\n"), length(kept), true}
  end

  defp clip_lines(selected, :head, budget) do
    case take_within(selected, budget) do
      [] -> [cut_line(List.first(selected), :head, budget)]
      kept -> kept
    end
  end

  defp clip_lines(selected, :tail, budget) do
    reversed = Enum.reverse(selected)

    case take_within(reversed, budget) do
      [] -> [cut_line(hd(reversed), :tail, budget)]
      kept -> Enum.reverse(kept)
    end
  end

  # Accumulate whole lines within `budget` bytes, each costed at its own
  # size + 1 for the join newline (one byte conservative on the first).
  defp take_within(lines, budget) do
    lines
    |> Enum.reduce_while({[], 0}, fn line, {kept, used} ->
      cost = byte_size(line) + 1

      if used + cost <= budget do
        {:cont, {[line | kept], used + cost}}
      else
        {:halt, {kept, used}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # A single selected line can alone exceed the budget (one enormous
  # grep match) — cut within it rather than return nothing. `:head`
  # keeps the line's prefix; `:tail` keeps its suffix (tail semantics:
  # the end is what was asked for).
  defp cut_line(line, :head, budget) do
    line
    |> binary_part(0, min(budget, byte_size(line)))
    |> OutputLimit.valid_utf8_prefix()
  end

  defp cut_line(line, :tail, budget) do
    keep = min(budget, byte_size(line))

    line
    |> binary_part(byte_size(line) - keep, keep)
    |> Generic.valid_utf8_suffix()
  end

  defp clip_note(:head, returned, selected) do
    "[fetch_output clipped: showing first #{returned} of #{selected} selected lines" <>
      " — refine with grep/head/tail/offset+limit]"
  end

  defp clip_note(:tail, returned, selected) do
    "[fetch_output clipped: showing last #{returned} of #{selected} selected lines" <>
      " — refine with grep/head/tail/offset+limit]"
  end
end
