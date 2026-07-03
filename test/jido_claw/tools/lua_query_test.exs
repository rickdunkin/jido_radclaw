defmodule JidoClaw.Tools.LuaQueryTest do
  # async: false — LuaQuery.run drives the FULL generated pipeline and the
  # Runner's unlinked eval task does the DB reads (shared sandbox needed).
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Tools.LuaQuery

  setup do
    %{tenant_id: tenant_id, workspace: workspace, session: session} =
      seed_full(tenant_label: "lua-query")

    context = %{
      tool_context: %{
        tenant_id: tenant_id,
        session_uuid: session.id,
        workspace_uuid: workspace.id
      }
    }

    {:ok, tenant_id: tenant_id, context: context}
  end

  describe "happy path (full pipeline)" do
    test "evaluates a script with host bindings under the caller's scope", %{
      tenant_id: tenant_id,
      context: context
    } do
      {:ok, run} =
        WorkflowRun.create(%{name: "pipeline-run", workflow_type: "audit"},
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      code = ~s|local runs = jido.runs({limit = 10})\nreturn #runs, runs[1].run_id|

      assert {:ok, result} = LuaQuery.run(%{code: code}, context)

      assert result["results"] == [1, run.id]
      assert result["call_count"] == 1
      assert [%{"binding" => "jido.runs", "status" => "ok"}] = result["calls"]
    end
  end

  describe "tenant requirement" do
    test "no tool_context refuses with :tenant_required" do
      assert {:error, %{code: :tenant_required}} =
               LuaQuery.run(%{code: "return 1"}, %{})
    end

    test "present-nil tenant_id refuses too (the ToolContext trap)" do
      assert {:error, %{code: :tenant_required}} =
               LuaQuery.run(%{code: "return 1"}, %{tool_context: %{tenant_id: nil}})
    end

    test "empty-string tenant_id refuses too" do
      assert {:error, %{code: :tenant_required}} =
               LuaQuery.run(%{code: "return 1"}, %{tool_context: %{tenant_id: ""}})
    end
  end

  describe "pipeline integration" do
    test "a secret-shaped string in the script result arrives redacted", %{context: context} do
      secret = "sk-ant-" <> String.duplicate("A", 32)

      assert {:ok, result} =
               LuaQuery.run(%{code: ~s|return "prefix #{secret} suffix"|}, context)

      rendered = Jason.encode!(result)
      refute rendered =~ secret
      assert rendered =~ "[REDACTED:ANTHROPIC_KEY]"
    end

    test "an oversized structured result ERRORS — never silently capped", %{context: context} do
      code = ~s|local t = {} for i = 1, 5000 do t[i] = string.rep("a", 20) end return t|

      assert {:error, %{code: :lua_result_too_large, details: details}} =
               LuaQuery.run(%{code: code}, context)

      assert details.retry == false
    end

    test "runner error envelopes flow through the pipeline intact", %{context: context} do
      assert {:error, %{code: :lua_runtime_error, message: message, details: %{retry: false}}} =
               LuaQuery.run(%{code: ~s|error("kaboom")|}, context)

      assert message =~ "kaboom"
    end
  end
end
