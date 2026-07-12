defmodule JidoClaw.Forge.PersistenceResumeFenceTest do
  @moduledoc """
  The forge_recovery incarnation fence at the Persistence layer: locked
  CAS mint, token+revision-fenced anchor mirror, the checked pointer-first
  checkpoint save, and the degraded marker — every stale writer surfaces a
  real error and writes nothing (`docs/system/forge-session-resume.md`).
  """
  use JidoClaw.TenantCase, async: true

  require Ash.Query

  alias JidoClaw.Forge.Persistence
  alias JidoClaw.Forge.Resources.Checkpoint
  alias JidoClaw.Forge.ResumeState

  setup do
    tenant_id = seed_tenant("forge-resume-fence")
    {:ok, workspace} = seed_workspace(tenant_id)

    sid = "resume_fence_#{:erlang.unique_integer([:positive])}"
    spec = %{runner: :claude_code, tenant_id: tenant_id, workspace_uuid: workspace.id}
    session = Persistence.record_session_started(sid, spec)
    assert session

    %{sid: sid, session: session}
  end

  defp mint!(sid, expected \\ nil, transplant \\ nil) do
    {:ok, pair} = Persistence.mint_resume_epoch(sid, expected, transplant)
    pair
  end

  defp anchored_state(epoch, revision) do
    {:ok, rs} = ResumeState.mint_client(ResumeState.new(), Ecto.UUID.generate(), "/work")
    ResumeState.stamp(rs, epoch, revision)
  end

  defp metadata_of(sid), do: Persistence.find_session(sid).metadata

  defp checkpoint_rows(session) do
    Checkpoint
    |> Ash.Query.filter(session_id == ^session.id)
    |> Ash.read!()
  end

  describe "mint_resume_epoch/3" do
    test "virgin mint installs epoch 1 with a blank transplant and no pointer", %{sid: sid} do
      assert Persistence.stored_recovery_pair(sid) == nil

      pair = mint!(sid)

      assert pair.epoch == 1
      assert is_binary(pair.token)
      assert Persistence.stored_recovery_pair(sid) == pair

      recovery = metadata_of(sid)["forge_recovery"]
      assert recovery["current_checkpoint_id"] == nil
      assert recovery["recovery_degraded"] == false
      assert metadata_of(sid)["resume"] == %{}
    end

    test "expected nil is refused once a pair exists", %{sid: sid} do
      mint!(sid)

      assert {:error, :stale_mint} = Persistence.mint_resume_epoch(sid, nil, nil)
    end

    test "CAS from the stored pair rotates; the old pair can never mint again", %{sid: sid} do
      pair1 = mint!(sid)
      pair2 = mint!(sid, pair1)

      assert pair2.epoch == 2
      refute pair2.token == pair1.token

      assert {:error, :stale_mint} = Persistence.mint_resume_epoch(sid, pair1, nil)
      assert Persistence.stored_recovery_pair(sid) == pair2
    end

    test "a mismatched expected token cannot mint", %{sid: sid} do
      pair1 = mint!(sid)
      forged = %{pair1 | token: Ecto.UUID.generate()}

      assert {:error, :stale_mint} = Persistence.mint_resume_epoch(sid, forged, nil)
    end

    test "unknown session refuses :no_session" do
      assert {:error, :no_session} =
               Persistence.mint_resume_epoch(Ecto.UUID.generate(), nil, nil)
    end

    test "the transplant installs stamped {new epoch, revision 0} with the marker re-stamped",
         %{sid: sid} do
      pair1 = mint!(sid)

      {:ok, with_guidance} = ResumeState.put_guidance(anchored_state(1, 7), "carry me")
      pair2 = mint!(sid, pair1, with_guidance)

      resume = metadata_of(sid)["resume"]
      assert resume["state"]["epoch"] == pair2.epoch
      assert resume["state"]["revision"] == 0
      assert resume["state"]["status"] == "anchored"
      assert resume["guidance"]["epoch"] == pair2.epoch
      assert resume["guidance"]["guidance_rev"] == 1
      assert resume["guidance"]["status"] == "pending"
      # sanitized: the transplant never carries guidance text
      refute Map.has_key?(resume["guidance"], "text")
    end

    test "a selector fun runs against the locked row inside the critical section", %{sid: sid} do
      pair1 = mint!(sid)
      test_pid = self()

      selector = fn locked_session ->
        send(test_pid, {:selector_saw, locked_session.name})
        anchored_state(1, 3)
      end

      pair2 = mint!(sid, pair1, selector)

      assert_received {:selector_saw, ^sid}
      assert metadata_of(sid)["resume"]["state"]["epoch"] == pair2.epoch
    end

    test "the mint clears an existing checkpoint pointer", %{sid: sid} do
      pair1 = mint!(sid)

      {:ok, _cp} =
        Persistence.save_recovery_checkpoint(sid, 1, %{"iteration" => 1}, %{}, nil, pair1.token)

      assert metadata_of(sid)["forge_recovery"]["current_checkpoint_id"]

      mint!(sid, pair1)
      assert metadata_of(sid)["forge_recovery"]["current_checkpoint_id"] == nil
    end
  end

  describe "anchor_session/3 (fenced mirror)" do
    test "current token + newer revision lands; sibling paths untouched", %{sid: sid} do
      pair = mint!(sid)

      assert :ok = Persistence.anchor_session(sid, anchored_state(pair.epoch, 1), pair.token)

      md = metadata_of(sid)
      assert md["resume"]["state"]["revision"] == 1
      assert md["forge_recovery"]["token"] == pair.token
    end

    test "a stale token is rejected with :stale_resume_write and state is unchanged",
         %{sid: sid} do
      pair = mint!(sid)
      assert :ok = Persistence.anchor_session(sid, anchored_state(pair.epoch, 1), pair.token)
      before_md = metadata_of(sid)

      assert {:error, :stale_resume_write} =
               Persistence.anchor_session(
                 sid,
                 anchored_state(pair.epoch, 2),
                 Ecto.UUID.generate()
               )

      assert metadata_of(sid) == before_md
    end

    test "a non-newer revision is rejected — same and lower both fence out", %{sid: sid} do
      pair = mint!(sid)
      assert :ok = Persistence.anchor_session(sid, anchored_state(pair.epoch, 2), pair.token)

      assert {:error, :stale_resume_write} =
               Persistence.anchor_session(sid, anchored_state(pair.epoch, 2), pair.token)

      assert {:error, :stale_resume_write} =
               Persistence.anchor_session(sid, anchored_state(pair.epoch, 1), pair.token)

      assert metadata_of(sid)["resume"]["state"]["revision"] == 2
    end

    test "token rotation invalidates a delayed writer holding the old token", %{sid: sid} do
      pair1 = mint!(sid)
      mint!(sid, pair1)

      assert {:error, :stale_resume_write} =
               Persistence.anchor_session(sid, anchored_state(pair1.epoch, 1), pair1.token)
    end

    test "no fence pair at all means every anchor write fences out", %{sid: sid} do
      assert {:error, :stale_resume_write} =
               Persistence.anchor_session(sid, anchored_state(0, 1), Ecto.UUID.generate())
    end
  end

  describe "save_recovery_checkpoint/6 (checked, pointer-first)" do
    test "success sets the pointer, clears degraded, mirrors the marker, creates the row",
         %{sid: sid, session: session} do
      pair = mint!(sid)
      marker = %{"v" => 1, "status" => "pending", "guidance_rev" => 1, "epoch" => pair.epoch}

      {:ok, checkpoint} =
        Persistence.save_recovery_checkpoint(
          sid,
          3,
          %{"iteration" => 3},
          %{"epoch" => pair.epoch},
          marker,
          pair.token
        )

      md = metadata_of(sid)
      assert md["forge_recovery"]["current_checkpoint_id"] == checkpoint.id
      assert md["forge_recovery"]["recovery_degraded"] == false
      assert md["resume"]["guidance"] == marker

      assert [row] = checkpoint_rows(session)
      assert row.id == checkpoint.id
      assert row.runner_state_snapshot == %{"iteration" => 3}
    end

    test "a nil marker moves the pointer without touching an existing guidance marker",
         %{sid: sid} do
      pair = mint!(sid)
      marker = %{"v" => 1, "status" => "consumed", "guidance_rev" => 4, "epoch" => pair.epoch}

      {:ok, _} = Persistence.save_recovery_checkpoint(sid, 1, %{}, %{}, marker, pair.token)
      {:ok, cp2} = Persistence.save_recovery_checkpoint(sid, 2, %{}, %{}, nil, pair.token)

      md = metadata_of(sid)
      assert md["resume"]["guidance"] == marker
      assert md["forge_recovery"]["current_checkpoint_id"] == cp2.id
    end

    test "a stale token is refused AND no checkpoint row is created",
         %{sid: sid, session: session} do
      mint!(sid)

      assert {:error, :stale_resume_write} =
               Persistence.save_recovery_checkpoint(
                 sid,
                 1,
                 %{"iteration" => 1},
                 %{},
                 nil,
                 Ecto.UUID.generate()
               )

      assert checkpoint_rows(session) == []
    end

    test "multiple checked saves in one incarnation keep pointer selection correct",
         %{sid: sid} do
      pair = mint!(sid)

      {:ok, _cp1} =
        Persistence.save_recovery_checkpoint(sid, 1, %{"n" => 1}, %{}, nil, pair.token)

      {:ok, cp2} = Persistence.save_recovery_checkpoint(sid, 2, %{"n" => 2}, %{}, nil, pair.token)

      assert metadata_of(sid)["forge_recovery"]["current_checkpoint_id"] == cp2.id
    end
  end

  describe "metadata-path isolation" do
    test "checkpoint-then-anchor: the pointer survives the anchor write", %{sid: sid} do
      pair = mint!(sid)

      {:ok, checkpoint} =
        Persistence.save_recovery_checkpoint(sid, 1, %{}, %{}, nil, pair.token)

      assert :ok = Persistence.anchor_session(sid, anchored_state(pair.epoch, 1), pair.token)

      md = metadata_of(sid)
      assert md["forge_recovery"]["current_checkpoint_id"] == checkpoint.id
      assert md["resume"]["state"]["revision"] == 1
    end

    test "anchor-then-checkpoint: the state survives the pointer write", %{sid: sid} do
      pair = mint!(sid)
      state = anchored_state(pair.epoch, 1)
      assert :ok = Persistence.anchor_session(sid, state, pair.token)

      marker = %{"v" => 1, "status" => "pending", "guidance_rev" => 1, "epoch" => pair.epoch}

      {:ok, checkpoint} =
        Persistence.save_recovery_checkpoint(sid, 2, %{}, %{}, marker, pair.token)

      md = metadata_of(sid)
      assert md["resume"]["state"]["session_id"] == state.session_id
      assert md["resume"]["guidance"] == marker
      assert md["forge_recovery"]["current_checkpoint_id"] == checkpoint.id
    end
  end

  describe "mark_recovery_degraded/2" do
    test "sets the flag under the current token; a later checked save self-heals",
         %{sid: sid} do
      pair = mint!(sid)

      assert :ok = Persistence.mark_recovery_degraded(sid, pair.token)
      assert metadata_of(sid)["forge_recovery"]["recovery_degraded"] == true

      {:ok, _cp} = Persistence.save_recovery_checkpoint(sid, 1, %{}, %{}, nil, pair.token)
      assert metadata_of(sid)["forge_recovery"]["recovery_degraded"] == false
    end

    test "a stale incarnation can never mark a newer one degraded", %{sid: sid} do
      pair1 = mint!(sid)
      mint!(sid, pair1)

      assert {:error, :stale_resume_write} =
               Persistence.mark_recovery_degraded(sid, pair1.token)

      assert metadata_of(sid)["forge_recovery"]["recovery_degraded"] == false
    end
  end

  describe "current_checkpoint/1 (pointer authority)" do
    test "returns the pointed row even when a newer unpointed checkpoint exists",
         %{sid: sid} do
      pair = mint!(sid)

      {:ok, pointed} =
        Persistence.save_recovery_checkpoint(sid, 1, %{"n" => 1}, %{}, nil, pair.token)

      # A later best-effort save (the ordinary iteration path) is wall-clock
      # newer but NEVER moves the pointer.
      Process.sleep(10)
      assert %{} = Persistence.save_checkpoint(sid, 2, %{"n" => 2}, %{})

      assert Persistence.current_checkpoint(sid).id == pointed.id
      # Contrast: wall-clock latest is the unpointed row — no longer a
      # selection authority anywhere in recovery.
      assert Persistence.latest_checkpoint(sid).id != pointed.id
    end

    test "no pointer → nil even with best-effort checkpoints present", %{sid: sid} do
      mint!(sid)
      assert %{} = Persistence.save_checkpoint(sid, 1, %{"n" => 1}, %{})

      assert Persistence.current_checkpoint(sid) == nil
    end

    test "a dangling pointer (row destroyed) → nil", %{sid: sid} do
      pair = mint!(sid)
      {:ok, pointed} = Persistence.save_recovery_checkpoint(sid, 1, %{}, %{}, nil, pair.token)

      :ok = Ash.destroy!(pointed)

      assert Persistence.current_checkpoint(sid) == nil
    end

    test "a foreign pointer (another session's checkpoint) → nil", %{sid: sid, session: session} do
      other_sid = "resume_fence_other_#{:erlang.unique_integer([:positive])}"

      other_spec = %{
        runner: :claude_code,
        tenant_id: session.tenant_id,
        workspace_uuid: session.workspace_id
      }

      assert Persistence.record_session_started(other_sid, other_spec)

      other_pair = mint!(other_sid)

      {:ok, foreign} =
        Persistence.save_recovery_checkpoint(other_sid, 1, %{}, %{}, nil, other_pair.token)

      # Corruption-sim: point THIS session at the other session's row.
      mint!(sid)
      put_pointer!(sid, foreign.id)

      assert Persistence.current_checkpoint(sid) == nil
    end
  end

  describe "context_for_resume/1 (pointer-keyed)" do
    test "selects the pointed checkpoint — and the events since IT — over a newer unpointed row",
         %{sid: sid} do
      pair = mint!(sid)

      Persistence.log_event(sid, "iteration.completed", %{iteration: 1, status: :done})
      Process.sleep(10)

      {:ok, pointed} =
        Persistence.save_recovery_checkpoint(sid, 1, %{"n" => 1}, %{}, nil, pair.token)

      Process.sleep(10)
      Persistence.log_event(sid, "iteration.completed", %{iteration: 2, status: :done})
      assert %{} = Persistence.save_checkpoint(sid, 2, %{"n" => 2}, %{})

      ctx = Persistence.context_for_resume(sid)

      assert ctx.last_checkpoint.id == pointed.id

      since_iterations =
        for e <- ctx.events_since_checkpoint,
            e.event_type == "iteration.completed",
            do: e.data["iteration"]

      assert 2 in since_iterations
      refute 1 in since_iterations
    end

    test "no pointer → no last_checkpoint, events since start", %{sid: sid} do
      mint!(sid)
      Persistence.log_event(sid, "iteration.completed", %{iteration: 1, status: :done})
      assert %{} = Persistence.save_checkpoint(sid, 1, %{}, %{})

      ctx = Persistence.context_for_resume(sid)

      assert ctx.last_checkpoint == nil
      assert Enum.any?(ctx.events_since_checkpoint, &(&1.event_type == "iteration.completed"))
    end
  end

  # Corruption-sim helper: recovery pointers are only ever written by the
  # fenced actions, so hand-editing the jsonb is the only way to construct a
  # foreign pointer.
  defp put_pointer!(sid, checkpoint_id) do
    JidoClaw.Repo.query!(
      "UPDATE forge_sessions SET metadata = jsonb_set(metadata, '{forge_recovery,current_checkpoint_id}', to_jsonb($1::text)) WHERE name = $2",
      [checkpoint_id, sid]
    )
  end
end
