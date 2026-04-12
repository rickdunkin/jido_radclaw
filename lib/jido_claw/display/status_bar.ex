defmodule JidoClaw.Display.StatusBar do
  @moduledoc """
  Pure module that computes the status bar ANSI string.
  Width-adaptive — drops segments right-to-left when terminal is narrow.
  """

  @doc """
  Render the status bar string for the given display and tracker state.
  Returns an ANSI-formatted string.
  """
  def render(display_state, tracker_state, width \\ 120) do
    model = display_state.model || "unknown"
    provider = display_state.provider || "unknown"
    context_window = display_state.context_window || 131_072

    # Sum tokens across all agents
    total_tokens =
      tracker_state.agents
      |> Enum.reduce(0, fn {_id, agent}, acc -> acc + agent.tokens end)

    pct = if context_window > 0, do: round(total_tokens / context_window * 100), else: 0
    pct = min(pct, 100)

    child_count =
      tracker_state.agents
      |> Enum.count(fn {id, _} -> id != "main" end)

    elapsed = elapsed_string(tracker_state)
    # TODO: wire Config.estimated_cost
    cost = "$0.00"

    # Build segments from left (required) to right (optional)
    segments = [
      {:required, " \e[36m⚕\e[0m #{model}"},
      {:required, provider},
      {:required, "#{format_tokens(total_tokens)}/#{format_tokens(context_window)}"},
      {:optional, "#{progress_bar(pct, 10)} #{pct}%"},
      {:optional, cost},
      {:optional, elapsed},
      {:optional, "#{child_count} agents"}
    ]

    build_bar(segments, width)
  end

  defp build_bar(segments, width) do
    sep = " \e[2m│\e[0m "
    # " │ " visible chars
    sep_len = 3

    # Always include required segments
    {required, optional} = Enum.split_with(segments, fn {type, _} -> type == :required end)

    required_parts = Enum.map(required, fn {_, text} -> text end)
    optional_parts = Enum.map(optional, fn {_, text} -> text end)

    # Start with all segments, drop optional ones from right until it fits
    parts = required_parts ++ trim_optional(optional_parts, required_parts, sep_len, width)

    Enum.join(parts, sep)
  end

  defp trim_optional(optional, required, sep_len, width) do
    all = required ++ optional
    visible_len = all |> Enum.map(&strip_ansi_length/1) |> Enum.sum()
    total_sep = (length(all) - 1) * sep_len

    if visible_len + total_sep <= width do
      optional
    else
      case optional do
        [] -> []
        _ -> trim_optional(Enum.drop(optional, -1), required, sep_len, width)
      end
    end
  end

  defp strip_ansi_length(text) do
    text
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.length()
  end

  @doc "Format a token count for display (e.g. 24100 → 24.1K)"
  def format_tokens(n) when n < 1000, do: "#{n}"

  def format_tokens(n) when n < 1_000_000 do
    k = Float.round(n / 1000, 1)
    if k == trunc(k), do: "#{trunc(k)}K", else: "#{k}K"
  end

  def format_tokens(n), do: "#{Float.round(n / 1_000_000, 1)}M"

  @doc "Render a progress bar: [██████░░░░]"
  def progress_bar(pct, width) do
    filled = round(pct / 100 * width)
    empty = width - filled

    bar = String.duplicate("█", filled) <> String.duplicate("░", empty)

    color =
      cond do
        # red
        pct >= 90 -> "\e[31m"
        # yellow
        pct >= 70 -> "\e[33m"
        # green
        true -> "\e[32m"
      end

    "#{color}[#{bar}]\e[0m"
  end

  defp elapsed_string(tracker_state) do
    case get_in(tracker_state, [:agents, "main"]) do
      nil ->
        "0s"

      main ->
        elapsed_ms = System.monotonic_time(:millisecond) - main.started_at
        format_elapsed(div(elapsed_ms, 1000))
    end
  end

  defp format_elapsed(s) when s < 60, do: "#{s}s"
  defp format_elapsed(s) when s < 3600, do: "#{div(s, 60)}m"
  defp format_elapsed(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
