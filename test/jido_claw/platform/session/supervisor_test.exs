defmodule JidoClaw.Session.SupervisorTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Tenant.InstanceSupervisor

  test "stop_session finds a global-fallback worker after the tenant supervisor appears" do
    tenant_id = "late-runtime-#{System.unique_integer([:positive, :monotonic])}"
    session_id = "fallback-worker"
    tenant_sup = InstanceSupervisor.session_sup(tenant_id)

    assert GenServer.whereis(tenant_sup) == nil
    assert {:ok, pid} = SessionSupervisor.start_session(tenant_id, session_id)

    assert Enum.any?(DynamicSupervisor.which_children(JidoClaw.SessionSupervisor), fn
             {_id, ^pid, _type, _modules} -> true
             _other -> false
           end)

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: tenant_sup})
    assert is_pid(GenServer.whereis(tenant_sup))

    assert :ok = SessionSupervisor.stop_session(tenant_id, session_id)
    refute Process.alive?(pid)

    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}
    assert GenServer.whereis(name) == nil
  end

  test "stop_session remains idempotent when no worker exists" do
    assert :ok =
             SessionSupervisor.stop_session(
               "missing-#{System.unique_integer([:positive, :monotonic])}",
               "missing"
             )
  end
end
