defmodule JidoClaw.Tools.AgentStatusTest do
  use JidoClaw.TenantCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Tools.AgentStatus

  setup do
    %{tenant_id: tenant_id, session: session, workspace: workspace} =
      seed_full(tenant_label: "agent_status_tool")

    {:ok, tenant_id: tenant_id, session: session, workspace: workspace}
  end

  defp ctx(tenant_id) do
    %{tool_context: %{tenant_id: tenant_id}}
  end

  describe "run/2" do
    test "happy path returns a JSON-safe map", %{
      tenant_id: tid,
      session: session
    } do
      {:ok, worker_pid} =
        JidoClaw.Session.Supervisor.ensure_session(tid, session.external_id,
          actor: actor_for(tid)
        )

      # The worker is spawned by the app-tree DynamicSupervisor (outside
      # $callers); allow it so its set_session_uuid hydration reads land on
      # the test's owner connection instead of a rescued OwnershipError.
      Sandbox.allow(JidoClaw.Repo, self(), worker_pid)

      :ok = SessionWorker.set_session_uuid(tid, session.external_id, session.id)

      assert {:ok, output} =
               AgentStatus.run(
                 %{session_id: session.external_id},
                 ctx(tid)
               )

      assert output.tenant_id == tid
      assert output.session_id == session.external_id
      assert output.status == "idle"
      assert is_list(output.recent_events)
    end

    test "missing tenant_id in tool_context surfaces as a structured tenant_required error",
         %{session: session} do
      assert {:error, %{code: :tenant_required}} =
               AgentStatus.run(
                 %{session_id: session.external_id},
                 %{tool_context: %{}}
               )
    end

    test "unknown session under known tenant returns a structured error", %{tenant_id: tid} do
      assert {:error, %{code: code}} =
               AgentStatus.run(
                 %{session_id: "no-such-session-#{System.unique_integer([:positive])}"},
                 ctx(tid)
               )

      assert code == :session_not_resolved
    end

    test "existing live session is hidden from another tenant", %{
      tenant_id: tid,
      session: session
    } do
      other_tenant = seed_tenant("agent-status-other")

      {:ok, worker_pid} =
        JidoClaw.Session.Supervisor.ensure_session(tid, session.external_id,
          actor: actor_for(tid)
        )

      Sandbox.allow(JidoClaw.Repo, self(), worker_pid)

      :ok = SessionWorker.set_session_uuid(tid, session.external_id, session.id)

      assert {:error, %{code: :session_not_resolved}} =
               AgentStatus.run(%{session_id: session.external_id}, ctx(other_tenant))
    end
  end
end
