defmodule JidoClaw.Forge.ManagerRecoveryTest do
  @moduledoc """
  The recovery lifecycle matrix behind `Manager.recoverable?/1`
  (docs/system/forge-session-resume.md): pointed-checkpoint authority plus
  per-copy epoch matching for armed sessions, pointer + ownership alone for
  resume-off sessions. DB rows only — no Harness boots; the epoch stamps are
  compared on reads, the incarnation token never participates.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Forge.Manager
  alias JidoClaw.Forge.Persistence
  alias JidoClaw.Forge.ResumeState

  setup do
    tenant_id = seed_tenant("forge-mgr-recovery")
    {:ok, workspace} = seed_workspace(tenant_id)

    sid = "mgr_recovery_#{:erlang.unique_integer([:positive])}"
    spec = %{runner: :claude_code, tenant_id: tenant_id, workspace_uuid: workspace.id}
    session = Persistence.record_session_started(sid, spec)
    assert session

    %{sid: sid}
  end

  defp mint!(sid, expected \\ nil, transplant \\ nil) do
    {:ok, pair} = Persistence.mint_resume_epoch(sid, expected, transplant)
    pair
  end

  defp anchored_state do
    {:ok, rs} = ResumeState.mint_client(ResumeState.new(), Ecto.UUID.generate(), "/work")
    rs
  end

  defp armed_snapshot(epoch) do
    stamped = ResumeState.stamp(anchored_state(), epoch, 1)
    %{"iteration" => 1, "resume" => %{"state" => ResumeState.encode_state(stamped)}}
  end

  # Corruption-sim: fenced writes keep every copy's epoch consistent by
  # construction, so hand-editing the jsonb is the only way to build a
  # mismatched row.
  defp corrupt_metadata!(sid, path, value) do
    JidoClaw.Repo.query!(
      "UPDATE forge_sessions SET metadata = jsonb_set(metadata, $1, $2::jsonb) WHERE name = $3",
      [path, Jason.encode!(value), sid]
    )
  end

  describe "recoverable?/1 — lifecycle matrix" do
    test "armed + pointed checkpoint + matching epochs recovers", %{sid: sid} do
      pair = mint!(sid, nil, anchored_state())

      {:ok, _cp} =
        Persistence.save_recovery_checkpoint(
          sid,
          1,
          armed_snapshot(pair.epoch),
          %{},
          nil,
          pair.token
        )

      Persistence.update_session_phase(sid, :running)

      assert Manager.recoverable?(sid)
    end

    test "resume-off (no ResumeState copies) recovers via pointer + ownership alone",
         %{sid: sid} do
      pair = mint!(sid)

      {:ok, _cp} =
        Persistence.save_recovery_checkpoint(sid, 1, %{"iteration" => 1}, %{}, nil, pair.token)

      Persistence.update_session_phase(sid, :running)

      assert Manager.recoverable?(sid)
    end

    test "a :failed phase stays recoverable (existing allowance preserved)", %{sid: sid} do
      pair = mint!(sid)
      {:ok, _cp} = Persistence.save_recovery_checkpoint(sid, 1, %{}, %{}, nil, pair.token)
      Persistence.update_session_phase(sid, :failed)

      assert Manager.recoverable?(sid)
    end

    test "best-effort checkpoints without a pointer never recover", %{sid: sid} do
      mint!(sid)
      assert %{} = Persistence.save_checkpoint(sid, 1, %{"iteration" => 1}, %{})
      Persistence.update_session_phase(sid, :running)

      refute Manager.recoverable?(sid)
    end

    test "a terminal phase never recovers even with a pointed checkpoint", %{sid: sid} do
      pair = mint!(sid)
      {:ok, _cp} = Persistence.save_recovery_checkpoint(sid, 1, %{}, %{}, nil, pair.token)
      Persistence.update_session_phase(sid, :cancelled)

      refute Manager.recoverable?(sid)
    end

    test "a checkpoint copy from a stale epoch refuses recovery", %{sid: sid} do
      pair = mint!(sid, nil, anchored_state())

      {:ok, _cp} =
        Persistence.save_recovery_checkpoint(
          sid,
          1,
          armed_snapshot(pair.epoch),
          %{},
          nil,
          pair.token
        )

      Persistence.update_session_phase(sid, :running)
      assert Manager.recoverable?(sid)

      # Corruption-sim: the fence claims a newer incarnation than either copy.
      corrupt_metadata!(sid, ["forge_recovery", "epoch"], pair.epoch + 1)

      refute Manager.recoverable?(sid)
    end

    test "a stale metadata state copy alone refuses recovery", %{sid: sid} do
      pair = mint!(sid, nil, anchored_state())

      {:ok, _cp} =
        Persistence.save_recovery_checkpoint(
          sid,
          1,
          armed_snapshot(pair.epoch),
          %{},
          nil,
          pair.token
        )

      Persistence.update_session_phase(sid, :running)

      # Only the metadata copy goes stale; fence + checkpoint still agree.
      corrupt_metadata!(sid, ["resume", "state", "epoch"], pair.epoch + 5)

      refute Manager.recoverable?(sid)
    end

    test "an unknown session never recovers" do
      refute Manager.recoverable?("mgr_recovery_never_created")
    end
  end
end
