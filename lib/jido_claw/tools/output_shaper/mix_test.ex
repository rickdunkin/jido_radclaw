defmodule JidoClaw.Tools.OutputShaper.MixTest do
  @moduledoc """
  ExUnit (`mix test`) output parser for `JidoClaw.Tools.OutputShaper`.

  Compresses the green, never the red: progress dots and pass noise
  collapse into one counts header; failure blocks are kept **verbatim**
  (up to a byte budget, then counted). Returns `:nomatch` whenever the
  output cannot be parsed honestly — no summary line (upstream-truncated
  runs lose their tail), or a non-zero failure count whose blocks could
  not be located — so the shaper falls back to generic head+tail rather
  than fabricating counts.

  Two summary grammars are recognized (the agent runs `mix test` in
  arbitrary target projects, so both are live):

    * classic (Elixir ≤ 1.19): `3 doctests, 311 tests, 2 failures,
      1 invalid, 1 skipped, 1 excluded`
    * Elixir ≥ 1.20: `Result: 309/311 passed, 1 invalid, 1 skipped`
      plus a separate `Failed: 2 tests` line (`Result: 311 passed`
      when everything is green)

  Parsers are ref-unaware by design: the returned `body` carries no
  `fetch_output` hint. The shaper appends the footer after storage
  resolves (the ref does not exist until `Store.put/2` succeeds).
  """

  alias JidoClaw.Tools.OutputShaper.Parsed

  @block_start ~r/^\s{0,2}\d+\)\s/m
  @finished_line ~r/^Finished in (.+)$/m
  @result_line ~r/^Result: (?:(\d+)\/(\d+)|(\d+)) passed(?:\s*\([^)]*\))?(.*)$/

  @typedoc "Lean per-failure identity — first error line only, never the block text."
  @type failure :: %{
          test: String.t(),
          location: String.t() | nil,
          error: String.t() | nil
        }

  @doc """
  Parse ExUnit output into a compact body + lean summary.

  `failures_budget_bytes` caps the verbatim failure blocks; blocks
  beyond the budget are represented by an `...and N more failures`
  count line (the first block is always kept whole, regardless of
  budget — failures must never be invisible).
  """
  @spec parse(binary(), pos_integer()) :: {:ok, Parsed.t()} | :nomatch
  def parse(text, failures_budget_bytes) when is_binary(text) do
    case find_counts(text) do
      nil ->
        :nomatch

      counts ->
        blocks = failure_blocks(text)

        if counts.failures > 0 and blocks == [] do
          # Red exists but could not be parsed — never claim green.
          :nomatch
        else
          {:ok, compose(text, counts, blocks, failures_budget_bytes)}
        end
    end
  end

  # -- Summary line -----------------------------------------------------------

  # Normalized counts: %{passed, failures, invalid, skipped, excluded}.
  # The LAST qualifying line wins (a command that runs mix test twice
  # reports the most recent run's counts).
  defp find_counts(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(nil, fn line, acc ->
      case parse_result_line(line) || parse_classic_line(line) do
        nil -> acc
        counts -> counts
      end
    end)
  end

  # Elixir ≥ 1.20: `Result: 309/311 passed, 1 invalid, 1 skipped` — the
  # P/T form appears when tests failed and T is passed+failed, so
  # T - P = failures (the separate `Failed: N tests` line agrees) — or
  # `Result: 311 passed (307 doctests, 4 tests), 1 skipped` when green.
  defp parse_result_line(line) do
    case Regex.run(@result_line, String.trim(line)) do
      [_, p, t, all_passed | rest] ->
        {passed, failures} =
          case {p, all_passed} do
            {"", _} -> {String.to_integer(all_passed), 0}
            {p, _} -> {String.to_integer(p), String.to_integer(t) - String.to_integer(p)}
          end

        extras = parse_extras(rest)

        %{
          passed: passed,
          failures: failures,
          invalid: Map.get(extras, :invalid, 0),
          skipped: Map.get(extras, :skipped, 0),
          excluded: Map.get(extras, :excluded, 0)
        }

      _ ->
        nil
    end
  end

  defp parse_extras([trailing]) do
    trailing
    |> String.split(",")
    |> Enum.map(&parse_segment/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp parse_extras(_), do: %{}

  # Classic: a comma-separated list of `N <kind>` segments, e.g.
  # "3 doctests, 311 tests, 2 failures, 1 excluded". Segment-wise parsing
  # is robust to ordering, singular/plural, and optional kinds. ALL
  # segments must parse — a prose line that merely contains "n tests"
  # never qualifies.
  defp parse_classic_line(line) do
    segments =
      line
      |> String.trim()
      |> String.split(", ")
      |> Enum.map(&parse_segment/1)

    counts = Map.new(Enum.reject(segments, &is_nil/1))

    qualifying? =
      segments != [] and Enum.all?(segments, &(&1 != nil)) and
        Map.has_key?(counts, :failures) and
        (Map.has_key?(counts, :tests) or Map.has_key?(counts, :doctests) or
           Map.has_key?(counts, :properties))

    if qualifying?, do: normalize_classic(counts)
  end

  defp normalize_classic(counts) do
    total =
      Map.get(counts, :tests, 0) + Map.get(counts, :doctests, 0) +
        Map.get(counts, :properties, 0)

    failures = Map.get(counts, :failures, 0) + Map.get(counts, :errors, 0)
    invalid = Map.get(counts, :invalid, 0)
    skipped = Map.get(counts, :skipped, 0)
    excluded = Map.get(counts, :excluded, 0)

    %{
      passed: max(total - failures - invalid - skipped - excluded, 0),
      failures: failures,
      invalid: invalid,
      skipped: skipped,
      excluded: excluded
    }
  end

  defp parse_segment(segment) do
    case Regex.run(~r/^(\d+)\s+([a-z]+)$/, String.trim(segment)) do
      [_, n, kind] ->
        case kind_key(kind) do
          nil -> nil
          key -> {key, String.to_integer(n)}
        end

      _ ->
        nil
    end
  end

  defp kind_key(kind) when kind in ~w(test tests), do: :tests
  defp kind_key(kind) when kind in ~w(doctest doctests), do: :doctests
  defp kind_key(kind) when kind in ~w(property properties), do: :properties
  defp kind_key(kind) when kind in ~w(failure failures), do: :failures
  defp kind_key(kind) when kind in ~w(error errors), do: :errors
  defp kind_key("invalid"), do: :invalid
  defp kind_key("excluded"), do: :excluded
  defp kind_key("skipped"), do: :skipped
  defp kind_key(_), do: nil

  # -- Failure blocks ---------------------------------------------------------

  # Each block runs from a `  N) test ...` header to the next header or
  # the `Finished in` line, with trailing progress-dot lines trimmed.
  defp failure_blocks(text) do
    finished_at =
      case Regex.run(@finished_line, text, return: :index) do
        [{start, _len} | _] -> start
        nil -> byte_size(text)
      end

    # Each block ends at the next block's start or the `Finished in`
    # line — chunk_every(2, 1, [finished_at]) pairs every start with its
    # successor in one pass.
    @block_start
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, _len} | _] -> start end)
    |> Enum.filter(&(&1 < finished_at))
    |> Enum.chunk_every(2, 1, [finished_at])
    |> Enum.map(fn [start, stop] ->
      text
      |> binary_part(start, stop - start)
      |> trim_block()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp trim_block(block) do
    block
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.drop_while(&progress_line?/1)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp progress_line?(line) do
    trimmed = String.trim(line)
    trimmed == "" or Regex.match?(~r/^[.*?!]+$/, trimmed)
  end

  defp summarize_block(block) do
    lines = String.split(block, "\n")

    test =
      lines
      |> List.first()
      |> String.trim()
      |> then(&Regex.replace(~r/^\d+\)\s*/, &1, ""))

    location_index = Enum.find_index(lines, &location_line?/1)

    location =
      case location_index do
        nil -> nil
        i -> String.trim(Enum.at(lines, i))
      end

    %{test: test, location: location, error: first_error_line(lines, location_index)}
  end

  defp location_line?(line), do: Regex.match?(~r/^\s+\S+\.exs:\d+\s*$/, line)

  # The first message line after the location covers both raise-style
  # (`** (MatchError) ...`) and assertion-style (`Assertion with ==
  # failed`) failures; without a location line, fall back to the first
  # `** (` line.
  defp first_error_line(lines, nil) do
    Enum.find_value(lines, fn line ->
      trimmed = String.trim(line)
      if String.starts_with?(trimmed, "** ("), do: trimmed
    end)
  end

  defp first_error_line(lines, location_index) do
    lines
    |> Enum.drop(location_index + 1)
    |> Enum.find_value(fn line ->
      trimmed = String.trim(line)
      if trimmed != "", do: trimmed
    end)
  end

  # -- Composition ------------------------------------------------------------

  defp compose(text, counts, blocks, failures_budget_bytes) do
    {kept_blocks, elided_count} = apply_budget(blocks, failures_budget_bytes)

    header = header_line(counts, text)

    body_parts =
      [header | kept_blocks] ++
        if elided_count > 0, do: ["...and #{elided_count} more failures"], else: []

    body = Enum.join(body_parts, "\n\n")

    summary = %{
      passed: counts.passed,
      failed: counts.failures,
      skipped: counts.skipped,
      invalid: counts.invalid,
      failures: Enum.map(blocks, &summarize_block/1),
      finished_in: finished_in(text),
      seed: seed(text)
    }

    %Parsed{body: body, summary: summary, compressed?: byte_size(body) < byte_size(text)}
  end

  # The first block is always kept whole — a failure must never be
  # invisible just because it alone exceeds the budget.
  defp apply_budget([], _budget), do: {[], 0}

  defp apply_budget([first | rest], budget) do
    do_budget(rest, [first], byte_size(first), budget)
  end

  defp do_budget([], kept, _used, _budget), do: {Enum.reverse(kept), 0}

  defp do_budget([block | rest] = remaining, kept, used, budget) do
    if used + byte_size(block) > budget do
      {Enum.reverse(kept), length(remaining)}
    else
      do_budget(rest, [block | kept], used + byte_size(block), budget)
    end
  end

  defp header_line(counts, text) do
    base = "mix test — #{counts.passed} passed, #{counts.failures} failed"

    extras =
      [
        extra(counts, :invalid, "invalid"),
        extra(counts, :skipped, "skipped"),
        extra(counts, :excluded, "excluded")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    base <> extras <> header_suffix(text)
  end

  defp extra(counts, key, label) do
    case Map.get(counts, key, 0) do
      0 -> nil
      n -> ", #{n} #{label}"
    end
  end

  defp header_suffix(text) do
    parts =
      Enum.reject(
        [
          case finished_in(text) do
            nil -> nil
            duration -> "Finished in #{duration}"
          end,
          case seed(text) do
            nil -> nil
            seed -> "seed #{seed}"
          end
        ],
        &is_nil/1
      )

    case parts do
      [] -> ""
      parts -> " (#{Enum.join(parts, ", ")})"
    end
  end

  defp finished_in(text) do
    case Regex.run(@finished_line, text) do
      [_, rest] ->
        rest
        |> String.split(" (", parts: 2)
        |> List.first()
        |> String.trim()

      nil ->
        nil
    end
  end

  defp seed(text) do
    case Regex.run(~r/Randomized with seed (\d+)|Running ExUnit with seed: (\d+)/, text) do
      [_, seed] -> seed
      [_, "", seed] -> seed
      _ -> nil
    end
  end
end
