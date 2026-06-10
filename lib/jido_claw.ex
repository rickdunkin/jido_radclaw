defmodule JidoClaw do
  @moduledoc """
  JidoClaw - AI agent platform with CLI, HTTP gateway, multi-tenancy,
  channel adapters (Discord, Telegram), cron scheduling, and swarm orchestration.
  Powered by the Jido framework on BEAM/OTP.

  ## Quick Start

      # Create a session and chat (kind required as of v0.6)
      {:ok, response} = JidoClaw.chat("default", "main", "Hello!", kind: :api)

      # List sessions for a tenant
      sessions = JidoClaw.sessions("default")

      # Get conversation history
      messages = JidoClaw.history("default", "main")
  """

  require Logger

  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Handoff.Router, as: HandoffRouter
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations
  alias JidoClaw.Conversations.Message, as: ConversationsMessage
  alias JidoClaw.Conversations.Recorder
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache, as: CorrelationCache
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Reasoning.Compactor.Identity, as: CompactionIdentity
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Tenant.Manager, as: TenantManager
  alias JidoClaw.Workspaces

  @version "0.6.4"

  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Renders a JidoClaw error (or any term) as a human-readable string.

  Delegates to `JidoClaw.Error.format/1`. Use this at the edge of any user-
  or operator-facing surface (CLI, LiveView, MCP) instead of `inspect/1` so
  that class containers flatten cleanly and leaves render their `:message`.
  """
  @spec format_error(term()) :: String.t()
  defdelegate format_error(error), to: JidoClaw.Error, as: :format

  @doc """
  Send a message to an agent session, creating it if needed.

  Deprecated 3-arity form. Routes through `chat/4` with `kind: :api`.
  Emits a one-time deprecation warning per process.
  """
  @spec chat(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def chat(tenant_id \\ "default", session_id, message)

  def chat(tenant_id, session_id, message) do
    warn_chat3_deprecation()
    chat(tenant_id, session_id, message, kind: :api)
  end

  @doc """
  Send a message to an agent session, creating it if needed.

  Resolves a `Workspaces.Workspace` and `Conversations.Session` row before
  dispatch so the threaded `tool_context` carries `workspace_uuid` and
  `session_uuid` for downstream tenanting + telemetry.

  ## Options

    * `:kind` — required. One of `:repl, :discord, :telegram, :web_rpc, :cron, :api, :mcp`
    * `:external_id` — defaults to `session_id`
    * `:workspace_id` — project directory anchor; defaults to `File.cwd!()`
    * `:user_id` — UUID of the authenticated user; nil for unauthenticated surfaces
    * `:metadata` — free-form map persisted on the Session row
  """
  @spec chat(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def chat(tenant_id, session_id, message, opts) when is_list(opts) do
    case Keyword.fetch(opts, :kind) do
      {:ok, kind} when is_atom(kind) ->
        project_dir = Keyword.get(opts, :workspace_id) || File.cwd!()

        # Build the actor up-front so the Session.Worker carries it from
        # init. Surfaces that have a real user (web/socket) pass actor
        # via opts; surfaces without a user (REPL, Discord, Cron) get a
        # tenant-bound system actor.
        user_id = Keyword.get(opts, :user_id)

        actor =
          Keyword.get(opts, :actor) ||
            if user_id,
              do: %{user_id: user_id, tenant_id: tenant_id},
              else: Actor.system(tenant_id)

        opts = Keyword.put(opts, :actor, actor)

        # Phase 2 ordering: resolve Workspace + Session row BEFORE the
        # user-message append. Worker.add_message now writes a
        # Conversations.Message row keyed by session.id (UUID); without
        # the resolver running first the worker has no UUID to write
        # against and add_message returns :session_uuid_unset.
        with {:ok, _} <- JidoClaw.Startup.ensure_project_state(project_dir),
             {:ok, _pid} <-
               JidoClaw.Session.Supervisor.ensure_session(tenant_id, session_id, actor: actor),
             {:ok, agent_pid} <- resolve_agent_pid(session_id),
             {:ok, workspace, session} <-
               resolve_persistence(tenant_id, project_dir, session_id, kind, opts),
             :ok <- SessionWorker.set_session_uuid(tenant_id, session_id, session.id),
             :ok <-
               JidoClaw.Startup.inject_system_prompt(agent_pid, project_dir, session) do
          run_chat_turn(
            agent_pid,
            tenant_id,
            session_id,
            message,
            project_dir,
            workspace,
            session,
            opts
          )
        end

      {:ok, other} ->
        {:error, {:invalid_kind, other}}

      :error ->
        {:error, :missing_kind}
    end
  end

  defp resolve_persistence(tenant_id, project_dir, session_id, kind, opts) do
    external_id = Keyword.get(opts, :external_id) || session_id
    user_id = Keyword.get(opts, :user_id)

    with {:ok, workspace} <-
           Workspaces.Resolver.ensure_workspace(tenant_id, project_dir, user_id: user_id),
         {:ok, session} <-
           Conversations.Resolver.ensure_session(
             tenant_id,
             workspace.id,
             kind,
             external_id,
             user_id: user_id,
             metadata: Keyword.get(opts, :metadata, %{}),
             project_dir: project_dir
           ) do
      {:ok, workspace, session}
    end
  end

  defp ask_runtime, do: Application.get_env(:jido_claw, :ask_runtime, JidoClaw.Agent)

  defp recorder_flush_timeout,
    do: Application.get_env(:jido_claw, :recorder_flush_timeout, 30_000)

  defp resolve_agent_pid(session_id) do
    case Jido.whereis(JidoClaw.Jido, session_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case JidoClaw.Jido.start_agent(JidoClaw.Agent, id: session_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, {:already_registered, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp run_chat_turn(
         agent_pid,
         tenant_id,
         session_id,
         message,
         project_dir,
         workspace,
         session,
         opts
       ) do
    user_id = Keyword.get(opts, :user_id)
    request_id = Ecto.UUID.generate()

    actor =
      Keyword.get(opts, :actor) ||
        if user_id,
          do: %{user_id: user_id, tenant_id: tenant_id},
          else: Actor.system(tenant_id)

    {routed_pid, routed_template, routed_agent_id, first_post_handoff?, owner} =
      HandoffRouter.resolve_session_owner(
        tenant_id,
        session_id,
        session.id,
        agent_pid,
        actor,
        project_dir: project_dir,
        session_record: session,
        default_agent_id: session_id
      )

    # Register correlation AFTER routing so the stamped compaction identity
    # reflects the resolved owner (main vs handoff worker). Still precedes
    # the user-message append and `ask_sync`, so the Recorder can resolve
    # scope for any tool signal during the turn.
    register_correlation(request_id, session.id, tenant_id, workspace.id, user_id,
      agent_id: CompactionIdentity.resolve(routed_template, routed_agent_id, session_id),
      subagent: false
    )

    preamble =
      if first_post_handoff? do
        HandoffRouter.build_preamble(tenant_id, session_id, owner)
      else
        ""
      end

    SessionWorker.add_message(tenant_id, session_id, :user, message, request_id)

    tool_context =
      JidoClaw.ToolContext.build(%{
        project_dir: project_dir,
        tenant_id: tenant_id,
        session_id: session_id,
        session_uuid: session.id,
        workspace_id: session_id,
        workspace_uuid: workspace.id,
        user_id: user_id,
        agent_id: routed_agent_id,
        agent_template: routed_template,
        subagent: false,
        actor: actor
      })

    # Handoff routing is an ownership *transfer*, not a freshly-built child
    # context: the same conversation's `tool_context` is routed to the owning
    # worker as-is. Full-context continuity is the defining purpose of handoff,
    # so the `forward_context` visibility policy (spawn / follow-up /
    # workflow-step) deliberately does NOT apply here.
    response =
      ask_runtime().ask_sync(routed_pid, preamble <> message,
        timeout: 120_000,
        request_id: request_id,
        tool_context: tool_context
      )

    # Barrier: ensure all tool/reasoning rows for this request are
    # committed BEFORE the assistant row is written, so the assistant
    # row's sequence is strictly greater than every tool/reasoning
    # row's sequence. Non-fatal on timeout — log and continue. The
    # timeout is configurable so tests that stub out the LLM (and
    # therefore never see a completion signal) can short-circuit
    # without blocking on the default 30s wait.
    _ = Recorder.flush(request_id, recorder_flush_timeout())

    HandoffRouter.mark_preamble_consumed_on_success(
      tenant_id,
      session_id,
      routed_template,
      first_post_handoff?,
      response
    )

    handle_response(response, tenant_id, session_id, request_id)
    # Public API turn entry — any unexpected fault is normalized to {:error, _}
    # so callers never see an exception escape.
  rescue
    # reach:disable-next-line bare_rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  @doc """
  Convenience entry point for child requests (sub-agents, workflows): pulls
  `session_uuid`, `tenant_id`, `workspace_uuid`, and `user_id` out of a
  tool_context map and forwards to `register_correlation/6`. Returns a fresh
  `request_id` regardless — if the context is missing `session_uuid` or
  `tenant_id`, registration is skipped but the caller still gets an id to
  thread through.

  See the note on `register_correlation/6` about eventual relocation.
  """
  @spec register_child_correlation(map()) :: String.t()
  def register_child_correlation(ctx) do
    request_id = Ecto.UUID.generate()

    case ctx do
      %{session_uuid: session_uuid, tenant_id: tenant_id} = c
      when is_binary(session_uuid) and is_binary(tenant_id) ->
        register_correlation(
          request_id,
          session_uuid,
          tenant_id,
          Map.get(c, :workspace_uuid),
          Map.get(c, :user_id),
          agent_id:
            CompactionIdentity.resolve(
              Map.get(c, :agent_template),
              Map.get(c, :agent_id),
              Map.get(c, :session_id)
            ),
          subagent: Map.get(c, :subagent, true)
        )

      _ ->
        :ok
    end

    request_id
  end

  @doc """
  Register a request-correlation scope: persists the row via
  `Conversations.RequestCorrelation.register/1` and mirrors it into the
  in-process `CorrelationCache`. If the Postgres write fails, logs a warning
  and still caches locally so the in-process `Recorder` can resolve scope —
  DB-side retry is left for later.

  > #### Note {: .info}
  >
  > This helper (and `register_child_correlation/1`) should be moved out of
  > the top-level `JidoClaw` module into
  > `JidoClaw.Conversations.RequestCorrelation` alongside the Ash resource it
  > wraps. It lives here for historical reasons.
  """
  @spec register_correlation(
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok
  def register_correlation(
        request_id,
        session_uuid,
        tenant_id,
        workspace_uuid,
        user_id,
        opts \\ []
      ) do
    # Default to the main agent so the `:register` create never receives an
    # explicit nil for the now-NOT-NULL `agent_id` (mirrors `subagent`'s
    # default below). Routed call sites already pass a non-nil identity via
    # `CompactionIdentity.resolve/3`.
    agent_id = Keyword.get(opts, :agent_id) || CompactionIdentity.main()
    subagent = Keyword.get(opts, :subagent, false)

    scope = %{
      session_id: session_uuid,
      tenant_id: tenant_id,
      workspace_id: workspace_uuid,
      user_id: user_id,
      agent_id: agent_id,
      subagent: subagent
    }

    case RequestCorrelation.register(%{
           request_id: request_id,
           session_id: session_uuid,
           tenant_id: tenant_id,
           workspace_id: workspace_uuid,
           user_id: user_id,
           agent_id: agent_id,
           subagent: subagent
         }) do
      {:ok, _} ->
        CorrelationCache.put(request_id, scope)
        :ok

      {:error, reason} ->
        Logger.warning("[chat] correlation registration failed: #{inspect(reason)}")
        # Still cache locally so the in-process Recorder can resolve scope
        # — Postgres write retry can come later.
        CorrelationCache.put(request_id, scope)
        :ok
    end
  end

  defp handle_response({:ok, answer}, tenant_id, session_id, request_id) when is_binary(answer) do
    SessionWorker.add_message(tenant_id, session_id, :assistant, answer, request_id)
    {:ok, answer}
  end

  defp handle_response({:ok, %{text: text}}, tenant_id, session_id, request_id) do
    SessionWorker.add_message(tenant_id, session_id, :assistant, text, request_id)
    {:ok, text}
  end

  defp handle_response({:ok, %{last_answer: answer}}, tenant_id, session_id, request_id) do
    SessionWorker.add_message(tenant_id, session_id, :assistant, answer, request_id)
    {:ok, answer}
  end

  defp handle_response({:ok, other}, tenant_id, session_id, request_id) do
    text = inspect(other)
    SessionWorker.add_message(tenant_id, session_id, :assistant, text, request_id)
    {:ok, text}
  end

  defp handle_response({:error, reason}, _tenant_id, _session_id, _request_id) do
    {:error, reason}
  end

  defp warn_chat3_deprecation do
    case Process.get(:jido_claw_chat3_deprecation_warned) do
      true ->
        :ok

      _ ->
        Logger.warning(
          "JidoClaw.chat/3 is deprecated. Pass an explicit :kind via chat/4 — e.g. chat(tenant, session, msg, kind: :api)."
        )

        Process.put(:jido_claw_chat3_deprecation_warned, true)
        :ok
    end
  end

  @doc "List active sessions for a tenant."
  @spec sessions(String.t()) :: [{String.t(), pid()}]
  def sessions(tenant_id \\ "default") do
    JidoClaw.Session.Supervisor.list_sessions(tenant_id)
  end

  @doc """
  Get message history for a session.

  Live-session path: reads from the running `Session.Worker` cache.
  Returns `[]` if no worker is alive — for cold-cache reads against a
  persisted session, use `history/3`.
  """
  @spec history(String.t(), String.t()) :: [map()]
  def history(tenant_id, session_id) do
    SessionWorker.get_messages(tenant_id, session_id)
    # Public read API — degrade to `[]` rather than crash the caller when the
    # worker is dead/unreachable.
  rescue
    # reach:disable-next-line bare_rescue
    _ -> []
  end

  @doc """
  Get message history for a session by external ID, with cold-cache
  Postgres fallback.

  ## Required opts

    * `:kind` — required. One of
      `:repl, :discord, :telegram, :web_rpc, :cron, :api, :mcp, :imported_legacy`.
      A missing `:kind` raises `KeyError`. Required because the unique
      identity for sessions is `(tenant, workspace, kind, external_id)`
      — defaulting `:kind` would silently mis-resolve REPL / Discord /
      Telegram sessions.

  ## Optional opts

    * `:workspace_id` — project directory anchor; defaults to `File.cwd!()`.

  ## Behavior

  This is a read-only resolution path: the workspace is ensured (idempotent),
  but the session row is NOT created. If the session doesn't exist,
  returns `{:error, :not_found}`.
  """
  @spec history(String.t(), String.t(), keyword()) ::
          [map()] | {:error, term()}
  def history(tenant_id, session_id_external, opts) when is_list(opts) do
    kind = Keyword.fetch!(opts, :kind)
    workspace_dir = Keyword.get(opts, :workspace_id) || File.cwd!()
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

    with {:ok, workspace} <-
           JidoClaw.Workspaces.Resolver.ensure_workspace(tenant_id, workspace_dir, actor: actor),
         {:ok, session} <-
           ConversationsSession.by_external(
             workspace.id,
             kind,
             session_id_external,
             tenant: tenant_id,
             actor: actor
           ),
         {:ok, rows} <-
           ConversationsMessage.for_session_primary(session.id,
             tenant: tenant_id,
             actor: actor
           ) do
      rows
      |> Enum.filter(&(&1.role in [:user, :assistant, :system]))
      |> Enum.map(&cold_view/1)
    end

    # Public cold-cache read API — any fault from resolver/Ash/Repo is normalized
    # to `{:error, _}` so callers never see an exception escape.
  rescue
    # reach:disable-next-line bare_rescue
    e -> {:error, Exception.message(e)}
  end

  defp cold_view(%{role: role, content: content, inserted_at: inserted_at}) do
    %{
      role: Atom.to_string(role),
      content: content,
      timestamp: DateTime.to_unix(inserted_at, :millisecond)
    }
  end

  @doc """
  Return the current handoff owner record for `(tenant, runtime_session_id)`,
  or `nil` when ownership is at main (no active handoff).
  """
  @spec handoff_owner(String.t(), String.t()) :: map() | nil
  def handoff_owner(tenant_id, runtime_session_id)
      when is_binary(tenant_id) and is_binary(runtime_session_id) do
    HandoffRegistry.owner(tenant_id, runtime_session_id)
  end

  @doc """
  Clear the handoff registry entry for `(tenant, runtime_session_id)`.

  Registry-only — use when `session_uuid` is unknown. Idempotent.
  """
  @spec reset_handoff(String.t(), String.t()) :: :ok
  def reset_handoff(tenant_id, runtime_session_id)
      when is_binary(tenant_id) and is_binary(runtime_session_id) do
    HandoffRegistry.clear(tenant_id, runtime_session_id)
  end

  @doc """
  Clear the handoff registry entry AND the durable
  `Conversations.Session.metadata["current_agent_template"]` mirror.

  Preferred when `session_uuid` is known so cold-start hydration on a
  later boot doesn't reinstate a stale owner.
  """
  @spec reset_handoff(String.t(), String.t(), String.t() | nil, map() | nil) :: :ok
  def reset_handoff(tenant_id, runtime_session_id, session_uuid, actor)
      when is_binary(tenant_id) and is_binary(runtime_session_id) do
    :ok = HandoffRegistry.clear(tenant_id, runtime_session_id)

    if is_binary(session_uuid) do
      actor = actor || Actor.system(tenant_id)

      case ConversationsSession.by_id(session_uuid, tenant: tenant_id, actor: actor) do
        {:ok, session} ->
          _ =
            ConversationsSession.set_current_agent_template(session, nil,
              tenant: tenant_id,
              actor: actor
            )

          :ok

        _ ->
          :ok
      end
    else
      :ok
    end

    # Public reset API — registry clear is done; durable mirror update is
    # best-effort, so DB/Ash faults swallow to :ok.
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  end

  @doc """
  Inspect an agent target (module, pid, agent id, `%Conversations.Session{}`,
  or `%{tenant_id, session_id}` map) and return a `%JidoClaw.Inspection.Summary{}`.

  Thin delegate over `JidoClaw.Inspection.inspect_agent/2`.
  """
  defdelegate inspect_agent(target, opts \\ []), to: JidoClaw.Inspection

  @doc """
  Inspect a request id. Requires `tenant_id:` in `opts`.

  Thin delegate over `JidoClaw.Inspection.inspect_request/2`.
  """
  defdelegate inspect_request(request_id, opts \\ []), to: JidoClaw.Inspection

  @doc """
  Inspect a workflow run by UUID or struct.

  Thin delegate over `JidoClaw.Inspection.inspect_workflow/1`.
  """
  defdelegate inspect_workflow(target), to: JidoClaw.Inspection

  @doc "Create a new tenant."
  @spec create_tenant(keyword()) :: {:ok, JidoClaw.Tenant.t()} | {:error, term()}
  def create_tenant(attrs \\ []) do
    TenantManager.create_tenant(attrs)
  end

  @doc "List all tenants."
  @spec tenants() :: [JidoClaw.Tenant.t()]
  def tenants do
    TenantManager.list_tenants()
  end
end
