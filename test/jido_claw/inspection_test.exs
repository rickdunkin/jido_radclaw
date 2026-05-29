defmodule JidoClaw.InspectionTest do
  use JidoClaw.TenantCase, async: false

  import JidoClaw.TraceTestHelpers, only: [sync_collector: 0]

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Workers.Reviewer
  alias JidoClaw.AgentTracker
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Inspection
  alias JidoClaw.Inspection.Summary
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Trace.Resources.TraceEvent
  alias JidoClaw.Trace.Resources.TraceRun

  setup do
    %{tenant_id: tenant_id, session: session, workspace: workspace} =
      seed_full(tenant_label: "inspection")

    actor = actor_for(tenant_id)
    on_exit(fn -> HandoffRegistry.clear(tenant_id, session.external_id) end)

    {:ok,
     tenant_id: tenant_id,
     session: session,
     workspace: workspace,
     actor: actor,
     runtime_session_id: session.external_id}
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

  describe "inspect_agent/2 — module dispatch" do
    test "JidoClaw.Agent returns tool_names from strategy_opts" do
      assert {:ok, %Summary{} = s} = Inspection.inspect_agent(JidoClaw.Agent)
      assert s.input_kind == :module
      assert is_list(s.tool_names)
      assert "read_file" in s.tool_names
    end

    test "worker module dispatch sees the worker's declared tools" do
      assert {:ok, %Summary{} = s} = Inspection.inspect_agent(JidoClaw.Agent.Workers.Coder)
      assert s.input_kind == :module
      assert is_list(s.tool_names)
    end

    test "unknown module returns :unknown_target" do
      assert {:error, :unknown_target} = Inspection.inspect_agent(:totally_bogus)
    end
  end

  describe "inspect_agent/2 — agent_id dispatch (non-handoff)" do
    test "untracked id returns :ok with nilable running fields and the main tool set" do
      assert {:ok, %Summary{} = s} =
               Inspection.inspect_agent("not-tracked-#{:rand.uniform(100_000)}")

      assert s.input_kind == :agent_id
      assert s.duration_ms == nil
      assert s.error == nil
      # No tracker entry → falls back to JidoClaw.Agent's tool set.
      assert "read_file" in s.tool_names
    end

    test "tracked id resolves the worker module via its template and lists its tools" do
      # AgentTracker is a process-global singleton with no deregister API;
      # reset on exit (cast) and barrier on get_state (call) so the "child"
      # entry never leaks into another async: false test's :subagents.
      on_exit(fn ->
        AgentTracker.reset()
        AgentTracker.get_state()
      end)

      :ok = AgentTracker.register("child", self(), "reviewer")

      assert {:ok, %Summary{} = s} = Inspection.inspect_agent("child")
      assert s.input_kind == :agent_id

      expected =
        Reviewer.strategy_opts()
        |> Keyword.fetch!(:tools)
        |> Enum.map(&to_string(&1.name()))

      assert MapSet.new(s.tool_names) == MapSet.new(expected)
    end
  end

  describe "inspect_agent/2 — pid dispatch" do
    test "a non-agent pid returns a :pid summary via the safe fallback (no raise)" do
      # `self()` is not a Jido.AgentServer, so the wrapped state lookup
      # fails fast → nil module → empty tool list, but no crash.
      assert {:ok, %Summary{input_kind: :pid} = s} = Inspection.inspect_agent(self())
      assert s.tool_names == []
    end
  end

  describe "inspect_agent/2 — handoff agent_id" do
    test "valid handoff:<uuid>:<template> with tenant_id resolves owner", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid
    } do
      install_handoff(tid, rsid, session.id, "reviewer", Reviewer)

      id = "handoff:#{session.id}:reviewer"

      assert {:ok, %Summary{handoffs: h, input_kind: :agent_id}} =
               Inspection.inspect_agent(id, tenant_id: tid)

      assert h.template == "reviewer"
    end

    test "handoff target without tenant_id returns :tenant_required", %{
      session: session
    } do
      id = "handoff:#{session.id}:reviewer"
      assert {:error, :tenant_required} = Inspection.inspect_agent(id)
    end

    test "handoff template mismatch returns :handoff_not_found", %{
      tenant_id: tid,
      session: session,
      runtime_session_id: rsid
    } do
      install_handoff(tid, rsid, session.id, "coder", JidoClaw.Agent.Workers.Coder)

      id = "handoff:#{session.id}:reviewer"
      assert {:error, :handoff_not_found} = Inspection.inspect_agent(id, tenant_id: tid)
    end

    test "session in wrong tenant returns :handoff_not_found", %{
      session: session
    } do
      other_tenant = seed_tenant("other")
      id = "handoff:#{session.id}:reviewer"

      assert {:error, :handoff_not_found} =
               Inspection.inspect_agent(id, tenant_id: other_tenant)
    end

    test "no owner registered returns :handoff_not_found", %{
      tenant_id: tid,
      session: session
    } do
      id = "handoff:#{session.id}:reviewer"
      assert {:error, :handoff_not_found} = Inspection.inspect_agent(id, tenant_id: tid)
    end
  end

  describe "inspect_agent/2 — session dispatches" do
    test "%Session{} input populates session-axis summary", %{session: session} do
      assert {:ok, %Summary{input_kind: :session} = s} = Inspection.inspect_agent(session)
      assert is_list(s.tool_names)
    end

    test "%{tenant_id, session_id} map input matches session dispatch", %{
      tenant_id: tid,
      runtime_session_id: rsid
    } do
      assert {:ok, %Summary{input_kind: :session}} =
               Inspection.inspect_agent(%{tenant_id: tid, session_id: rsid})
    end
  end

  describe "inspect_request/2" do
    test "missing tenant_id returns :tenant_required" do
      assert {:error, :tenant_required} = Inspection.inspect_request("req-1")
    end

    test "unknown request returns :not_found", %{tenant_id: tid} do
      assert {:error, :not_found} =
               Inspection.inspect_request("no-such-req-#{System.unique_integer([:positive])}",
                 tenant_id: tid
               )
    end

    test "tenant mismatch on Trace returns :not_found", %{
      tenant_id: tid,
      runtime_session_id: rsid
    } do
      request_id = Ecto.UUID.generate()

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: rsid, request_id: request_id, tenant_id: tid, run_id: request_id}
      )

      :ok = sync_collector()

      other_tenant = seed_tenant("isolated")

      assert {:error, :not_found} =
               Inspection.inspect_request(request_id, tenant_id: other_tenant)
    end

    test "happy path returns request_id summary with usage", %{
      tenant_id: tid,
      session: session,
      workspace: workspace,
      runtime_session_id: rsid
    } do
      request_id = Ecto.UUID.generate()

      {:ok, _} =
        RequestCorrelation.register(%{
          request_id: request_id,
          session_id: session.id,
          tenant_id: tid,
          workspace_id: workspace.id,
          user_id: nil
        })

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: rsid, request_id: request_id, tenant_id: tid, run_id: request_id}
      )

      :telemetry.execute(
        [:jido, :ai, :llm, :complete],
        %{input_tokens: 10, output_tokens: 20},
        %{agent_id: rsid, request_id: request_id, tenant_id: tid, run_id: request_id}
      )

      :ok = sync_collector()

      assert {:ok, %Summary{usage: usage, input_kind: :request_id, request_id: ^request_id}} =
               Inspection.inspect_request(request_id, tenant_id: tid)

      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
    end

    test "correlation found under a different tenant returns :not_found", %{
      tenant_id: tid,
      runtime_session_id: rsid
    } do
      request_id = Ecto.UUID.generate()

      # The correlation row lives in another tenant...
      other = seed_full(tenant_label: "wrong_corr")

      {:ok, _} =
        RequestCorrelation.register(%{
          request_id: request_id,
          session_id: other.session.id,
          tenant_id: other.tenant_id,
          workspace_id: other.workspace.id,
          user_id: nil
        })

      # ...but the Trace itself IS visible to the requesting tenant, so
      # `Trace.for_request` succeeds and only the correlation tenant
      # cross-check fails (otherwise the test would pass for the wrong
      # reason — trace not found).
      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: rsid, request_id: request_id, tenant_id: tid, run_id: request_id}
      )

      :ok = sync_collector()

      assert {:error, :not_found} = Inspection.inspect_request(request_id, tenant_id: tid)
    end

    test "missing correlation returns :ok with nil session fields but populated usage/duration",
         %{tenant_id: tid, runtime_session_id: rsid} do
      request_id = Ecto.UUID.generate()

      # No RequestCorrelation row registered for this request_id.
      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: rsid, request_id: request_id, tenant_id: tid, run_id: request_id}
      )

      :telemetry.execute(
        [:jido, :ai, :llm, :complete],
        %{input_tokens: 7, output_tokens: 11},
        %{agent_id: rsid, request_id: request_id, tenant_id: tid, run_id: request_id}
      )

      :telemetry.execute(
        [:jido, :ai, :request, :complete],
        %{},
        %{agent_id: rsid, request_id: request_id, tenant_id: tid, run_id: request_id}
      )

      :ok = sync_collector()

      assert {:ok, %Summary{} = s} = Inspection.inspect_request(request_id, tenant_id: tid)

      assert s.context_preview == nil
      assert s.compaction == nil
      assert s.usage.input_tokens == 7
      assert is_integer(s.duration_ms)
    end

    test "durable-rehydrated trace with string-keyed measurements still aggregates usage", %{
      tenant_id: tid
    } do
      # Seed `trace_runs` + `trace_events` directly (mirroring
      # Trace.Persistence's attr shapes) for a request_id NEVER emitted
      # through the in-memory collector, so inspect_request must route
      # through Trace.for_request -> rehydrate_from_postgres. The model
      # event's measurements use STRING keys (the Postgres round-trip
      # leaves measurements string-keyed); coalesce_field must still read
      # them.
      request_id = Ecto.UUID.generate()
      trace_id = "trace-rehydrate-#{System.unique_integer([:positive])}"

      {:ok, _} =
        TraceRun.upsert_run(
          %{
            trace_id: trace_id,
            tenant_id: tid,
            request_id: request_id,
            run_id: request_id,
            status: "completed",
            started_at_ms: 1_000,
            completed_at_ms: 1_500,
            incoming_last_seq: 1
          },
          tenant: tid
        )

      {:ok, _} =
        TraceEvent.append_event(
          %{
            tenant_id: tid,
            trace_id: trace_id,
            seq: 1,
            at_ms: 1_000,
            source: "jido_claw",
            category: "model",
            event: "complete",
            measurements: %{"input_tokens" => 10, "output_tokens" => 20}
          },
          tenant: tid
        )

      assert {:ok, %Summary{usage: usage}} =
               Inspection.inspect_request(request_id, tenant_id: tid)

      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
    end
  end

  describe "inspect_workflow/1" do
    test "with %WorkflowRun{} struct" do
      run = %WorkflowRun{
        id: Ecto.UUID.generate(),
        name: "test-flow",
        status: :running,
        started_at: DateTime.utc_now()
      }

      assert {:ok, %Summary{input_kind: :workflow_id, workflows: [w]}} =
               Inspection.inspect_workflow(run)

      assert w.name == "test-flow"
    end

    test "with UUID string of a created run" do
      {:ok, run} =
        WorkflowRun.create(%{name: "by-id-test"})

      assert {:ok, %Summary{input_kind: :workflow_id, workflows: [w]}} =
               Inspection.inspect_workflow(run.id)

      assert w.id == run.id
    end

    test "unknown UUID returns :not_found" do
      assert {:error, :not_found} = Inspection.inspect_workflow(Ecto.UUID.generate())
    end
  end

  describe "safe-rescue behavior" do
    test "raising inside an isolated lookup does not propagate (smoke-check by invalid map input)" do
      assert {:error, :unknown_target} = Inspection.inspect_agent(%{not_a_target: true})
    end
  end
end
