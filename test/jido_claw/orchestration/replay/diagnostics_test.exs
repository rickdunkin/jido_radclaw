defmodule JidoClaw.Orchestration.Replay.DiagnosticsTest do
  @moduledoc """
  One test per axis of `Replay.diagnose/2`: the recorded-health `status`
  (`:complete`/`:waiting`/`:failed`/`:incomplete`) and the replay-safety axis
  (`blockers` + `preflight_clear?` + `input_status`), proven against real runs
  (skill/gate/failure) and forged rows (the `human_gates_test` corruption-sim
  precedent). Pins the never-decrypt discipline (presence-only `input_status`),
  the redaction boundary (no secret reaches the encoded MCP map), and the
  `to_mcp_map/1` bounding. The disk-edit test cross-checks diagnose's hashes
  against the exact pair `Replay.replay/2` refuses with — the anti-drift pin
  for the shared `DefinitionResolver`.
  """
  use JidoClaw.TenantCase, async: false

  import JidoClaw.Test.ReplayFixtures

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.Replay
  alias JidoClaw.Orchestration.Replay.Diagnostics
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep
  alias JidoClaw.Skills
  alias JidoClaw.Test.EchoStub
  alias JidoClaw.Test.ErrorStub
  alias JidoClaw.Test.SecretErrorStub

  @module_hash DefinitionFingerprint.for_module(GatedTestReactor)

  setup do
    tenant = seed_tenant("diagnostics")
    Application.put_env(:jido_claw, :echo_stub_target, self())

    Application.put_env(:jido_claw, :agent_templates_override, %{
      "researcher" => template(EchoStub),
      "docs_writer" => template(EchoStub)
    })

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :echo_stub_target)
    end)

    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "status axis (recorded health)" do
    test "a clean completed skill run is :complete and preflight-clear", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_stub_messages()
      assert original.status == :completed

      assert {:ok, diag} = Replay.diagnose(original.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.run_id == original.id
      assert diag.status == :complete
      assert diag.terminal? == true
      assert diag.definition.status == :match
      assert diag.input_status == :present_unverified
      assert diag.preflight_clear? == true
      assert diag.blockers == []
      assert %DateTime{} = diag.generated_at
    end

    test "a terminal run with a still-running step row is :incomplete with unresolved_steps",
         ctx do
      run = forge_replayable!(%{name: "forge-unresolved"}, ctx)

      {:ok, _step} =
        WorkflowStep.record_started(%{name: "stuck", workflow_run_id: run.id, sequence: 0},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      assert {:ok, diag} = Replay.diagnose(run.id, tenant: ctx.tenant, actor: ctx.actor)

      refute diag.unresolved_steps == []
      assert diag.status == :incomplete
    end

    test "a failed-step run has failed_steps and diagnoses :failed", ctx do
      override_templates(ErrorStub)
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_stub_messages()
      assert original.status == :failed

      assert {:ok, diag} = Replay.diagnose(original.id, tenant: ctx.tenant, actor: ctx.actor)

      refute diag.failed_steps == []
      assert diag.status == :failed
    end

    test "a gate-parked (non-terminal) run is :waiting with pending gates", ctx do
      TestIrreversibleWrite.reset()
      uniq = System.unique_integer([:positive])
      inputs = %{workspace_name: "diag-gate-#{uniq}", workspace_path: "/tmp/diag-gate-#{uniq}"}

      assert {:ok, {:paused, _case_id}, parked} =
               ReactorRunner.run(GatedTestReactor, inputs, tenant: ctx.tenant, actor: ctx.actor)

      assert parked.status == :awaiting_approval

      assert {:ok, diag} = Replay.diagnose(parked.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.status == :waiting
      assert diag.terminal? == false
      refute diag.pending_gates == []
      assert {:not_replayable, :run_not_terminal} in diag.blockers
      refute diag.preflight_clear?
    end
  end

  describe "definition axis (shares DefinitionResolver with the replay gate)" do
    test "a disk-edited skill diagnoses :changed with the same hashes replay refuses with", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_stub_messages()
      stored = original.definition_hash

      write_fixture!(dir, String.replace(fixture_yaml(), "do alpha", "do alpha CHANGED"))
      {:ok, edited} = Skills.load_skill(fixture_name(), dir)
      current = DefinitionFingerprint.for_skill(edited)
      refute current == stored

      assert {:ok, diag} = Replay.diagnose(original.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.definition.status == :changed
      assert diag.definition.stored_hash == stored
      assert diag.definition.current_hash == current
      assert {:definition_changed, stored, current} in diag.blockers
      refute diag.preflight_clear?

      # Anti-drift: replay refuses with the EXACT same hashes diagnose reports.
      assert {:error, {:definition_changed, ^stored, ^current}} =
               Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test "a valid-config run with no stored hash diagnoses :no_hash but :complete health", ctx do
      run =
        forge_terminal_run!(
          %{name: "forge-nohash", config: module_config(), replay_inputs: encode_inputs()},
          ctx
        )

      assert {:ok, diag} = Replay.diagnose(run.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.definition.status == :no_hash
      assert diag.definition.kind == "module"
      assert {:not_replayable, :no_hash} in diag.blockers
      refute diag.preflight_clear?
      # A valid kind is required, or precedence reports :no_definition_kind
      # first; nothing failed/pending/unresolved → recorded health is :complete.
      assert diag.status == :complete
    end

    test ":no_definition_kind config diagnoses :unavailable (kind checked before hash)", ctx do
      # A non-nil hash proves the precedence: replay refuses :no_definition_kind
      # BEFORE the hash gate, so diagnose reports :unavailable, not :no_hash.
      run =
        forge_terminal_run!(
          %{name: "forge-no-kind", definition_hash: "irrelevant", replay_inputs: encode_inputs()},
          ctx
        )

      assert {:ok, diag} = Replay.diagnose(run.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.definition.status == :unavailable
      assert diag.definition.detail == :no_definition_kind
      assert diag.definition.kind == nil
      assert {:not_replayable, :no_definition_kind} in diag.blockers
    end

    test "a disallowed-module config diagnoses :unavailable with the {:disallowed_module, _} detail",
         ctx do
      run =
        forge_terminal_run!(
          %{
            name: "forge-disallowed",
            config: %{reactor: "Enum", definition_kind: "module"},
            definition_hash: "irrelevant",
            replay_inputs: encode_inputs()
          },
          ctx
        )

      assert {:ok, diag} = Replay.diagnose(run.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.definition.status == :unavailable
      assert diag.definition.detail == {:disallowed_module, "Enum"}
      assert {:not_replayable, {:disallowed_module, "Enum"}} in diag.blockers
    end

    test "a hash-less run whose definition is now unavailable diagnoses :unavailable, not :no_hash",
         ctx do
      # Hash-less (no definition_hash key ⇒ nil) AND unavailable (disallowed
      # module). Replay resolves BEFORE its no-hash gate, so the resolution
      # failure must win over :no_hash — otherwise diagnose would mask the real
      # refusal and preflight_clear? could disagree with replay/2.
      run =
        forge_terminal_run!(
          %{
            name: "forge-nohash-unavailable",
            config: %{reactor: "Enum", definition_kind: "module"},
            replay_inputs: encode_inputs()
          },
          ctx
        )

      {:ok, reloaded} = WorkflowRun.by_id(run.id, tenant: ctx.tenant, actor: ctx.actor)
      assert reloaded.definition_hash == nil

      assert {:ok, diag} = Replay.diagnose(run.id, tenant: ctx.tenant, actor: ctx.actor)
      assert diag.definition.status == :unavailable
      assert diag.definition.detail == {:disallowed_module, "Enum"}
      assert {:not_replayable, {:disallowed_module, "Enum"}} in diag.blockers
      # Pins "no :no_hash union" — the resolution failure short-circuits it.
      refute {:not_replayable, :no_hash} in diag.blockers
      refute diag.preflight_clear?

      # Anti-drift: replay refuses with the SAME blocker (resolves before the
      # no-hash gate), so diagnose must not report :no_hash here.
      assert {:error, {:not_replayable, {:disallowed_module, "Enum"}}} =
               Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test "a deleted skill YAML diagnoses :unavailable (:skill_unavailable), no crash", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_stub_messages()

      File.rm!(Path.join([dir, ".jido", "skills", "fixture.yaml"]))

      assert {:ok, diag} = Replay.diagnose(original.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.definition.status == :unavailable
      assert diag.definition.detail == :skill_unavailable
      assert {:not_replayable, :skill_unavailable} in diag.blockers
    end
  end

  describe "irreversible axis (shares Safety with the replay gate)" do
    test "an executed irreversible step sets irreversible_executed? and the blocker", ctx do
      dir = tmp_project_dir!()

      write_fixture!(dir, """
      name: replay_fixture
      description: irreversible fixture
      steps:
        - name: push
          template: researcher
          task: "push something"
          irreversible: true
      synthesis: done
      """)

      original = launch_fixture!(dir, ctx)
      drain_stub_messages()
      assert original.status == :completed

      assert {:ok, diag} = Replay.diagnose(original.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.irreversible_executed? == true
      assert :irreversible_steps_executed in diag.blockers
      refute diag.preflight_clear?
      # Irreversibility is a replay-safety fact, not a recorded-health failure.
      assert diag.status == :complete
    end
  end

  describe "input axis (encrypted-column presence only — never decrypt)" do
    test "a run with a hash but no inputs blob has input_status :missing", ctx do
      run =
        forge_terminal_run!(
          %{name: "forge-noinputs", config: module_config(), definition_hash: @module_hash},
          ctx
        )

      # The presence check's basis: the raw encrypted column is SQL NULL.
      {:ok, reloaded} = WorkflowRun.by_id(run.id, tenant: ctx.tenant, actor: ctx.actor)
      assert reloaded.encrypted_replay_inputs == nil

      assert {:ok, diag} = Replay.diagnose(run.id, tenant: ctx.tenant, actor: ctx.actor)

      assert diag.input_status == :missing
      assert {:not_replayable, :no_inputs} in diag.blockers
      refute diag.preflight_clear?
    end
  end

  describe "to_mcp_map/1 (security + bounding)" do
    test "a secret on a failed run never appears in the encoded MCP map", ctx do
      override_templates(SecretErrorStub)
      secret = SecretErrorStub.secret()

      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_stub_messages()
      assert original.status == :failed

      # The raw secret IS on the run row (defense-in-depth is read-side).
      {:ok, reloaded} = WorkflowRun.by_id(original.id, tenant: ctx.tenant, actor: ctx.actor)
      assert reloaded.error =~ secret

      assert {:ok, diag} = Replay.diagnose(original.id, tenant: ctx.tenant, actor: ctx.actor)
      encoded = Jason.encode!(Diagnostics.to_mcp_map(diag))
      refute encoded =~ secret
    end

    test "oversized failed_steps truncate to the cap with the omitted count set", ctx do
      run = forge_replayable!(%{name: "forge-many-failed"}, ctx)

      total = 13

      for i <- 1..total do
        {:ok, _} =
          WorkflowStep.record_failed(
            %{name: "f#{i}", workflow_run_id: run.id, sequence: i, error: "boom #{i}"},
            tenant: ctx.tenant,
            actor: ctx.actor
          )
      end

      assert {:ok, diag} = Replay.diagnose(run.id, tenant: ctx.tenant, actor: ctx.actor)
      # The struct holds every failed step (unbounded); the wire map caps.
      assert Enum.count_until(diag.failed_steps, total + 1) == total

      mcp = Diagnostics.to_mcp_map(diag)
      assert Enum.count_until(mcp["failed_steps"], total) == 10
      assert mcp["failed_steps_omitted"] == total - 10
      # Bounding precedes encode: the wire map is string-keyed and JSON-safe.
      assert {:ok, _json} = Jason.encode(mcp)
    end

    test "byte-caps oversized string leaves in list-item fields and warnings" do
      # Count-capping the lists does NOT bound an oversized string INSIDE a kept
      # item; the post-encode string-leaf cap does. Build the struct directly
      # (the cleanest seam — no read failure needed) with >512-byte strings in a
      # warning, a pending-gate step_name, and a failed-step name/step_type.
      long = String.duplicate("x", 5_000)

      diag = %Diagnostics{
        run_id: Ash.UUID.generate(),
        warnings: [long],
        pending_gates: [
          %{id: Ash.UUID.generate(), step_name: long, kind: :approval, status: :pending}
        ],
        failed_steps: [%{name: long, step_type: long, sequence: 0, status: :failed}],
        generated_at: DateTime.utc_now()
      }

      mcp = Diagnostics.to_mcp_map(diag)

      assert byte_size(hd(mcp["warnings"])) <= 512
      assert byte_size(hd(mcp["pending_gates"])["step_name"]) <= 512
      assert byte_size(hd(mcp["failed_steps"])["name"]) <= 512
      assert byte_size(hd(mcp["failed_steps"])["step_type"]) <= 512
      assert {:ok, _json} = Jason.encode(mcp)
    end
  end

  describe "error contract" do
    test "missing tenant/actor opts return :missing_required_opt", ctx do
      assert {:error, :missing_required_opt} = Replay.diagnose(Ash.UUID.generate(), [])

      assert {:error, :missing_required_opt} =
               Replay.diagnose(Ash.UUID.generate(), tenant: ctx.tenant)
    end

    test "an unknown id returns :not_found", ctx do
      assert {:error, :not_found} =
               Replay.diagnose(Ash.UUID.generate(), tenant: ctx.tenant, actor: ctx.actor)
    end

    test "a cross-tenant id returns :not_found (tenant isolation)", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_stub_messages()

      tenant_b = seed_tenant("diagnostics-b")

      assert {:error, :not_found} =
               Replay.diagnose(original.id, tenant: tenant_b, actor: actor_for(tenant_b))
    end
  end

  # -- Helpers --

  defp template(module),
    do: %{module: module, description: "stub", model: :fast, max_iterations: 1}

  defp override_templates(module) do
    Application.put_env(:jido_claw, :agent_templates_override, %{
      "researcher" => template(module),
      "docs_writer" => template(module)
    })
  end

  defp encode_inputs, do: :erlang.term_to_binary({1, %{}, %{}})

  # A forged terminal run that clears the definition + input axes (valid module
  # hash + present inputs blob), so a test can isolate the axis it exercises.
  defp forge_replayable!(attrs, ctx) do
    attrs
    |> Map.merge(%{
      config: module_config(),
      definition_hash: @module_hash,
      replay_inputs: encode_inputs()
    })
    |> forge_terminal_run!(ctx)
  end

  defp drain_stub_messages do
    receive do
      {:echo_stub, _tag, _payload} -> drain_stub_messages()
      {:stub_invoked, _which} -> drain_stub_messages()
    after
      0 -> :ok
    end
  end
end
