defmodule JidoClaw.Forge.HarnessResumeTest.ArmedRunner do
  @moduledoc false
  # Armed test runner for the Harness resume integration: no sandbox calls,
  # per-test iteration behavior injected via the :harness_resume_iteration
  # app-env fun (async: false suite), vendor-faithful serialize/restore via
  # ResumePolicy so checked checkpoints round-trip the canonical
  # ["resume"]["state"] shape. Config keys are read in BOTH atom and string
  # form: an unstamped runner_config recovers string-keyed (the
  # RecoveredSpec passthrough lane).
  @behaviour JidoClaw.Forge.Runner

  alias JidoClaw.Forge.{ResumeState, Runner}
  alias JidoClaw.Forge.Runners.ResumePolicy

  @impl JidoClaw.Forge.Runner
  def init(_client, config) do
    state =
      case cfg(config, :resume) do
        armed when armed in [:armed, "armed"] ->
          %{iteration: 0, resume: ResumeState.new(workdir: cfg(config, :workdir) || "/work")}

        _off ->
          %{iteration: 0}
      end

    {:ok, state}
  end

  @impl JidoClaw.Forge.Runner
  def run_iteration(_client, state, opts) do
    case Application.get_env(:jido_claw, :harness_resume_iteration) do
      fun when is_function(fun, 2) ->
        fun.(state, opts)

      _default ->
        result = Runner.done("noop")

        case state do
          %{resume: %ResumeState{} = rs} ->
            {:ok, ResumePolicy.attach_runner_state(result, state, rs)}

          _off ->
            {:ok, result}
        end
    end
  end

  @impl JidoClaw.Forge.Runner
  def apply_input(_client, _input, _state), do: :ok

  @impl JidoClaw.Forge.Runner
  def serialize_state(state), do: ResumePolicy.serialize_state(state)

  @impl JidoClaw.Forge.Runner
  def restore_state(state, snapshot), do: ResumePolicy.restore_state(state, snapshot)

  defp cfg(config, key), do: Map.get(config, key) || Map.get(config, Atom.to_string(key))
end

defmodule JidoClaw.Forge.HarnessResumeTest.FailFirstCheckedSave do
  @moduledoc false
  # `:forge_persistence` seam stub: the FIRST checked save fails (driving the
  # initial-checkpoint → recovery_degraded path); every later call — and every
  # other fenced op — delegates to the real Persistence, so the next checked
  # save can self-heal the marker for real.
  alias JidoClaw.Forge.Persistence

  defdelegate enabled?(), to: Persistence
  defdelegate stored_recovery_pair(session_id), to: Persistence
  defdelegate mint_resume_epoch(session_id, expected, transplant), to: Persistence
  defdelegate pointed_checkpoint(session), to: Persistence
  defdelegate mark_recovery_degraded(session_id, token), to: Persistence
  defdelegate anchor_session(session_id, resume, token), to: Persistence
  defdelegate complete_session(session_id), to: Persistence

  @spec save_recovery_checkpoint(
          String.t(),
          non_neg_integer(),
          map(),
          map(),
          map() | nil,
          String.t()
        ) :: {:ok, struct()} | {:error, atom()}
  def save_recovery_checkpoint(session_id, sequence, snapshot, metadata, marker, token) do
    if :ets.update_counter(:harness_resume_fail_first, :saves, 1) == 1 do
      {:error, :not_persisted}
    else
      Persistence.save_recovery_checkpoint(
        session_id,
        sequence,
        snapshot,
        metadata,
        marker,
        token
      )
    end
  end
end

defmodule JidoClaw.Forge.HarnessResumeTest.RefuseMint do
  @moduledoc false
  # `:forge_persistence` seam stub: the mint itself fails — the session must
  # stop loudly rather than run un-fenced.
  alias JidoClaw.Forge.Persistence

  defdelegate enabled?(), to: Persistence
  defdelegate stored_recovery_pair(session_id), to: Persistence
  defdelegate complete_session(session_id), to: Persistence

  @spec mint_resume_epoch(String.t(), map() | nil, term()) :: {:error, :mint_failed}
  def mint_resume_epoch(_session_id, _expected, _transplant), do: {:error, :mint_failed}
end

