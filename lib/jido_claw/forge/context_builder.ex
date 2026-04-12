defmodule JidoClaw.Forge.ContextBuilder do
  @moduledoc """
  Transforms the durable session event log into structured context for LLM
  consumption. Enables selective retrieval and summarisation of session history
  without stuffing the full event log into the context window.
  """

  alias JidoClaw.Forge.Persistence

  @default_max_tokens 4_000

  @doc """
  Condenses a list of events into a compact text summary.

  Options:
    * `:max_tokens` - approximate token budget (chars / 4). Default #{@default_max_tokens}.
    * `:include_data` - whether to inline event data maps. Default `false`.
  """
  @spec summarize_events([map()], keyword()) :: String.t()
  def summarize_events(events, opts \\ [])
  def summarize_events([], _opts), do: "No events recorded."

  def summarize_events(events, opts) do
    max_chars = Keyword.get(opts, :max_tokens, @default_max_tokens) * 4
    include_data = Keyword.get(opts, :include_data, false)

    lines =
      events
      |> collapse_runs()
      |> Enum.map(&format_event(&1, include_data))

    truncate_lines(lines, max_chars)
  end

  @doc """
  Builds a narrative resume prompt suitable for injecting into an LLM's context
  when recovering or continuing a session.

  Returns `{:ok, prompt}` or `{:error, reason}`.
  """
  @spec build_resume_prompt(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_resume_prompt(session_id, opts \\ []) do
    case Persistence.context_for_resume(session_id) do
      nil ->
        {:error, :no_session}

      %{} = ctx ->
        {:ok, render_prompt(ctx, opts)}
    end
  end

  # -- Private ----------------------------------------------------------------

  defp render_prompt(ctx, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    max_chars = max_tokens * 4

    sections = [
      session_header(ctx),
      checkpoint_section(ctx),
      progress_section(ctx, max_tokens),
      error_section(ctx, max_tokens),
      recent_activity_section(ctx, max_tokens)
    ]

    prompt =
      sections
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if byte_size(prompt) > max_chars do
      binary_part(prompt, 0, max_chars) <> "\n... (truncated to fit token budget)"
    else
      prompt
    end
  end

  defp session_header(%{session: session, iteration_count: n}) do
    runner = session.runner_type || "unknown"
    phase = session.phase || :unknown

    """
    ## Session Context
    Session: #{session.name}
    Runner: #{runner}
    Current phase: #{phase}
    Completed iterations: #{n}\
    """
    |> String.trim()
  end

  defp checkpoint_section(%{last_checkpoint: nil}), do: nil

  defp checkpoint_section(%{last_checkpoint: cp}) do
    seq = cp.exec_session_sequence || 0

    """
    ## Last Checkpoint
    Checkpoint at iteration #{seq} (#{format_timestamp(cp.created_at)}).\
    """
    |> String.trim()
  end

  defp progress_section(%{iteration_count: 0}, _max_tokens), do: nil

  defp progress_section(%{iteration_count: n, last_output: nil}, _max_tokens) do
    "## Progress\n#{n} iteration(s) completed. No output recorded for the last iteration."
  end

  defp progress_section(%{iteration_count: n, last_output: data}, max_tokens) do
    status = Map.get(data, :status)
    output = Map.get(data, :output)
    seq = Map.get(data, :sequence)

    lines = ["## Progress", "#{n} iteration(s) completed."]

    lines =
      if seq, do: lines ++ ["Last execution: iteration #{seq}, status: #{status}."], else: lines

    lines =
      if output && output != "" do
        # Reserve ~25% of the total token budget for the output excerpt
        max_excerpt_chars = div(max_tokens, 4) * 4
        excerpt = output |> String.trim() |> String.slice(0, max_excerpt_chars)
        lines ++ ["Last output (excerpt):", "```", excerpt, "```"]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp error_section(%{error_history: []}, _max_tokens), do: nil

  defp error_section(%{error_history: errors}, max_tokens) do
    # Budget ~10% of tokens for the error section, split across up to 5 entries
    max_reason_chars = div(max_tokens * 4, 50) |> max(80)

    lines =
      errors
      |> Enum.take(-5)
      |> Enum.map(&format_error(&1, max_reason_chars))

    "## Errors (last #{length(lines)})\n#{Enum.join(lines, "\n")}"
  end

  defp format_error(%{event_type: "iteration.completed", data: data}, _max_reason_chars) do
    iteration = Map.get(data, "iteration") || Map.get(data, :iteration)
    prefix = if iteration, do: "iteration #{iteration}", else: "iteration"
    "- #{prefix}: completed with error status"
  end

  defp format_error(%{event_type: type, data: data}, max_reason_chars) do
    reason =
      (Map.get(data, "reason") || Map.get(data, :reason) || "unknown")
      |> to_string()
      |> String.slice(0, max_reason_chars)

    "- #{type}: #{reason}"
  end

  defp recent_activity_section(%{events_since_checkpoint: events}, max_tokens) do
    case events do
      [] ->
        nil

      events ->
        summary = summarize_events(events, max_tokens: div(max_tokens, 2), include_data: false)
        "## Activity Since Checkpoint\n#{summary}"
    end
  end

  # Collapse consecutive events of the same type into a single entry with a count.
  defp collapse_runs(events) do
    events
    |> Enum.chunk_by(& &1.event_type)
    |> Enum.flat_map(fn
      [single] -> [single]
      [first | _] = group -> [Map.put(first, :_run_count, length(group))]
    end)
  end

  defp format_event(event, include_data) do
    ts = format_timestamp(Map.get(event, :timestamp))
    type = event.event_type
    count = Map.get(event, :_run_count)
    count_suffix = if count && count > 1, do: " (x#{count})", else: ""

    base = "[#{ts}] #{type}#{count_suffix}"

    if include_data && event.data && event.data != %{} do
      "#{base} #{inspect(event.data, limit: 5, printable_limit: 200)}"
    else
      base
    end
  end

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_timestamp(_), do: "?"

  defp truncate_lines(lines, max_chars) do
    {taken, _remaining} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, size} ->
        new_size = size + byte_size(line) + 1

        if new_size > max_chars do
          {:halt, {acc ++ ["... (#{length(lines) - length(acc)} more events)"], new_size}}
        else
          {:cont, {acc ++ [line], new_size}}
        end
      end)

    Enum.join(taken, "\n")
  end
end
