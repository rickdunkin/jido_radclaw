defmodule JidoClaw.Tools.SendToAgent do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "send_to_agent",
    description: "Send a follow-up message to a running child agent.",
    category: "swarm",
    tags: ["swarm", "write"],
    output_schema: [
      agent_id: [type: :string, required: true],
      status: [type: :string, required: true],
      message: [type: :string, required: true]
    ],
    schema: [
      agent_id: [type: :string, required: true, doc: "The agent ID to send to"],
      message: [type: :string, required: true, doc: "The message to send"]
    ]

  require Logger

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Conversations.SubagentTranscript
  alias JidoClaw.Error
  alias JidoClaw.Tools.SwarmScope

  @impl Jido.Action
  def run(params, context) do
    with {:ok, scope_opts} <- SwarmScope.tracker_scope(context),
         {:ok, entry} <- SwarmScope.scoped_agent(agent_tracker(), params.agent_id, scope_opts) do
      case jido_runtime().whereis(params.agent_id) do
        nil ->
          {:error, Error.not_found(:agent, params.agent_id)}

        pid ->
          send_to_agent(pid, params, context, entry)
      end
    end
  end

  defp send_to_agent(pid, params, context, entry) do
    case template_for_agent(params.agent_id, entry) do
      {:ok, template} ->
        # Re-apply the template's forward_context on every follow-up so a
        # child can't be re-widened mid-conversation.
        visibility = Map.get(template, :forward_context, :public)

        # `child/3` clears :agent_template; restore it from the tracked entry's
        # template so the per-template approval policy applies to every
        # follow-up turn too. Before register_child_correlation (the contract
        # at ToolContext.child/2).
        child_tool_context =
          context
          |> Map.get(:tool_context)
          |> JidoClaw.ToolContext.child(params.agent_id, visibility)
          |> Map.put(:agent_template, entry.template)

        # Fallible setup (correlation registration touches Postgres) runs
        # BEFORE the tracker gate, so a failure here leaves the entry untouched.
        case JidoClaw.register_child_correlation(child_tool_context) do
          {:ok, request_id} ->
            dispatch(pid, params, template, entry.template, child_tool_context, request_id)

          # Marked registration failed (AR-2 Phase 2b C4) — the agent is
          # pre-existing and still running, so just don't dispatch the turn
          # (leave the running agent untouched), unlike the spawn path.
          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(pid, params, template, template_name, child_tool_context, request_id) do
    agent_id = params.agent_id

    # mark_running is the last gate before dispatch: it re-activates a
    # terminal entry (follow-up to a finished agent) only while the tracked
    # pid matches the dispatch target and is still alive — so a `:running`
    # entry always has an armed monitor behind it, and an expired/dead agent
    # reads as not_found instead of being resurrected. Success says which:
    # `:reactivated` (this call flipped a terminal entry, and now owns its
    # release on a start failure) or `:already_running` (an in-flight
    # orchestration still owns the entry; its monitor stays armed).
    case agent_tracker().mark_running(agent_id, pid) do
      {:ok, activation} ->
        start_result =
          Task.Supervisor.start_child(task_supervisor(), fn ->
            # Arm the tracker's orchestrator monitor before any work — the
            # backstop for kills the try/catch below can't see.
            agent_tracker().attach_orchestrator(agent_id, self())

            # Bounded: register the tracked template's allowlisted external MCP
            # proxies onto the running child before the follow-up turn. Blocks
            # only this task; best-effort (`:skipped` with no Consumer).
            _ = mcp().ensure_attached(pid, template_name, 8_000)

            # AR-5: re-inject the doctrine system prompt before the follow-up
            # turn. A follow-up can outrun the spawn's async injection, so
            # without this the first follow-up could run on the default ReAct
            # prompt. Safe to repeat (set_system_prompt replaces, never
            # appends); best-effort + gated, mirrors the ensure_attached above.
            _ = JidoClaw.Startup.inject_subagent_prompt(pid, template_name, child_tool_context)

            try do
              SubagentTranscript.record_task(child_tool_context, request_id, params.message)

              outcome =
                SubagentTranscript.run(
                  template.module,
                  pid,
                  params.message,
                  request_id,
                  child_tool_context
                )

              status = SubagentTranscript.record_result(child_tool_context, request_id, outcome)
              agent_tracker().mark_complete(agent_id, status)
            catch
              # An orchestration crash must not strand the re-activated entry
              # `:running` (it would consume the spawn cap until the child dies).
              kind, reason ->
                agent_tracker().mark_complete(agent_id, :error)

                Logger.warning(
                  "[SendToAgent] follow-up orchestration for #{agent_id} #{kind}: #{inspect(reason)}"
                )
            end
          end)

        case start_result do
          {:ok, _task_pid} ->
            # Only point the tracker at the new request once orchestration is
            # actually running behind it — a start failure must not leave the
            # entry referencing a request with no transcript/request state.
            agent_tracker().update_request_id(agent_id, request_id)

            {:ok,
             %{
               agent_id: agent_id,
               status: "message_sent",
               message: "Message sent to agent '#{agent_id}'"
             }}

          {:error, reason} ->
            # A `:reactivated` entry has nothing left to complete it — force
            # it terminal (the agent pre-existed this call and stays alive:
            # terminal-but-alive remains re-engageable). An `:already_running`
            # entry still belongs to the in-flight orchestration, whose
            # monitor stayed armed through the gate — leave it untouched.
            release_failed_engagement(activation, agent_id)

            {:error,
             Error.execution_error("Failed to start follow-up orchestration.",
               phase: :dispatch,
               details: %{reason: inspect(reason), agent_id: agent_id}
             )}
        end

      {:error, :not_found} ->
        {:error, Error.not_found(:agent, agent_id)}
    end
  end

  defp release_failed_engagement(:reactivated, agent_id),
    do: agent_tracker().mark_complete(agent_id, :error)

  defp release_failed_engagement(:already_running, _agent_id), do: :ok

  defp template_for_agent(agent_id, entry) do
    case entry do
      # AR-8b / AR-8b-2 F2 / AR-8c: a composer-private template (sandboxed OR the
      # explicit AR-8c `system_*` flag) must never take a follow-up turn via the
      # LLM-exposed swarm tool (mirrors spawn_agent). Resolve through the same
      # `templates()` provider that runs the turn, then gate on that RESOLVED map
      # via `composer_private_template?/1` — re-resolving the name against the
      # canonical registry would let an overridden `:agent_templates` provider
      # slip a private template past the guard (AR-8c review fix).
      %{template: template_name} when is_binary(template_name) ->
        with {:ok, template} <- resolve_template(agent_id, template_name) do
          if Templates.composer_private_template?(template) do
            {:error, composer_private_error(template_name)}
          else
            {:ok, template}
          end
        end

      other ->
        {:error,
         Error.execution_error("Agent '#{agent_id}' has invalid tracker metadata.",
           phase: :tracker_lookup,
           details: %{agent_id: agent_id, metadata: inspect(other)}
         )}
    end
  end

  defp resolve_template(agent_id, template_name) do
    case templates().get(template_name) do
      {:ok, template} ->
        {:ok, template}

      {:error, reason} ->
        {:error,
         Error.execution_error(
           "Template '#{template_name}' for agent '#{agent_id}' is unavailable.",
           phase: :template_lookup,
           details: %{
             template: template_name,
             agent_id: agent_id,
             reason: inspect(reason)
           }
         )}
    end
  end

  # Details intentionally {reason, template} (not adding agent_id) — the
  # {agent_id, reason, template} 3-key shape is already used twice elsewhere and
  # a third occurrence trips the reach fixed_shape_map smell. The message names
  # the template; agent_id is not load-bearing here.
  defp composer_private_error(template_name) do
    Error.execution_error(
      "Template '#{template_name}' is composer-private; follow-ups are not allowed.",
      phase: :template_lookup,
      details: %{reason: :composer_private, template: template_name}
    )
  end

  defp jido_runtime do
    Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
  end

  defp task_supervisor do
    Application.get_env(:jido_claw, :task_supervisor, JidoClaw.TaskSupervisor)
  end

  defp agent_tracker do
    Application.get_env(:jido_claw, :agent_tracker, JidoClaw.AgentTracker)
  end

  defp templates do
    Application.get_env(:jido_claw, :agent_templates, Templates)
  end

  # Kept apart from the sibling Application.get_env/3 seams above: three
  # byte-identical seams clustered across this and spawn_agent.ex trip the
  # cross-file duplicate-clone gate; split, the shared block stays under it.
  defp mcp do
    Application.get_env(:jido_claw, :mcp_facade, JidoClaw.MCP)
  end
end
