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
    # Validate :kind up-front. Doing this inside dispatch_to_agent meant a
    # missing :kind raised KeyError only after project setup, session
    # creation, user-message persistence, agent startup, and prompt
    # injection had already left side effects on disk and in the
    # Session.Worker registry.
    case Keyword.fetch(opts, :kind) do
      {:ok, kind} when is_atom(kind) ->
        project_dir = Keyword.get(opts, :workspace_id) || File.cwd!()

        with {:ok, _} <- JidoClaw.Startup.ensure_project_state(project_dir),
             {:ok, _pid} <- JidoClaw.Session.Supervisor.ensure_session(tenant_id, session_id),
             _ = JidoClaw.Session.Worker.add_message(tenant_id, session_id, :user, message),
             {:ok, pid} <- resolve_agent_pid(session_id),
             :ok <- JidoClaw.Startup.inject_system_prompt(pid, project_dir) do
          dispatch_to_agent(pid, tenant_id, session_id, message, project_dir, kind, opts)
        end

      {:ok, other} ->
        {:error, {:invalid_kind, other}}

      :error ->
        {:error, :missing_kind}
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

  defp dispatch_to_agent(pid, tenant_id, session_id, message, project_dir, kind, opts) do
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
             metadata: Keyword.get(opts, :metadata, %{})
           ) do
      tool_context =
        JidoClaw.ToolContext.build(%{
          project_dir: project_dir,
          tenant_id: tenant_id,
          session_id: session_id,
          session_uuid: session.id,
          workspace_id: session_id,
          workspace_uuid: workspace.id,
          agent_id: session_id
        })

      JidoClaw.Agent.ask_sync(pid, message, timeout: 120_000, tool_context: tool_context)
      |> handle_response(tenant_id, session_id)
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp handle_response({:ok, answer}, tenant_id, session_id) when is_binary(answer) do
    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, answer)
    {:ok, answer}
  end

  defp handle_response({:ok, %{text: text}}, tenant_id, session_id) do
    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, text)
    {:ok, text}
  end

  defp handle_response({:ok, %{last_answer: answer}}, tenant_id, session_id) do
    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, answer)
    {:ok, answer}
  end

  defp handle_response({:ok, other}, tenant_id, session_id) do
    text = inspect(other)
    JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, text)
    {:ok, text}
  end

  defp handle_response({:error, reason}, _tenant_id, _session_id) do
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

  @doc "Get message history for a session."
  def history(tenant_id, session_id) do
    JidoClaw.Session.Worker.get_messages(tenant_id, session_id)
  rescue
    _ -> []
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
