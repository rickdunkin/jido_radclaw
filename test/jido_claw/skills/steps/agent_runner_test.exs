defmodule JidoClaw.Skills.Steps.AgentRunnerTest do
  @moduledoc """
  Tests the spawn/run/capture core ported from the retired `StepAction`:

    * `resolve_scope/2` — now resolves from the **Reactor context**
      (`context[:tenant]` → tenant_id, `context[:actor]` → actor, plus the
      merged session/workspace/user/project_dir keys) with the legacy
      precedence/fallback semantics.
    * the async typed-output capture path (driven by `:step_agent_server`
      FakeAgentServers + the `ask/3`-exporting `EchoAskStub`).
    * `forward_context` policy enforcement and child-correlation `:user_id`
      propagation (these hit the DB, so they own a shared sandbox).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Forge
  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Reasoning.Compactor.RequestTransformer
  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Test.{EchoAskStub, EchoStub, StubSandbox}
  alias JidoClaw.Workflows.StepResult

  alias JidoClaw.Skills.Steps.AgentRunnerTest.{
    ArtifactsFakeAgentServer,
    ErrorFakeAgentServer,
    FailedFakeAgentServer,
    FreeFormFakeAgentServer,
    SummaryFakeAgentServer,
    ValidatedFakeAgentServer
  }

  describe "resolve_scope/2" do
    test "maps run-identity keys: context[:tenant] → tenant_id, context[:actor] → actor" do
      actor = %{kind: :system, tenant_id: "t"}
      scope = AgentRunner.resolve_scope(%{tenant: "t", actor: actor}, "tag1")

      assert scope.tenant_id == "t"
      assert scope.actor == actor
      assert scope.agent_id == "tag1"
      assert scope.subagent == true
    end

    test "falls back to context[:tenant_id] when :tenant is absent" do
      scope = AgentRunner.resolve_scope(%{tenant_id: "scoped"}, "tag2")
      assert scope.tenant_id == "scoped"
    end

    test "reads session/workspace/user from the merged scope keys" do
      ctx = %{
        tenant: "t",
        session_id: "sess",
        session_uuid: "00000000-0000-0000-0000-000000000111",
        workspace_id: "ws-runtime",
        workspace_uuid: "00000000-0000-0000-0000-000000000222",
        user_id: "00000000-0000-0000-0000-000000000099"
      }

      scope = AgentRunner.resolve_scope(ctx, "tag3")

      assert scope.session_id == "sess"
      assert scope.session_uuid == "00000000-0000-0000-0000-000000000111"
      assert scope.workspace_id == "ws-runtime"
      assert scope.workspace_uuid == "00000000-0000-0000-0000-000000000222"
      assert scope.user_id == "00000000-0000-0000-0000-000000000099"
    end

    test "workspace_id falls back to wf_<tag>, project_dir to cwd, UUIDs to nil" do
      scope = AgentRunner.resolve_scope(%{}, "tag4")

      assert scope.workspace_id == "wf_tag4"
      assert scope.project_dir == File.cwd!()
      assert scope.tenant_id == nil
      assert scope.session_uuid == nil
      assert scope.workspace_uuid == nil
      assert scope.user_id == nil
      assert scope.agent_id == "tag4"
    end

    test "agent_id is always the supplied tag, never inherited from context" do
      scope = AgentRunner.resolve_scope(%{agent_id: "ignored"}, "actual_tag")
      assert scope.agent_id == "actual_tag"
    end

    test "threads the AR-2 Phase 2b marker + TTL ceiling from the reactor context (B1/C5)" do
      expires = DateTime.utc_now()

      ctx = %{
        tenant: "t",
        sanitize_sensitive_context: true,
        request_correlation_expires_at: expires
      }

      scope = AgentRunner.resolve_scope(ctx, "tag-marked")
      assert scope.sanitize_sensitive_context == true
      assert scope.request_correlation_expires_at == expires
    end

    test "defaults the marker to false when the reactor context omits it" do
      scope = AgentRunner.resolve_scope(%{tenant: "t"}, "tag-plain")
      assert scope.sanitize_sensitive_context == false
      assert scope.request_correlation_expires_at == nil
    end

    test "carries forge_session_key from the reactor context (AR-8b-2 F2 D5)" do
      scope = AgentRunner.resolve_scope(%{forge_session_key: "sess-123"}, "tag-fk")
      assert scope.forge_session_key == "sess-123"
    end
  end

  describe "run/4 — async typed-output capture" do
    setup do
      Application.put_env(:jido_claw, :agent_templates_override, %{
        "echo_async" => %{
          module: EchoAskStub,
          description: "test-only async echo template",
          model: :fast,
          max_iterations: 1
        }
      })

      previous = Application.get_env(:jido_claw, :step_agent_server)

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)

        case previous do
          nil -> Application.delete_env(:jido_claw, :step_agent_server)
          mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
        end
      end)

      :ok
    end

    test "populates typed_output when meta.output.status is :validated" do
      Application.put_env(:jido_claw, :step_agent_server, ValidatedFakeAgentServer)

      assert {:ok, %StepResult{} = result} =
               AgentRunner.run("echo_async", "go", "async_step", %{})

      assert result.name == "async_step"
      assert result.typed_output == %{verdict: :pass, confidence: :high, reasoning: "ok"}
      assert is_binary(result.result) and result.result != ""
    end

    test "leaves typed_output nil when meta.output.status is :error" do
      Application.put_env(:jido_claw, :step_agent_server, ErrorFakeAgentServer)

      assert {:ok, %StepResult{} = result} = AgentRunner.run("echo_async", "go", nil, %{})
      assert result.typed_output == nil
      assert result.name == nil
    end

    test "projects typed_output[:summary] to StepResult.result as prose" do
      Application.put_env(:jido_claw, :step_agent_server, SummaryFakeAgentServer)

      assert {:ok, %StepResult{} = result} = AgentRunner.run("echo_async", "go", "s", %{})
      assert result.result == "Implemented foo"
    end

    test "merges typed_output[:artifacts] into StepResult.artifacts (stringified)" do
      Application.put_env(:jido_claw, :step_agent_server, ArtifactsFakeAgentServer)

      assert {:ok, %StepResult{} = result} = AgentRunner.run("echo_async", "go", "s", %{})
      assert result.artifacts["url"] == "http://localhost:4000"
      assert result.artifacts["port"] == "4000"
    end

    test "free-form path extracts artifacts from a fenced ARTIFACTS: block" do
      Application.put_env(:jido_claw, :step_agent_server, FreeFormFakeAgentServer)

      assert {:ok, %StepResult{} = result} = AgentRunner.run("echo_async", "go", "s", %{})
      assert result.typed_output == nil
      assert result.artifacts["url"] == "http://localhost:4001"
    end

    test "a failed request becomes a step {:error, _}" do
      Application.put_env(:jido_claw, :step_agent_server, FailedFakeAgentServer)

      assert {:error, msg} = AgentRunner.run("echo_async", "go", "s", %{})
      assert msg =~ "failed"
    end
  end

  describe "run/6 — AR-9 stage tier threading" do
    setup do
      Application.put_env(:jido_claw, :agent_templates_override, %{
        "echo_async" => %{
          module: EchoAskStub,
          description: "test-only async echo template",
          model: :fast,
          max_iterations: 1
        }
      })

      Application.put_env(:jido_claw, :step_agent_server, ValidatedFakeAgentServer)
      Application.put_env(:jido_claw, :echo_ask_stub_target, self())

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :step_agent_server)
        Application.delete_env(:jido_claw, :echo_ask_stub_target)
      end)

      :ok
    end

    test "non-tiered run: NO :request_transformer opt, NO tier key (byte-identity guard)" do
      assert {:ok, %StepResult{}} = AgentRunner.run("echo_async", "go", "s", %{})

      assert_receive {:echo_ask_stub, :opts, opts}
      refute Keyword.has_key?(opts, :request_transformer)

      tool_context = Keyword.fetch!(opts, :tool_context)
      refute Map.has_key?(tool_context, RequestTransformer.stage_tier_key())
    end

    test "tiered run/6: transformer opt pre-set, tier map under stage_tier_key in tool_context" do
      assert {:ok, %StepResult{}} =
               AgentRunner.run("echo_async", "go", "s", %{}, nil,
                 model: :capable,
                 effort: :high
               )

      assert_receive {:echo_ask_stub, :opts, opts}
      assert Keyword.get(opts, :request_transformer) == RequestTransformer

      tool_context = Keyword.fetch!(opts, :tool_context)

      assert Map.get(tool_context, RequestTransformer.stage_tier_key()) ==
               %{model: :capable, effort: :high}
    end

    test "half-tiered run/6 carries only the declared half" do
      assert {:ok, %StepResult{}} =
               AgentRunner.run("echo_async", "go", "s", %{}, nil, effort: :low)

      assert_receive {:echo_ask_stub, :opts, opts}
      assert Keyword.get(opts, :request_transformer) == RequestTransformer

      tool_context = Keyword.fetch!(opts, :tool_context)
      assert Map.get(tool_context, RequestTransformer.stage_tier_key()) == %{effort: :low}
    end

    test "an all-nil tier is treated as untiered (defensive nil-half rejection)" do
      assert {:ok, %StepResult{}} =
               AgentRunner.run("echo_async", "go", "s", %{}, nil, model: nil, effort: nil)

      assert_receive {:echo_ask_stub, :opts, opts}
      refute Keyword.has_key?(opts, :request_transformer)

      tool_context = Keyword.fetch!(opts, :tool_context)
      refute Map.has_key?(tool_context, RequestTransformer.stage_tier_key())
    end
  end

  describe "run/4 — setup failure" do
    test "an unknown template returns a clean {:error, _} (no crash)" do
      assert {:error, msg} = AgentRunner.run("does_not_exist_tmpl", "go", "s", %{})
      assert msg =~ "setup failed"
    end
  end

  describe "run/4 — executor dispatch (item 7, camus C1-1)" do
    setup do
      Application.put_env(:jido_claw, :agent_templates_override, %{
        "custom_stub" => %{
          module: EchoStub,
          description: "unbuilt forge kind",
          model: :fast,
          max_iterations: 1,
          executor: {:forge, :custom}
        }
      })

      on_exit(fn -> Application.delete_env(:jido_claw, :agent_templates_override) end)
      :ok
    end

    test "the unbuilt {:forge, :custom} kind is refused at dispatch — clean error, no worker" do
      assert {:error, msg} = AgentRunner.run("custom_stub", "go", "s", %{})
      assert msg =~ "not implemented"
      assert msg =~ "{:forge, :custom}"
    end
  end

  # Item 7 PR-1: the shared run_recorded/correlation/transcript envelope on the
  # FORGE arm — which the direct ForgeExecutor tests (no AgentRunner) can't
  # prove. Real tenant/session UUIDs ⇒ shared sandbox; Forge persistence off
  # (the hermetic ready_start pattern) so only the envelope rows hit the DB.
  describe "run/4 — forge-fake envelope (correlation + transcript rows)" do
    setup do
      pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
      prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "forge_env" => %{
          module: JidoClaw.Agent.Workers.Coder,
          description: "forge-fake envelope template",
          model: :fast,
          max_iterations: 1,
          executor: {:forge, :fake}
        }
      })

      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        "forge_env" => %{
          "summary" => "Implemented the envelope thing.",
          "status" => "completed",
          "files_changed" => [],
          "notes" => "n/a",
          "artifacts" => %{}
        }
      })

      on_exit(fn ->
        Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :executor_fake_outputs)
        Sandbox.stop_owner(pid)
      end)

      :ok
    end

    test "a forge step lands the correlation row plus task + terminal transcript rows" do
      %{context: context, session: session} = real_scope_context()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:run_result, AgentRunner.run("forge_env", "do the envelope thing", "fstep", context)}
          )
        end)

      assert_received {:run_result, result}
      assert {:ok, %StepResult{result: "Implemented the envelope thing."}} = result

      # The forge arm publishes the terminal signal itself (no AgentServer on
      # this path), so the Recorder flush inside record_step_terminal releases
      # on the SIGNAL — never the no-signal timeout degrade (50ms in test
      # config, 30s in prod), which would log a Recorder.flush warning here.
      refute log =~ "[Recorder.flush] timeout"

      {:ok, rows} =
        Message.for_session(session.id, tenant: context.tenant, actor: context.actor)

      task = Enum.find(rows, &(&1.role == :user and &1.content == "do the envelope thing"))
      terminal = Enum.find(rows, &(&1.role == :assistant))

      assert task, "expected the task :user transcript row"
      assert terminal, "expected the terminal :assistant transcript row"
      assert terminal.content == "Implemented the envelope thing."
      assert terminal.request_id == task.request_id
      assert task.subagent == true
      assert String.starts_with?(task.agent_id, "wf_forge_env_")

      # The durable correlation row persists past terminal-signal finalization
      # (only the cache entry clears; the row lives until TTL sweep).
      assert {:ok, correlation} =
               RequestCorrelation.lookup(task.request_id, authorize?: false)

      assert correlation.session_id == session.id
    end
  end

  # Item 7 PR-2: the vendor arm through the FULL AgentRunner envelope
  # (dispatch → correlation → transcript rows → flush-barrier signal) plus the
  # P1a prompt-parity contract — the subagent system prompt survives the
  # executor swap, threaded as the vendor prompt prefix rather than injected.
  describe "run/4 — vendor envelope + prompt parity (item 7 PR-2)" do
    setup do
      pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
      prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "vendor_env" => %{
          module: JidoClaw.Agent.Workers.Coder,
          description: "vendor envelope template",
          model: :fast,
          executor: {:forge, :codex}
        }
      })

      Application.put_env(:jido_claw, :executor_vendor_runners, %{
        codex: JidoClaw.Test.ScriptedDepositRunner
      })

      on_exit(fn ->
        Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :executor_vendor_runners)
        Application.delete_env(:jido_claw, :scripted_deposit_runner)
        Sandbox.stop_owner(pid)
      end)

      :ok
    end

    test "a vendor step lands the correlation row plus task + terminal transcript rows" do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{
        deposits: [
          %{
            "summary" => "Vendor enveloped the thing.",
            "status" => "completed",
            "files_changed" => [],
            "notes" => "n/a",
            "artifacts" => %{}
          }
        ],
        output: "raw-vendor-stream"
      })

      %{context: context, session: session} = real_scope_context()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:run_result, AgentRunner.run("vendor_env", "do the vendor thing", "vstep", context)}
          )
        end)

      assert_received {:run_result, result}
      assert {:ok, %StepResult{result: "Vendor enveloped the thing."}} = result

      # The forge arm publishes the terminal signal itself — the Recorder
      # flush must release on the SIGNAL, never the timeout degrade.
      refute log =~ "[Recorder.flush] timeout"

      {:ok, rows} =
        Message.for_session(session.id, tenant: context.tenant, actor: context.actor)

      task = Enum.find(rows, &(&1.role == :user and &1.content == "do the vendor thing"))
      terminal = Enum.find(rows, &(&1.role == :assistant))

      assert task, "expected the task :user transcript row"
      assert terminal, "expected the terminal :assistant transcript row"
      # P3a: the durable terminal shows the typed projection, not raw stream.
      assert terminal.content == "Vendor enveloped the thing."
      assert terminal.request_id == task.request_id

      assert {:ok, correlation} =
               RequestCorrelation.lookup(task.request_id, authorize?: false)

      assert correlation.session_id == session.id
    end

    test "doctrine ON: the vendor prompt carries the subagent contract, stage steers persona, deposit last" do
      prev_doc = Application.get_env(:jido_claw, :doctrine, [])
      prev_psy = Application.get_env(:jido_claw, :psychology, [])
      Application.put_env(:jido_claw, :doctrine, enabled?: true)
      Application.put_env(:jido_claw, :psychology, enabled?: true)

      on_exit(fn ->
        Application.put_env(:jido_claw, :doctrine, prev_doc)
        Application.put_env(:jido_claw, :psychology, prev_psy)
      end)

      Application.put_env(:jido_claw, :scripted_deposit_runner, %{deposits: [], notify: self()})

      %{context: context} = real_scope_context()

      assert {:ok, _} =
               AgentRunner.run(
                 "vendor_env",
                 "vendor parity task",
                 "vstep",
                 context,
                 "security-reviewer"
               )

      assert_receive {:scripted_deposit_runner, :prompt, prompt}, 5_000

      # The SubagentPrompt contract leads the prompt (role section first)...
      assert prompt =~ "# Role"
      [pre_task, _] = String.split(prompt, "vendor parity task", parts: 2)
      assert pre_task =~ "# Role"

      # ...the catalog stage steers the persona ("vendor_env" has NO template
      # fallback persona, so the defender block can only arrive via the
      # threaded stage name)...
      assert prompt =~ "## PSYCHOLOGY:"
      assert prompt =~ ~r/defender/i

      # ...and the deposit instruction stays LAST (nearest to action).
      [_, post_deposit] = String.split(prompt, "submit_structured_output", parts: 2)
      refute post_deposit =~ "vendor parity task"
    end

    test "doctrine OFF: the vendor prompt starts at the task (byte-consistent with in-process off)" do
      Application.put_env(:jido_claw, :scripted_deposit_runner, %{deposits: [], notify: self()})

      %{context: context} = real_scope_context()

      assert {:ok, _} = AgentRunner.run("vendor_env", "bare vendor task", "vstep", context)

      assert_receive {:scripted_deposit_runner, :prompt, prompt}, 5_000
      assert String.starts_with?(prompt, "bare vendor task")
      refute prompt =~ "# Role"
    end
  end

  describe "run/4 — AR-8b sandbox scope" do
    setup do
      pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(pid) end)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "sketch_stub" => %{
          module: EchoStub,
          description: "sandboxed sketch stub",
          model: :fast,
          max_iterations: 1,
          sandbox: :prototype
        }
      })

      Application.put_env(:jido_claw, :echo_stub_target, self())

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :echo_stub_target)
      end)

      :ok
    end

    test "a sandbox template with a nil project_dir is a setup error, no worker" do
      assert {:error, msg} = AgentRunner.run("sketch_stub", "go", "s", %{})
      assert msg =~ "setup failed"
      assert msg =~ "sandbox_scope_missing"
      refute_receive {:echo_stub, :tool_context, _tc}, 200
    end

    test "a sandbox template with a non-.prototypes project_dir is a setup error, no worker" do
      assert {:error, msg} =
               AgentRunner.run("sketch_stub", "go", "s", %{
                 tenant: "t",
                 project_dir: File.cwd!()
               })

      assert msg =~ "setup failed"
      assert msg =~ "not_under_prototypes"
      refute_receive {:echo_stub, :tool_context, _tc}, 200
    end

    test "a valid .prototypes scope runs and stamps tool_context[:sandbox] == :prototype" do
      base = Path.join(System.tmp_dir!(), "ar-sbx-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)
      {:ok, %{dir: proto}} = JidoClaw.VFS.Sandbox.create_prototype_dir(base)

      %{context: base_context} = real_scope_context()
      context = Map.put(base_context, :project_dir, proto)

      assert {:ok, _} = AgentRunner.run("sketch_stub", "go", "s", context)
      assert_receive {:echo_stub, :tool_context, tc}, 5_000

      assert tc.sandbox == :prototype
      assert tc.agent_template == "sketch_stub"
    end
  end

  describe "run/4 — AR-8b-2 F2 :docker scope (fail-closed, no worker)" do
    setup do
      # In-memory Forge only (no Persistence/DB ownership), mirroring
      # harness_bootstrap_env_test — these tests never launch a worker.
      prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "docker_stub" => %{
          module: EchoStub,
          description: "docker sketch stub",
          model: :fast,
          max_iterations: 1,
          sandbox: :docker
        }
      })

      Application.put_env(:jido_claw, :echo_stub_target, self())

      base = Path.join(System.tmp_dir!(), "ar-docker-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      {:ok, %{dir: proto}} = JidoClaw.VFS.Sandbox.create_prototype_dir(base)

      on_exit(fn ->
        Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev)
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :echo_stub_target)
        File.rm_rf!(base)
      end)

      {:ok, proto: proto}
    end

    test "a missing forge_session_key fails closed before launch", %{proto: proto} do
      assert {:error, msg} = AgentRunner.run("docker_stub", "go", "s", docker_context(proto, %{}))
      assert msg =~ "setup failed"
      assert msg =~ "docker_session_missing"
      refute_receive {:echo_stub, :tool_context, _tc}, 200
    end

    test "a dead/unknown forge_session_key fails closed", %{proto: proto} do
      ctx =
        docker_context(proto, %{forge_session_key: "no-such-session-#{System.unique_integer()}"})

      assert {:error, msg} = AgentRunner.run("docker_stub", "go", "s", ctx)
      assert msg =~ "docker_session_unavailable"
      refute_receive {:echo_stub, :tool_context, _tc}, 200
    end

    test "a non-.prototypes project_dir fails closed even with a ready session", %{proto: proto} do
      sid = start_ready_session(%{runner: :shell, sandbox: StubSandbox})
      ctx = docker_context(proto, %{project_dir: File.cwd!(), forge_session_key: sid})

      assert {:error, msg} = AgentRunner.run("docker_stub", "go", "s", ctx)
      assert msg =~ "not_under_prototypes"
      refute_receive {:echo_stub, :tool_context, _tc}, 200
    end

    test "a DEFERRED Docker session (state :ready, no default sandbox) fails closed — no lazy re-provision",
         %{proto: proto} do
      sid =
        start_ready_session(%{runner: :shell, sandbox: :docker_sandbox, deferred_provision: true})

      # Precondition: the deferred session is :ready but its default sandbox is
      # NOT provisioned — exactly the state a later Forge.exec would lazily fill.
      {:ok, status} = Forge.status(sid)
      assert status.sandbox_module == JidoClaw.Forge.Sandbox.Docker
      refute :default in status.sandboxes

      ctx = docker_context(proto, %{forge_session_key: sid})

      assert {:error, msg} = AgentRunner.run("docker_stub", "go", "s", ctx)
      assert msg =~ "docker_session_not_ready"
      refute_receive {:echo_stub, :tool_context, _tc}, 200
    end

    test "a fully-ready NON-Docker (StubSandbox) session fails closed — wrong backend",
         %{proto: proto} do
      sid = start_ready_session(%{runner: :shell, sandbox: StubSandbox})

      # Forge.status now exposes the backend module (the D5 additive change).
      {:ok, status} = Forge.status(sid)
      assert status.sandbox_module == StubSandbox
      assert status.state == :ready
      assert status.sandbox_status == :ready
      assert :default in status.sandboxes

      ctx = docker_context(proto, %{forge_session_key: sid})

      assert {:error, msg} = AgentRunner.run("docker_stub", "go", "s", ctx)
      assert msg =~ "docker_session_wrong_backend"
      refute_receive {:echo_stub, :tool_context, _tc}, 200
    end
  end

  describe "run/4 — forward_context policy + child correlation (DB)" do
    setup do
      pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(pid) end)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "echo_public" => %{module: EchoStub, description: "d", model: :fast, max_iterations: 1},
        "echo_restricted" => %{
          module: EchoStub,
          description: "d",
          model: :fast,
          max_iterations: 1,
          forward_context: :none
        }
      })

      Application.put_env(:jido_claw, :echo_stub_target, self())

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :echo_stub_target)
      end)

      :ok
    end

    test "forward_context :none nulls policy keys but keeps tenant_id/session_uuid" do
      %{context: context} = real_scope_context()

      assert {:ok, _} = AgentRunner.run("echo_restricted", "go", "s", context)
      assert_receive {:echo_stub, :tool_context, tc}, 5_000

      assert tc.user_id == nil
      assert tc.workspace_uuid == nil
      assert tc.actor == nil
      assert tc.tenant_id == context.tenant
      assert tc.session_uuid == context.session_uuid
    end

    test "the spawned step worker is genuinely stopped after the run (P1 regression)" do
      %{context: context} = real_scope_context()

      assert {:ok, _} = AgentRunner.run("echo_public", "go", "s", context)
      assert_receive {:echo_stub, :tool_context, tc}, 5_000

      # The after-block cleanup used `Process.exit(pid, :normal)`, which is
      # silently discarded when sent to another (non-trapping) process — the
      # worker leaked alive after every skill step. The real stop_agent goes
      # through the supervisor; registry cleanup is async, so poll.
      wait_until(fn -> JidoClaw.Jido.whereis(tc.agent_id) == nil end)
    end

    test "sets :agent_template to the step's template name on the worker tool_context" do
      %{context: context} = real_scope_context()

      assert {:ok, _} = AgentRunner.run("echo_public", "go", "s", context)
      assert_receive {:echo_stub, :tool_context, tc}, 5_000

      # resolve_scope/2 omits the template; run/4 sets it so the per-template
      # approval policy applies to skill-step workers too.
      assert tc.agent_template == "echo_public"
    end

    test "ensure_attaches the step template's external MCP tools onto the worker" do
      %{context: context} = real_scope_context()

      Application.put_env(:jido_claw, :mcp_facade, JidoClaw.Test.MCPFacadeCapture)
      Application.put_env(:jido_claw, :mcp_facade_capture_target, self())

      on_exit(fn ->
        Application.delete_env(:jido_claw, :mcp_facade)
        Application.delete_env(:jido_claw, :mcp_facade_capture_target)
      end)

      assert {:ok, _} = AgentRunner.run("echo_public", "go", "s", context)

      # run/4 bounds-attaches the freshly-spawned worker under the step's
      # template before its single-shot turn (steps previously got no externals).
      assert_receive {:mcp_ensure_attached, pid, "echo_public", 8_000}, 5_000
      assert is_pid(pid)
    end

    test "child correlation carries the parent's user_id end-to-end" do
      # Opt out of EchoStub's terminal-signal emit: finalization would
      # Cache.delete the correlation entry this test asserts on.
      prev = Application.fetch_env(:jido_claw, :echo_stub_emit_terminal)
      Application.put_env(:jido_claw, :echo_stub_emit_terminal, false)

      on_exit(fn ->
        case prev do
          {:ok, val} -> Application.put_env(:jido_claw, :echo_stub_emit_terminal, val)
          :error -> Application.delete_env(:jido_claw, :echo_stub_emit_terminal)
        end
      end)

      %{context: context, session: session, user_id: user_id} = real_scope_context()

      assert {:ok, _} = AgentRunner.run("echo_public", "go", "s", context)
      assert_receive {:echo_stub, :tool_context, tc}, 5_000
      assert tc.user_id == user_id

      cached =
        :jido_claw_request_correlations
        |> :ets.tab2list()
        |> Enum.filter(fn {_rid, scope} ->
          Map.get(scope, :user_id) == user_id and Map.get(scope, :session_id) == session.id
        end)

      assert cached != []
      {request_id, _scope} = hd(cached)

      case RequestCorrelation.lookup(request_id, authorize?: false) do
        {:ok, row} -> assert row.user_id == user_id
        _ -> :ok
      end

      _ = RequestCorrelation.complete(request_id, authorize?: false)
      Cache.delete(request_id)
    end
  end

  describe "run/4 — AR-5 doctrine injection" do
    setup do
      original = Application.get_env(:jido_claw, :doctrine)
      Application.put_env(:jido_claw, :doctrine, enabled?: true)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_claw, :doctrine)
          val -> Application.put_env(:jido_claw, :doctrine, val)
        end
      end)

      :ok
    end

    @tag :capture_log
    test "injects the doctrine prompt onto the freshly-spawned step worker" do
      handler_id = "ar5-agentrunner-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:jido_claw, :agent, :prompt_injected],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:injected, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # A bare context: no session_uuid → the step's correlation goes cache-only
      # and its transcript writes hit do_append's no-op clause, so the worker turn
      # touches no DB. Real "coder" template + default runtime so the pid actually
      # handles the ReAct set_system_prompt signal. run/4 is synchronous (it blocks
      # until the step's turn finishes); the injection fires before the turn runs
      # (agent_runner.ex, right after ensure_attached), so drive run/4 in a Task and
      # assert the early event. The flag is OFF globally, so a deleted call would
      # make this never fire — that's the point.
      Task.start(fn -> AgentRunner.run("coder", "go", "s", %{}) end)

      assert_receive {:injected, metadata}, 10_000
      assert metadata.source == :doctrine
      assert metadata.template == "coder"

      # Stop the worker the Task spawned (idempotent — the step's after-block also
      # stops it) so a failing assertion never leaks a supervised process.
      if is_pid(metadata.pid), do: JidoClaw.Jido.stop_agent(metadata.pid)
    end
  end

  # Builds a real tenant/workspace/session and a Reactor-style context carrying
  # the full scope (the shape ReactorRunner merges into the context).
  defp docker_context(proto, extra) do
    Map.merge(%{tenant: "t", project_dir: proto}, extra)
  end

  # Start an in-memory Forge session and block until it broadcasts :ready
  # (the deferred path readies without provisioning a default sandbox).
  defp start_ready_session(spec) do
    sid = "ar-docker-sess-#{System.unique_integer([:positive])}"
    ForgePubSub.subscribe(sid)
    on_exit(fn -> stop_session_quietly(sid) end)
    {:ok, _} = Forge.start_session(sid, spec)
    assert_receive {:ready, ^sid}, 10_000
    sid
  end

  defp stop_session_quietly(sid) do
    Forge.stop_session(sid)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp real_scope_context do
    tenant_id = "tenant-ar-#{System.unique_integer([:positive])}"
    project_dir = "/tmp/ar-#{System.unique_integer([:positive])}"
    user_id = "00000000-0000-0000-0000-0000ffff0001"

    {:ok, workspace} = JidoClaw.Workspaces.Resolver.ensure_workspace(tenant_id, project_dir)

    {:ok, session} =
      JidoClaw.Conversations.Resolver.ensure_session(
        tenant_id,
        workspace.id,
        :api,
        "ext-#{System.unique_integer([:positive])}"
      )

    context = %{
      tenant: tenant_id,
      actor: %{kind: :system, tenant_id: tenant_id},
      session_id: "runtime-sess",
      session_uuid: session.id,
      workspace_id: "runtime-ws",
      workspace_uuid: workspace.id,
      user_id: user_id,
      project_dir: project_dir
    }

    %{context: context, session: session, user_id: user_id}
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    wait_until_deadline(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait_until_deadline(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        wait_until_deadline(fun, deadline)
    end
  end
end

# ---------------------------------------------------------------------------
# FakeAgentServers — stub `Jido.AgentServer.await_completion/2` for the async
# path (ported from the retired StepActionTest).
# ---------------------------------------------------------------------------

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.ValidatedFakeAgentServer do
  @moduledoc false
  alias JidoClaw.Test.TerminalSignal

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    TerminalSignal.emit_from_await(opts)

    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: %{verdict: :pass, confidence: :high, reasoning: "ok"},
         meta: %{output: %{status: :validated, schema_kind: :map}}
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.ErrorFakeAgentServer do
  @moduledoc false
  alias JidoClaw.Test.TerminalSignal

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    TerminalSignal.emit_from_await(opts)

    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: %{verdict: :pass, confidence: :high, reasoning: "ok"},
         meta: %{output: %{status: :error, schema_kind: :map}}
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.SummaryFakeAgentServer do
  @moduledoc false
  alias JidoClaw.Test.TerminalSignal

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    TerminalSignal.emit_from_await(opts)

    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: %{status: :completed, summary: "Implemented foo", files_changed: [], notes: ""},
         meta: %{output: %{status: :validated, schema_kind: :map}}
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.ArtifactsFakeAgentServer do
  @moduledoc false
  alias JidoClaw.Test.TerminalSignal

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    TerminalSignal.emit_from_await(opts)

    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: %{
           status: :completed,
           summary: "Started server",
           files_changed: [],
           notes: "",
           artifacts: %{url: "http://localhost:4000", port: 4000}
         },
         meta: %{output: %{status: :validated, schema_kind: :map}}
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.FreeFormFakeAgentServer do
  @moduledoc false
  alias JidoClaw.Test.TerminalSignal

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    TerminalSignal.emit_from_await(opts)

    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: "Started the server.\n\nARTIFACTS:\nurl: http://localhost:4001\nport: 4001\n"
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.FailedFakeAgentServer do
  @moduledoc false
  alias JidoClaw.Test.TerminalSignal

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    TerminalSignal.emit_from_await(opts, "ai.request.failed")
    {:ok, %{status: :failed, result: :boom}}
  end
end
