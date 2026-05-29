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

  describe "forward_context policy — child/3 + apply_visibility/2" do
    test ":public forwards the parent's full scope" do
      child = ToolContext.child(full_parent(), "c", :public)

      assert child.tenant_id == "t"
      assert child.session_uuid == "s"
      assert child.user_id == "u"
      assert child.workspace_id == "runtime-w"
      assert child.workspace_uuid == "w"
      assert child.actor == %{kind: :system}
      assert child.forge_session_key == "fk"
    end

    test ":none strips every policy-controlled key but keeps structural keys" do
      child = ToolContext.child(full_parent(), "c", :none)

      # Structural keys always survive.
      assert child.tenant_id == "t"
      assert child.session_uuid == "s"

      # The five policy-controlled keys are nulled.
      assert child.user_id == nil
      assert child.workspace_id == nil
      assert child.workspace_uuid == nil
      assert child.actor == nil
      # forge_session_key is omitted (not nil-valued) once build/1 drops a nil.
      assert Map.get(child, :forge_session_key) == nil
    end

    test "{:only, [:user_id]} keeps only that key, nulls the rest" do
      child = ToolContext.child(full_parent(), "c", {:only, [:user_id]})

      assert child.user_id == "u"
      assert child.workspace_id == nil
      assert child.workspace_uuid == nil
      assert child.actor == nil
      assert Map.get(child, :forge_session_key) == nil
      assert child.tenant_id == "t"
      assert child.session_uuid == "s"
    end

    test "{:except, [:actor]} nulls only :actor" do
      child = ToolContext.child(full_parent(), "c", {:except, [:actor]})

      assert child.actor == nil
      assert child.user_id == "u"
      assert child.workspace_id == "runtime-w"
      assert child.workspace_uuid == "w"
      assert child.forge_session_key == "fk"
    end

    test "{:except, [:tenant_id]} fails closed — a non-policy key strips everything strippable; structural keys survive regardless" do
      # :tenant_id is not policy-controlled, so naming it is a malformed
      # policy. The primitive fails closed (strips every policy-controlled
      # key) rather than leaking the full scope; the structural keys
      # survive regardless of the policy.
      child = ToolContext.child(full_parent(), "c", {:except, [:tenant_id]})

      assert child.tenant_id == "t"
      assert child.session_uuid == "s"

      assert child.user_id == nil
      assert child.workspace_id == nil
      assert child.workspace_uuid == nil
      assert child.actor == nil
      assert Map.get(child, :forge_session_key) == nil
    end

    test "{:except, [:usr_id]} (typo'd atom) fails closed instead of leaking the full scope" do
      # Headline regression: a typo'd atom used to filter to [], dropping
      # nothing and forwarding the parent's full scope to the child.
      child = ToolContext.child(full_parent(), "c", {:except, [:usr_id]})

      assert child.user_id == nil
      assert child.workspace_id == nil
      assert child.workspace_uuid == nil
      assert child.actor == nil
      assert Map.get(child, :forge_session_key) == nil
      assert child.tenant_id == "t"
      assert child.session_uuid == "s"
    end

    test "{:except, [\"user_id\"]} (string key) fails closed" do
      # A string key is never a member of the (atom) policy-controlled
      # universe, so it too fails closed.
      child = ToolContext.child(full_parent(), "c", {:except, ["user_id"]})

      assert child.user_id == nil
      assert child.workspace_id == nil
      assert child.workspace_uuid == nil
      assert child.actor == nil
      assert Map.get(child, :forge_session_key) == nil
      assert child.tenant_id == "t"
    end

    test "{:only, [:user_id, :usr_id]} (valid + unknown) fails closed" do
      # The {:only} tightening: any unknown key in the keep list fails the
      # whole policy closed, matching validate_fc. The valid :user_id is
      # NOT silently kept.
      child = ToolContext.child(full_parent(), "c", {:only, [:user_id, :usr_id]})

      assert child.user_id == nil
      assert child.workspace_id == nil
      assert child.workspace_uuid == nil
      assert child.actor == nil
      assert Map.get(child, :forge_session_key) == nil
      assert child.tenant_id == "t"
    end

    test "an invalid policy fails closed (strips every policy-controlled key)" do
      child = ToolContext.child(full_parent(), "c", :bogus)

      assert child.user_id == nil
      assert child.workspace_id == nil
      assert child.workspace_uuid == nil
      assert child.actor == nil
      assert Map.get(child, :forge_session_key) == nil
      assert child.tenant_id == "t"
      assert child.session_uuid == "s"
    end

    test "apply_visibility/2 nulls in place without building the canonical shape" do
      assert ToolContext.apply_visibility(full_parent(), :public) == full_parent()

      assert %{user_id: nil, actor: nil, tenant_id: "t", session_uuid: "s"} =
               ToolContext.apply_visibility(full_parent(), :none)
    end

    test "policy_controlled_keys/0 lists exactly the strippable keys" do
      assert ToolContext.policy_controlled_keys() ==
               [:user_id, :workspace_id, :workspace_uuid, :actor, :forge_session_key]
    end
  end

  defp full_parent do
    %{
      tenant_id: "t",
      session_uuid: "s",
      user_id: "u",
      workspace_id: "runtime-w",
      workspace_uuid: "w",
      actor: %{kind: :system},
      forge_session_key: "fk"
    }
  end
end
