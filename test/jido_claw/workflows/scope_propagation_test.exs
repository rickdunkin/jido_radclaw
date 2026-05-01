defmodule JidoClaw.Workflows.ScopePropagationTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Test.EchoStub
  alias JidoClaw.Workflows.{SkillWorkflow, StepAction}

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
    setup do
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
      end)

      :ok
    end

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
end
