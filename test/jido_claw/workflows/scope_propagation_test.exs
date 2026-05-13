defmodule JidoClaw.Workflows.ScopePropagationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Test.EchoStub
  alias JidoClaw.Workflows.{IterativeWorkflow, PlanWorkflow, SkillWorkflow, StepAction}

  # Module-level setup applied to every integration describe. Spawned
  # workflow workers call into the chat dispatcher and write a
  # `RequestCorrelation` row, so we own a shared sandbox connection to
  # prevent the worker PIDs racing on a connection yanked by an unrelated
  # shared-mode test exiting first. Env vars install the EchoStub agent
  # template override and the capture target so the test process can
  # `assert_receive` the per-step `tool_context`.
  setup context do
    if context[:integration_workflow] do
      sandbox_pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "echo_test" => %{
          module: EchoStub,
          description: "test-only echo template",
          model: :fast,
          max_iterations: 1
        }
      })

      Application.put_env(:jido_claw, :echo_stub_target, self())

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :echo_stub_target)
        Sandbox.stop_owner(sandbox_pid)
      end)
    end

    :ok
  end

  describe "StepAction.resolve_scope/3 (unit)" do
    test "params win over context.tool_context" do
      params = %{tenant_id: "param_t", session_uuid: "param_s"}
      context = %{tool_context: %{tenant_id: "ctx_t", session_uuid: "ctx_s"}}

      scope = StepAction.resolve_scope(params, context, "tag1")

      assert scope.tenant_id == "param_t"
      assert scope.session_uuid == "param_s"
      assert scope.agent_id == "tag1"
    end

    test "context.tool_context wins over fallback when params absent" do
      params = %{}

      context = %{
        tool_context: %{
          workspace_uuid: "ws-uu",
          tenant_id: "ctx_t"
        }
      }

      scope = StepAction.resolve_scope(params, context, "tag2")

      assert scope.tenant_id == "ctx_t"
      assert scope.workspace_uuid == "ws-uu"
    end

    test "workspace_id falls back to wf_<tag> when neither params nor context provide one" do
      scope = StepAction.resolve_scope(%{}, %{}, "tag3")
      assert scope.workspace_id == "wf_tag3"
    end

    test "phase 0 UUIDs fall back to nil when nothing provides them" do
      scope = StepAction.resolve_scope(%{}, %{}, "tag4")
      assert scope.tenant_id == nil
      assert scope.session_id == nil
      assert scope.session_uuid == nil
      assert scope.workspace_uuid == nil
    end

    test "context (top-level, not inside :tool_context) is consulted as a middle source" do
      params = %{}
      context = %{tenant_id: "raw_ctx_t"}

      scope = StepAction.resolve_scope(params, context, "tag5")
      assert scope.tenant_id == "raw_ctx_t"
    end

    test "agent_id is always the supplied tag, never inherited from params/context" do
      scope =
        StepAction.resolve_scope(
          %{agent_id: "ignored_param"},
          %{tool_context: %{agent_id: "ignored_ctx"}},
          "actual_tag"
        )

      assert scope.agent_id == "actual_tag"
    end
  end

  describe "scope_context plumbing (params shape)" do
    test "scope_context map merged into StepAction params reaches resolve_scope/3" do
      scope_context = %{
        tenant_id: "scoped_tenant",
        session_uuid: "scoped_sess",
        workspace_uuid: "scoped_ws",
        workspace_id: "scoped_runtime_ws"
      }

      # Mirror the merge that the workflow drivers perform: the driver
      # turns the keyword opt into a map, merges it into the per-step
      # params, and passes the same map as context.
      params =
        %{template: "ignored", task: "ignored", project_dir: File.cwd!(), name: "n"}
        |> Map.merge(scope_context)

      scope = StepAction.resolve_scope(params, scope_context, "wf_tag")

      assert scope.tenant_id == "scoped_tenant"
      assert scope.session_uuid == "scoped_sess"
      assert scope.workspace_uuid == "scoped_ws"
      assert scope.workspace_id == "scoped_runtime_ws"
    end

    test "project_dir is inherited via the same pick chain (P3 regression)" do
      # Direct StepAction.run/2 callers that pass a parent tool_context
      # without re-supplying params.project_dir should still inherit the
      # parent's project_dir — not silently fall back to File.cwd!().
      params = %{}
      context = %{tool_context: %{project_dir: "/some/parent/dir"}}

      scope = StepAction.resolve_scope(params, context, "tagP")
      assert scope.project_dir == "/some/parent/dir"
    end
  end

  describe "SkillWorkflow integration via agent_templates_override" do
    @describetag :integration_workflow

    test "child agent ask_sync receives parent scope via :scope_context" do
      skill = %JidoClaw.Skills{
        name: "scope_smoke",
        steps: [
          %{
            "name" => "echo_step",
            "template" => "echo_test",
            "task" => "echo this"
          }
        ],
        synthesis: "n/a"
      }

      parent_scope = %{
        tenant_id: "parent_tenant",
        session_id: "sess-string",
        session_uuid: "00000000-0000-0000-0000-000000000111",
        workspace_id: "parent_runtime_ws",
        workspace_uuid: "00000000-0000-0000-0000-000000000222",
        project_dir: File.cwd!()
      }

      assert {:ok, [_step_result]} =
               SkillWorkflow.run(skill, "", File.cwd!(), scope_context: parent_scope)

      assert_receive {:echo_stub, :tool_context, tc}, 5_000
      assert tc.tenant_id == "parent_tenant"
      assert tc.session_uuid == "00000000-0000-0000-0000-000000000111"
      assert tc.workspace_uuid == "00000000-0000-0000-0000-000000000222"
      assert tc.workspace_id == "parent_runtime_ws"
      assert tc.project_dir == File.cwd!()
      # agent_id is the per-step generated tag, not inherited.
      assert is_binary(tc.agent_id)
      assert String.starts_with?(tc.agent_id, "wf_echo_test_")
    end
  end

  describe "PlanWorkflow integration via agent_templates_override" do
    @describetag :integration_workflow

    test "every step in a parallel DAG receives parent scope via :scope_context" do
      parent_scope = %{
        tenant_id: "parent_tenant_dag",
        session_id: "sess-dag",
        session_uuid: "00000000-0000-0000-0000-000000000a01",
        workspace_id: "parent_ws_dag",
        workspace_uuid: "00000000-0000-0000-0000-000000000a02",
        project_dir: File.cwd!()
      }

      # Parallel DAG: step_a and step_b have no dependencies (run in
      # parallel). step_c depends_on [step_a, step_b] (fan-in). This
      # exercises DAG mode specifically — a linear `step_a -> step_b`
      # skill collapses to sequential ordering and would also pass under
      # a broken DAG implementation.
      skill = test_parallel_dag_skill()

      assert {:ok, _results} =
               PlanWorkflow.run(skill, "", File.cwd!(), scope_context: parent_scope)

      # Receive one tool_context message per step (3 total) and assert
      # each carries the parent scope subset. Order is not guaranteed
      # (parallel), so collect first, assert second.
      tcs = collect_echo_stub_tool_contexts(3, 5_000)
      assert length(tcs) == 3

      Enum.each(tcs, fn tc ->
        assert tc.tenant_id == parent_scope.tenant_id
        assert tc.session_uuid == parent_scope.session_uuid
        assert tc.workspace_uuid == parent_scope.workspace_uuid
        assert tc.workspace_id == parent_scope.workspace_id
        assert tc.project_dir == parent_scope.project_dir
        # agent_id is the per-step generated tag, not inherited.
        assert is_binary(tc.agent_id)
        assert String.starts_with?(tc.agent_id, "wf_echo_test_")
      end)
    end
  end

  describe "IterativeWorkflow integration via agent_templates_override" do
    @describetag :integration_workflow

    test "generator and evaluator receive parent scope on every iteration" do
      parent_scope = %{
        tenant_id: "parent_tenant_iter",
        session_id: "sess-iter",
        session_uuid: "00000000-0000-0000-0000-000000000b01",
        workspace_id: "parent_ws_iter",
        workspace_uuid: "00000000-0000-0000-0000-000000000b02",
        project_dir: File.cwd!()
      }

      # max_iterations: 2 with EchoStub never emitting `VERDICT: PASS`
      # produces 4 invocations: gen+eval × 2 iterations. Asserting
      # `length(tcs) == 4` catches both "scope propagation skipped on
      # iteration 2" AND "second iteration never ran" regressions.
      skill = test_iterative_skill(2)

      assert {:ok, _results} =
               IterativeWorkflow.run(skill, "", File.cwd!(), scope_context: parent_scope)

      tcs = collect_echo_stub_tool_contexts(4, 5_000)

      assert length(tcs) == 4,
             "expected 4 captures (gen+eval × 2 iterations); got #{length(tcs)}"

      Enum.each(tcs, fn tc ->
        assert tc.tenant_id == parent_scope.tenant_id
        assert tc.session_uuid == parent_scope.session_uuid
        assert tc.workspace_uuid == parent_scope.workspace_uuid
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Test skills + helpers
  # ---------------------------------------------------------------------------

  defp test_parallel_dag_skill do
    %JidoClaw.Skills{
      name: "scope_dag_smoke",
      steps: [
        %{"name" => "step_a", "template" => "echo_test", "task" => "step a"},
        %{"name" => "step_b", "template" => "echo_test", "task" => "step b"},
        %{
          "name" => "step_c",
          "template" => "echo_test",
          "task" => "step c",
          "depends_on" => ["step_a", "step_b"]
        }
      ],
      synthesis: "n/a"
    }
  end

  defp test_iterative_skill(max_iterations) do
    %JidoClaw.Skills{
      name: "scope_iter_smoke",
      mode: :iterative,
      max_iterations: max_iterations,
      steps: [
        %{
          "name" => "gen_step",
          "template" => "echo_test",
          "task" => "generate",
          "role" => "generator"
        },
        %{
          "name" => "eval_step",
          "template" => "echo_test",
          "task" => "evaluate",
          "role" => "evaluator"
        }
      ],
      synthesis: "n/a"
    }
  end

  # Drain N {:echo_stub, :tool_context, tc} messages from the mailbox.
  defp collect_echo_stub_tool_contexts(n, timeout) do
    for _ <- 1..n do
      receive do
        {:echo_stub, :tool_context, tc} -> tc
      after
        timeout -> flunk("did not receive expected #{n} tool_context messages")
      end
    end
  end
end
