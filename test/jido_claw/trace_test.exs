defmodule JidoClaw.TraceTest do
  # The Collector is a process-global singleton; concurrent tests would
  # see each other's events.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Jido.Tracing.Context, as: TracingContext
  alias Jido.Tracing.Trace, as: TracingTrace
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Reasoning.Telemetry, as: ReasoningTelemetry
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Trace
  alias JidoClaw.Trace.Collector
  alias JidoClaw.TraceTestHelpers, as: H
  alias JidoClaw.Workspaces.Workspace

  setup do
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)

    # Disable persistence in this file — these tests assert on the
    # in-memory ring only, and an async Persistence write outlasting
    # the sandbox owner would leak Postgrex connection errors.
    previous_trace_cfg = Application.get_env(:jido_claw, :trace)

    Application.put_env(
      :jido_claw,
      :trace,
      Keyword.merge(previous_trace_cfg || [], persist?: false)
    )

    on_exit(fn ->
      # Drain the Collector THEN Persistence before the sandbox owner exits.
      # The global Collector borrows the shared connection for best-effort
      # durable tenant lookups during ingest, so an un-drained event (e.g.
      # the reasoning canonical-path test emits + asserts but never calls
      # sync_collector) leaves a lookup query in flight that races stop_owner.
      _ = H.drain_trace_processes()

      if previous_trace_cfg do
        Application.put_env(:jido_claw, :trace, previous_trace_cfg)
      else
        Application.delete_env(:jido_claw, :trace)
      end

      Sandbox.stop_owner(pid)
    end)

    # Drain any leftover events before each test so previous-test seq
    # leaks don't pollute index assertions.
    :ok = H.sync_collector()
    :ok
  end

  describe "normalize + ingest" do
    test "normalizes Jido.AI telemetry into ordered events with categories" do
      agent_id = unique_id("agent")
      request_id = unique_id("req")
      run_id = unique_id("run")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{duration_ms: 0},
        %{
          agent_id: agent_id,
          request_id: request_id,
          run_id: run_id,
          jido_trace_id: "trace-#{request_id}",
          jido_span_id: "span-root",
          query: "do not store this prompt",
          api_key: "secret"
        }
      )

      :telemetry.execute(
        [:jido, :ai, :llm, :complete],
        %{duration_ms: 12, input_tokens: 5, output_tokens: 7},
        %{
          agent_id: agent_id,
          request_id: request_id,
          run_id: run_id,
          model: "anthropic:test",
          llm_call_id: "llm-1"
        }
      )

      :telemetry.execute(
        [:jido, :ai, :tool, :complete],
        %{duration_ms: 3},
        %{
          agent_id: agent_id,
          request_id: request_id,
          run_id: run_id,
          tool_name: "add_numbers",
          tool_call_id: "tool-1"
        }
      )

      :telemetry.execute(
        [:jido, :ai, :request, :complete],
        %{duration_ms: 20},
        %{agent_id: agent_id, request_id: request_id, run_id: run_id}
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert trace.agent_id == agent_id
      assert trace.request_id == request_id
      assert trace.run_id == run_id
      assert trace.status == :completed
      assert Enum.map(trace.events, & &1.category) == [:request, :model, :tool, :request]

      first = hd(trace.events)
      assert first.metadata.query == "[OMITTED]"
      assert first.metadata.api_key == "[REDACTED]"

      assert {:ok, spans} = Trace.spans(trace)
      assert Enum.any?(spans, &(&1.category == :tool and &1.name == "add_numbers"))
    end

    test "sanitizes :params in metadata" do
      agent_id = unique_id("params-agent")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :tool, :execute, :start],
        %{},
        %{
          agent_id: agent_id,
          request_id: request_id,
          tool_name: "echo",
          params: %{should_be: "omitted", token: "x"}
        }
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      first = hd(trace.events)
      assert first.metadata.params == "[OMITTED]"
    end

    test "value-scrubs an embedded secret in a non-omitted metadata string" do
      agent_id = unique_id("scrub-agent")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{
          agent_id: agent_id,
          request_id: request_id,
          note: "Bearer sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA"
        }
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      first = hd(trace.events)
      # `note` is neither omitted nor key-redacted, yet the embedded key is gone.
      refute first.metadata.note =~ "sk-ant-api03"
      assert first.metadata.note =~ "[REDACTED"
    end
  end

  describe "schema_version stamp" do
    test "schema_version/0 is 1 and every ingested event carries it" do
      agent_id = unique_id("schema-agent")
      request_id = unique_id("req")

      assert Trace.Event.schema_version() == 1

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      :telemetry.execute(
        [:jido, :ai, :llm, :complete],
        %{duration_ms: 1, input_tokens: 1, output_tokens: 1},
        %{
          agent_id: agent_id,
          request_id: request_id,
          run_id: request_id,
          model: "anthropic:test",
          llm_call_id: "llm-1"
        }
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert trace.events != []
      assert Enum.all?(trace.events, &(&1.schema_version == 1))
    end
  end

  describe "spans/2" do
    test "groups events by category + correlation key" do
      agent_id = unique_id("span-agent")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :llm, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, llm_call_id: "llm-A"}
      )

      :telemetry.execute(
        [:jido, :ai, :llm, :complete],
        %{duration_ms: 5},
        %{agent_id: agent_id, request_id: request_id, llm_call_id: "llm-A"}
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert {:ok, spans} = Trace.spans(trace)
      assert [span] = spans
      assert span.category == :model
      assert span.status == :completed
    end
  end

  describe "latest/2 + list/2" do
    test "returns latest and list traces for an agent id" do
      agent_id = unique_id("latest-agent")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.latest(agent_id)
      assert trace.request_id == request_id

      assert {:ok, traces} = Trace.list(agent_id)
      assert Enum.any?(traces, &(&1.request_id == request_id))
    end
  end

  describe "bounded retention" do
    test "evicts oldest beyond max_traces" do
      agent_id = unique_id("retention-agent")

      for index <- 1..105 do
        request_id = "#{agent_id}-req-#{index}"

        :telemetry.execute(
          [:jido, :ai, :request, :start],
          %{},
          %{agent_id: agent_id, request_id: request_id, run_id: request_id}
        )
      end

      :ok = H.sync_collector()
      assert {:ok, traces} = Trace.list(agent_id)
      assert Enum.count(traces) <= 100
      refute Enum.any?(traces, &(&1.request_id == "#{agent_id}-req-1"))
    end

    test "evicts oldest events beyond max_events_per_trace" do
      agent_id = unique_id("event-evict")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      # 304 more (305 total) — the first should evict at 300.
      for index <- 1..304 do
        :telemetry.execute(
          [:jido, :ai, :tool, :complete],
          %{duration_ms: 1},
          %{
            agent_id: agent_id,
            request_id: request_id,
            tool_name: "t-#{index}",
            tool_call_id: "tool-#{index}"
          }
        )
      end

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert Enum.count(trace.events) == 300
      # The earliest event was a request:start; it should have been pushed out.
      refute Enum.any?(trace.events, &(&1.category == :request and &1.event == :start))
    end
  end

  describe "for_request/3" do
    test "returns trace when agent_id is nil" do
      request_id = unique_id("req-noagent")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{request_id: request_id, run_id: request_id}
      )

      :ok = H.sync_collector()

      assert {:ok, trace} = Trace.for_request({:request, request_id}, request_id)
      assert trace.request_id == request_id
    end
  end

  describe "lazy agent_id backfill" do
    test "agent_id populated when a later event carries it" do
      request_id = unique_id("req-lazy")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{request_id: request_id, run_id: request_id}
      )

      agent_id = unique_id("backfilled-agent")

      :telemetry.execute(
        [:jido, :ai, :tool, :complete],
        %{duration_ms: 1},
        %{
          agent_id: agent_id,
          request_id: request_id,
          tool_name: "t",
          tool_call_id: "c"
        }
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request({:request, request_id}, request_id)
      assert trace.agent_id == agent_id
    end
  end

  describe "configuration" do
    test "enabled?: false short-circuits ingest" do
      previous = Application.get_env(:jido_claw, :trace)

      on_exit(fn ->
        Application.put_env(:jido_claw, :trace, previous || [])
        :ok = restart_collector()
      end)

      Application.put_env(:jido_claw, :trace, enabled?: false)
      :ok = restart_collector()

      agent_id = unique_id("disabled-agent")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id}
      )

      :ok = H.sync_collector()
      assert {:error, :not_found} = Trace.for_request(agent_id, request_id)
    end
  end

  describe "Trace.emit/3" do
    test "round-trips through Jido.Observe.emit_event/3 with correlation IDs" do
      agent_id = unique_id("emit-agent")
      request_id = unique_id("req")

      # Seed a Jido tracing context so emit_event/3 enriches with
      # jido_trace_id, jido_span_id, jido_parent_span_id.
      Process.put({:jido, :trace_context}, TracingTrace.new_root())

      try do
        Trace.emit(:hook, %{
          event: :start,
          hook: "trace-emit-hook",
          agent_id: agent_id,
          request_id: request_id
        })

        :ok = H.sync_collector()
        assert {:ok, trace} = Trace.for_request(agent_id, request_id)
        event = Enum.find(trace.events, &(&1.category == :hook))
        assert event.event == :start
        assert is_binary(event.trace_id)
      after
        TracingContext.clear()
      end
    end

    test "argument-order regression guard — metadata keys are not measurements" do
      agent_id = unique_id("emit-order-agent")
      request_id = unique_id("req")

      Trace.emit(:reasoning, %{
        event: :start,
        phase: :strategy,
        name: "react",
        agent_id: agent_id,
        request_id: request_id
      })

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      event = Enum.find(trace.events, &(&1.category == :reasoning))
      assert event != nil
      assert event.event == :start
      assert event.phase == :strategy
      assert event.source == :jido_claw
    end
  end

  describe "terminal status" do
    test "derives :failed status from request:failed" do
      agent_id = unique_id("status-agent")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id}
      )

      :telemetry.execute(
        [:jido, :ai, :request, :failed],
        %{},
        %{agent_id: agent_id, request_id: request_id}
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert trace.status == :failed
    end

    test "derives :cancelled status from request:cancelled" do
      agent_id = unique_id("cancel-agent")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id}
      )

      :telemetry.execute(
        [:jido, :ai, :request, :cancelled],
        %{},
        %{agent_id: agent_id, request_id: request_id}
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert trace.status == :cancelled
    end
  end

  describe "concurrent emit" do
    test "two agents don't collide on indexes" do
      a = unique_id("agent-a")
      b = unique_id("agent-b")
      r_a = unique_id("req")
      r_b = unique_id("req")

      tasks =
        for {agent, req} <- [{a, r_a}, {b, r_b}] do
          Task.async(fn ->
            for _ <- 1..20 do
              :telemetry.execute(
                [:jido, :ai, :tool, :complete],
                %{duration_ms: 1},
                %{
                  agent_id: agent,
                  request_id: req,
                  tool_name: "t",
                  tool_call_id: "c-#{System.unique_integer([:positive])}"
                }
              )
            end
          end)
        end

      Enum.each(tasks, &Task.await/1)
      :ok = H.sync_collector()

      assert {:ok, trace_a} = Trace.for_request(a, r_a)
      assert {:ok, trace_b} = Trace.for_request(b, r_b)
      assert trace_a.agent_id == a
      assert trace_b.agent_id == b
    end
  end

  describe "tenant scoping (strict)" do
    test "stamps tenant_id from RequestCorrelation.Cache on first event" do
      tenant_id = "tenant-#{System.unique_integer([:positive])}"
      agent_id = unique_id("tenant-agent")
      request_id = unique_id("req")

      :ok =
        RequestCorrelation.Cache.put(request_id, %{
          session_id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          workspace_id: nil,
          user_id: nil
        })

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id}
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert trace.tenant_id == tenant_id
    after
      :ok = RequestCorrelation.Cache.clear()
    end

    test "latest(agent_id, tenant_id: B) returns :not_found when only tenant-A traces exist" do
      tenant_a = "tenant-a-#{System.unique_integer([:positive])}"
      tenant_b = "tenant-b-#{System.unique_integer([:positive])}"
      agent_id = unique_id("dual-tenant-agent")
      request_id = unique_id("req")

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, tenant_id: tenant_a}
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.latest(agent_id, tenant_id: tenant_a)
      assert trace.tenant_id == tenant_a

      assert {:error, :not_found} = Trace.latest(agent_id, tenant_id: tenant_b)
    end

    test "strict filter happens BEFORE latest pick" do
      tenant_a = "tenant-a-#{System.unique_integer([:positive])}"
      tenant_b = "tenant-b-#{System.unique_integer([:positive])}"
      agent_id = unique_id("mixed-tenant-agent")

      req_a = unique_id("req-a")
      req_b = unique_id("req-b")

      # Order matters: req_a (tenant_a) first, then req_b (tenant_b)
      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: req_a, tenant_id: tenant_a}
      )

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: req_b, tenant_id: tenant_b}
      )

      :ok = H.sync_collector()
      # Without filter, latest is req_b (tenant_b)
      assert {:ok, %{request_id: ^req_b}} = Trace.latest(agent_id)
      # With tenant_a filter, latest must be req_a (NOT fall through to req_b)
      assert {:ok, %{request_id: ^req_a, tenant_id: ^tenant_a}} =
               Trace.latest(agent_id, tenant_id: tenant_a)
    end

    test "latest/2 stays insertion-ordered once the Collector holds many traces" do
      # Regression: the per-agent index must preserve insertion order. The
      # 2-trace case above never grows the Collector's `traces` map past
      # Erlang's ~32-entry HAMT threshold, so it can't catch the bug where
      # `rebuild_indexes/1` iterated the (hash-ordered) `traces` map and
      # made `latest/2` return a stale, hash-arbitrary trace for a busy
      # agent. Emit >32 distinct requests for one agent and assert the
      # newest still wins. (max_traces is 100, so none are evicted.)
      agent_id = unique_id("busy-agent")

      # Emit 40 distinct requests for one agent (oldest first); the reduce's
      # final value is the newest request_id.
      newest =
        Enum.reduce(1..40, nil, fn i, _prev ->
          request_id = unique_id("req-#{i}")

          :telemetry.execute(
            [:jido, :ai, :request, :start],
            %{},
            %{agent_id: agent_id, request_id: request_id}
          )

          request_id
        end)

      :ok = H.sync_collector()

      assert {:ok, %{request_id: ^newest}} = Trace.latest(agent_id)
    end

    test "tenant_id resolves from durable RequestCorrelation when Cache is empty" do
      tenant_id = "tenant-durable-#{System.unique_integer([:positive])}"
      agent_id = unique_id("durable-agent")
      request_id = unique_id("req-durable")

      session = seed_session_for(tenant_id)
      :ok = RequestCorrelation.Cache.clear()

      {:ok, _} =
        RequestCorrelation.register(%{
          request_id: request_id,
          session_id: session.id,
          tenant_id: tenant_id
        })

      :ok = RequestCorrelation.Cache.delete(request_id)

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id}
      )

      :ok = H.sync_collector()
      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert trace.tenant_id == tenant_id
    end

    test "list({:tenant, tid}) returns only that tenant's traces" do
      tenant_a = "tenant-list-a-#{System.unique_integer([:positive])}"
      tenant_b = "tenant-list-b-#{System.unique_integer([:positive])}"

      for tid <- [tenant_a, tenant_a, tenant_b] do
        :telemetry.execute(
          [:jido, :ai, :request, :start],
          %{},
          %{
            agent_id: "tenant-list-agent-#{System.unique_integer([:positive])}",
            request_id: "req-#{System.unique_integer([:positive])}",
            tenant_id: tid
          }
        )
      end

      :ok = H.sync_collector()
      assert {:ok, traces_a} = Trace.list({:tenant, tenant_a})
      assert {:ok, traces_b} = Trace.list({:tenant, tenant_b})
      assert [_, _] = traces_a
      assert [_] = traces_b
      assert Enum.all?(traces_a, &(&1.tenant_id == tenant_a))
      assert Enum.all?(traces_b, &(&1.tenant_id == tenant_b))
    end
  end

  describe "reasoning canonical path" do
    test "Reasoning.Telemetry emits a single canonical trace event per start/stop" do
      handler_id = "reasoning-canonical-#{System.unique_integer([:positive])}"
      ref = make_ref()
      test_pid = self()

      try do
        :telemetry.attach(
          handler_id,
          [:jido_claw, :reasoning, :event],
          fn _, _, metadata, _ -> send(test_pid, {ref, metadata.event}) end,
          nil
        )

        ReasoningTelemetry.with_outcome(
          "cot",
          "canonical-path prompt",
          [execution_kind: :strategy_run, request_id: unique_id("req")],
          fn -> {:ok, %{}} end
        )

        assert_receive {^ref, :start}
        assert_receive {^ref, :stop}
        # Ensure no legacy 4-segment events leak through.
        refute_received {^ref, _other}
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "delta filter" do
    test "[:jido, :ai, :llm, :delta] is not attached in v1" do
      agent_id = unique_id("delta-agent")
      request_id = unique_id("req")

      for _ <- 1..100 do
        :telemetry.execute(
          [:jido, :ai, :llm, :delta],
          %{},
          %{agent_id: agent_id, request_id: request_id, llm_call_id: "llm"}
        )
      end

      :ok = H.sync_collector()
      assert {:error, :not_found} = Trace.for_request(agent_id, request_id)
    end
  end

  # -------------------------------------------------------------------------
  # helpers
  # -------------------------------------------------------------------------

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp seed_session_for(tenant_id) do
    {:ok, _} = Tenant.ensure(tenant_id)
    actor = %{user_id: tenant_id, tenant_id: tenant_id}

    {:ok, workspace} =
      Workspace.register(
        %{name: "ws-#{System.unique_integer([:positive])}", path: "/tmp/#{tenant_id}"},
        tenant: tenant_id,
        actor: actor
      )

    {:ok, session} =
      Session.start(
        %{
          workspace_id: workspace.id,
          kind: :api,
          external_id: "ext-#{System.unique_integer([:positive])}",
          started_at: DateTime.utc_now()
        },
        tenant: tenant_id,
        actor: actor
      )

    session
  end

  defp restart_collector do
    case Process.whereis(Collector) do
      nil ->
        case Collector.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      pid ->
        ref = Process.monitor(pid)
        Supervisor.terminate_child(JidoClaw.InfraSupervisor, Collector)
        Supervisor.restart_child(JidoClaw.InfraSupervisor, Collector)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

        :ok
    end
  end
end
