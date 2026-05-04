defmodule JidoClaw.Tools.RunSkillTest do
  @moduledoc """
  Pure-function unit tests for the canonical `scope_context/1` helper —
  the chokepoint that decides which `tool_context` keys propagate from
  the parent agent into workflow drivers (and from there into child
  agents). The Phase 0 attribution chain breaks if `:user_id` is dropped
  here.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.RunSkill

  describe "scope_context/1" do
    test "carries :user_id through to the workflow scope" do
      ctx = %{
        tenant_id: "t",
        session_id: "s",
        session_uuid: "u-session",
        workspace_id: "ws",
        workspace_uuid: "u-ws",
        project_dir: "/tmp",
        user_id: "u-user",
        agent_id: "should-be-stripped",
        forge_session_key: "should-be-stripped",
        random_extra_key: "should-be-stripped"
      }

      out = RunSkill.scope_context(ctx)

      assert out == %{
               tenant_id: "t",
               session_id: "s",
               session_uuid: "u-session",
               workspace_id: "ws",
               workspace_uuid: "u-ws",
               project_dir: "/tmp",
               user_id: "u-user"
             }
    end

    test "missing keys produce a smaller map (no nil padding)" do
      out = RunSkill.scope_context(%{tenant_id: "t", user_id: "u"})

      assert out == %{tenant_id: "t", user_id: "u"}
    end

    test "empty input produces an empty scope" do
      assert RunSkill.scope_context(%{}) == %{}
    end
  end
end
