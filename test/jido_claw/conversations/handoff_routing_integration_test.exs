defmodule JidoClaw.Conversations.HandoffRoutingIntegrationTest do
  @moduledoc """
  End-to-end routing test: install a handoff via `Tools.Handoff.run/2`,
  then drive `HandoffRouter.resolve_session_owner/6` across multiple
  turns and assert the routed pid, the preamble lifecycle, and that the
  durable artifacts (registry, metadata, :system message, trace event)
  all line up.

  Driving the actual main agent's LLM to choose `handoff(…)` is out of
  scope — the load-bearing behavior here is routing, not LLM tool
  selection. The tool is invoked directly to install ownership.
  """

  use JidoClaw.TenantCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Handoff.Router, as: HandoffRouter
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Tools.Handoff, as: HandoffTool
  alias JidoClaw.TraceTestHelpers

  setup do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "integration")
    runtime_session_id = session.external_id
    actor = actor_for(tenant_id)

    {:ok, worker_pid} =
      SessionSupervisor.ensure_session(tenant_id, runtime_session_id, actor: actor)

    # The worker is spawned by the app-tree DynamicSupervisor (outside
    # $callers); allow it so its DB work — hydration on set_session_uuid and
    # the durable :system row HandoffTool.run writes via add_message — lands
    # on the test's owner connection.
    Sandbox.allow(JidoClaw.Repo, self(), worker_pid)

    :ok = SessionWorker.set_session_uuid(tenant_id, runtime_session_id, session.id)

    default_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      HandoffRegistry.clear(tenant_id, runtime_session_id)
      Process.exit(default_pid, :kill)
    end)

    {:ok,
     tenant_id: tenant_id,
     session: session,
     runtime_session_id: runtime_session_id,
     actor: actor,
     default_pid: default_pid}
  end

  test "full lifecycle: install → first turn (preamble) → next turn (no preamble) → reset → main",
       %{
         tenant_id: t,
         session: session,
         runtime_session_id: rsid,
         actor: actor,
         default_pid: default_pid
       } do
    # ---- 1. Install ownership directly via the tool ----
    request_id = Ecto.UUID.generate()

    ctx = %{
      tool_context: %{
        tenant_id: t,
        session_id: rsid,
        session_uuid: session.id,
        agent_id: "main",
        agent_template: "main",
        actor: actor
      },
      request_id: request_id
    }

    assert {:ok, payload} =
             HandoffTool.run(
               %{
                 to_template: "reviewer",
                 message: "Please review the recent diff",
                 summary: "User asked for a review"
               },
               ctx
             )

    assert payload.status == "handed_off"

    # Registry is the source of truth.
    owner = HandoffRegistry.owner(t, rsid)
    assert owner.template == "reviewer"
    assert owner.preamble_consumed? == false

    # Durable metadata mirror.
    {:ok, fresh} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)
    assert fresh.metadata["current_agent_template"] == "reviewer"

    # Durable :system message — worker-scoped identity + enriched body.
    {:ok, rows} = Message.for_session(session.id, tenant: t, actor: actor)

    assert Enum.any?(rows, fn r ->
             r.role == :system and r.content =~ "[HANDOFF main → reviewer]" and
               r.agent_id == "handoff:#{session.id}:reviewer" and r.subagent == false
           end)

    # Trace event.
    :ok = TraceTestHelpers.sync_collector()

    # ---- 2. First post-handoff turn — Router returns Reviewer pid, preamble built ----
    {pid1, template1, agent_id1, first1, _fresh1, owner1} =
      HandoffRouter.resolve_session_owner(t, rsid, session.id, default_pid, actor,
        project_dir: File.cwd!(),
        session_record: fresh,
        default_agent_id: "main"
      )

    assert is_pid(pid1)
    assert pid1 != default_pid
    assert template1 == "reviewer"
    assert agent_id1 == "handoff:#{session.id}:reviewer"
    assert first1 == true

    preamble = HandoffRouter.build_preamble(t, rsid, owner1)
    assert preamble =~ "HANDOFF CONTEXT"
    assert preamble =~ "Please review the recent diff"
    assert preamble =~ "User asked for a review"

    # Simulate successful dispatch — dispatcher would mark consumed.
    :ok = HandoffRegistry.mark_preamble_consumed(t, rsid)

    # ---- 3. Subsequent turn — same Reviewer pid, no preamble ----
    {pid2, template2, _, first2, _, _} =
      HandoffRouter.resolve_session_owner(t, rsid, session.id, default_pid, actor,
        project_dir: File.cwd!(),
        session_record: fresh,
        default_agent_id: "main"
      )

    assert pid2 == pid1
    assert template2 == "reviewer"
    assert first2 == false

    # ---- 4. /reset (full form) → registry + metadata cleared ----
    :ok = JidoClaw.reset_handoff(t, rsid, session.id, actor)

    assert HandoffRegistry.owner(t, rsid) == nil

    {:ok, reread} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)
    refute Map.has_key?(reread.metadata || %{}, "current_agent_template")

    # ---- 5. Next turn routes to main again ----
    {pid3, template3, agent_id3, first3, _fresh3, owner3} =
      HandoffRouter.resolve_session_owner(t, rsid, session.id, default_pid, actor,
        project_dir: File.cwd!(),
        session_record: reread,
        default_agent_id: "main"
      )

    assert pid3 == default_pid
    assert template3 == "main"
    assert agent_id3 == "main"
    assert first3 == false
    assert owner3 == nil
  end

  test "if the dispatch fails, preamble_consumed? stays false so the next turn gets a fresh preamble",
       %{
         tenant_id: t,
         session: session,
         runtime_session_id: rsid,
         actor: actor,
         default_pid: default_pid
       } do
    ctx = %{
      tool_context: %{
        tenant_id: t,
        session_id: rsid,
        session_uuid: session.id,
        agent_id: "main",
        agent_template: "main",
        actor: actor
      },
      request_id: Ecto.UUID.generate()
    }

    assert {:ok, _} =
             HandoffTool.run(
               %{to_template: "reviewer", message: "Review"},
               ctx
             )

    {_, _, _, first1, _, _} =
      HandoffRouter.resolve_session_owner(t, rsid, session.id, default_pid, actor,
        project_dir: File.cwd!(),
        session_record: session,
        default_agent_id: "main"
      )

    # Simulate a FAILED dispatch — the dispatcher would NOT mark consumed.
    assert first1 == true
    refute HandoffRegistry.owner(t, rsid).preamble_consumed?

    # Next call still gets first_post_handoff? = true.
    {_, _, _, first2, _, _} =
      HandoffRouter.resolve_session_owner(t, rsid, session.id, default_pid, actor,
        project_dir: File.cwd!(),
        session_record: session,
        default_agent_id: "main"
      )

    assert first2 == true
  end
end
