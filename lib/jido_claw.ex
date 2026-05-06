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

  alias JidoClaw.{Conversations, Workspaces}
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache, as: CorrelationCache
  alias JidoClaw.Conversations.Recorder

  @version "0.3.0"

  def version, do: @version

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

        # Phase 2 ordering: resolve Workspace + Session row BEFORE the
        # user-message append. Worker.add_message now writes a
        # Conversations.Message row keyed by session.id (UUID); without
        # the resolver running first the worker has no UUID to write
        # against and add_message returns :session_uuid_unset.
        with {:ok, _} <- JidoClaw.Startup.ensure_project_state(project_dir),
             {:ok, _pid} <- JidoClaw.Session.Supervisor.ensure_session(tenant_id, session_id),
             {:ok, agent_pid} <- resolve_agent_pid(session_id),
             {:ok, workspace, session} <-
               resolve_persistence(tenant_id, project_dir, session_id, kind, opts),
             :ok <- JidoClaw.Session.Worker.set_session_uuid(tenant_id, session_id, session.id),
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

    register_correlation(request_id, session.id, tenant_id, workspace.id, user_id)

    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :user, message, request_id)

    tool_context =
      JidoClaw.ToolContext.build(%{
        project_dir: project_dir,
        tenant_id: tenant_id,
        session_id: session_id,
        session_uuid: session.id,
        workspace_id: session_id,
        workspace_uuid: workspace.id,
        user_id: user_id,
        agent_id: session_id
      })

    response =
      JidoClaw.Agent.ask_sync(agent_pid, message,
        timeout: 120_000,
        request_id: request_id,
        tool_context: tool_context
      )

    # Barrier: ensure all tool/reasoning rows for this request are
    # committed BEFORE the assistant row is written, so the assistant
    # row's sequence is strictly greater than every tool/reasoning
    # row's sequence. Non-fatal on timeout — log and continue.
    _ = Recorder.flush(request_id)

    handle_response(response, tenant_id, session_id, request_id)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  @doc false
  def register_correlation(request_id, session_uuid, tenant_id, workspace_uuid, user_id) do
    scope = %{
      session_id: session_uuid,
      tenant_id: tenant_id,
      workspace_id: workspace_uuid,
      user_id: user_id
    }

    case RequestCorrelation.register(%{
           request_id: request_id,
           session_id: session_uuid,
           tenant_id: tenant_id,
           workspace_id: workspace_uuid,
           user_id: user_id
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
    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, answer, request_id)
    {:ok, answer}
  end

  defp handle_response({:ok, %{text: text}}, tenant_id, session_id, request_id) do
    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, text, request_id)
    {:ok, text}
  end

  defp handle_response({:ok, %{last_answer: answer}}, tenant_id, session_id, request_id) do
    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, answer, request_id)
    {:ok, answer}
  end

  defp handle_response({:ok, other}, tenant_id, session_id, request_id) do
    text = inspect(other)
    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, text, request_id)
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
  def sessions(tenant_id \\ "default") do
    JidoClaw.Session.Supervisor.list_sessions(tenant_id)
  end

  @doc """
  Get message history for a session.

  Live-session path: reads from the running `Session.Worker` cache.
  Returns `[]` if no worker is alive — for cold-cache reads against a
  persisted session, use `history/3`.
  """
  def history(tenant_id, session_id) do
    JidoClaw.Session.Worker.get_messages(tenant_id, session_id)
  rescue
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

    with {:ok, workspace} <-
           JidoClaw.Workspaces.Resolver.ensure_workspace(tenant_id, workspace_dir),
         {:ok, session} <-
           JidoClaw.Conversations.Session.by_external(
             tenant_id,
             workspace.id,
             kind,
             session_id_external
           ),
         {:ok, rows} <- JidoClaw.Conversations.Message.for_session(session.id) do
      rows
      |> Enum.filter(&(&1.role in [:user, :assistant, :system]))
      |> Enum.map(&cold_view/1)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp cold_view(%{role: role, content: content, inserted_at: inserted_at}) do
    %{
      role: Atom.to_string(role),
      content: content,
      timestamp: DateTime.to_unix(inserted_at, :millisecond)
    }
  end

  @doc "Create a new tenant."
  def create_tenant(attrs \\ []) do
    JidoClaw.Tenant.Manager.create_tenant(attrs)
  end

  @doc "List all tenants."
  def tenants do
    JidoClaw.Tenant.Manager.list_tenants()
  end
end
