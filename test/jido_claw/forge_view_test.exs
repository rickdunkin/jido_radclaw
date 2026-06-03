defmodule JidoClaw.ForgeViewTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Forge.Persistence
  alias JidoClaw.ForgeView
  alias JidoClaw.Tools.ForgeStatus

  setup do
    previous = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: true)

    tenant_a = seed_tenant("forge-view-a")
    tenant_b = seed_tenant("forge-view-b")
    {:ok, workspace_a} = seed_workspace(tenant_a)
    {:ok, workspace_b} = seed_workspace(tenant_b)

    on_exit(fn -> Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, previous) end)

    {:ok,
     tenant_a: tenant_a, tenant_b: tenant_b, workspace_a: workspace_a, workspace_b: workspace_b}
  end

  test "list/1 and forge_status hide sessions from other tenants", %{
    tenant_a: tenant_a,
    tenant_b: tenant_b,
    workspace_a: workspace_a,
    workspace_b: workspace_b
  } do
    session_a = "forge-a-#{System.unique_integer([:positive])}"
    session_b = "forge-b-#{System.unique_integer([:positive])}"

    assert %{} =
             Persistence.record_session_started(session_a, %{
               runner: :shell,
               tenant_id: tenant_a,
               workspace_id: workspace_a.id
             })

    assert %{} =
             Persistence.record_session_started(session_b, %{
               runner: :workflow,
               tenant_id: tenant_b,
               workspace_id: workspace_b.id
             })

    assert {:ok, view} = ForgeView.list(%{tenant_id: tenant_a})
    assert Enum.map(view.sessions, & &1.session_id) == [session_a]

    assert {:error, :not_found} = ForgeView.snapshot(session_b, %{tenant_id: tenant_a})

    assert {:ok, status} =
             ForgeStatus.run(%{}, %{
               tool_context: %{tenant_id: tenant_a, workspace_uuid: workspace_a.id}
             })

    assert status["active_count"] == 1
    assert Enum.map(status["sessions"], & &1["session_id"]) == [session_a]
  end

  test "tenant scope is required" do
    assert {:error, :tenant_required} = ForgeView.list(%{})
    assert {:error, %{code: :tenant_required}} = ForgeStatus.run(%{}, %{tool_context: %{}})
  end

  test "snapshot/2 scopes by workspace_id when supplied", %{
    tenant_a: tenant_a,
    workspace_a: workspace_a
  } do
    {:ok, workspace_a2} = seed_workspace(tenant_a)
    session_id = "forge-ws-#{System.unique_integer([:positive])}"

    assert %{} =
             Persistence.record_session_started(session_id, %{
               runner: :shell,
               tenant_id: tenant_a,
               workspace_id: workspace_a2.id
             })

    # Session lives in workspace_a2; scoping to a different same-tenant
    # workspace excludes it.
    assert {:error, :not_found} =
             ForgeView.snapshot(session_id, %{tenant_id: tenant_a, workspace_id: workspace_a.id})

    # The matching workspace returns it...
    assert {:ok, snap} =
             ForgeView.snapshot(session_id, %{tenant_id: tenant_a, workspace_id: workspace_a2.id})

    assert snap.session_id == session_id

    # ...and so does an unscoped (no workspace_id) call.
    assert {:ok, %{session_id: ^session_id}} =
             ForgeView.snapshot(session_id, %{tenant_id: tenant_a})
  end
end
