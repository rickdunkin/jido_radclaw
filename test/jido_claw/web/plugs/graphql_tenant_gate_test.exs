defmodule JidoClaw.Web.Plugs.GraphqlTenantGateTest do
  @moduledoc """
  Public-behavior coverage for the `/gql` tenant-activity gate: active
  tenants continue with the Ash tenant set; inactive tenants 403; a missing
  or malformed actor fails closed 403; an activity-check infra failure 503s
  through the `:tenant_access_module` app-env seam (stub injected, previous
  value restored — never merely deleted).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Tenants.Access
  alias JidoClaw.Web.Plugs.GraphqlTenantGate

  defmodule InfraDownAccess do
    @moduledoc false

    @spec ensure_active(String.t()) :: {:error, :db_down}
    def ensure_active(_tenant_id), do: {:error, :db_down}
  end

  setup do
    previous = Application.fetch_env(:jido_claw, :tenant_access_module)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_claw, :tenant_access_module, value)
        :error -> Application.delete_env(:jido_claw, :tenant_access_module)
      end
    end)

    :ok
  end

  defp call_gate(actor) do
    :post
    |> Phoenix.ConnTest.build_conn("/gql", %{})
    |> then(fn conn ->
      if actor, do: Ash.PlugHelpers.set_actor(conn, actor), else: conn
    end)
    |> GraphqlTenantGate.call(GraphqlTenantGate.init([]))
  end

  test "an active tenant's actor continues with the Ash tenant set" do
    tenant_id = seed_tenant(:gate_active)
    conn = call_gate(actor_for(tenant_id))

    refute conn.halted
    assert Ash.PlugHelpers.get_tenant(conn) == tenant_id
  end

  test "a first-ever actor provisions its tenant row and continues" do
    tenant_id = unique_tenant_id(:gate_provision)
    conn = call_gate(actor_for(tenant_id))

    refute conn.halted
    assert Ash.PlugHelpers.get_tenant(conn) == tenant_id
    assert :ok = Access.active?(tenant_id)
  end

  test "an inactive tenant halts 403 tenant_inactive" do
    tenant_id = seed_tenant(:gate_suspended)
    {:ok, tenant} = Tenant.by_id(tenant_id)
    {:ok, _} = Tenant.suspend(tenant)

    conn = call_gate(actor_for(tenant_id))

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "tenant_inactive"}
    assert Ash.PlugHelpers.get_tenant(conn) == nil
  end

  test "a missing actor halts 403 (fail closed)" do
    conn = call_gate(nil)

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_actor"}
  end

  test "malformed actors halt 403 (fail closed)" do
    for actor <- [%{}, %{tenant_id: nil}, %{tenant_id: ""}, %{tenant_id: :not_a_binary}] do
      conn = call_gate(actor)

      assert conn.halted, "expected halt for actor #{inspect(actor)}"
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_actor"}
    end
  end

  test "an activity-check infra failure halts 503 tenant_unavailable" do
    Application.put_env(:jido_claw, :tenant_access_module, InfraDownAccess)

    conn = call_gate(actor_for(unique_tenant_id(:gate_infra)))

    assert conn.halted
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"error" => "tenant_unavailable"}
  end
end