defmodule JidoClaw.Forge.HarnessResumeTest do
  @moduledoc """
  Harness ↔ resume-fence integration (docs/system/forge-session-resume.md):
  claim-time mint, the checked initial checkpoint before `:ready`, iteration
  opts threading, the fenced post-iteration anchor mirror, the recovery
  transplant sequence, terminal-reuse blank re-mint, materialize-then-persist,
  and the checked apply_input guidance lifecycle.

  `async: false` + TenantCase shared sandbox mode: the Harness GenServer and
  its iteration tasks must see the test's DB rows.
  """
  use JidoClaw.TenantCase, async: false

  import Ecto.Query

  @moduletag :capture_log

  alias JidoClaw.Forge
  alias JidoClaw.Forge.ChildTracker
  alias JidoClaw.Forge.HarnessResumeTest.{ArmedRunner, FailFirstCheckedSave, RefuseMint}
  alias JidoClaw.Forge.Persistence
  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Forge.Resources.Checkpoint
  alias JidoClaw.Forge.ResumeState
  alias JidoClaw.Forge.Runner
  alias JidoClaw.Forge.Runners.ResumePolicy
  alias JidoClaw.ForgeView
  alias JidoClaw.Orchestration.RunFailure
  alias JidoClaw.Repo
  alias JidoClaw.Test.StubSandbox

  @timeout 10_000

  setup do
    tenant_id = seed_tenant("harness-resume")
    {:ok, workspace} = seed_workspace(tenant_id)

    on_exit(fn -> Application.delete_env(:jido_claw, :harness_resume_iteration) end)

    %{tenant_id: tenant_id, workspace: workspace}
  end

  defp armed_spec(scope, config_overrides \\ %{}) do
    %{
      runner: ArmedRunner,
      sandbox: StubSandbox,
      runner_config: Map.merge(%{resume: :armed}, config_overrides),
      tenant_id: scope.tenant_id,
      workspace_uuid: scope.workspace.id
    }
  end

  defp start_ready!(sid, spec) do
    ForgePubSub.subscribe(sid)
    {:ok, handle} = Forge.start_session(sid, spec)
    assert_receive {:ready, ^sid}, @timeout
    on_exit(fn -> _ = Forge.stop_session(sid) end)
    handle
  end

  defp unique_sid(label), do: "#{label}_#{:erlang.unique_integer([:positive])}"

  defp metadata_of(sid), do: Persistence.find_session(sid).metadata

  defp set_iteration(fun), do: Application.put_env(:jido_claw, :harness_resume_iteration, fun)

  defp assert_child_gone(sid) do
    cleared? =
      Enum.reduce_while(1..100, false, fn _i, _acc ->
        case Forge.get_handle(sid) do
          {:error, :not_found} -> {:halt, true}
          _ -> Process.sleep(10) && {:cont, false}
        end
      end)

    assert cleared?, "expected the Forge child for #{sid} to be torn down"
  end

  # A vendor-faithful "anchor then done" turn: client-mint on the first call,
  # stamped with the threaded incarnation epoch, threaded back via
  # metadata.state — what the fenced mirror + checked save consume.
  defp anchor_and_done_fun(anchor_id, test_pid) do
    fn state, opts ->
      send(test_pid, {:iteration_opts, opts})

      rs =
        case state.resume do
          %ResumeState{status: :unanchored} = rs ->
            {:ok, anchored} = ResumeState.mint_client(rs, anchor_id, "/work")
            anchored

          rs ->
            rs
        end

      epoch = Keyword.get(opts, :incarnation_epoch, rs.epoch)
      stamped = ResumeState.stamp(rs, epoch, rs.revision + 1)
      {:ok, ResumePolicy.attach_runner_state(Runner.done("ok"), state, stamped)}
    end
  end

  describe "claim-time mint + checked initial checkpoint" do
    test "a fresh claimed session mints epoch 1 and points a this-epoch checkpoint before :ready",
         scope do
      sid = unique_sid("resume_fresh")
      start_ready!(sid, armed_spec(scope))

      pair = Persistence.stored_recovery_pair(sid)
      assert pair.epoch == 1
      assert is_binary(pair.token)

      # Blank transplant: no anchor state carried into a fresh incarnation.
      assert metadata_of(sid)["resume"] == %{}
      assert metadata_of(sid)["forge_recovery"]["recovery_degraded"] == false

      # The initial checkpoint landed BEFORE :ready and its encoded copy is
      # stamped with THIS incarnation's epoch (the recoverable?/1 epoch rule).
      checkpoint = Persistence.current_checkpoint(sid)
      assert checkpoint
      assert get_in(checkpoint.runner_state_snapshot, ["resume", "state", "epoch"]) == 1

      assert get_in(checkpoint.runner_state_snapshot, ["resume", "state", "status"]) ==
               "unanchored"
    end

    test "a resume-off runner still mints the harness-level fence and points its checkpoint",
         scope do
      sid = unique_sid("resume_off_fence")
      spec = %{armed_spec(scope) | runner_config: %{}}
      start_ready!(sid, spec)

      assert %{epoch: 1} = Persistence.stored_recovery_pair(sid)

      checkpoint = Persistence.current_checkpoint(sid)
      assert checkpoint
      refute Map.has_key?(checkpoint.runner_state_snapshot, "resume")
    end

    test "initial checkpoint failure marks recovery degraded, the session runs, and the next checked save self-heals",
         scope do
      :ets.new(:harness_resume_fail_first, [:named_table, :public])
      :ets.insert(:harness_resume_fail_first, {:saves, 0})
      Application.put_env(:jido_claw, :forge_persistence, FailFirstCheckedSave)
      on_exit(fn -> Application.delete_env(:jido_claw, :forge_persistence) end)

      sid = unique_sid("resume_degraded")
      start_ready!(sid, armed_spec(scope))

      # Degraded: flag set, loud channel emitted, NO pointer — and the
      # session is still alive and ready.
      assert metadata_of(sid)["forge_recovery"]["recovery_degraded"] == true
      assert Persistence.current_checkpoint(sid) == nil
      assert_receive {:recovery_degraded, %{session_id: ^sid}}, @timeout
      assert {:ok, %{state: :ready}} = Forge.status(sid)

      # The next checked save (the post-iteration one) self-heals: pointer
      # set + degraded cleared in the same transaction.
      set_iteration(anchor_and_done_fun(Ecto.UUID.generate(), self()))
      assert {:ok, %{status: :done}} = Forge.run_iteration(sid, timeout: 5_000)

      assert metadata_of(sid)["forge_recovery"]["recovery_degraded"] == false
      assert Persistence.current_checkpoint(sid)
    end

    test "a failed mint stops the session start loudly — never an un-fenced run", scope do
      Application.put_env(:jido_claw, :forge_persistence, RefuseMint)
      on_exit(fn -> Application.delete_env(:jido_claw, :forge_persistence) end)

      sid = unique_sid("resume_mint_fail")

      assert {:error, {:mint_failed, :mint_failed}} =
               Forge.start_session(sid, armed_spec(scope))
    end
  end

  describe "iteration threading + fenced mirror" do
    test "run_iteration threads forge_session_id, the incarnation token, and the epoch", scope do
      sid = unique_sid("resume_opts")
      start_ready!(sid, armed_spec(scope))
      pair = Persistence.stored_recovery_pair(sid)

      set_iteration(anchor_and_done_fun(Ecto.UUID.generate(), self()))
      assert {:ok, _} = Forge.run_iteration(sid, timeout: 5_000)

      assert_receive {:iteration_opts, opts}, @timeout
      assert Keyword.get(opts, :forge_session_id) == sid
      assert Keyword.get(opts, :incarnation_token) == pair.token
      assert Keyword.get(opts, :incarnation_epoch) == pair.epoch
    end

    test "iteration_complete mirrors the anchor fenced into metadata and re-points the checkpoint",
         scope do
      sid = unique_sid("resume_mirror")
      start_ready!(sid, armed_spec(scope))
      anchor_id = Ecto.UUID.generate()

      initial_pointer = Persistence.current_checkpoint(sid).id

      set_iteration(anchor_and_done_fun(anchor_id, self()))
      assert {:ok, %{status: :done}} = Forge.run_iteration(sid, timeout: 5_000)

      md = metadata_of(sid)
      assert md["resume"]["state"]["session_id"] == anchor_id
      assert md["resume"]["state"]["status"] == "anchored"
      assert md["resume"]["state"]["epoch"] == 1
      # Runner stamped revision 1; the harness mirror owns the bump to 2.
      assert md["resume"]["state"]["revision"] == 2

      # The post-iteration checked save moved the pointer past the initial
      # checkpoint, and its snapshot carries the anchored copy.
      checkpoint = Persistence.current_checkpoint(sid)
      refute checkpoint.id == initial_pointer

      assert get_in(checkpoint.runner_state_snapshot, ["resume", "state", "session_id"]) ==
               anchor_id
    end

    test "iteration.completed events carry the whitelist-decoded source marker (EM3-3)",
         scope do
      sid = unique_sid("resume_source")
      start_ready!(sid, armed_spec(scope))
      set_iteration(anchor_and_done_fun(Ecto.UUID.generate(), self()))

      assert {:ok, _} = Forge.run_iteration(sid, timeout: 5_000)
      assert {:ok, _} = Forge.run_iteration(sid, timeout: 5_000, source: :replay)
      assert {:ok, _} = Forge.run_iteration(sid, timeout: 5_000, source: :"free form")

      sources =
        sid
        |> Persistence.get_events(event_types: ["iteration.completed"])
        |> Enum.sort_by(& &1.exec_session_sequence)
        |> Enum.map(& &1.data["source"])

      assert sources == ["live", "replay", "live"]
    end

    test "an :error result prefers the runner-classified failure_kind over re-classifying",
         scope do
      sid = unique_sid("resume_kind")
      start_ready!(sid, armed_spec(scope))

      set_iteration(fn state, _opts ->
        base = Runner.error("some vendor label", "output")

        result = %{
          base
          | metadata:
              Map.put(
                base.metadata,
                :error_details,
                RunFailure.error_details(:agent_session_poisoned, %{})
              )
        }

        {:ok, ResumePolicy.attach_runner_state(result, state, state.resume)}
      end)

      assert {:ok, %{status: :error}} = Forge.run_iteration(sid, timeout: 5_000)

      # Re-classifying "some vendor label" would give :agent_unknown — the
      # broadcast must carry the runner's evidence-closest kind instead.
      assert_receive {:error, %{kind: :agent_session_poisoned}}, @timeout
    end
  end

  describe "terminal reuse" do
    test "a fresh start of a completed session re-mints blank — the old anchor is never carried",
         scope do
      sid = unique_sid("resume_reuse")
      anchor_id = Ecto.UUID.generate()

      start_ready!(sid, armed_spec(scope))
      set_iteration(anchor_and_done_fun(anchor_id, self()))
      assert {:ok, _} = Forge.run_iteration(sid, timeout: 5_000)
      assert metadata_of(sid)["resume"]["state"]["session_id"] == anchor_id

      assert :ok = Forge.complete_session(sid)
      assert_child_gone(sid)

      # Same name, fresh :start — the row (and its metadata) survives the
      # upsert, so the mint must CAS from the stored pair into a blank.
      start_ready!(sid, armed_spec(scope))

      pair = Persistence.stored_recovery_pair(sid)
      assert pair.epoch == 2
      assert metadata_of(sid)["resume"] == %{}

      checkpoint = Persistence.current_checkpoint(sid)
      assert get_in(checkpoint.runner_state_snapshot, ["resume", "state", "epoch"]) == 2

      assert get_in(checkpoint.runner_state_snapshot, ["resume", "state", "status"]) ==
               "unanchored"
    end
  end

  describe "recovery transplant" do
    test "recovery transplants the newest copy under the new epoch and restores it into the runner",
         scope do
      sid = unique_sid("resume_transplant")
      first_anchor = Ecto.UUID.generate()
      test_pid = self()

      start_ready!(sid, armed_spec(scope))
      set_iteration(anchor_and_done_fun(first_anchor, self()))
      assert {:ok, _} = Forge.run_iteration(sid, timeout: 5_000)

      pair1 = Persistence.stored_recovery_pair(sid)
      old_pointer = Persistence.current_checkpoint(sid).id

      # Simulate a crash: stop (→ :cancelled, which auto-recovery refuses,
      # keeping this deterministic), then flip the row back to a recoverable
      # phase as a crashed live session would have left it.
      assert :ok = Forge.stop_session(sid)
      assert_child_gone(sid)
      Persistence.update_session_phase(sid, :ready)

      # A newer metadata mirror than the pointed checkpoint (revision 99 on a
      # DIFFERENT anchor): the select must prefer it over the checkpoint copy.
      newer_anchor = Ecto.UUID.generate()

      {:ok, rearmed} =
        ResumeState.mint_client(ResumeState.new(workdir: "/work"), newer_anchor, "/work")

      newer_copy = ResumeState.stamp(rearmed, pair1.epoch, 99)
      assert :ok = Persistence.anchor_session(sid, newer_copy, pair1.token)

      set_iteration(fn state, _opts ->
        send(test_pid, {:restored_resume, state.resume})
        rs = state.resume
        {:ok, ResumePolicy.attach_runner_state(Runner.done("ok"), state, rs)}
      end)

      # The recovery spec `Forge.wake/2` would hand the Manager, minus the
      # jsonb round-trip: an UNSTAMPED runner_config recovers string-keyed
      # (the RecoveredSpec passthrough lane) so a test runner cannot re-arm
      # through wake — arming is config-owned and only the stamped vendor
      # codecs decode to the atom-keyed form. The wake-level normalize lane
      # is pinned in wake_test/recovered_spec_test; this drives the
      # harness's mint → transplant → restore machinery directly.
      recovery_spec = Map.put(armed_spec(scope), :resume_checkpoint_id, old_pointer)

      assert {:ok, _} = Forge.start_session(sid, recovery_spec)
      assert_receive {:ready, ^sid}, @timeout
      on_exit(fn -> _ = Forge.stop_session(sid) end)

      # New incarnation: epoch bumped, transplant installed at revision 0
      # carrying the NEWER anchor (metadata won the select), pointer moved to
      # a NEW transplant checkpoint stamped with the new epoch.
      pair2 = Persistence.stored_recovery_pair(sid)
      assert pair2.epoch == pair1.epoch + 1
      refute pair2.token == pair1.token

      md = metadata_of(sid)
      assert md["resume"]["state"]["session_id"] == newer_anchor
      assert md["resume"]["state"]["epoch"] == pair2.epoch

      checkpoint = Persistence.current_checkpoint(sid)
      refute checkpoint.id == old_pointer

      assert get_in(checkpoint.runner_state_snapshot, ["resume", "state", "session_id"]) ==
               newer_anchor

      assert get_in(checkpoint.runner_state_snapshot, ["resume", "state", "epoch"]) == pair2.epoch

      # And the RUNNER restored the transplanted copy (the pointed snapshot
      # reached restore_state), not the stale pre-select checkpoint anchor.
      assert {:ok, _} = Forge.run_iteration(sid, timeout: 5_000)
      assert_receive {:restored_resume, %ResumeState{session_id: ^newer_anchor}}, @timeout
    end
  end

  describe "materialize-then-persist" do
    test "the claim row persists the stamped materialized static config", scope do
      sid = unique_sid("resume_materialize")
      ForgePubSub.subscribe(sid)

      # deferred_provision: the session reaches :ready without touching the
      # runner or any host claude config — claim-time materialization is
      # what's under test.
      spec = %{
        runner: :claude_code,
        sandbox: StubSandbox,
        deferred_provision: true,
        runner_config: %{prompt: "hello", mcp_config_path: "/tmp/attempt.json"},
        tenant_id: scope.tenant_id,
        workspace_uuid: scope.workspace.id
      }

      {:ok, _} = Forge.start_session(sid, spec)
      assert_receive {:ready, ^sid}, @timeout
      on_exit(fn -> _ = Forge.stop_session(sid) end)

      session = Persistence.find_session(sid)

      # The persisted config is the COMPLETE materialized posture, stamped —
      # and attempt-scoped values never reach the durable row.
      assert session.runner_config["config_codec"] == %{"runner" => "claude_code", "v" => 1}
      assert session.runner_config["access"] == "full"
      assert session.runner_config["config_sync"] == "full"
      assert session.runner_config["resume"] == "off"
      assert session.runner_config["prompt"] == "hello"
      refute Map.has_key?(session.runner_config, "mcp_config_path")

      # The nested spec copy (what RecoveredSpec.normalize/1 decodes at wake)
      # carries the same materialized map.
      assert session.spec["runner_config"]["config_codec"]["runner"] == "claude_code"
      refute Map.has_key?(session.spec["runner_config"], "mcp_config_path")
    end
  end

  describe "apply_input guidance lifecycle" do
    defp park_session!(scope, sid) do
      start_ready!(sid, armed_spec(scope))

      set_iteration(fn state, _opts ->
        {:ok,
         ResumePolicy.attach_runner_state(Runner.needs_input("which file?"), state, state.resume)}
      end)

      assert {:ok, %{status: :needs_input}} = Forge.run_iteration(sid, timeout: 5_000)
      assert {:ok, %{state: :needs_input}} = Forge.status(sid)
    end

    test "the answer parks :pending via the checked save — encrypted text in the checkpoint, marker in metadata",
         scope do
      sid = unique_sid("resume_park")
      park_session!(scope, sid)

      assert :ok = Forge.apply_input(sid, "fix the flaky test first")

      md = metadata_of(sid)
      assert md["resume"]["guidance"]["status"] == "pending"
      # Metadata NEVER carries guidance text.
      refute Map.has_key?(md["resume"]["guidance"], "text")

      checkpoint = Persistence.current_checkpoint(sid)
      encoded = get_in(checkpoint.runner_state_snapshot, ["resume", "guidance"])
      assert {:ok, copy} = ResumeState.decode_guidance(encoded)
      assert copy.status == :pending
      assert copy.text == "fix the flaky test first"
      # The raw answer never lands in the snapshot as plaintext.
      refute inspect(checkpoint.runner_state_snapshot) =~ "fix the flaky test first"
    end

    test "the next iteration flips :pending → :inflight CHECKED before the spawn, and :consumed after",
         scope do
      sid = unique_sid("resume_inflight")
      test_pid = self()
      park_session!(scope, sid)
      assert :ok = Forge.apply_input(sid, "answer text")

      set_iteration(fn state, _opts ->
        send(test_pid, {:spawn_guidance, state.resume.pending_guidance})
        {:ok, ResumePolicy.attach_runner_state(Runner.done("ok"), state, state.resume)}
      end)

      assert {:ok, %{status: :done}} = Forge.run_iteration(sid, timeout: 5_000)

      # The runner saw :inflight — the checked transition happened pre-spawn.
      assert_receive {:spawn_guidance, %{status: :inflight, text: "answer text"}}, @timeout

      # Post-completion the marker rides the checked save as :consumed (text
      # dropped) — a stale copy can never resend an answered question.
      assert metadata_of(sid)["resume"]["guidance"]["status"] == "consumed"
    end

    test "an over-bound answer is rejected, never truncated", scope do
      sid = unique_sid("resume_too_large")
      park_session!(scope, sid)

      huge = String.duplicate("a", 16_385)
      assert {:error, :guidance_too_large} = Forge.apply_input(sid, huge)
    end

    test "a rotated incarnation fences the pending park — the ack is honest", scope do
      sid = unique_sid("resume_park_fenced")
      park_session!(scope, sid)

      # Rotate the fence behind the live harness's back (a newer claimant).
      pair = Persistence.stored_recovery_pair(sid)
      {:ok, _newer} = Persistence.mint_resume_epoch(sid, pair, nil)

      assert {:error, :not_persisted} = Forge.apply_input(sid, "too late")
    end

    test "a rotated incarnation blocks the inflight transition — no spawn", scope do
      sid = unique_sid("resume_inflight_fenced")
      test_pid = self()
      park_session!(scope, sid)
      assert :ok = Forge.apply_input(sid, "answer text")

      pair = Persistence.stored_recovery_pair(sid)
      {:ok, _newer} = Persistence.mint_resume_epoch(sid, pair, nil)

      set_iteration(fn _state, _opts ->
        send(test_pid, :spawned_anyway)
        {:ok, Runner.done("ok")}
      end)

      assert {:error, {:guidance_not_persisted, :stale_resume_write}} =
               Forge.run_iteration(sid, timeout: 5_000)

      refute_receive :spawned_anyway, 200
    end
  end

  describe "guidance recovery (F6)" do
    defp crash_simulate!(sid) do
      pointer = Persistence.current_checkpoint(sid).id
      assert :ok = Forge.stop_session(sid)
      assert_child_gone(sid)
      Persistence.update_session_phase(sid, :ready)
      pointer
    end

    defp recover!(scope, sid, pointer) do
      recovery_spec = Map.put(armed_spec(scope), :resume_checkpoint_id, pointer)
      assert {:ok, _} = Forge.start_session(sid, recovery_spec)
      on_exit(fn -> _ = Forge.stop_session(sid) end)
    end

    defp forge_view_row(scope, sid) do
      {:ok, view} = ForgeView.list(%{tenant_id: scope.tenant_id})
      Enum.find(view.sessions, &(&1.session_id == sid))
    end

    test "a parked answer survives crash → recover: ciphertext retained, delivered inflight",
         scope do
      sid = unique_sid("resume_park_recover")
      test_pid = self()

      park_session!(scope, sid)
      assert :ok = Forge.apply_input(sid, "the parked answer")

      pointer = crash_simulate!(sid)
      recover!(scope, sid, pointer)

      # Pending WITH text restores → the ready tail, not a re-park. This is
      # the F6 tie-break end-to-end: both stores carry rev 1, and only the
      # checkpoint-wins merge keeps the text.
      assert_receive {:ready, ^sid}, @timeout

      # The transplant/initial checkpoint retains DECODABLE ciphertext.
      checkpoint = Persistence.current_checkpoint(sid)
      encoded = get_in(checkpoint.runner_state_snapshot, ["resume", "guidance"])

      assert {:ok, %{status: :pending, text: "the parked answer"}} =
               ResumeState.decode_guidance(encoded)

      set_iteration(fn state, _opts ->
        send(test_pid, {:spawn_guidance, state.resume.pending_guidance})
        {:ok, ResumePolicy.attach_runner_state(Runner.done("ok"), state, state.resume)}
      end)

      assert {:ok, %{status: :done}} = Forge.run_iteration(sid, timeout: 5_000)
      assert_receive {:spawn_guidance, %{status: :inflight, text: "the parked answer"}}, @timeout
    end

    test "a durably-inflight answer re-parks: broadcast, phase, durable marker, projection, re-answer",
         scope do
      sid = unique_sid("resume_repark")
      park_session!(scope, sid)
      assert :ok = Forge.apply_input(sid, "ambiguous answer")

      # An :error turn leaves the CHECKED inflight durable (consume skips
      # :error; recovery must re-park, never resend).
      set_iteration(fn state, _opts ->
        {:ok, ResumePolicy.attach_runner_state(Runner.error("boom", "out"), state, state.resume)}
      end)

      assert {:ok, %{status: :error}} = Forge.run_iteration(sid, timeout: 5_000)

      pointer = crash_simulate!(sid)
      recover!(scope, sid, pointer)

      prompt = ResumeState.repark_prompt()

      assert_receive {:needs_input, %{prompt: ^prompt, reason: :inflight_delivery_ambiguous}},
                     @timeout

      assert {:ok, %{state: :needs_input}} = Forge.status(sid)

      # The durable marker landed fenced via the initial checkpoint.
      md = metadata_of(sid)
      assert md["resume"]["guidance"]["repark_reason"] == "inflight_delivery_ambiguous"
      assert md["resume"]["guidance"]["status"] == "consumed"
      rev_at_repark = md["resume"]["guidance"]["guidance_rev"]

      # A FRESH ForgeView (post-broadcast) shows the actionable instructions
      # — a late-arriving operator does not need to have seen the PubSub.
      assert forge_view_row(scope, sid).needs_input ==
               %{reason: :inflight_delivery_ambiguous, prompt: prompt}

      # Re-answering re-parks :pending at a higher rev AND clears the marker.
      assert :ok = Forge.apply_input(sid, "the answer again")

      md2 = metadata_of(sid)
      assert md2["resume"]["guidance"]["status"] == "pending"
      refute Map.has_key?(md2["resume"]["guidance"], "repark_reason")
      assert md2["resume"]["guidance"]["guidance_rev"] > rev_at_repark

      row = forge_view_row(scope, sid)
      assert row.phase == :ready
      assert row.needs_input == nil
    end

    test "second-recovery authority: a re-parked session that crashes again re-parks again",
         scope do
      sid = unique_sid("resume_repark_twice")
      park_session!(scope, sid)
      assert :ok = Forge.apply_input(sid, "ambiguous answer")

      set_iteration(fn state, _opts ->
        {:ok, ResumePolicy.attach_runner_state(Runner.error("boom", "out"), state, state.resume)}
      end)

      assert {:ok, %{status: :error}} = Forge.run_iteration(sid, timeout: 5_000)

      pointer = crash_simulate!(sid)
      recover!(scope, sid, pointer)
      assert_receive {:needs_input, %{reason: :inflight_delivery_ambiguous}}, @timeout

      # Crash AGAIN before any answer: the persisted reason is AUTHORITATIVE
      # — the session must land back in :needs_input, never recover :ready
      # and silently drop the operator request.
      pointer2 = crash_simulate!(sid)
      recover!(scope, sid, pointer2)

      assert_receive {:needs_input, %{reason: :inflight_delivery_ambiguous}}, @timeout
      assert {:ok, %{state: :needs_input}} = Forge.status(sid)

      assert metadata_of(sid)["resume"]["guidance"]["repark_reason"] ==
               "inflight_delivery_ambiguous"

      assert forge_view_row(scope, sid).needs_input ==
               %{reason: :inflight_delivery_ambiguous, prompt: ResumeState.repark_prompt()}
    end

    test "tampered guidance evidence re-parks as :guidance_text_missing (mint-time graft)",
         scope do
      sid = unique_sid("resume_tampered")
      park_session!(scope, sid)
      assert :ok = Forge.apply_input(sid, "the parked answer")

      pointer = crash_simulate!(sid)

      # Tamper via direct row updates: corrupt the pointed checkpoint's
      # guidance envelope AND blank the metadata marker — without the
      # mint-time graft the evidence would be erased entirely.
      {:ok, checkpoint} = Checkpoint.get_by_id(pointer)

      corrupted =
        put_in(
          checkpoint.runner_state_snapshot,
          ["resume", "guidance", "text"],
          %{"v" => 1, "alg" => "vault", "data" => "!!!not-base64"}
        )

      {1, _} =
        Repo.update_all(
          from(c in "forge_checkpoints", where: c.id == type(^pointer, :binary_id)),
          set: [runner_state_snapshot: corrupted]
        )

      blanked = Map.update(metadata_of(sid), "resume", %{}, &Map.delete(&1, "guidance"))

      {1, _} =
        Repo.update_all(
          from(s in "forge_sessions", where: s.name == ^sid),
          set: [metadata: blanked]
        )

      recover!(scope, sid, pointer)

      assert_receive {:needs_input, %{reason: :guidance_text_missing}}, @timeout
      assert {:ok, %{state: :needs_input}} = Forge.status(sid)
      assert metadata_of(sid)["resume"]["guidance"]["repark_reason"] == "guidance_text_missing"
    end
  end

  describe "deferred kickoff checkpoint (F7)" do
    defp deferred_spec(scope) do
      %{
        runner: ArmedRunner,
        sandbox: StubSandbox,
        deferred_provision: true,
        runner_config: %{},
        tenant_id: scope.tenant_id,
        workspace_uuid: scope.workspace.id
      }
    end

    test "a deferred+claimed session points an initial checkpoint (empty snapshot) at :ready",
         scope do
      sid = unique_sid("deferred_checkpoint")
      ForgePubSub.subscribe(sid)

      {:ok, _} = Forge.start_session(sid, deferred_spec(scope))
      assert_receive {:ready, ^sid}, @timeout
      on_exit(fn -> _ = Forge.stop_session(sid) end)

      # The mint cleared the pointer; the deferred ready-path must
      # re-establish it like every sibling ready-path, with an honest
      # runner-less %{} snapshot.
      checkpoint = Persistence.current_checkpoint(sid)
      assert checkpoint
      assert checkpoint.runner_state_snapshot == %{}
      assert metadata_of(sid)["forge_recovery"]["recovery_degraded"] == false
    end

    test "a deferred initial-checkpoint failure marks recovery degraded — never a silent pointer gap",
         scope do
      :ets.new(:harness_resume_fail_first, [:named_table, :public])
      :ets.insert(:harness_resume_fail_first, {:saves, 0})
      Application.put_env(:jido_claw, :forge_persistence, FailFirstCheckedSave)
      on_exit(fn -> Application.delete_env(:jido_claw, :forge_persistence) end)

      sid = unique_sid("deferred_degraded")
      ForgePubSub.subscribe(sid)

      {:ok, _} = Forge.start_session(sid, deferred_spec(scope))
      assert_receive {:ready, ^sid}, @timeout
      on_exit(fn -> _ = Forge.stop_session(sid) end)

      assert metadata_of(sid)["forge_recovery"]["recovery_degraded"] == true
      assert Persistence.current_checkpoint(sid) == nil
      assert_receive {:recovery_degraded, %{session_id: ^sid}}, @timeout
    end
  end

  describe "closing-session refusal (F4)" do
    test "a tombstoned session refuses new iterations with :session_closing", scope do
      sid = unique_sid("resume_closing")
      start_ready!(sid, armed_spec(scope))
      test_pid = self()

      set_iteration(fn state, _opts ->
        send(test_pid, :iteration_ran)
        {:ok, ResumePolicy.attach_runner_state(Runner.done("ok"), state, state.resume)}
      end)

      # Tombstone the whole session in the tracker, as the final teardown
      # barrier does before removing run_forge_home.
      assert :ok = ChildTracker.graceful_teardown_session(sid, grace_ms: 100)

      assert {:error, :session_closing} = Forge.run_iteration(sid, timeout: 5_000)
      refute_receive :iteration_ran, 200
    end
  end

  describe "local posture (persistence disabled)" do
    test "no mint, epoch 0, no token — iterations run unfenced" do
      prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)
      on_exit(fn -> Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev) end)

      sid = unique_sid("resume_local")
      ForgePubSub.subscribe(sid)

      {:ok, _} =
        Forge.start_session(sid, %{
          runner: ArmedRunner,
          sandbox: StubSandbox,
          runner_config: %{resume: :armed}
        })

      assert_receive {:ready, ^sid}, @timeout
      on_exit(fn -> _ = Forge.stop_session(sid) end)

      test_pid = self()

      set_iteration(fn state, opts ->
        send(test_pid, {:local_opts, opts})
        {:ok, ResumePolicy.attach_runner_state(Runner.done("ok"), state, state.resume)}
      end)

      assert {:ok, %{status: :done}} = Forge.run_iteration(sid, timeout: 5_000)

      assert_receive {:local_opts, opts}, @timeout
      assert Keyword.get(opts, :forge_session_id) == sid
      assert Keyword.get(opts, :incarnation_epoch) == 0
      refute Keyword.has_key?(opts, :incarnation_token)
    end
  end
end
