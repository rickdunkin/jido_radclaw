defmodule JidoClaw.Display.StatusBar do
  @moduledoc """
  Pure module that computes the status bar ANSI string.
  Width-adaptive — drops segments right-to-left when terminal is narrow.
  """

  alias JidoClaw.Config

  @doc """
  Render the status bar string for the given display and tracker state.
  Returns an ANSI-formatted string.
  """
  @spec render(map(), map(), non_neg_integer()) :: String.t()
  def render(display_state, tracker_state, width \\ 120) do
    model = display_state.model || "unknown"
    provider = display_state.provider || "unknown"
    context_window = display_state.context_window || 131_072
    {total_tokens, child_count} = metrics(tracker_state)
    elapsed = session_elapsed(display_state)

    pct =
      if context_window > 0,
        do: min(round(total_tokens / context_window * 100), 100),
        else: 0

    # Build segments from left (required) to right (optional)
    segments = [
      {:required, " \e[36m⚕\e[0m #{model}"},
      {:required, provider},
      {:required, "#{format_tokens(total_tokens)}/#{format_tokens(context_window)}"},
      profile_segment(display_state),
      {:optional, "#{progress_bar(pct, 10)} #{pct}%"},
      streaming_segment(display_state),
      cost_segment(total_tokens, display_state),
      {:optional, elapsed},
      {:optional, "#{child_count} agents"}
    ]

    build_bar(Enum.reject(segments, &is_nil/1), width)
  end

  # Estimated session cost from LLMDB model metadata; `nil` (segment
  # dropped) for local/unknown models without cost data. Format mirrors
  # the goodbye banner (`JidoClaw.CLI.Branding.goodbye/1`).
  defp cost_segment(tokens, %{model_meta: meta}) do
    case Config.estimated_cost(tokens, meta) do
      nil -> nil
      cost when cost < 0.001 -> {:optional, "~$0.00"}
      cost -> {:optional, "~$#{:erlang.float_to_binary(cost, decimals: 4)}"}
    end
  end

  defp cost_segment(_tokens, _display_state), do: nil

  @doc """
  Streaming-shell-output segment — cyan `⟲ streaming` (with active
  count when more than one stream is live). `nil` when no streams
  are active so non-streaming UX is unchanged.
  """
  @spec streaming_segment(map()) :: {:optional, String.t()} | nil
  def streaming_segment(%{streaming_sessions: %{} = sessions}) do
    case map_size(sessions) do
      0 -> nil
      1 -> {:optional, " \e[36m⟲\e[0m streaming"}
      n -> {:optional, " \e[36m⟲\e[0m streaming (#{n})"}
    end
  end

  def streaming_segment(_), do: nil

  @doc """
  Profile segment — yellow `⚑ <name>` when the active profile differs
  from the default, `nil` otherwise so the bar stays unchanged for
  non-profile users.
  """
  @spec profile_segment(map()) :: {:optional, String.t()} | nil
  def profile_segment(%{profile: profile, default_profile: default})
      when is_binary(profile) and profile != default do
    {:optional, " \e[33m⚑ #{profile}\e[0m"}
  end

  def profile_segment(_), do: nil

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
    visible_len = Enum.sum_by(all, &strip_ansi_length/1)
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
  @spec format_tokens(number()) :: String.t()
  def format_tokens(n) when n < 1000, do: "#{n}"

  def format_tokens(n) when n < 1_000_000 do
    k = Float.round(n / 1000, 1)
    if k == trunc(k), do: "#{trunc(k)}K", else: "#{k}K"
  end

  def format_tokens(n), do: "#{Float.round(n / 1_000_000, 1)}M"

  @doc "Render a progress bar: [██████░░░░]"
  @spec progress_bar(number(), non_neg_integer()) :: String.t()
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

  # Session elapsed comes from the Display state's session_started_at (set
  # when the REPL establishes a session), not from process/tracker timers.
  defp session_elapsed(%{session_started_at: started_at}) when is_integer(started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    format_elapsed(div(elapsed_ms, 1000))
  end

  defp session_elapsed(_), do: "0s"

  defp metrics(%JidoClaw.SwarmView{} = view) do
    {view.total_tokens, length(view.agents)}
  end

  defp metrics(%{agents: agents}) when is_map(agents) do
    total_tokens =
      Enum.reduce(agents, 0, fn {_id, agent}, acc -> acc + agent.tokens end)

    child_count = Enum.count(agents, fn {id, _} -> id != "main" end)

    {total_tokens, child_count}
  end

  defp format_elapsed(s) when s < 60, do: "#{s}s"
  defp format_elapsed(s) when s < 3600, do: "#{div(s, 60)}m"
  defp format_elapsed(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
