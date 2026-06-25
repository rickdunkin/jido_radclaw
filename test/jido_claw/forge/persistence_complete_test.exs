defmodule JidoClaw.Forge.PersistenceCompleteTest do
  @moduledoc """
  AR-8b-2 F2 (1.3): `Persistence.complete_session/1` calls the `:complete` Ash
  action (sets `phase: :completed` AND stamps `completed_at`), distinct from the
  generic `:update_phase` (which does not). Tested at the Persistence layer
  directly — no Harness/Manager, so deterministic with a real DB row.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Forge.Persistence

  setup do
    tenant_id = seed_tenant("forge-persist-complete")
    {:ok, workspace} = seed_workspace(tenant_id)

    sid = "persist_complete_#{:erlang.unique_integer([:positive])}"
    spec = %{runner: :shell, tenant_id: tenant_id, workspace_uuid: workspace.id}
    session = Persistence.record_session_started(sid, spec)
    assert session.phase in [:created, :provisioning]

    %{sid: sid}
  end

  test "complete_session/1 stamps :completed AND completed_at", %{sid: sid} do
    assert %{phase: :completed} = updated = Persistence.complete_session(sid)
    assert updated.completed_at != nil

    # Persisted, not just in-memory.
    reloaded = Persistence.find_session(sid)
    assert reloaded.phase == :completed
    assert reloaded.completed_at != nil
  end

  test "the generic :update_phase(:completed) does NOT stamp completed_at (the distinction)",
       %{sid: sid} do
    assert %{phase: :completed} = updated = Persistence.update_session_phase(sid, :completed)
    # This is precisely why 1.3 builds on the `:complete` action, not `:update_phase`.
    assert updated.completed_at == nil
  end
end
