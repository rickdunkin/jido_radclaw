defmodule JidoClaw.Tools.OutputShaper.GitDiff do
  @moduledoc """
  Unified-diff parser for `JidoClaw.Tools.OutputShaper`.

  Compresses a `git diff` into a per-file stat header (`N files changed,
  +X/−Y` plus one `path | +a −b` line per file) followed by as many
  whole per-file diff chunks as fit the byte budget; the remainder is
  counted in a ref-free elision line (the shaper appends the
  `fetch_output` footer after storage resolves). Returns `:nomatch` when
  no `diff --git` headers are present, so the shaper falls back to
  generic head+tail.
  """

  alias JidoClaw.Tools.OutputShaper.Parsed

  @file_header ~r/^diff --git /m

  @spec parse(binary(), pos_integer()) :: {:ok, Parsed.t()} | :nomatch
  def parse(text, budget_bytes) when is_binary(text) do
    case file_chunks(text) do
      [] -> :nomatch
      chunks -> {:ok, compose(text, chunks, budget_bytes)}
    end
  end

  defp file_chunks(text) do
    # Each chunk ends at the next header's start or the end of the diff —
    # chunk_every(2, 1, [end]) pairs every start with its successor in
    # one pass.
    @file_header
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, _len} | _] -> start end)
    |> Enum.chunk_every(2, 1, [byte_size(text)])
    |> Enum.map(fn [start, stop] ->
      chunk = binary_part(text, start, stop - start)
      %{text: chunk, stat: chunk_stat(chunk)}
    end)
  end

  defp chunk_stat(chunk) do
    lines = String.split(chunk, "\n")

    path =
      case Regex.run(~r/^diff --git a\/(.+?) b\/(.+?)\s*$/, List.first(lines) || "") do
        [_, a, b] when a == b -> b
        [_, a, b] -> "#{a} → #{b}"
        _ -> "(unknown)"
      end

    {insertions, deletions, binary?} =
      Enum.reduce(lines, {0, 0, false}, &classify_line/2)

    %{path: path, insertions: insertions, deletions: deletions, binary?: binary?}
  end

  defp classify_line(line, {insertions, deletions, binary?}) do
    cond do
      String.starts_with?(line, "+++") or String.starts_with?(line, "---") ->
        {insertions, deletions, binary?}

      String.starts_with?(line, "+") ->
        {insertions + 1, deletions, binary?}

      String.starts_with?(line, "-") ->
        {insertions, deletions + 1, binary?}

      String.starts_with?(line, "Binary files ") ->
        {insertions, deletions, true}

      true ->
        {insertions, deletions, binary?}
    end
  end

  defp compose(text, chunks, budget_bytes) do
    stats = Enum.map(chunks, & &1.stat)
    files_changed = length(chunks)
    total_ins = Enum.reduce(stats, 0, &(&1.insertions + &2))
    total_del = Enum.reduce(stats, 0, &(&1.deletions + &2))

    header =
      "git diff — #{files_changed} files changed, +#{total_ins}/−#{total_del}\n\n" <>
        Enum.map_join(stats, "\n", &stat_line/1)

    {kept, elided} = apply_budget(chunks, budget_bytes)

    body_parts =
      [header | Enum.map(kept, &String.trim_trailing(&1.text))] ++
        case elided do
          [] ->
            []

          elided ->
            bytes = Enum.reduce(elided, 0, &(byte_size(&1.text) + &2))
            ["... [#{length(elided)} more files: #{bytes} bytes of diff elided]"]
        end

    body = Enum.join(body_parts, "\n\n")

    summary = %{
      files_changed: files_changed,
      insertions: total_ins,
      deletions: total_del,
      files:
        Enum.map(stats, fn stat ->
          %{path: stat.path, insertions: stat.insertions, deletions: stat.deletions}
        end)
    }

    %Parsed{body: body, summary: summary, compressed?: byte_size(body) < byte_size(text)}
  end

  defp stat_line(%{binary?: true} = stat), do: "#{stat.path} | binary"
  defp stat_line(stat), do: "#{stat.path} | +#{stat.insertions} −#{stat.deletions}"

  # Sequential prefix until the budget is exhausted. Unlike test
  # failures there is no always-include-first rule: the stat header plus
  # the ref already cover an oversized first chunk honestly.
  defp apply_budget(chunks, budget_bytes), do: do_budget(chunks, [], 0, budget_bytes)

  defp do_budget([], kept, _used, _budget), do: {Enum.reverse(kept), []}

  defp do_budget([chunk | rest] = remaining, kept, used, budget) do
    if used + byte_size(chunk.text) > budget do
      {Enum.reverse(kept), remaining}
    else
      do_budget(rest, [chunk | kept], used + byte_size(chunk.text), budget)
    end
  end
end
