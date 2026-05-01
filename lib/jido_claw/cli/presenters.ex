defmodule JidoClaw.CLI.Presenters do
  @moduledoc """
  Plain-text presenters for introspection surfaces shared between the
  persistent shell commands (`JidoClaw.Shell.Commands.Jido`) and any
  future consumer that wants uncoloured, emit-friendly output.

  All functions are pure: they accept plain maps/structs and return
  `[String.t()]`. No direct reads of globally named processes — fetching
  data is the caller's responsibility. That keeps the module
  unit-testable without standing up `JidoClaw.Memory`,
  `JidoClaw.AgentTracker`, `JidoClaw.Solutions.Solution`, or
  `JidoClaw.Stats` fixtures.

  The REPL slash commands in `lib/jido_claw/cli/commands.ex`
  (`/status`, `/memory search`, `/solutions`) continue to use their
  own ANSI-coloured renderers; migrating those to this module is a
  follow-up once more consumers of the presenters emerge.
  """

  alias JidoClaw.Solutions.Solution

  @doc """
  Format the JidoClaw status snapshot for a shell `emit` loop.

  `snapshot`:

    * `:tracker`  — `JidoClaw.AgentTracker.get_state/0` (map with
      `:agents` and `:order`).
    * `:sessions` — `{:ok, list} | {:error, reason}`. On error the
      per-session breakdown is replaced with a single
      `"sessions unavailable: <reason>"` line.
    * `:stats`    — `JidoClaw.Stats.get/0` snapshot. `:uptime_seconds`
      and `:agents_spawned` are read from here rather than recomputed.
    * `:profile`  — optional active profile name for the session this
      status is being emitted for. Defaults to `"default"` when
      absent so callers that don't have per-session plumbing aren't
      forced to pass it.
  """
  @spec status_lines(%{
          :tracker => %{agents: map(), order: list()},
          :sessions => {:ok, list()} | {:error, term()},
          :stats => map(),
          optional(:profile) => String.t(),
          optional(:ssh_sessions) => non_neg_integer()
        }) :: [String.t()]
  def status_lines(%{tracker: tracker, sessions: sessions, stats: stats} = snapshot) do
    children = tracker.agents |> Enum.reject(fn {id, _} -> id == "main" end)
    running = Enum.count(children, fn {_, a} -> a.status == :running end)
    spawned = Map.get(stats, :agents_spawned, 0)
    uptime = Map.get(stats, :uptime_seconds, 0)
    profile = Map.get(snapshot, :profile, "default")
    ssh_count = Map.get(snapshot, :ssh_sessions, 0)

    header = [
      "JidoClaw Status",
      "  agents      #{running} running / #{spawned} spawned",
      "  uptime      #{format_elapsed(uptime)}",
      "  profile     #{profile}",
      "  ssh         #{ssh_count} active session(s)"
    ]

    header ++ session_lines(sessions)
  end

  @doc """
  Format the memory search results for the shell's `emit` loop.

  `results` is the list returned by `JidoClaw.Memory.recall/2`.
  """
  @spec memory_search_lines(String.t(), [map()]) :: [String.t()]
  def memory_search_lines(query, []) do
    ["Memory search: #{query}", "  (no memories matched)"]
  end

  def memory_search_lines(query, results) when is_list(results) do
    header = ["Memory search: #{query}", "  #{length(results)} result(s)"]

    body =
      Enum.flat_map(results, fn mem ->
        type = Map.get(mem, :type, "fact")
        key = Map.get(mem, :key, "")
        content = Map.get(mem, :content, "")
        ["  [#{type}] #{key}", "    #{content}"]
      end)

    header ++ body
  end

  @doc """
  Format a solution lookup result for the shell's `emit` loop.

  `find_result` is `{:ok, %Solution{}} | :not_found`.
  """
  @spec solution_lines({:ok, Solution.t()} | :not_found) :: [String.t()]
  def solution_lines(:not_found) do
    ["No solution with that signature."]
  end

  def solution_lines({:ok, %Solution{} = solution}) do
    [
      "Solution #{solution.id}",
      "  signature   #{solution.problem_signature}",
      "  language    #{solution.language || "—"}",
      "  framework   #{solution.framework || "—"}",
      "  trust       #{format_trust(solution.trust_score)}",
      "  tags        #{format_tags(solution.tags)}",
      "  inserted    #{format_timestamp(solution.inserted_at)}",
      "",
      solution.solution_content || ""
    ]
  end

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(other) when is_binary(other), do: other
  defp format_timestamp(other), do: inspect(other)

  # -- Helpers ---------------------------------------------------------------

  defp session_lines({:ok, []}) do
    ["  forge       0 active session(s)"]
  end

  defp session_lines({:ok, sessions}) when is_list(sessions) do
    header = "  forge       #{length(sessions)} active session(s)"

    body =
      Enum.map(sessions, fn session ->
        name = Map.get(session, :name, "—")
        phase = Map.get(session, :phase, :unknown)
        "    - #{name} (#{phase})"
      end)

    [header | body]
  end

  defp session_lines({:error, reason}) do
    ["  forge       sessions unavailable: #{format_reason(reason)}"]
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp format_trust(nil), do: "—"

  defp format_trust(score) when is_number(score) do
    :io_lib.format("~.2f", [score * 1.0]) |> IO.iodata_to_binary()
  end

  defp format_trust(other), do: inspect(other)

  defp format_tags([]), do: "—"
  defp format_tags(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp format_tags(other), do: inspect(other)

  defp format_elapsed(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"

  defp format_elapsed(seconds) when is_integer(seconds) and seconds < 3600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_elapsed(seconds) when is_integer(seconds),
    do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp format_elapsed(other), do: inspect(other)
end
