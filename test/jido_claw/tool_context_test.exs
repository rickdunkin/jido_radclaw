defmodule JidoClaw.ToolContextTest do
  use ExUnit.Case, async: true

  alias JidoClaw.ToolContext

  describe "build/1" do
    test "preserves :user_id (regression: previously dropped silently)" do
      ctx = ToolContext.build(%{user_id: "u-1", tenant_id: "t", project_dir: "/tmp"})

      assert ctx[:user_id] == "u-1"
      assert ctx[:tenant_id] == "t"
      assert ctx[:project_dir] == "/tmp"
    end

    test "writes nil for missing canonical keys" do
      ctx = ToolContext.build(%{})

      for key <- [
            :project_dir,
            :tenant_id,
            :session_id,
            :session_uuid,
            :workspace_id,
            :workspace_uuid,
            :user_id,
            :agent_id
          ] do
        assert Map.has_key?(ctx, key)
      end
    end

    test "preserves :forge_session_key when present" do
      ctx = ToolContext.build(%{forge_session_key: "fk-1"})
      assert ctx[:forge_session_key] == "fk-1"
    end

    test "omits :forge_session_key when absent" do
      ctx = ToolContext.build(%{tenant_id: "t"})
      refute Map.has_key?(ctx, :forge_session_key)
    end
  end

  describe "child/2" do
    test "child carries :user_id forward" do
      parent = ToolContext.build(%{user_id: "u-2", tenant_id: "t", project_dir: "/d"})
      child = ToolContext.child(parent, "child-tag")

      assert child[:user_id] == "u-2"
      assert child[:agent_id] == "child-tag"
    end
  end
end
