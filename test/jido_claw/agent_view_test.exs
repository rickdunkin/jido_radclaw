defmodule JidoClaw.AgentViewTest do
  # async: false — two blockers: the messages-cap tests write rows via
  # SessionWorker.add_message from the worker process (outside $callers;
  # the write itself is what's asserted), and the status/events tests
  # round-trip through the process-global Trace.Collector ring like the rest
  # of the sync trace cohort.
  use JidoClaw.TenantCase, async: false

  import JidoClaw.TraceTestHelpers, only: [sync_collector: 0]

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.AgentView
  alias JidoClaw.Conversations.Message, as: ConversationsMessage
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Orchestration.ToolApprovals
  alias JidoClaw.Session.Worker, as: SessionWorker

  setup do
    %{tenant_id: tenant_id, session: session, workspace: workspace} =
      seed_full(tenant_label: "agent_view")

    actor = actor_for(tenant_id)
    on_exit(fn -> HandoffRegistry.clear(tenant_id, session.external_id) end)

    {:ok,
     tenant_id: tenant_id,
     session: session,
     workspace: workspace,
     actor: actor,
     runtime_session_id: session.external_id}
  end

  defp start_worker(tenant_id, session_id, actor) do
    {:ok, _pid} = JidoClaw.Session.Supervisor.ensure_session(tenant_id, session_id, actor: actor)
    :ok
  end

  defp install_handoff(tenant_id, runtime_session_id, session_uuid, template, module) do
    handoff =
      Handoff.new(%{
        tenant_id: tenant_id,
        runtime_session_id: runtime_session_id,
        session_uuid: session_uuid,
        from_template: "main",
        to_template: template,
        to_module: module,
        message: "Please handle"
      })

    :ok = HandoffRegistry.put_owner(tenant_id, runtime_session_id, handoff)
    handoff
  end

  defp install_consumed_handoff(tenant_id, runtime_session_id, session_uuid, template, module) do
    handoff =
      Handoff.new(%{
        tenant_id: tenant_id,
        runtime_session_id: runtime_session_id,
        session_uuid: session_uuid,
        from_template: "main",
        to_template: template,
        to_module: module,
        message: "Please handle"
      })

    :ok =
      HandoffRegistry.put_owner(tenant_id, runtime_session_id, handoff, preamble_consumed?: true)

    handoff
  end

  defp emit_request!(event, metadata) do
    metadata = Map.put_new(metadata, :run_id, metadata[:request_id])
    :telemetry.execute([:jido, :ai, :request, event], %{}, metadata)
    :ok = sync_collector()
  end

  defp emit_model_start!(metadata) do
    metadata = Map.put_new(metadata, :run_id, metadata[:request_id])
    :telemetry.execute([:jido, :ai, :llm, :start], %{}, metadata)
    :ok = sync_collector()
  end

  defp emit_tool_start!(metadata) do
    metadata = Map.put_new(metadata, :run_id, metadata[:request_id])
    :telemetry.execute([:jido, :ai, :tool, :execute, :start], %{}, metadata)
    :ok = sync_collector()
  end

  describe "snapshot/2 — input contracts" do
    test "%Session{} input with no live worker returns :idle, empty messages, count 0", %{
      session: session
    } do
      assert {:ok, view} = AgentView.snapshot(session)
      assert view.tenant_id == session.tenant_id
      assert view.session_id == session.external_id
      assert view.session_uuid == session.id
      assert view.status == :idle
      assert view.messages == []
      assert view.message_count == 0
      assert view.agent_template == "main"
    end

    test "map input with no live worker and no session_uuid returns :session_not_resolved", %{
      tenant_id: tid,
      runtime_session_id: rsid
    } do
      assert {:error, :session_not_resolved} =
               AgentView.snapshot(%{tenant_id: tid, session_id: rsid})
    end

    test "map input with session_uuid in wrong tenant returns :session_not_found", %{
      session: session
    } do
      other_tenant = seed_tenant("other")

      assert {:error, :session_not_found} =
               AgentView.snapshot(%{
                 tenant_id: other_tenant,
                 session_id: session.external_id,
                 session_uuid: session.id
               })
    end

    test "map input with session_uuid whose external_id mismatches returns :session_id_mismatch",
         %{tenant_id: tid, session: session} do
      assert {:error, :session_id_mismatch} =
               AgentView.snapshot(%{
                 tenant_id: tid,
                 session_id: "bogus",
                 session_uuid: session.id
               })
    end
  end

  describe "snapshot/2 — worker + status" do
    test "live worker with :active status reports :idle (active != running)", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      assert {:ok, view} = AgentView.snapshot(session)
      assert view.status == :idle
    end

    test "trace status :running overrides worker idle and bubbles to :running", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      request_id = Ecto.UUID.generate()
      agent_id = JidoClaw.runtime_agent_id(session.id)
      emit_request!(:start, %{agent_id: agent_id, request_id: request_id, tenant_id: tid})

      assert {:ok, view} = AgentView.snapshot(session)
      assert view.status == :running
    end

    test "trace status :failed promotes status to :error and populates error", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      request_id = Ecto.UUID.generate()
      agent_id = JidoClaw.runtime_agent_id(session.id)
      emit_request!(:start, %{agent_id: agent_id, request_id: request_id, tenant_id: tid})

      emit_request!(:failed, %{
        agent_id: agent_id,
        request_id: request_id,
        tenant_id: tid,
        error: "boom"
      })

      assert {:ok, view} = AgentView.snapshot(session)
      assert view.status == :error
      assert is_map(view.error)
    end

    test "handoff owner with preamble_consumed?: false yields :awaiting_handoff", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid
    } do
      install_handoff(tid, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)

      assert {:ok, view} = AgentView.snapshot(session)
      assert view.status == :awaiting_handoff
      assert view.agent_template == "reviewer"
      assert view.agent_module == JidoClaw.Agent.Workers.Reviewer
      assert view.handoff_owner.template == "reviewer"
      refute view.handoff_owner.preamble_consumed?
    end

    test "consumed handoff still surfaces template but status falls back to :idle", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid
    } do
      install_consumed_handoff(tid, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)

      assert {:ok, view} = AgentView.snapshot(session)
      assert view.status == :idle
      assert view.agent_template == "reviewer"
      assert view.handoff_owner.preamble_consumed?
    end

    test "a pending tool-call approval case yields :awaiting_approval", %{
      tenant_id: tid,
      session: session
    } do
      scope = %{
        tenant_id: tid,
        session_uuid: session.id,
        session_id: session.external_id,
        actor: actor_for(tid)
      }

      assert {:pending, _case} = ToolApprovals.request(scope, "git_commit", %{message: "x"})

      assert {:ok, view} = AgentView.snapshot(session)
      assert view.status == :awaiting_approval
    end
  end

  describe "snapshot/2 — agent_id selection" do
    test "handoff owner produces handoff:<uuid>:<template>", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid
    } do
      install_handoff(tid, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)

      assert {:ok, view} = AgentView.snapshot(session)
      assert view.agent_id == "handoff:#{session.id}:reviewer"
    end

    test "without a worker pid and without handoff, agent_id uses the durable session UUID",
         %{session: session} do
      assert {:ok, view} = AgentView.snapshot(session)
      assert view.agent_id == JidoClaw.runtime_agent_id(session.id)
    end

    test "a legacy worker without a durable UUID falls back to its raw runtime session id", %{
      tenant_id: tid,
      runtime_session_id: rsid
    } do
      worker = %SessionWorker{id: rsid, tenant_id: tid, session_uuid: nil}

      assert {:ok, view} = AgentView.snapshot(worker)
      assert view.agent_id == rsid
    end

    test "handoff fallback uses owner.handoff.session_uuid when input lacks session_uuid", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid
    } do
      install_handoff(tid, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)

      # Pass a Worker struct with no session_uuid set; the AgentView should
      # still derive the trace key from the owner's handoff.session_uuid.
      worker = %SessionWorker{id: rsid, tenant_id: tid, session_uuid: nil}

      assert {:ok, view} = AgentView.snapshot(worker)
      assert view.agent_id == "handoff:#{session.id}:reviewer"
    end

    test "a worker reporting a dead agent_pid falls through to the durable runtime id (not nil)",
         %{tenant_id: tid, session: session, runtime_session_id: rsid, actor: actor} do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      # A confirmed-dead pid.
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)

      receive do
        {:DOWN, ^ref, :process, ^dead, _reason} -> :ok
      after
        1_000 -> flunk("spawned process did not exit")
      end

      # Inject the dead pid straight into the worker's state. We deliberately
      # do NOT use SessionWorker.set_agent/3 — it monitors the pid, and an
      # already-dead pid would fire :DOWN immediately, flipping agent_pid back
      # to nil. :sys.replace_state reproduces the real race: get_info reports a
      # dead agent_pid before the worker has processed the agent's :DOWN.
      worker_pid =
        tid
        |> JidoClaw.Session.Supervisor.list_sessions()
        |> Enum.find_value(fn {sid, p} -> if sid == rsid, do: p end)

      true = is_pid(worker_pid)
      :sys.replace_state(worker_pid, fn state -> %{state | agent_pid: dead} end)

      assert {:ok, view} = AgentView.snapshot(session)
      # The dead pid must NOT collapse agent_id to nil; the durable runtime id
      # is still a valid trace key and does not collide across sessions.
      assert view.agent_id == JidoClaw.runtime_agent_id(session.id)
    end
  end

  describe "snapshot/2 — events filtering and capping" do
    test "events_categories filter runs before events_limit cap", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      request_id = Ecto.UUID.generate()

      common = %{
        request_id: request_id,
        agent_id: JidoClaw.runtime_agent_id(session.id),
        tenant_id: tid
      }

      # 4 model events
      for i <- 1..4 do
        emit_model_start!(Map.put(common, :tool_call_id, "model-#{i}"))
      end

      # 6 tool events
      for i <- 1..6 do
        emit_tool_start!(Map.put(common, :tool_call_id, "tool-#{i}"))
      end

      assert {:ok, view} =
               AgentView.snapshot(session,
                 events_categories: [:model],
                 events_limit: 3
               )

      assert Enum.all?(view.events, &(&1.category == :model))
      assert [_, _, _] = view.events
    end

    test "events_limit: :infinity returns all filtered events without arity crash", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      request_id = Ecto.UUID.generate()

      common = %{
        request_id: request_id,
        agent_id: JidoClaw.runtime_agent_id(session.id),
        tenant_id: tid
      }

      for i <- 1..3 do
        emit_model_start!(Map.put(common, :tool_call_id, "model-#{i}"))
      end

      assert {:ok, view} =
               AgentView.snapshot(session,
                 events_categories: [:model],
                 events_limit: :infinity
               )

      assert [_, _, _] = view.events
    end
  end

  describe "snapshot/2 — messages cap" do
    test "messages_limit caps but message_count keeps the underlying total", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      for i <- 1..10 do
        :ok = SessionWorker.add_message(tid, rsid, :user, "msg #{i}")
      end

      assert {:ok, view} = AgentView.snapshot(session, messages_limit: 3)
      assert [_, _, _] = view.messages
      assert view.message_count == 10
    end

    test "messages_limit: :infinity returns all messages", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      for i <- 1..5 do
        :ok = SessionWorker.add_message(tid, rsid, :user, "msg #{i}")
      end

      assert {:ok, view} = AgentView.snapshot(session, messages_limit: :infinity)
      assert Enum.count(view.messages) == 5
    end

    test "cold snapshot (no worker) caps messages at the default while message_count keeps the pre-cap total",
         %{tenant_id: tid, session: session, actor: actor} do
      for i <- 1..60 do
        {:ok, _} =
          ConversationsMessage.append(
            %{session_id: session.id, role: :user, content: "m#{i}"},
            tenant: tid,
            actor: actor
          )
      end

      assert {:ok, view} = AgentView.snapshot(session)
      assert Enum.count(view.messages) == 50
      assert view.message_count == 60
    end
  end

  describe "snapshot/2 — compaction" do
    test "include_compaction?: false omits compaction lookup", %{session: session} do
      assert {:ok, view} = AgentView.snapshot(session, include_compaction?: false)
      assert view.compaction == nil
    end

    test "compaction snapshot is surfaced when present", %{
      tenant_id: tid,
      session: session,
      actor: actor
    } do
      snap = %{
        "summary" => "rolled up",
        "summarized_request_ids" => [],
        "version" => 1
      }

      # No handoff owner → AgentView reads the main agent's key.
      {:ok, _} =
        ConversationsSession.set_compaction_snapshot(session, "main::default", snap,
          tenant: tid,
          actor: actor
        )

      assert {:ok, view} = AgentView.snapshot(session)
      assert is_map(view.compaction)
    end
  end

  describe "to_mcp_map/1" do
    test "produces a JSON-safe map: no leaf atoms (besides nil/bool), no DateTimes, no modules",
         %{tenant_id: tid, session: session, runtime_session_id: rsid} do
      install_handoff(tid, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)
      {:ok, view} = AgentView.snapshot(session)

      mapped = AgentView.to_mcp_map(view)

      refute leaf_violates?(mapped)
      # agent_module dropped
      refute Map.has_key?(mapped, "agent_module")
      # status was an atom; it is now a string
      assert mapped["status"] == "awaiting_handoff"
    end

    test "Trace.Event rows are slimmed and atoms stringified", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)
      request_id = Ecto.UUID.generate()

      emit_model_start!(%{
        request_id: request_id,
        agent_id: JidoClaw.runtime_agent_id(session.id),
        tenant_id: tid,
        tool_call_id: "model-1"
      })

      {:ok, view} = AgentView.snapshot(session)
      mapped = AgentView.to_mcp_map(view)

      assert is_list(mapped["events"])
      assert [_event] = mapped["events"]

      Enum.each(mapped["events"], fn ev ->
        # `category` was an atom, must now be a string
        assert is_binary(ev["category"])
        # event keys are strings, not atoms
        assert Enum.all?(Map.keys(ev), &is_binary/1)
      end)
    end
  end

  describe "snapshot/2 — worker failure tolerance" do
    test "killing the worker mid-test does not crash the snapshot for a %Session{} input", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      pid =
        Enum.find_value(
          JidoClaw.Session.Supervisor.list_sessions(tid),
          fn {sid, p} -> if sid == rsid, do: p end
        )

      true = is_pid(pid)
      Process.exit(pid, :kill)
      Process.sleep(20)

      assert {:ok, _view} = AgentView.snapshot(session)
    end
  end

  describe "snapshot/2 — trace terminal status semantics" do
    test "completed trace yields status :idle (NOT :done) and trace_status :completed", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid,
      actor: actor
    } do
      :ok = start_worker(tid, rsid, actor)
      :ok = SessionWorker.set_session_uuid(tid, rsid, session.id)

      request_id = Ecto.UUID.generate()

      common = %{
        agent_id: JidoClaw.runtime_agent_id(session.id),
        request_id: request_id,
        tenant_id: tid
      }

      emit_request!(:start, common)
      emit_request!(:complete, common)

      assert {:ok, view} = AgentView.snapshot(session)
      assert view.status == :idle
      assert view.trace_status == :completed
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Any struct (DateTime, NaiveDateTime, Date, …) is JSON-unsafe at the MCP
  # boundary. Must precede the `is_map/1` clause — structs are maps, and one
  # reaching that clause would crash `Enum.any?` (structs aren't Enumerable).
  defp leaf_violates?(value) when is_struct(value), do: true

  defp leaf_violates?(value) when is_map(value) do
    Enum.any?(value, fn {k, v} -> not is_binary(k) or leaf_violates?(v) end)
  end

  defp leaf_violates?(value) when is_list(value), do: Enum.any?(value, &leaf_violates?/1)
  defp leaf_violates?(nil), do: false
  defp leaf_violates?(true), do: false
  defp leaf_violates?(false), do: false
  defp leaf_violates?(value) when is_atom(value), do: true
  defp leaf_violates?(_), do: false
end
