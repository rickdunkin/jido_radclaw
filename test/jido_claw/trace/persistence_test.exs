defmodule JidoClaw.Trace.PersistenceTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Trace
  alias JidoClaw.Trace.Resources.{TraceEvent, TraceRun}
  alias JidoClaw.TraceTestHelpers, as: H

  setup do
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    previous_trace_cfg = Application.get_env(:jido_claw, :trace)
    Application.put_env(:jido_claw, :trace, persist_sync?: true, persist?: true)

    on_exit(fn ->
      if previous_trace_cfg do
        Application.put_env(:jido_claw, :trace, previous_trace_cfg)
      else
        Application.delete_env(:jido_claw, :trace)
      end
    end)

    :ok = H.sync_collector()
    :ok = H.sync_persistence()
    :ok
  end

  describe "round-trip" do
    test "writes trace_runs + trace_events rows on emit" do
      agent_id = "p-agent-#{System.unique_integer([:positive])}"
      request_id = "p-req-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      :telemetry.execute(
        [:jido, :ai, :request, :complete],
        %{duration_ms: 5},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      :ok = H.sync_collector()

      assert {:ok, run} = TraceRun.by_request(request_id)
      assert run != nil
      assert run.agent_id == agent_id
      assert run.status in ["completed", "running"]

      assert {:ok, events} = TraceEvent.for_trace(run.trace_id)
      assert length(events) == 2
      assert Enum.all?(events, &is_binary(&1.category))
    end
  end

  describe "ordering guarantee" do
    test "trace_events.seq increases monotonically; trace_runs reflects terminal seq" do
      agent_id = "ord-agent-#{System.unique_integer([:positive])}"
      request_id = "ord-req-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      for index <- 1..50 do
        :telemetry.execute(
          [:jido, :ai, :tool, :complete],
          %{duration_ms: 1},
          %{
            agent_id: agent_id,
            request_id: request_id,
            tool_name: "t-#{index}",
            tool_call_id: "tc-#{index}"
          }
        )
      end

      :telemetry.execute(
        [:jido, :ai, :request, :complete],
        %{duration_ms: 5},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      :ok = H.sync_collector()
      assert {:ok, run} = TraceRun.by_request(request_id)
      assert {:ok, events} = TraceEvent.for_trace(run.trace_id)

      seqs = Enum.map(events, & &1.seq)
      assert seqs == Enum.sort(seqs)
      assert run.status == "completed"
      assert run.last_seq == List.last(seqs)
    end
  end

  describe "out-of-order safety" do
    test "older snapshot upsert is a no-op when last_seq > incoming_last_seq" do
      tenant_id = "ord-skip-tenant-#{System.unique_integer([:positive])}"
      trace_id = "trace-#{System.unique_integer([:positive])}"

      {:ok, _} =
        TraceRun.upsert_run(
          %{
            trace_id: trace_id,
            tenant_id: tenant_id,
            status: "completed",
            incoming_last_seq: 7
          },
          tenant: tenant_id
        )

      # Older snapshot: smaller last_seq. Upsert_condition makes this
      # a :skipped_upsert no-op.
      assert {:ok, _} =
               TraceRun.upsert_run(
                 %{
                   trace_id: trace_id,
                   tenant_id: tenant_id,
                   status: "running",
                   incoming_last_seq: 5
                 },
                 tenant: tenant_id
               )

      assert {:ok, row} = TraceRun.by_trace_id(trace_id, tenant: tenant_id)
      assert row.status == "completed"
      assert row.last_seq == 7
    end
  end

  describe "duplicate event append idempotency" do
    test "calling append_event twice does not mutate the first persistence" do
      tenant_id = "dup-tenant-#{System.unique_integer([:positive])}"
      trace_id = "trace-dup-#{System.unique_integer([:positive])}"

      {:ok, _} =
        TraceRun.upsert_run(
          %{trace_id: trace_id, tenant_id: tenant_id, incoming_last_seq: 1},
          tenant: tenant_id
        )

      attrs = %{
        tenant_id: tenant_id,
        trace_id: trace_id,
        seq: 1,
        at_ms: 100,
        source: "jido_claw",
        category: "hook",
        event: "start",
        name: "first-write"
      }

      assert {:ok, first} = TraceEvent.append_event(attrs, tenant: tenant_id)

      # Re-emission with same (trace_id, seq) — upsert_fields: []
      # makes this a no-op; the persisted row keeps its original
      # `name`.
      assert {:ok, _} =
               TraceEvent.append_event(%{attrs | name: "should-not-overwrite"},
                 tenant: tenant_id
               )

      assert {:ok, [row]} = TraceEvent.for_trace(trace_id, tenant: tenant_id)
      assert row.id == first.id
      assert row.name == "first-write"
    end
  end

  describe "Postgres fallback on for_request/3" do
    test "returns trace after collector ring eviction" do
      previous = Application.get_env(:jido_claw, :trace)

      try do
        Application.put_env(
          :jido_claw,
          :trace,
          Keyword.merge(previous || [], max_traces: 2, persist_sync?: true, persist?: true)
        )

        :ok = restart_collector()

        target_agent = "evict-agent-#{System.unique_integer([:positive])}"
        target_req = "evict-req-#{System.unique_integer([:positive])}"

        :telemetry.execute(
          [:jido, :ai, :request, :start],
          %{},
          %{agent_id: target_agent, request_id: target_req}
        )

        :telemetry.execute(
          [:jido, :ai, :request, :complete],
          %{duration_ms: 5},
          %{agent_id: target_agent, request_id: target_req}
        )

        :ok = H.sync_collector()

        # Push >2 more traces to evict the target from the ring.
        for index <- 1..3 do
          :telemetry.execute(
            [:jido, :ai, :request, :start],
            %{},
            %{
              agent_id: "filler-#{index}",
              request_id: "filler-req-#{index}-#{System.unique_integer([:positive])}"
            }
          )
        end

        :ok = H.sync_collector()

        # In-memory ring should no longer have target_req — Postgres fallback hits.
        assert {:ok, trace} =
                 Trace.for_request({:request, target_req}, target_req)

        assert trace.request_id == target_req
        # Events have been rehydrated from trace_events.
        assert length(trace.events) >= 1
      after
        if previous do
          Application.put_env(:jido_claw, :trace, previous)
        else
          Application.delete_env(:jido_claw, :trace)
        end

        :ok = restart_collector()
      end
    end
  end

  describe "history/1" do
    test "paginates trace_runs" do
      for index <- 1..5 do
        :telemetry.execute(
          [:jido, :ai, :request, :start],
          %{},
          %{
            agent_id: "hist-agent-#{index}",
            request_id: "hist-req-#{index}-#{System.unique_integer([:positive])}"
          }
        )
      end

      :ok = H.sync_collector()

      assert {:ok, page} = Trace.history(page: [limit: 3])
      assert length(page) <= 3
    end
  end

  describe "cross-tenant isolation" do
    test "history(tenant_id: B) returns empty when only tenant A has rows" do
      tenant_a = "ten-iso-a-#{System.unique_integer([:positive])}"
      tenant_b = "ten-iso-b-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{
          agent_id: "iso-agent",
          request_id: "iso-req-#{System.unique_integer([:positive])}",
          tenant_id: tenant_a
        }
      )

      :ok = H.sync_collector()
      assert {:ok, rows_b} = Trace.history(tenant_id: tenant_b, page: [limit: 10])
      assert rows_b == []

      assert {:ok, rows_a} = Trace.history(tenant_id: tenant_a, page: [limit: 10])
      assert length(rows_a) >= 1
    end
  end

  describe "UUID fallback for unattributed traces" do
    test "two collector restarts with metadata-less emits produce distinct trace_ids" do
      previous = Application.get_env(:jido_claw, :trace)

      try do
        :telemetry.execute([:jido, :ai, :request, :start], %{}, %{})
        :ok = H.sync_collector()

        # Restart Collector — seq resets to 0
        :ok = restart_collector()

        :telemetry.execute([:jido, :ai, :request, :start], %{}, %{})
        :ok = H.sync_collector()

        # Both emits should have made unique trace_runs rows.
        assert {:ok, page} = TraceRun.recent(page: [limit: 50])

        # Different trace_ids — UUIDs collision-free even after seq reset.
        trace_ids = Enum.map(page.results, & &1.trace_id)
        assert length(trace_ids) == length(Enum.uniq(trace_ids))
      after
        if previous do
          Application.put_env(:jido_claw, :trace, previous)
        else
          Application.delete_env(:jido_claw, :trace)
        end
      end
    end
  end

  defp restart_collector do
    pid = Process.whereis(JidoClaw.Trace.Collector)

    if pid do
      ref = Process.monitor(pid)
      Supervisor.terminate_child(JidoClaw.InfraSupervisor, JidoClaw.Trace.Collector)
      Supervisor.restart_child(JidoClaw.InfraSupervisor, JidoClaw.Trace.Collector)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    wait_for_restart(20)
  end

  defp wait_for_restart(0), do: :ok

  defp wait_for_restart(retries) do
    case Process.whereis(JidoClaw.Trace.Collector) do
      nil ->
        Process.sleep(10)
        wait_for_restart(retries - 1)

      _pid ->
        :ok
    end
  end
end
