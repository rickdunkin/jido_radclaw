defmodule JidoClaw.Forge.WakeTest do
  @moduledoc """
  `Forge.wake/2`'s checkpoint-selection seam: recovery restores ONLY the
  pointed checkpoint (`forge_recovery.current_checkpoint_id`) — a
  best-effort (unpointed) row no longer wakes a session
  (docs/system/forge-session-resume.md). Negative rows only: the positive
  path boots a Harness and lands with the recovery integration suite.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Forge
  alias JidoClaw.Forge.Persistence

  setup do
    tenant_id = seed_tenant("forge-wake")
    {:ok, workspace} = seed_workspace(tenant_id)

    sid = "wake_seam_#{:erlang.unique_integer([:positive])}"
    spec = %{runner: :shell, tenant_id: tenant_id, workspace_uuid: workspace.id}
    session = Persistence.record_session_started(sid, spec)
    assert session

    %{sid: sid}
  end

  test "only best-effort (unpointed) checkpoints refuse to wake", %{sid: sid} do
    # Pre-pointer this row WOULD have woken via wall-clock latest — the
    # pointer is now the only selection authority.
    assert %{} = Persistence.save_checkpoint(sid, 1, %{"iteration" => 1}, %{})
    Persistence.update_session_phase(sid, :running)

    assert {:error, :no_checkpoint} = Forge.wake(sid)
  end

  test "a terminal session refuses to wake even with a pointed checkpoint", %{sid: sid} do
    {:ok, pair} = Persistence.mint_resume_epoch(sid, nil, nil)
    {:ok, _cp} = Persistence.save_recovery_checkpoint(sid, 1, %{}, %{}, nil, pair.token)
    Persistence.update_session_phase(sid, :completed)

    assert {:error, :session_terminal} = Forge.wake(sid)
  end
end
