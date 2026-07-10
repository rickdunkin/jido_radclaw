defmodule JidoClaw.Tenants.AccessTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Tenant.InstanceSupervisor
  alias JidoClaw.Tenant.Manager
  alias JidoClaw.Tenants.Access
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Resolver
  alias JidoClaw.Workspaces.Workspace

  test "suspension denies new activity and synchronizes the legacy runtime" do
    tenant_id = unique_tenant_id("activity-gate")
    {:ok, _legacy} = Manager.ensure_tenant(tenant_id)
    assert is_pid(GenServer.whereis(InstanceSupervisor.session_sup(tenant_id)))

    {:ok, row} = Tenant.by_id(tenant_id)
    {:ok, suspended} = Tenant.suspend(row)
    assert suspended.status == :suspended
    assert {:error, {:tenant_inactive, :suspended}} = Access.ensure_active(tenant_id)

    path = Path.join(System.tmp_dir!(), "suspended-#{System.unique_integer([:positive])}")

    assert {:error, {:tenant_inactive, :suspended}} =
             Resolver.ensure_workspace(tenant_id, path, actor: actor_for(tenant_id))

    assert {:error, %Ash.Error.Forbidden{}} =
             Workspace.register(
               %{name: "blocked", path: path},
               tenant: tenant_id,
               actor: actor_for(tenant_id)
             )

    assert GenServer.whereis(InstanceSupervisor.session_sup(tenant_id)) == nil

    {:ok, resumed} = Tenant.resume(suspended)
    assert resumed.status == :active
    assert :ok = Access.ensure_active(tenant_id)
    assert is_pid(GenServer.whereis(InstanceSupervisor.session_sup(tenant_id)))
  end

  test "ensure_active provisions on first call and is read-only at steady state" do
    tenant_id = unique_tenant_id("read-first")

    assert {:ok, nil} = Tenant.by_id(tenant_id, not_found_error?: false)
    assert :ok = Access.ensure_active(tenant_id)

    {:ok, created} = Tenant.by_id(tenant_id)
    assert created.status == :active

    # Steady state issues no write: the old ensure-first shape upserted
    # `updated_at` on EVERY activity check (each LiveView mount).
    assert :ok = Access.ensure_active(tenant_id)
    {:ok, after_second} = Tenant.by_id(tenant_id)
    assert after_second.updated_at == created.updated_at
  end

  test "the legacy Manager suspend API writes the durable tenant row" do
    tenant_id = unique_tenant_id("manager-suspend")
    {:ok, _legacy} = Manager.ensure_tenant(tenant_id)

    assert {:ok, %{status: :suspended}} = Manager.suspend_tenant(tenant_id)
    assert {:ok, %{status: :suspended}} = Tenant.by_id(tenant_id)

    assert {:ok, %{status: :active}} = Manager.resume_tenant(tenant_id)
    assert {:ok, %{status: :active}} = Tenant.by_id(tenant_id)
  end

  test "an ETS cache miss never reactivates a durably suspended tenant" do
    tenant_id = unique_tenant_id("manager-reload")
    {:ok, _legacy} = Manager.ensure_tenant(tenant_id)
    {:ok, row} = Tenant.by_id(tenant_id)
    {:ok, _suspended} = Tenant.suspend(row)

    # Simulates the post-restart state for this tenant: durable row present,
    # runtime/cache absent. The Manager must load status from PostgreSQL.
    :ets.delete(:jido_claw_tenants, tenant_id)

    assert {:ok, %{status: :suspended}} = Manager.ensure_tenant(tenant_id)
    assert GenServer.whereis(InstanceSupervisor.session_sup(tenant_id)) == nil
  end
end
