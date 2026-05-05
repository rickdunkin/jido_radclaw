defmodule JidoClaw.Shell.Commands.Jido do
  @moduledoc """
  JidoClaw introspection surface as a first-class `jido_shell` command.

  Registered through the `Jido.Shell.Command.Registry` patch at
  `lib/jido_claw/core/jido_shell_registry_patch.ex` so it is discoverable
  from `help` and dispatchable inside any persistent shell session.

  ## Usage

      jido
      jido help
      jido status
      jido memory search <query>
      jido solutions find <fingerprint>

  ## Sub-commands

    * `status` — agents running/spawned, active forge sessions, uptime.
    * `memory search <query>` — keyword search across
      `JidoClaw.Memory.recall/2`. The query is variadic; remaining
      words are joined on whitespace.
    * `solutions find <fingerprint>` — exact signature lookup via
      `JidoClaw.Solutions.Solution.by_signature/5`. A `:not_found`
      result is reported on stdout with exit 0 — the query was valid,
      the corpus just doesn't hold that signature.

  Unknown sub-commands and missing required arguments return an exit
  code of 1, print the usage block, and follow up with a human-readable
  `error:` line.
  """

  @behaviour Jido.Shell.Command

  alias JidoClaw.CLI.Presenters
  alias JidoClaw.Shell.ProfileManager

  @impl true
  def name, do: "jido"

  @impl true
  def summary, do: "JidoClaw introspection — status, memory search, solutions find"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(_state, %{args: []}, emit), do: emit_usage_ok(emit)
  def run(_state, %{args: ["help"]}, emit), do: emit_usage_ok(emit)
  def run(state, %{args: ["status"]}, emit), do: emit_status(state, emit)

  def run(_state, %{args: ["memory", "search"]}, emit),
    do: emit_missing(:memory_search_query, "query", emit)

  def run(_state, %{args: ["memory", "search" | rest]}, emit),
    do: emit_memory(rest, emit)

  def run(_state, %{args: ["solutions", "find"]}, emit),
    do: emit_missing(:solutions_find_fingerprint, "fingerprint", emit)

  def run(_state, %{args: ["solutions", "find", fingerprint]}, emit),
    do: emit_solution(fingerprint, emit)

  def run(_state, %{args: [sub | _]}, emit), do: emit_unknown(sub, emit)

  # -- Success emitters ------------------------------------------------------

  defp emit_usage_ok(emit) do
    Enum.each(usage_lines(), &emit_line(emit, &1))
    {:ok, nil}
  end

  defp emit_status(state, emit) do
    snapshot = %{
      tracker: JidoClaw.AgentTracker.get_state(),
      sessions: fetch_active_sessions(),
      stats: JidoClaw.Stats.get(),
      profile: active_profile(state),
      ssh_sessions: ssh_session_count(state)
    }

    snapshot
    |> Presenters.status_lines()
    |> Enum.each(&emit_line(emit, &1))

    {:ok, nil}
  end

  defp emit_memory(query_words, emit) do
    query = Enum.join(query_words, " ")
    {tenant_id, workspace_uuid} = default_scope()
    tool_context = %{tenant_id: tenant_id, workspace_uuid: workspace_uuid}
    results = JidoClaw.Memory.recall(query, tool_context: tool_context)

    query
    |> Presenters.memory_search_lines(results)
    |> Enum.each(&emit_line(emit, &1))

    {:ok, nil}
  end

  defp emit_solution(fingerprint, emit) do
    # The shell command runs without a tool_context — fall back to the
    # default tenant (`"default"`) and the cwd-anchored workspace, the
    # same scope MCP-mode tools use. Multi-tenant shell is out of
    # scope for v0.6.x.
    {tenant_id, workspace_uuid} = default_scope()

    result =
      case JidoClaw.Solutions.Solution.by_signature(
             fingerprint,
             workspace_uuid,
             tenant_id,
             [:local, :shared, :public],
             [:public]
           ) do
        {:ok, [first | _]} -> {:ok, first}
        {:ok, []} -> :not_found
        {:ok, %JidoClaw.Solutions.Solution{} = sol} -> {:ok, sol}
        _ -> :not_found
      end

    result
    |> Presenters.solution_lines()
    |> Enum.each(&emit_line(emit, &1))

    {:ok, nil}
  end

  defp default_scope do
    case Application.get_env(:jido_claw, :jido_claw_mcp_default_scope) do
      %{tenant_id: tid, workspace_uuid: wid} ->
        {tid, wid}

      _ ->
        case JidoClaw.Workspaces.Resolver.ensure_workspace("default", File.cwd!()) do
          {:ok, %{id: wid, tenant_id: tid}} -> {tid, wid}
          _ -> {"default", nil}
        end
    end
  end

  # -- Error emitters --------------------------------------------------------

  defp emit_missing(field, label, emit) do
    Enum.each(usage_lines(), &emit_line(emit, &1))
    emit_line(emit, "error: #{label} is required")

    {:error,
     Jido.Shell.Error.validation("jido", [
       %{path: [:args, field], message: "is required"}
     ])}
  end

  defp emit_unknown(sub, emit) do
    Enum.each(usage_lines(), &emit_line(emit, &1))
    emit_line(emit, "error: unknown sub-command \"#{sub}\"")

    {:error, Jido.Shell.Error.shell(:unknown_command, %{name: "jido " <> sub})}
  end

  # -- Helpers ---------------------------------------------------------------

  defp fetch_active_sessions do
    case JidoClaw.Forge.Resources.Session.list_active() do
      {:ok, sessions} -> {:ok, sessions}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Thread the session's workspace_id into the status snapshot so we
  # show the profile active for *this* shell session (multi-workspace
  # safe by construction). Falls back to `"default"` when the state
  # shape isn't what we expect, so status still renders on malformed
  # invocations rather than crashing the session.
  defp active_profile(state) do
    case workspace_id_from_state(state) do
      nil -> "default"
      ws -> ProfileManager.current(ws)
    end
  end

  defp workspace_id_from_state(%Jido.Shell.ShellSession.State{workspace_id: ws})
       when is_binary(ws),
       do: ws

  defp workspace_id_from_state(_), do: nil

  # Defensive: returns 0 if SessionManager is down or the call races a
  # crash. Process.whereis is the cheap pre-check; the surrounding
  # `catch :exit, _` handles the noproc/timeout/system-limit shapes
  # that don't reduce cleanly to a single tuple.
  defp ssh_session_count(state) do
    case workspace_id_from_state(state) do
      nil ->
        0

      ws ->
        case Process.whereis(JidoClaw.Shell.SessionManager) do
          nil -> 0
          _pid -> JidoClaw.Shell.SessionManager.count_active_ssh_sessions(ws)
        end
    end
  catch
    :exit, _ -> 0
  end

  defp usage_lines do
    [
      "Usage: jido <sub-command>",
      "",
      "Sub-commands:",
      "  help                          Show this usage block",
      "  status                        Agents, forge sessions, uptime",
      "  memory search <query>         Keyword search across persistent memory",
      "  solutions find <fingerprint>  Lookup a solution by its problem signature"
    ]
  end

  defp emit_line(emit, line), do: emit.({:output, line <> "\n"})
end
