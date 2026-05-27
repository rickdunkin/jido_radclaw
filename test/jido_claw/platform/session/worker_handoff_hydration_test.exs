defmodule JidoClaw.Platform.Session.WorkerHandoffHydrationTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker

  describe "set_session_uuid/3 cold-start hydration" do
    test "seeds the handoff registry from session metadata when template is valid" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "hydrate")
      actor = actor_for(tenant_id)
      runtime_session_id = session.external_id

      # Pre-seed metadata before the worker learns the session_uuid.
      {:ok, _} =
        ConversationsSession.set_current_agent_template(session, "reviewer",
          tenant: tenant_id,
          actor: actor
        )

      assert HandoffRegistry.owner(tenant_id, runtime_session_id) == nil

      # Start the worker (no session_uuid yet) then push the uuid through.
      {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, runtime_session_id, actor: actor)

      :ok = SessionWorker.set_session_uuid(tenant_id, runtime_session_id, session.id)

      owner = HandoffRegistry.owner(tenant_id, runtime_session_id)
      assert owner != nil
      assert owner.template == "reviewer"
      assert owner.preamble_consumed? == true

      on_exit(fn -> HandoffRegistry.clear(tenant_id, runtime_session_id) end)
    end

    test "stale metadata is cleared and registry remains empty" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "hydrate-stale")
      actor = actor_for(tenant_id)
      runtime_session_id = session.external_id

      {:ok, _} =
        ConversationsSession.set_current_agent_template(session, "phantom_template",
          tenant: tenant_id,
          actor: actor
        )

      {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, runtime_session_id, actor: actor)

      :ok = SessionWorker.set_session_uuid(tenant_id, runtime_session_id, session.id)

      assert HandoffRegistry.owner(tenant_id, runtime_session_id) == nil

      {:ok, fresh} = ConversationsSession.by_id(session.id, tenant: tenant_id, actor: actor)

      refute Map.has_key?(fresh.metadata || %{}, "current_agent_template")
    end

    test "no metadata means no hydration" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "hydrate-nometa")
      actor = actor_for(tenant_id)
      runtime_session_id = session.external_id

      {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, runtime_session_id, actor: actor)

      :ok = SessionWorker.set_session_uuid(tenant_id, runtime_session_id, session.id)

      assert HandoffRegistry.owner(tenant_id, runtime_session_id) == nil
    end
  end
end
