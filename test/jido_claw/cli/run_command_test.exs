defmodule JidoClaw.CLI.RunCommandTest do
  @moduledoc """
  Drives the pure one-shot core (`JidoClaw.CLI.RunCommand.main/2`, no-op
  boot) end-to-end through the real `JidoClaw.chat/4` with the front-door
  seams stubbed, pinning the OQ-4 exit contract:

    0 answered / composer completed · 1 error/failed/timeout ·
    2 usage/config · 3 approval gate pending.

  The runner hardcodes tenant `"default"`, so seeded resume fixtures live
  under that tenant (sandboxed — rolled back per test).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.CLI.RunCommand
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Test.HandoffDispatchCapture

  # Simulates the real tool-approval mechanics: the gate opens its AgentCase
  # MID-ask (a require-listed tool tripping `ToolApproval.gate/4`) and the
  # LLM relays the approval-pending error as plain text — invisible in
  # chat/4's `{:ok, binary}` return. Opening it here makes `inserted_at >=
  # turn_started_at` deterministically true (the `fresh: true` class).
  defmodule GateTrippingAsk do
    @moduledoc false

    alias JidoClaw.Authorization.Actor, as: GateActor
    alias JidoClaw.Orchestration.AgentCase, as: GateCase
    alias JidoClaw.Test.TerminalSignal

    @spec ask_sync(pid(), term(), keyword()) :: {:ok, String.t()}
    def ask_sync(_pid, _query, opts) do
      tool_context = Keyword.fetch!(opts, :tool_context)

      {:ok, _case} =
        GateCase.open_tool_call(
          %{
            step_name: "network_share",
            tool_name: "network_share",
            fingerprint: "fp-run-cmd-#{System.unique_integer([:positive])}",
            session_id: tool_context.session_uuid,
            details: %{"tool" => "network_share"}
          },
          tenant: tool_context.tenant_id,
          actor: GateActor.system(tool_context.tenant_id)
        )

      TerminalSignal.emit_completed(Keyword.get(opts, :request_id))
      {:ok, "I need approval before running that tool."}
    end
  end

  defmodule FailingRestore do
    @moduledoc false
    @spec restore(pid(), struct(), String.t(), keyword()) :: {:error, :forced_failure}
    def restore(_pid, _session, _project_dir, _opts), do: {:error, :forced_failure}
  end

  @env_keys ~w(triage_impl triage_canned_verdict ask_runtime dispatch_capture_target
               dispatch_capture_response front_door_composer
               front_door_create_mode front_door_ensure_mode context_restore_impl
               mode skip_discord project_dir)a

  setup do
    tmp = Path.join(System.tmp_dir!(), "run-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, ".jido"))

    File.write!(
      Path.join([tmp, ".jido", "config.yaml"]),
      "provider: ollama\nmodel: ollama:test-model\n"
    )

    saved = Map.new(@env_keys, &{&1, Application.fetch_env(:jido_claw, &1)})
    saved_aliases = Application.fetch_env(:jido_ai, :model_aliases)

    Application.put_env(:jido_claw, :triage_impl, JidoClaw.Test.TriageStub)
    Application.put_env(:jido_claw, :triage_canned_verdict, :talk)
    Application.put_env(:jido_claw, :ask_runtime, HandoffDispatchCapture)
    Application.put_env(:jido_claw, :dispatch_capture_target, self())
    Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "one-shot answer"})
    Application.put_env(:jido_claw, :front_door_composer, JidoClaw.Test.FrontDoorComposerStub)
    Application.put_env(:jido_claw, :front_door_create_mode, :delegate)
    Application.put_env(:jido_claw, :front_door_ensure_mode, :noop)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, :error} -> Application.delete_env(:jido_claw, key)
        {key, {:ok, value}} -> Application.put_env(:jido_claw, key, value)
      end)

      case saved_aliases do
        :error -> Application.delete_env(:jido_ai, :model_aliases)
        {:ok, value} -> Application.put_env(:jido_ai, :model_aliases, value)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, actor: Actor.system("default")}
  end

  defp main(argv), do: RunCommand.main(argv, boot: fn -> :ok end)

  defp seed_default_fixture(ctx, session_opts \\ []) do
    {:ok, _} = Tenant.ensure("default")
    {:ok, ws} = seed_workspace("default", path: ctx.tmp)

    {:ok, session} =
      seed_session(
        "default",
        ws.id,
        Keyword.merge([kind: :cli_run, actor: ctx.actor], session_opts)
      )

    {ws, session}
  end

  defp decode!(output), do: Jason.decode!(output)

  describe "usage errors (exit 2)" do
    test "missing prompt" do
      assert {2, output} = main([])
      assert output =~ "usage:"
      assert output =~ "missing prompt"
    end

    test "empty prompt", ctx do
      assert {2, output} = main(["   ", ctx.tmp])
      assert output =~ "empty prompt"
    end

    test "--session and --continue together", ctx do
      assert {2, output} =
               main(["hi", ctx.tmp, "--session", Ecto.UUID.generate(), "--continue"])

      assert output =~ "mutually exclusive"
    end

    test "unknown session uuid", ctx do
      uuid = Ecto.UUID.generate()
      assert {2, output} = main(["hi", ctx.tmp, "--session", uuid])
      assert output =~ "session #{uuid} not found"
    end

    test "--continue with no resumable session in the workspace", ctx do
      assert {2, output} = main(["hi", ctx.tmp, "--continue"])
      assert output =~ "no open CLI session to continue"
    end

    test "unconfigured project dir points at --setup", ctx do
      bare = Path.join(ctx.tmp, "bare")
      File.mkdir_p!(bare)

      assert {2, output} = main(["hi", bare])
      assert output =~ "mix jidoclaw --setup"
    end

    test "a session from another workspace names its owning path", ctx do
      {:ok, _} = Tenant.ensure("default")

      other_path =
        Path.join(System.tmp_dir!(), "run-cmd-other-#{System.unique_integer([:positive])}")

      File.mkdir_p!(other_path)
      on_exit(fn -> File.rm_rf!(other_path) end)

      {:ok, other_ws} = seed_workspace("default", path: other_path)

      {:ok, foreign} =
        seed_session("default", other_ws.id, kind: :cli_run, actor: ctx.actor)

      assert {2, output} = main(["hi", ctx.tmp, "--session", foreign.id])
      assert output =~ "belongs to workspace #{other_path}"
      assert output =~ "run from there"
    end

    test "usage errors render as a json envelope when asked" do
      assert {2, output} = main(["--format", "json"])

      decoded = decode!(output)
      assert decoded["ok"] == false
      assert decoded["exit_code"] == 2
      assert decoded["outcome"] == "usage"
      assert decoded["error"] =~ "missing prompt"
    end
  end

  describe "inline route" do
    test "answered with no pending approvals exits 0 (json envelope)", ctx do
      assert {0, output} = main(["say hi", ctx.tmp, "--format", "json"])

      decoded = decode!(output)
      assert decoded["ok"] == true
      assert decoded["exit_code"] == 0
      assert decoded["route"] == "inline"
      assert decoded["outcome"] == "answered"
      assert decoded["message"] == "one-shot answer"
      assert decoded["pending_cases"] == []
      assert decoded["error"] == nil
      assert is_binary(decoded["session_id"])
      assert decoded["run_id"] == nil
    end

    test "answered exits 0 in text mode with the session id", ctx do
      assert {0, output} = main(["say hi", ctx.tmp])
      assert output =~ "one-shot answer"
      assert output =~ "session: "
    end

    test "a gate tripped MID-turn exits 3 with a fresh pending case", ctx do
      Application.put_env(:jido_claw, :ask_runtime, GateTrippingAsk)

      assert {3, output} = main(["share the network", ctx.tmp, "--format", "json"])

      decoded = decode!(output)
      assert decoded["exit_code"] == 3
      assert decoded["outcome"] == "gate_pending"

      assert [%{"id" => case_id, "fresh" => true, "tool" => "network_share"}] =
               decoded["pending_cases"]

      assert is_binary(case_id)
    end

    test "a PRE-EXISTING pending case (fingerprint-reuse class) still exits 3, fresh: false",
         ctx do
      {_ws, session} = seed_default_fixture(ctx)

      {:ok, stale} =
        AgentCase.open_tool_call(
          %{
            step_name: "git_commit",
            tool_name: "git_commit",
            fingerprint: "fp-stale-#{System.unique_integer([:positive])}",
            session_id: session.id,
            details: %{}
          },
          tenant: "default",
          actor: ctx.actor
        )

      assert {3, output} = main(["hi", ctx.tmp, "--session", session.id, "--format", "json"])

      decoded = decode!(output)
      assert decoded["exit_code"] == 3
      assert [%{"id" => case_id, "fresh" => false}] = decoded["pending_cases"]
      assert case_id == stale.id

      # Text mode labels the stale case explicitly.
      Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "again"})
      assert {3, text} = main(["hi again", ctx.tmp, "--session", session.id])
      assert text =~ "pending since before this run"
      assert text =~ "/gates approve"
    end
  end

  describe "composer route" do
    defp stamp_when_launched(status, extra_attrs \\ %{}) do
      actor = Actor.system("default")

      Task.async(fn ->
        run = await_composer_parent(actor, 100)

        attrs = Map.merge(%{status: status, completed_at: DateTime.utc_now()}, extra_attrs)

        {:ok, _} =
          run
          |> Ash.Changeset.for_update(:set_status, attrs, tenant: "default", authorize?: false)
          |> Ash.update()

        run.id
      end)
    end

    defp await_composer_parent(_actor, 0), do: flunk("composer parent run never appeared")

    defp await_composer_parent(actor, attempts) do
      {:ok, runs} = WorkflowRun.list(tenant: "default", actor: actor)

      case Enum.find(runs, &(&1.workflow_type == "composer" and is_nil(&1.parent_run_id))) do
        nil ->
          Process.sleep(50)
          await_composer_parent(actor, attempts - 1)

        run ->
          run
      end
    end

    test "a launched run that completes exits 0 with the run id", ctx do
      Application.put_env(:jido_claw, :triage_canned_verdict, :code)
      watcher = stamp_when_launched(:completed)

      assert {0, output} = main(["refactor it", ctx.tmp, "--timeout", "30", "--format", "json"])

      stamped_run_id = Task.await(watcher, 10_000)
      decoded = decode!(output)
      assert decoded["exit_code"] == 0
      assert decoded["route"] == "composer"
      assert decoded["outcome"] == "launched_completed"
      assert decoded["run_id"] == stamped_run_id
    end

    test "a done_with_findings completion STILL exits 0 but the envelope is marked (camus C1-4)",
         ctx do
      Application.put_env(:jido_claw, :triage_canned_verdict, :code)

      watcher =
        stamp_when_launched(:completed, %{
          result: %{
            "disposition" => "done_with_findings",
            "finding_keys" => ["k1", "k2"],
            "findings_deferred_count" => 2
          }
        })

      assert {0, output} = main(["refactor it", ctx.tmp, "--timeout", "30", "--format", "json"])

      _ = Task.await(watcher, 10_000)
      decoded = decode!(output)
      # The pinned OQ-4 contract: done_with_findings stays exit 0 —
      # never plain green in the OUTPUT, though.
      assert decoded["exit_code"] == 0
      assert decoded["outcome"] == "launched_completed"
      assert decoded["disposition"] == "done_with_findings"
      assert decoded["findings_deferred_count"] == 2
    end

    test "a done_with_findings completion marks the TEXT run line too", ctx do
      Application.put_env(:jido_claw, :triage_canned_verdict, :code)

      watcher =
        stamp_when_launched(:completed, %{
          result: %{
            "disposition" => "done_with_findings",
            "findings_deferred_count" => 1
          }
        })

      assert {0, text} = main(["refactor it", ctx.tmp, "--timeout", "30"])

      _ = Task.await(watcher, 10_000)
      assert text =~ "done_with_findings (1 finding(s) deferred)"
    end

    test "a launched run that fails exits 1", ctx do
      Application.put_env(:jido_claw, :triage_canned_verdict, :code)
      watcher = stamp_when_launched(:failed)

      assert {1, output} = main(["refactor it", ctx.tmp, "--timeout", "30", "--format", "json"])

      _ = Task.await(watcher, 10_000)
      decoded = decode!(output)
      assert decoded["exit_code"] == 1
      assert decoded["outcome"] == "failed"
    end

    test "a gate on a CHILD run exits 3 with the case id", ctx do
      Application.put_env(:jido_claw, :triage_canned_verdict, :code)
      actor = ctx.actor

      watcher =
        Task.async(fn ->
          parent = await_composer_parent(actor, 100)

          {:ok, child} =
            WorkflowRun.create(
              %{name: "wave-1", workflow_type: "composer", parent_run_id: parent.id},
              tenant: "default",
              actor: actor
            )

          {:ok, agent_case} =
            AgentCase.create(
              %{workflow_run_id: child.id, step_name: "gate", kind: :irreversible_write},
              tenant: "default",
              actor: actor
            )

          agent_case.id
        end)

      assert {3, output} = main(["refactor it", ctx.tmp, "--timeout", "30", "--format", "json"])

      case_id = Task.await(watcher, 10_000)
      decoded = decode!(output)
      assert decoded["exit_code"] == 3
      assert decoded["outcome"] == "gate_pending"
      assert decoded["pending_cases"] == [%{"id" => case_id, "fresh" => true, "tool" => nil}]
    end

    test "await timeout exits 1 and names the still-running run", ctx do
      Application.put_env(:jido_claw, :triage_canned_verdict, :code)

      assert {1, output} = main(["refactor it", ctx.tmp, "--timeout", "1", "--format", "json"])

      decoded = decode!(output)
      assert decoded["exit_code"] == 1
      assert decoded["outcome"] == "timeout"
      assert decoded["error"] =~ "still in progress"
      assert is_binary(decoded["run_id"])
    end

    test "a composer that fails to start exits 1", ctx do
      Application.put_env(:jido_claw, :triage_canned_verdict, :code)
      Application.put_env(:jido_claw, :front_door_create_mode, :error)

      assert {1, output} = main(["refactor it", ctx.tmp, "--format", "json"])

      decoded = decode!(output)
      assert decoded["exit_code"] == 1
      assert decoded["outcome"] == "error"
      assert decoded["error"] =~ "failed to start"
    end
  end

  describe "resume" do
    test "--continue with a broken restore exits 1 (strict, never amnesic)", ctx do
      {_ws, session} = seed_default_fixture(ctx)

      {:ok, _} =
        Message.append(
          %{session_id: session.id, role: :user, content: "earlier question"},
          tenant: "default",
          actor: ctx.actor
        )

      Application.put_env(:jido_claw, :context_restore_impl, FailingRestore)

      assert {1, output} = main(["what did I ask?", ctx.tmp, "--continue", "--format", "json"])

      decoded = decode!(output)
      assert decoded["exit_code"] == 1
      assert decoded["outcome"] == "error"
      assert decoded["error"] =~ "could NOT be restored"
    end

    test "--continue resumes the seeded CLI session and answers", ctx do
      {_ws, session} = seed_default_fixture(ctx)

      assert {0, output} = main(["hello again", ctx.tmp, "--continue", "--format", "json"])

      decoded = decode!(output)
      assert decoded["exit_code"] == 0
      assert decoded["session_id"] == session.id
    end
  end
end
