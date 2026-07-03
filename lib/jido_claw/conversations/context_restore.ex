defmodule JidoClaw.Conversations.ContextRestore do
  @moduledoc """
  Restores a fresh agent process's LLM context from a session's persisted
  transcript — the one net-new mechanism behind CLI session resume.

  A resumed session used to look resumed only in the REPL view (the
  `Session.Worker` hydrates its chat cache from Postgres) while the model
  remembered nothing: nothing seeded `Jido.AI.Context` from the durable
  `Conversations.Message` rows. This module closes that gap by rebuilding a
  context from the session's **chat transcript only** — `:user`/`:assistant`
  rows, with `refs.request_id` preserved — and delivering it to the agent as
  an `ai.react.context.modify` `:replace` operation (reason `:restore`).

  Deliberately skipped: tool / reasoning / system rows. Tool rows would need
  paired tool-call/tool-result reconstruction, and system rows are carried by
  the system prompt itself.

  Two invariants matter here:

    * **The restored context must carry the system prompt.** At ask time the
      strategy uses `context.system_prompt` with no config fallback — a
      `:replace` whose context has `system_prompt: nil` silently drops the
      prompt. The prompt comes from `JidoClaw.Startup.resolve_prompt/2`, the
      same byte source `inject_system_prompt/3` uses, so the injected and
      restored prompts are byte-identical and the provider prompt-cache
      prefix survives resume (CC2-2).
    * **`refs.request_id` must survive.** The compaction
      `RequestTransformer` filters projected messages by
      `refs.request_id ∈ snapshot.summarized_request_ids`; snapshots in
      `Session.metadata["compactions"]` are re-read every ask, so restoring
      the refs makes compaction survive resume for free.
  """

  alias Jido.AI.Context
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Startup

  @signal_type "ai.react.context.modify"
  @signal_source "/jido_claw/conversations/context_restore"
  @call_timeout 15_000

  @doc """
  Pure builder: fold persisted message rows into a `Jido.AI.Context`.

  Only `:user`/`:assistant` rows with binary content survive; each entry
  carries `refs: %{request_id: row.request_id}` when the row has one (legacy
  untagged rows get nil refs, which the compaction transformer keeps).
  """
  @spec build_context([Message.t()] | [map()], String.t() | nil) :: Context.t()
  def build_context(rows, system_prompt) when is_list(rows) do
    rows
    |> Enum.filter(&chat_row?/1)
    |> Enum.reduce(Context.new(system_prompt: system_prompt), &append_row/2)
  end

  defp chat_row?(%{role: role, content: content}),
    do: role in [:user, :assistant] and is_binary(content)

  defp append_row(%{role: :user} = row, ctx),
    do: Context.append_user(ctx, row.content, refs: refs_of(row))

  defp append_row(%{role: :assistant} = row, ctx),
    do: Context.append_assistant(ctx, row.content, nil, refs: refs_of(row))

  defp refs_of(%{request_id: request_id}) when is_binary(request_id),
    do: %{request_id: request_id}

  defp refs_of(_row), do: nil

  @doc """
  Load the session's primary transcript and deliver the rebuilt context to
  `pid` via `ai.react.context.modify`.

  No user/assistant rows → `:ok` no-op (nothing to restore; the signal is
  never sent). Delivery mirrors `Jido.AI.set_system_prompt/3`:
  `Jido.AgentServer.call/3` with a bounded timeout.

  ## Options

    * `:actor` — defaults to a tenant-bound system actor.
  """
  @spec restore(pid(), Session.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def restore(pid, %Session{} = session, project_dir, opts \\ [])
      when is_pid(pid) and is_binary(project_dir) do
    actor = Keyword.get(opts, :actor) || Actor.system(session.tenant_id)

    case Message.for_session_primary(session.id, tenant: session.tenant_id, actor: actor) do
      {:ok, rows} ->
        deliver_unless_empty(pid, Enum.filter(rows, &chat_row?/1), session, project_dir)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_unless_empty(_pid, [], _session, _project_dir), do: :ok

  defp deliver_unless_empty(pid, chat_rows, session, project_dir) do
    context = build_context(chat_rows, Startup.resolve_prompt(session, project_dir))

    signal =
      Jido.Signal.new!(
        @signal_type,
        %{operation: %{type: :replace, reason: :restore, result_context: context}},
        source: @signal_source
      )

    case call_agent(pid, signal) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A dead/stopping pid exits the caller out of GenServer.call; convert to an
  # error tuple so the strict/best-effort policy in `JidoClaw.chat/4` decides
  # the outcome instead of the exit crashing the turn.
  defp call_agent(pid, signal) do
    Jido.AgentServer.call(pid, signal, @call_timeout)
  catch
    :exit, reason -> {:error, {:agent_call_exit, reason}}
  end
end
