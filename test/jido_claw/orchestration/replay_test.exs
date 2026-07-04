defmodule JidoClaw.Orchestration.ReplayTest do
  @moduledoc """
  The Phase 4 "done" matrix for `Replay.replay/2`: a completed skill run
  replays into a fresh run with provenance + a full re-wired timeline; the
  definition gate compares against the CURRENT ON-DISK YAML (the disk-edit
  tests would pass against the boot cache and are the reason `Skills.load_skill/2`
  exists); the irreversible gate scans the original's durable `step_*`
  payloads; refusals cover the whole taxonomy via real runs and forged rows
  (corruption-sim precedent from `human_gates_test.exs`).

  Full replay *launch* is proven via the skill path only — a module reactor
  like `ProjectRegistration` performs unique writes that a verbatim-input
  second run would violate; module-side provenance is covered in
  `reactor_runner_test.exs`.
  """
  use JidoClaw.TenantCase, async: false

  import JidoClaw.Test.ReplayFixtures,
    except: [launch_fixture!: 2, launch_fixture!: 3, launch_fixture!: 4]

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.Replay
  alias JidoClaw.Orchestration.Replay.Diagnostics
  alias JidoClaw.Orchestration.Replay.Safety
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Skills
  alias JidoClaw.Test.EchoStub
  alias JidoClaw.Test.FailStub
  alias JidoClaw.Test.ReplayFixtures
  alias JidoClaw.Test.SecretErrorStub
  alias JidoClaw.Tools.ReplayWorkflow
  alias JidoClaw.Web.WorkflowsLive
  alias Phoenix.HTML.Safe

  setup do
    tenant = seed_tenant("replay")
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

  describe "happy path (compiled skill)" do
    test "replays a completed run: provenance, equal hashes, full re-wired timeline", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()

      assert {:ok, new_run} = Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)

      refute new_run.id == original.id
      assert new_run.retry_of_id == original.id
      assert new_run.status == :completed
      assert new_run.definition_hash == original.definition_hash
      assert new_run.config["definition_kind"] == "skill"

      # The full timeline proves the middleware was re-wired on the replay run.
      kinds = kinds(new_run, ctx)
      assert [:run_started | _rest] = kinds
      assert [:run_completed | _earlier] = Enum.reverse(kinds)
      assert :step_started in kinds
      assert :step_completed in kinds

      # Durable provenance on the replay's genesis event.
      started = event(new_run, :run_started, ctx)
      assert started.payload["definition_hash"] == original.definition_hash
    end
  end

  describe "definition gate (disk edits — the cache-bypass behavior)" do
    test "a semantic YAML edit refuses; force: true proceeds stamping the NEW hash", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()
      stored = original.definition_hash

      # Edit the YAML ON DISK (a task change is semantic). An in-memory struct
      # mutation would not catch a cache-serving lookup — this must touch disk.
      write_fixture!(dir, String.replace(fixture_yaml(), "do alpha", "do alpha CHANGED"))
      {:ok, edited} = Skills.load_skill(fixture_name(), dir)
      new_hash = DefinitionFingerprint.for_skill(edited)
      refute new_hash == stored

      assert {:error, {:definition_changed, ^stored, ^new_hash}} =
               Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)

      assert {:ok, forced} =
               Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor, force: true)

      assert forced.status == :completed
      # The forced replay ran (and stamped) the NEW disk definition.
      assert forced.definition_hash == new_hash
      assert forced.retry_of_id == original.id
    end

    test "a docs-only edit (description + comment) does not trip the gate", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()

      docs_only =
        fixture_yaml()
        |> String.replace("description: replay fixture skill", "description: reworded docs")
        |> Kernel.<>("# a trailing comment\n")

      write_fixture!(dir, docs_only)

      assert {:ok, replayed} = Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)
      assert replayed.status == :completed
      assert replayed.definition_hash == original.definition_hash
    end

    test "a deadline-only edit passes un-forced; the replay carries the NEW deadline (T2-1)",
         ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()
      refute Map.has_key?(original.config, "deadline")

      # Add ONLY a top-level deadline — observability semantics, excluded from
      # the fingerprint, so the gate must pass without force:.
      write_fixture!(dir, fixture_yaml() <> "deadline:\n  within: 1800\n  due_soon: 300\n")

      assert {:ok, replayed} = Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)
      assert replayed.status == :completed
      assert replayed.definition_hash == original.definition_hash

      # Skill replays use the FRESHLY re-resolved skill.deadline, not the
      # original config's (which had none).
      assert replayed.config["deadline"] == %{"within" => 1800, "due_soon" => 300}
    end
  end

  describe "replay scope" do
    # Fake session/user UUIDs make the best-effort transcript writes log FK
    # noise; they never propagate (SubagentTranscript contract).
    @tag :capture_log
    test "preserves durable scope, replaces cron scratch workspace, drops stale actor", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)

      workspace_uuid = Ash.UUID.generate()
      session_uuid = Ash.UUID.generate()
      user_id = Ash.UUID.generate()

      original =
        launch_fixture!(dir, ctx, %{
          workspace_id: "cron:job-1:42",
          workspace_uuid: workspace_uuid,
          session_uuid: session_uuid,
          user_id: user_id,
          actor: ctx.actor
        })

      drain_echo_messages()

      replay_actor = %{user_id: "replayer-#{ctx.tenant}", tenant_id: ctx.tenant}

      assert {:ok, new_run} = Replay.replay(original.id, tenant: ctx.tenant, actor: replay_actor)
      assert new_run.status == :completed

      contexts = collect_tool_contexts(2)

      for tool_context <- contexts do
        # Durable identity scope is preserved verbatim.
        assert tool_context.workspace_uuid == workspace_uuid
        assert tool_context.session_uuid == session_uuid
        assert tool_context.user_id == user_id

        # The synthetic per-tick cron scratch key was replaced with a fresh
        # replay-scoped one anchored on the original run's short id.
        assert String.starts_with?(
                 tool_context.workspace_id,
                 "replay:#{String.slice(original.id, 0, 8)}:"
               )

        # The live caller's actor is authoritative — the embedded original
        # actor was dropped from the decoded context.
        assert tool_context.actor == replay_actor
      end

      # Both steps share the single fresh replay workspace.
      workspace_count =
        contexts
        |> Enum.map(& &1.workspace_id)
        |> Enum.uniq()
        |> length()

      assert workspace_count == 1
    end
  end

  describe "irreversible gate" do
    test "an executed irreversible step refuses; allow_irreversible: true proceeds", ctx do
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
      drain_echo_messages()

      assert {:error, :irreversible_steps_executed} =
               Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)

      assert {:ok, replayed} =
               Replay.replay(original.id,
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 allow_irreversible: true
               )

      assert replayed.status == :completed
      assert replayed.retry_of_id == original.id
    end

    # Regression: the compiler used to drop role irreversible flags, so the
    # loop step's payloads never carried them and iterative skills sailed
    # straight past this gate.
    test "an iterative loop with an irreversible role is stamped and gated", ctx do
      dir = tmp_project_dir!()

      # The evaluator must emit a REAL failing verdict (FailStub's
      # `VERDICT: FAIL`) so the loop caps at max_iterations: 1 and the run
      # still completes — EchoStub's tokenless "echoed" is an *infra* input
      # under the camus C1-3 normalizer contract and would fail the run.
      Application.put_env(:jido_claw, :agent_templates_override, %{
        "researcher" => template(EchoStub),
        "docs_writer" => template(FailStub)
      })

      write_fixture!(dir, """
      name: replay_fixture
      description: irreversible iterative fixture
      mode: iterative
      max_iterations: 1
      steps:
        - name: implement
          role: generator
          template: researcher
          task: "generate the thing"
          irreversible: true
        - name: verify
          role: evaluator
          template: docs_writer
          task: "check the thing"
      synthesis: done
      """)

      original = launch_fixture!(dir, ctx)
      drain_echo_messages()

      # The middleware stamped the OR'd role flag into the loop's payloads.
      assert event(original, :step_started, ctx).payload["irreversible"] == true

      assert {:error, :irreversible_steps_executed} =
               Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)

      assert {:ok, replayed} =
               Replay.replay(original.id,
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 allow_irreversible: true
               )

      assert replayed.status == :completed
      assert replayed.retry_of_id == original.id
    end
  end

  describe "both gates (definition + irreversible)" do
    test "each single override is refused by the other gate; both together proceed", ctx do
      dir = tmp_project_dir!()

      irreversible_yaml = """
      name: replay_fixture
      description: irreversible fixture
      steps:
        - name: push
          template: researcher
          task: "push something"
          irreversible: true
      synthesis: done
      """

      write_fixture!(dir, irreversible_yaml)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()
      stored = original.definition_hash

      # A semantic disk edit arms the definition gate on top of the
      # already-armed irreversible gate.
      write_fixture!(dir, String.replace(irreversible_yaml, "push something", "push EDITED"))
      {:ok, edited} = Skills.load_skill(fixture_name(), dir)
      new_hash = DefinitionFingerprint.for_skill(edited)

      # force alone passes the definition gate, then trips the irreversible one.
      assert {:error, :irreversible_steps_executed} =
               Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor, force: true)

      # allow_irreversible alone trips the definition gate (checked first).
      assert {:error, {:definition_changed, ^stored, ^new_hash}} =
               Replay.replay(original.id,
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 allow_irreversible: true
               )

      assert {:ok, replayed} =
               Replay.replay(original.id,
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 force: true,
                 allow_irreversible: true
               )

      assert replayed.status == :completed
      # The forced replay ran (and stamped) the NEW disk definition.
      assert replayed.definition_hash == new_hash
      assert replayed.retry_of_id == original.id
    end
  end

  describe "refusals" do
    test "a non-terminal (gate-parked) run is not replayable", ctx do
      TestIrreversibleWrite.reset()
      uniq = System.unique_integer([:positive])

      inputs = %{
        workspace_name: "replay-gate-#{uniq}",
        workspace_path: "/tmp/replay-gate-#{uniq}"
      }

      assert {:ok, {:paused, _case_id}, parked} =
               ReactorRunner.run(GatedTestReactor, inputs, tenant: ctx.tenant, actor: ctx.actor)

      assert parked.status == :awaiting_approval

      assert {:error, {:not_replayable, :run_not_terminal}} =
               Replay.replay(parked.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test "a module replay preserves the ORIGINAL run's deadline policy (T2-1 asymmetry)", ctx do
      # A module has no YAML to re-resolve a deadline from — the original
      # config's policy must survive the replay (string-keyed jsonb in,
      # re-normalized by the runner, string-keyed jsonb out).
      run =
        forge_terminal_run!(
          %{
            name: "forge-module-deadline",
            config: Map.put(module_config(), :deadline, %{within: 600}),
            definition_hash:
              DefinitionFingerprint.for_module(JidoClaw.Orchestration.Reactors.GatedTestReactor),
            replay_inputs:
              :erlang.term_to_binary(
                {1,
                 %{
                   workspace_name: "replay-mod-dl-#{System.unique_integer([:positive])}",
                   workspace_path: "/tmp/replay-mod-dl"
                 }, %{}}
              )
          },
          ctx
        )

      assert run.config["deadline"] == %{"within" => 600}

      # The gated module pauses at its gate — still {:ok, run}: a replay run
      # came into existence, which is all this pin needs.
      assert {:ok, replayed} = Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
      assert replayed.status == :awaiting_approval
      assert replayed.config["deadline"] == %{"within" => 600}
      assert replayed.retry_of_id == run.id
    end

    test ":no_hash — a terminal run without a stored fingerprint", ctx do
      run =
        forge_terminal_run!(
          %{
            name: "forge-nohash",
            config: module_config(),
            replay_inputs: :erlang.term_to_binary({1, %{}, %{}})
          },
          ctx
        )

      assert {:error, {:not_replayable, :no_hash}} =
               Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test ":no_inputs — a terminal run without the inputs blob", ctx do
      run =
        forge_terminal_run!(
          %{name: "forge-noinputs", config: module_config(), definition_hash: "irrelevant"},
          ctx
        )

      assert {:error, {:not_replayable, :no_inputs}} =
               Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test ":corrupt_inputs — an undecodable blob", ctx do
      run =
        forge_terminal_run!(
          %{
            name: "forge-corrupt",
            config: module_config(),
            definition_hash: "irrelevant",
            replay_inputs: "definitely not external term format"
          },
          ctx
        )

      assert {:error, {:not_replayable, :corrupt_inputs}} =
               Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test "{:disallowed_module, _} — a config claiming a module outside Reactors.*", ctx do
      run =
        forge_terminal_run!(
          %{
            name: "forge-disallowed",
            config: %{reactor: "Enum", definition_kind: "module"},
            definition_hash: "irrelevant",
            replay_inputs: :erlang.term_to_binary({1, %{}, %{}})
          },
          ctx
        )

      assert {:error, {:not_replayable, {:disallowed_module, "Enum"}}} =
               Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test ":no_definition_kind — a run created outside ReactorRunner", ctx do
      run = forge_terminal_run!(%{name: "forge-plain"}, ctx)

      assert {:error, {:not_replayable, :no_definition_kind}} =
               Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test ":not_found for an unknown id", ctx do
      assert {:error, :not_found} =
               Replay.replay(Ash.UUID.generate(), tenant: ctx.tenant, actor: ctx.actor)
    end

    test "cross-tenant ids are not found (tenant isolation)", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()

      tenant_b = seed_tenant("replay-b")

      assert {:error, :not_found} =
               Replay.replay(original.id, tenant: tenant_b, actor: actor_for(tenant_b))
    end

    test "missing tenant/actor opts refuse cleanly (never raises)", ctx do
      assert {:error, :missing_required_opt} = Replay.replay(Ash.UUID.generate(), [])

      assert {:error, :missing_required_opt} =
               Replay.replay(Ash.UUID.generate(), tenant: ctx.tenant)
    end
  end

  describe "irreversible read failure (V2-4)" do
    # A run that clears the definition + input gates so the pipeline reaches the
    # irreversible gate, where the injected reader fails (the run row still reads
    # fine — only the events read fails).
    defp forge_readfail_run!(name, ctx) do
      forge_terminal_run!(
        %{
          name: name,
          config: module_config(),
          definition_hash: DefinitionFingerprint.for_module(GatedTestReactor),
          replay_inputs: :erlang.term_to_binary({1, %{}, %{}})
        },
        ctx
      )
    end

    @tag :capture_log
    test "an events-read failure refuses with :irreversible_check_failed, not a raw bubble",
         ctx do
      put_failing_event_reader!()
      run = forge_readfail_run!("forge-readfail", ctx)

      assert {:error, {:not_replayable, :irreversible_check_failed}} =
               Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    @tag :capture_log
    test "the irreversible gate reads ONLY the step kinds Safety inspects (O-M1 bounded-read contract)",
         ctx do
      # Behavior tests can't catch a silently-dropped `query:` (the filter only
      # excludes events the check already ignores) — capture the reader's opts
      # and pin the contract to `Safety.irreversible_kinds/0` directly.
      put_capturing_event_reader!(self())
      run = forge_readfail_run!("forge-bounded-read", ctx)

      assert {:error, {:not_replayable, :irreversible_check_failed}} =
               Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)

      assert_receive {:reader_opts, _run_id, opts}
      assert opts[:query][:filter] == [kind: [in: Safety.irreversible_kinds()]]
    end

    @tag :capture_log
    test "the dashboard stashes preflight diagnostics on the read-failure refusal", ctx do
      put_failing_event_reader!()
      run = forge_readfail_run!("forge-readfail-dash", ctx)
      socket = build_socket(ctx.actor)

      assert {:noreply, blocked} =
               WorkflowsLive.handle_event("replay", %{"id" => run.id}, socket)

      assert Phoenix.Flash.get(blocked.assigns.flash, :error) =~ "Couldn't verify replay safety"

      assert %Diagnostics{} = diag = blocked.assigns.replay_diagnostics[run.id]
      assert {:not_replayable, :irreversible_check_failed} in diag.blockers
      refute diag.preflight_clear?
    end
  end

  describe "replay-inputs size guard (L9)" do
    # The launch logs the dropped-blob warning.
    @tag :capture_log
    test "an over-cap inputs blob is omitted: run completes, column is SQL NULL, replay refuses",
         ctx do
      put_replay_inputs_cap!(64)

      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx, %{}, %{extra_context: String.duplicate("a", 10_000)})
      drain_echo_messages()

      assert original.status == :completed

      {:ok, reloaded} = WorkflowRun.by_id(original.id, tenant: ctx.tenant, actor: ctx.actor)
      # The raw encrypted column must be SQL NULL — the attrs key was OMITTED.
      # AshCloak encrypts any PRESENT argument, so `replay_inputs: nil` would
      # have persisted ciphertext-of-nil here and broken the presence check.
      assert reloaded.encrypted_replay_inputs == nil

      {:ok, loaded} = Ash.load(reloaded, :replay_inputs, tenant: ctx.tenant, actor: ctx.actor)
      assert loaded.replay_inputs == nil

      # The absent blob surfaces through the existing refusal vocabulary.
      assert {:error, {:not_replayable, :no_inputs}} =
               Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)
    end

    test "a non-positive cap env value falls back to the 1 MB default — replayability survives",
         ctx do
      # A raw -1 cap would make `byte_size(blob) > cap` true for EVERY blob,
      # silently stripping replayability from every run.
      put_replay_inputs_cap!(-1)

      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()

      {:ok, reloaded} = WorkflowRun.by_id(original.id, tenant: ctx.tenant, actor: ctx.actor)
      assert is_binary(reloaded.encrypted_replay_inputs)

      assert {:ok, replayed} = Replay.replay(original.id, tenant: ctx.tenant, actor: ctx.actor)
      assert replayed.status == :completed
      assert replayed.retry_of_id == original.id
    end
  end

  describe "MCP seam (ReplayWorkflow tool, T2-2 security pin)" do
    test "a replay-run error carrying a secret never reaches MCP output", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()

      # The replay executes with a stub whose error embeds a secret-shaped
      # string; the run row stores it RAW — the tool must scrub at read.
      Application.put_env(:jido_claw, :agent_templates_override, %{
        "researcher" => template(SecretErrorStub),
        "docs_writer" => template(SecretErrorStub)
      })

      secret = SecretErrorStub.secret()

      # The Tools.Action wrapper normalizes a `status: "failed"` result into
      # an error envelope; the summarized fields ride in details.context.
      assert {:error, %{code: :failed, details: %{context: context}} = envelope} =
               ReplayWorkflow.run(
                 %{run_id: original.id},
                 %{tool_context: %{tenant_id: ctx.tenant, actor: ctx.actor}}
               )

      assert context.status == "failed"
      # Operator scope, not overridable here: redacted then truncated to 200.
      assert String.length(context.error) <= 200
      refute inspect(envelope) =~ secret

      # The raw secret IS on the run row (defense-in-depth is read-side).
      {:ok, replayed} =
        WorkflowRun.by_id(context.new_run_id, tenant: ctx.tenant, actor: ctx.actor)

      assert replayed.error =~ secret
    end
  end

  describe "dashboard seam (WorkflowsLive)" do
    test "replay click launches + flashes; a blocked definition arms the force re-click", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()

      socket = build_socket(ctx.actor)

      assert {:noreply, ok_socket} =
               WorkflowsLive.handle_event("replay", %{"id" => original.id}, socket)

      assert Phoenix.Flash.get(ok_socket.assigns.flash, :info) =~ "Replay launched"
      # The refreshed list contains the replay run with provenance.
      assert Enum.any?(ok_socket.assigns.runs, &(&1.retry_of_id == original.id))

      # A disk edit blocks the next click and arms the per-run force button.
      write_fixture!(dir, String.replace(fixture_yaml(), "do alpha", "do alpha CHANGED"))

      assert {:noreply, blocked} =
               WorkflowsLive.handle_event("replay", %{"id" => original.id}, ok_socket)

      assert %{reason: :definition_changed} = blocked.assigns.replay_blocked[original.id]
      assert Phoenix.Flash.get(blocked.assigns.flash, :error) =~ "definition changed"

      # Diagnostics are stashed in the SEPARATE assign on the blocked click.
      assert %Diagnostics{definition: %{status: :changed}} =
               blocked.assigns.replay_diagnostics[original.id]

      # The force re-click (phx-value-force) launches and clears the block —
      # and the run's diagnostics entry along with it.
      assert {:noreply, forced} =
               WorkflowsLive.handle_event(
                 "replay",
                 %{"id" => original.id, "force" => "true"},
                 blocked
               )

      assert Phoenix.Flash.get(forced.assigns.flash, :info) =~ "Replay launched"
      refute Map.has_key?(forced.assigns.replay_blocked, original.id)
      refute Map.has_key?(forced.assigns.replay_diagnostics, original.id)
    end

    test "the preflight diagnostics detail renders only when stashed for a run", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      completed = launch_fixture!(dir, ctx)
      drain_echo_messages()

      {:ok, diag} = Replay.diagnose(completed.id, tenant: ctx.tenant, actor: ctx.actor)

      # Stashed → the full-width detail row renders.
      with_diag = render_workflows([completed], %{}, %{completed.id => diag})
      assert with_diag =~ ~s(id="replay-diagnostics-#{completed.id}")
      assert with_diag =~ "Replay preflight"

      # No entry → absent (the 30s refresh never computes diagnostics).
      without = render_workflows([completed])
      refute without =~ ~s(id="replay-diagnostics-#{completed.id}")
    end

    test "a run tripping BOTH gates resolves in three clicks (grants carry forward)", ctx do
      dir = tmp_project_dir!()

      irreversible_yaml = """
      name: replay_fixture
      description: irreversible fixture
      steps:
        - name: push
          template: researcher
          task: "push something"
          irreversible: true
      synthesis: done
      """

      write_fixture!(dir, irreversible_yaml)
      original = launch_fixture!(dir, ctx)
      drain_echo_messages()

      write_fixture!(dir, String.replace(irreversible_yaml, "push something", "push EDITED"))

      socket = build_socket(ctx.actor)

      # Click 1 — plain Replay: the definition gate refuses first, arming force.
      assert {:noreply, after_first} =
               WorkflowsLive.handle_event("replay", %{"id" => original.id}, socket)

      assert after_first.assigns.replay_blocked[original.id] ==
               %{reason: :definition_changed, force: true, allow_irreversible: false}

      # Click 2 — what the force button emits: the irreversible gate refuses,
      # and the already-granted force flag is carried onto the armed button.
      assert {:noreply, after_second} =
               WorkflowsLive.handle_event(
                 "replay",
                 %{"id" => original.id, "force" => "true"},
                 after_first
               )

      assert after_second.assigns.replay_blocked[original.id] ==
               %{reason: :irreversible, force: true, allow_irreversible: true}

      assert Phoenix.Flash.get(after_second.assigns.flash, :error) =~
               "keeping the definition override"

      # Click 3 — the armed button now emits BOTH flags: launch + clear.
      assert {:noreply, launched} =
               WorkflowsLive.handle_event(
                 "replay",
                 %{"id" => original.id, "force" => "true", "allow_irreversible" => "true"},
                 after_second
               )

      assert Phoenix.Flash.get(launched.assigns.flash, :info) =~ "Replay launched"
      refute Map.has_key?(launched.assigns.replay_blocked, original.id)
    end

    test "an armed override button emits carried flags; ungranted ones are omitted", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      completed = launch_fixture!(dir, ctx)
      drain_echo_messages()

      button = ~r/<button[^>]*id="replay-irreversible-#{completed.id}"[^>]*>/

      carried = %{completed.id => %{reason: :irreversible, force: true, allow_irreversible: true}}
      assert [armed] = Regex.run(button, render_workflows([completed], carried))
      assert armed =~ ~s(phx-value-allow_irreversible="true")
      assert armed =~ ~s(phx-value-force="true")

      bare = %{completed.id => %{reason: :irreversible, force: false, allow_irreversible: true}}
      assert [unarmed] = Regex.run(button, render_workflows([completed], bare))
      assert unarmed =~ ~s(phx-value-allow_irreversible="true")
      refute unarmed =~ "phx-value-force"
    end

    test "row toggle binding lives on the data cells; Replay renders only when terminal", ctx do
      dir = tmp_project_dir!()
      write_fixture!(dir)
      completed = launch_fixture!(dir, ctx)
      drain_echo_messages()

      {:ok, pending} =
        WorkflowRun.create(%{name: "still-pending"}, tenant: ctx.tenant, actor: ctx.actor)

      html = render_workflows([completed, pending])

      # The <tr> itself carries NO toggle binding (it moved to the data
      # cells), so a click in the Actions cell cannot double-fire a toggle.
      assert [row_tag] = Regex.run(~r/<tr[^>]*id="run-#{completed.id}"[^>]*>/, html)
      refute row_tag =~ "phx-click"
      assert html =~ ~s(phx-click="toggle_steps")

      # Replay renders for the terminal run only.
      assert html =~ ~s(id="replay-#{completed.id}")
      refute html =~ ~s(id="replay-#{pending.id}")
    end
  end

  # -- Helpers --

  defp template(module),
    do: %{module: module, description: "stub", model: :fast, max_iterations: 1}

  defp put_replay_inputs_cap!(value) do
    previous = Application.fetch_env(:jido_claw, :workflow_replay_inputs_max_bytes)
    Application.put_env(:jido_claw, :workflow_replay_inputs_max_bytes, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:jido_claw, :workflow_replay_inputs_max_bytes, v)
        :error -> Application.delete_env(:jido_claw, :workflow_replay_inputs_max_bytes)
      end
    end)
  end

  defp build_socket(actor) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_actor: actor,
        runs: [],
        runs_error: nil,
        expanded_run_id: nil,
        steps: [],
        steps_error: nil,
        replay_blocked: %{},
        replay_diagnostics: %{},
        reveal_runs: MapSet.new(),
        steps_view: :graph,
        step_graph: nil
      }
    }
  end

  defp render_workflows(runs, replay_blocked \\ %{}, replay_diagnostics \\ %{}) do
    %{
      __changed__: %{},
      flash: %{},
      runs: runs,
      runs_error: nil,
      expanded_run_id: nil,
      steps: [],
      steps_error: nil,
      replay_blocked: replay_blocked,
      replay_diagnostics: replay_diagnostics,
      reveal_runs: MapSet.new(),
      steps_view: :graph,
      step_graph: nil
    }
    |> WorkflowsLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # Delegate the run mechanics to the shared fixtures, keeping only this file's
  # completion assertion (the shared helper returns the run for ok OR error to
  # serve the diagnostics suite's failure-path tests, and does not assert).
  defp launch_fixture!(dir, ctx, overrides \\ %{}, inputs \\ %{extra_context: "initial"}) do
    run = ReplayFixtures.launch_fixture!(dir, ctx, overrides, inputs)
    assert run.status == :completed
    run
  end

  defp kinds(run, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor)
    Enum.map(events, & &1.kind)
  end

  defp event(run, kind, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor)
    Enum.find(events, &(&1.kind == kind))
  end

  defp drain_echo_messages do
    receive do
      {:echo_stub, _tag, _payload} -> drain_echo_messages()
    after
      0 -> :ok
    end
  end

  defp collect_tool_contexts(count) do
    for _ <- 1..count do
      receive do
        {:echo_stub, :tool_context, tool_context} -> tool_context
      after
        5_000 -> flunk("did not receive #{count} tool_context messages")
      end
    end
  end
end
