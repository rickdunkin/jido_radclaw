defmodule JidoClaw do
  @moduledoc """
  JidoClaw - AI agent platform with CLI, HTTP gateway, multi-tenancy,
  channel adapters (Discord, Telegram), cron scheduling, and swarm orchestration.
  Powered by the Jido framework on BEAM/OTP.

  ## Quick Start

      # Create a session and chat
      {:ok, response} = JidoClaw.chat("default", "main", "Hello!")

      # List sessions for a tenant
      sessions = JidoClaw.sessions("default")

      # Get conversation history
      messages = JidoClaw.history("default", "main")
  """

  @version "0.3.0"

  def version, do: @version

  @doc """
  Send a message to an agent session, creating it if needed.
  Routes through the session GenServer and Jido agent.
  """
  @spec chat(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def chat(tenant_id \\ "default", session_id, message) do
    project_dir = File.cwd!()

    with {:ok, _} <- JidoClaw.Startup.ensure_project_state(project_dir),
         {:ok, _pid} <- JidoClaw.Session.Supervisor.ensure_session(tenant_id, session_id),
         _ = JidoClaw.Session.Worker.add_message(tenant_id, session_id, :user, message),
         {:ok, pid} <- resolve_agent_pid(session_id),
         :ok <- JidoClaw.Startup.inject_system_prompt(pid, project_dir) do
      dispatch_to_agent(pid, tenant_id, session_id, message, project_dir)
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

  defp dispatch_to_agent(pid, tenant_id, session_id, message, project_dir) do
    result =
      JidoClaw.Agent.ask_sync(pid, message,
        timeout: 120_000,
        tool_context: %{project_dir: project_dir, workspace_id: session_id}
      )

    case result do
      {:ok, answer} when is_binary(answer) ->
        JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, answer)
        {:ok, answer}

      {:ok, %{text: text}} ->
        JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, text)
        {:ok, text}

      {:ok, %{last_answer: answer}} ->
        JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, answer)
        {:ok, answer}

      {:ok, other} ->
        text = inspect(other)
        JidoClaw.Session.Worker.add_message(tenant_id, session_id, :assistant, text)
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
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
