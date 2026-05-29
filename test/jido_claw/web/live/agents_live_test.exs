defmodule JidoClaw.Web.AgentsLiveTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Web.AgentsLive

  defp build_socket(assigns) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          flash: %{},
          page_title: "Agents",
          tenant_id: nil,
          agent_views: [],
          current_user: nil
        },
        assigns
      )

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  defp install_handoff(tenant_id, runtime_session_id, session_uuid, template, module) do
    handoff =
      Handoff.new(%{
        tenant_id: tenant_id,
        runtime_session_id: runtime_session_id,
        session_uuid: session_uuid,
        from_template: "main",
        to_template: template,
        to_module: module,
        message: "Please handle"
      })

    :ok = HandoffRegistry.put_owner(tenant_id, runtime_session_id, handoff)
    handoff
  end

  describe "mount/3" do
    test "with no authenticated user, assigns empty agent_views and no crash" do
      socket = build_socket(%{current_user: nil})
      assert {:ok, returned} = AgentsLive.mount(%{}, %{}, socket)
      assert returned.assigns.agent_views == []
      assert returned.assigns.tenant_id == nil
    end

    test "with authenticated user and no active sessions, assigns empty list" do
      tenant_id = seed_tenant("agents_live")
      user = %{id: tenant_id}

      socket = build_socket(%{current_user: user})

      assert {:ok, returned} = AgentsLive.mount(%{}, %{}, socket)
      assert returned.assigns.tenant_id == tenant_id
      assert returned.assigns.agent_views == []
    end

    test "with an active session, surfaces the matching AgentView card" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "agents_live_full")

      {:ok, _pid} =
        JidoClaw.Session.Supervisor.ensure_session(tenant_id, session.external_id,
          actor: actor_for(tenant_id)
        )

      :ok = SessionWorker.set_session_uuid(tenant_id, session.external_id, session.id)

      user = %{id: tenant_id}
      socket = build_socket(%{current_user: user})

      assert {:ok, returned} = AgentsLive.mount(%{}, %{}, socket)
      assert [view] = returned.assigns.agent_views
      assert view.session_id == session.external_id
      assert view.status == :idle
    end

    test "awaiting handoff yields status :awaiting_handoff on the rendered view" do
      %{tenant_id: tenant_id, session: session} =
        seed_full(tenant_label: "agents_live_handoff")

      {:ok, _pid} =
        JidoClaw.Session.Supervisor.ensure_session(tenant_id, session.external_id,
          actor: actor_for(tenant_id)
        )

      :ok = SessionWorker.set_session_uuid(tenant_id, session.external_id, session.id)

      install_handoff(
        tenant_id,
        session.external_id,
        session.id,
        "reviewer",
        JidoClaw.Agent.Workers.Reviewer
      )

      user = %{id: tenant_id}
      socket = build_socket(%{current_user: user})

      assert {:ok, returned} = AgentsLive.mount(%{}, %{}, socket)
      assert [view] = returned.assigns.agent_views
      assert view.status == :awaiting_handoff
      assert view.agent_template == "reviewer"

      HandoffRegistry.clear(tenant_id, session.external_id)
    end
  end

  describe "handle_info(:refresh, ...)" do
    test "re-fetches agent_views without crashing" do
      tenant_id = seed_tenant("agents_live_refresh")
      socket = build_socket(%{tenant_id: tenant_id, agent_views: []})

      assert {:noreply, returned} = AgentsLive.handle_info(:refresh, socket)
      assert returned.assigns.agent_views == []
    end
  end
end
