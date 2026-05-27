defmodule JidoClaw.PublicAPIHandoffTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Conversations.Session, as: ConversationsSession

  describe "public API exports" do
    test "handoff_owner/2, reset_handoff/2, reset_handoff/4 exist" do
      assert function_exported?(JidoClaw, :handoff_owner, 2)
      assert function_exported?(JidoClaw, :reset_handoff, 2)
      assert function_exported?(JidoClaw, :reset_handoff, 4)
    end
  end

  describe "handoff_owner/2" do
    test "returns nil for unknown {tenant, session}" do
      assert JidoClaw.handoff_owner("unknown_tenant", "unknown_session") == nil
    end

    test "returns the installed owner record" do
      tenant_id = seed_tenant("api-owner")

      handoff =
        Handoff.new(%{
          tenant_id: tenant_id,
          runtime_session_id: "s1",
          session_uuid: Ecto.UUID.generate(),
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          from_template: "main",
          message: "review"
        })

      :ok = HandoffRegistry.put_owner(tenant_id, "s1", handoff)

      assert %{template: "reviewer"} = JidoClaw.handoff_owner(tenant_id, "s1")

      on_exit(fn -> HandoffRegistry.clear(tenant_id, "s1") end)
    end
  end

  describe "reset_handoff/2 (registry-only)" do
    test "is idempotent for absent ownership" do
      assert :ok = JidoClaw.reset_handoff("ghost", "ghost-session")
    end

    test "clears an installed owner" do
      tenant_id = seed_tenant("api-reset2")

      handoff =
        Handoff.new(%{
          tenant_id: tenant_id,
          runtime_session_id: "s1",
          session_uuid: Ecto.UUID.generate(),
          to_template: "coder",
          to_module: JidoClaw.Agent.Workers.Coder,
          message: "code"
        })

      :ok = HandoffRegistry.put_owner(tenant_id, "s1", handoff)
      assert HandoffRegistry.owner(tenant_id, "s1") != nil

      assert :ok = JidoClaw.reset_handoff(tenant_id, "s1")
      assert HandoffRegistry.owner(tenant_id, "s1") == nil
    end
  end

  describe "reset_handoff/4 (registry + metadata mirror)" do
    test "clears the durable metadata mirror" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "api-reset4")
      actor = actor_for(tenant_id)

      handoff =
        Handoff.new(%{
          tenant_id: tenant_id,
          runtime_session_id: session.external_id,
          session_uuid: session.id,
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: "review"
        })

      :ok = HandoffRegistry.put_owner(tenant_id, session.external_id, handoff)

      {:ok, fresh} =
        ConversationsSession.by_id(session.id, tenant: tenant_id, actor: actor)

      {:ok, _} =
        ConversationsSession.set_current_agent_template(fresh, "reviewer",
          tenant: tenant_id,
          actor: actor
        )

      assert :ok =
               JidoClaw.reset_handoff(
                 tenant_id,
                 session.external_id,
                 session.id,
                 actor
               )

      assert HandoffRegistry.owner(tenant_id, session.external_id) == nil

      {:ok, reread} =
        ConversationsSession.by_id(session.id, tenant: tenant_id, actor: actor)

      refute Map.has_key?(reread.metadata || %{}, "current_agent_template")
    end

    test "is no-op safe when session_uuid is nil" do
      tenant_id = seed_tenant("api-reset4-nil")
      assert :ok = JidoClaw.reset_handoff(tenant_id, "s1", nil, nil)
    end
  end
end
