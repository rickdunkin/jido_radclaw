defmodule JidoClaw.Conversations.SubagentTranscript do
  @moduledoc """
  Completes a spawned sub-agent's durable transcript: the task (`:user`)
  turn written before dispatch, and the terminal turn written after —
  `:assistant` on success, `:system` on failure.

  Today only a sub-agent's *tool* rows are durable (the Recorder writes
  them from the agent's `ai.tool.*` signals). Its task and result turns are
  not — leaving the durable slice a dangling tool sequence with no
  user/answer framing. These helpers close that gap so the Compactor sees
  a coherent per-sub-agent slice (task → tools → terminal).

  Every row is stamped with the sub-agent's compaction identity — `agent_id`
  is the spawn tag and `subagent: true` — read from the child
  `tool_context` (`JidoClaw.ToolContext.child/2,3` / the workflow scope set
  both). This is the single shared stamping path for `SpawnAgent`,
  `SendToAgent`, and `Workflows.StepAction`, so they can't drift.

  All writes are best-effort: failures are logged and never propagated,
  and a missing `session_uuid` (e.g. a non-session spawn) is a no-op — a
  persistence hiccup must never break the spawn path.
  """

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.{Message, Recorder}
  alias JidoClaw.Reasoning.Output

  @default_flush_timeout_ms 30_000
  @ask_timeout_ms 120_000

  @type outcome :: {:ok, term()} | {:error, term()} | term()

  @doc """
  Run a child agent's `ask_sync/3` synchronously, normalizing every
  termination path (`{:ok, _}` / `{:error, _}` / other return / exception /
  exit / throw) into an `outcome` that `record_result/3` can map to a
  terminal row and tracker status. Shared by `SpawnAgent`/`SendToAgent` so
  their dispatch + error handling can't drift.
  """
  @spec run(module(), pid(), term(), String.t() | nil, map()) :: outcome()
  def run(module, pid, message, request_id, tool_context) do
    module.ask_sync(pid, message,
      timeout: @ask_timeout_ms,
      request_id: request_id,
      tool_context: tool_context
    )
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Persist the sub-agent's task as its `:user` turn (no flush — no tool rows
  exist yet). Call BEFORE dispatch so the durable slice opens with the task.
  """
  @spec record_task(map(), String.t() | nil, term()) :: :ok
  def record_task(tool_context, request_id, task) when is_map(tool_context) do
    append(tool_context, request_id, :user, to_text(task))
  end

  @doc """
  Flush the Recorder for `request_id` (so the sub-agent's tool rows commit
  first, with strictly-lower sequences) then persist the terminal turn for
  a raw `ask_sync` outcome. Returns the AgentTracker-style status atom
  (`:done` / `:error`) so callers can mark completion from the same call.
  """
  @spec record_result(map(), String.t() | nil, outcome()) :: :done | :error
  def record_result(tool_context, request_id, {:ok, result}) when is_map(tool_context) do
    record_terminal(tool_context, request_id, :assistant, Output.extract_result(result))
    :done
  end

  def record_result(tool_context, request_id, {:error, reason}) when is_map(tool_context) do
    record_terminal(tool_context, request_id, :system, failure_text(reason))
    :error
  end

  def record_result(tool_context, request_id, other) when is_map(tool_context) do
    record_terminal(tool_context, request_id, :assistant, Output.extract_result(other))
    :done
  end

  @doc """
  Flush the Recorder for `request_id`, then persist a terminal turn with an
  explicit `role` (`:assistant` | `:system`) and `content`. Used by
  `Workflows.StepAction`, which already has the extracted step text.
  """
  @spec record_terminal(map(), String.t() | nil, :assistant | :system, term()) :: :ok
  def record_terminal(tool_context, request_id, role, content)
      when is_map(tool_context) and role in [:assistant, :system] do
    flush(request_id)
    append(tool_context, request_id, role, to_text(content))
  end

  @doc "Failure summary string for a non-result terminal turn."
  @spec failure_text(term()) :: String.t()
  def failure_text(reason) do
    "[sub-agent terminated without a result] " <> summarize(reason)
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp append(tool_context, request_id, role, content) do
    session_uuid = Map.get(tool_context, :session_uuid)
    tenant_id = Map.get(tool_context, :tenant_id)
    do_append(session_uuid, tenant_id, role, content, request_id, tool_context)
  end

  defp do_append(session_uuid, tenant_id, role, content, request_id, tool_context)
       when is_binary(session_uuid) and session_uuid != "" and is_binary(tenant_id) do
    attrs =
      %{
        session_id: session_uuid,
        request_id: request_id,
        role: role,
        content: content,
        metadata: %{}
      }
      |> put_present(:agent_id, Map.get(tool_context, :agent_id))
      |> Map.put(:subagent, Map.get(tool_context, :subagent, true))

    case Message.append(attrs, append_opts(tenant_id, Map.get(tool_context, :actor))) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[SubagentTranscript] #{role} append failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[SubagentTranscript] #{role} append raised: #{Exception.message(e)}")
      :ok
  end

  defp do_append(_session_uuid, _tenant_id, _role, _content, _request_id, _tool_context), do: :ok

  defp append_opts(tenant_id, actor) do
    [tenant: tenant_id, actor: actor || Actor.system(tenant_id)]
  end

  defp flush(request_id) when is_binary(request_id) do
    _ = Recorder.flush(request_id, flush_timeout_ms())
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp flush(_), do: :ok

  defp flush_timeout_ms do
    Application.get_env(:jido_claw, :recorder_flush_timeout, @default_flush_timeout_ms)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: inspect(value, limit: :infinity, pretty: true)

  defp summarize(reason) when is_binary(reason), do: reason
  defp summarize(reason), do: inspect(reason, limit: :infinity, pretty: true)
end
