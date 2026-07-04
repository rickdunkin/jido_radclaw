defmodule JidoClaw.Trace.CollectorTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Trace
  alias JidoClaw.Trace.Collector
  alias JidoClaw.Trace.Policy
  alias JidoClaw.Trace.Sink
  alias JidoClaw.TraceTestHelpers, as: H

  setup do
    previous_trace_cfg = Application.get_env(:jido_claw, :trace)

    Application.put_env(
      :jido_claw,
      :trace,
      Keyword.merge(previous_trace_cfg || [], persist?: false)
    )

    on_exit(fn ->
      _ = H.sync_persistence()

      if previous_trace_cfg do
        Application.put_env(:jido_claw, :trace, previous_trace_cfg)
      else
        Application.delete_env(:jido_claw, :trace)
      end
    end)

    :ok = H.sync_collector()
    :ok
  end

  describe "by_tenant index" do
    test "rebuilds correctly after LRU eviction" do
      previous = Application.get_env(:jido_claw, :trace)

      on_exit(fn ->
        Application.put_env(:jido_claw, :trace, previous || [])
        :ok = restart_collector()
      end)

      Application.put_env(:jido_claw, :trace, Keyword.merge(previous || [], max_traces: 3))
      :ok = restart_collector()

      tenant_id = "tenant-#{System.unique_integer([:positive])}"

      for index <- 1..5 do
        :telemetry.execute(
          [:jido, :ai, :request, :start],
          %{},
          %{
            agent_id: "by-tenant-agent",
            request_id: "req-#{index}-#{System.unique_integer([:positive])}",
            tenant_id: tenant_id
          }
        )
      end

      :ok = H.sync_collector()
      assert {:ok, traces} = Trace.list({:tenant, tenant_id})
      assert [_, _, _] = traces
      # Every retained trace should still carry the tenant stamp.
      assert Enum.all?(traces, &(&1.tenant_id == tenant_id))
    end
  end

  describe "composer trace channel (camus C1-3 post-review P2)" do
    test "[:jido_claw, :composer, :event] is attached and a review_infra emit is retrievable by tenant" do
      # The direct pin of the missed attach: the collector must subscribe the
      # composer channel (pre-fix @jido_claw_events had no :composer entry and
      # every composer trace event was silently dropped).
      assert :telemetry.list_handlers([:jido_claw, :composer, :event]) != []

      # End-to-end through the production emit shape (route_composer.ex
      # `emit_infra_observability/3`, incl. the tenant_id stamp that makes the
      # per-run timeline reachable via `Trace.list({:tenant, …})` — the by_run
      # index has no public reader). Unique ids keep this collision-proof
      # against prior in-memory entries from other trace tests.
      tenant_id = "composer-tenant-#{System.unique_integer([:positive])}"
      run_id = "composer-run-#{System.unique_integer([:positive])}"

      Trace.emit(
        :composer,
        %{
          event: :review_infra,
          run_id: run_id,
          parent_run_id: run_id,
          stage: "quality-reviewer",
          reason: "wave_execution_failed: observe timeout",
          wave_index: 0,
          lane: :output,
          tenant_id: tenant_id
        },
        %{count: 1}
      )

      :ok = H.sync_collector()

      assert {:ok, traces} = Trace.list({:tenant, tenant_id})

      found =
        traces
        |> Enum.flat_map(& &1.events)
        |> Enum.filter(
          &(&1.category == :composer and &1.event == :review_infra and &1.run_id == run_id)
        )

      assert [_event] = found
      # The trace carrying the event is tenant-stamped (the reachability fix).
      assert Enum.all?(traces, &(&1.tenant_id == tenant_id))
    end
  end

  describe "robustness" do
    test "handles missing optional metadata fields without crashing" do
      :telemetry.execute([:jido, :ai, :request, :start], %{}, %{})
      :ok = H.sync_collector()
      # The Collector should still be alive after a metadata-light event.
      assert Process.alive?(Process.whereis(Collector))
    end
  end

  describe "native [:jido, :ai, :output, *] events" do
    test "captures :start as running, :validated as completed" do
      request_id = "out-req-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:jido, :ai, :output, :start],
        %{},
        %{request_id: request_id, agent_id: "out-agent"}
      )

      :telemetry.execute(
        [:jido, :ai, :output, :validated],
        %{},
        %{request_id: request_id, agent_id: "out-agent"}
      )

      :ok = H.sync_collector()

      assert {:ok, trace} = Trace.for_request(%{agent_id: "out-agent"}, request_id)
      output_events = Enum.filter(trace.events, &(&1.category == :output))
      assert [start_event, validated_event] = Enum.sort_by(output_events, & &1.seq)
      assert start_event.event == :start
      assert start_event.status == :running

      assert validated_event.event == :validated
      assert validated_event.status == :completed
    end

    test "captures :repair as running, :error as failed" do
      request_id = "out-fail-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:jido, :ai, :output, :repair],
        %{},
        %{request_id: request_id, agent_id: "out-agent-2"}
      )

      :telemetry.execute(
        [:jido, :ai, :output, :error],
        %{},
        %{request_id: request_id, agent_id: "out-agent-2"}
      )

      :ok = H.sync_collector()

      assert {:ok, trace} = Trace.for_request(%{agent_id: "out-agent-2"}, request_id)
      output_events = Enum.filter(trace.events, &(&1.category == :output))
      assert [repair_event, error_event] = Enum.sort_by(output_events, & &1.seq)
      assert repair_event.event == :repair
      assert repair_event.status == :running

      assert error_event.event == :error
      assert error_event.status == :failed
    end
  end

  describe "sampling" do
    test "sample_rate 1.0 keeps all traces (baseline)" do
      with_trace_config([sample_rate: 1.0, persist?: false], fn ->
        request_id = "samp-keep-#{System.unique_integer([:positive])}"

        :telemetry.execute(
          [:jido, :ai, :request, :start],
          %{},
          %{agent_id: "samp-agent", request_id: request_id}
        )

        :ok = H.sync_collector()
        assert {:ok, _} = Trace.for_request(%{agent_id: "samp-agent"}, request_id)
      end)
    end

    test "sample_rate 0.0 drops all traces" do
      with_trace_config([sample_rate: 0.0, persist?: false], fn ->
        request_id = "samp-drop-#{System.unique_integer([:positive])}"

        :telemetry.execute(
          [:jido, :ai, :request, :start],
          %{},
          %{agent_id: "samp-agent", request_id: request_id}
        )

        :ok = H.sync_collector()
        assert {:error, :not_found} = Trace.for_request(%{agent_id: "samp-agent"}, request_id)
      end)
    end

    test "mid-rate keeps each request whole-or-not, matching Policy.keep_trace?" do
      with_trace_config([sample_rate: 0.5, persist?: false], fn ->
        policy = %{Policy.default() | sample_rate: 0.5}

        for i <- 1..40 do
          request_id = "samp-mid-#{i}-#{System.unique_integer([:positive])}"

          :telemetry.execute(
            [:jido, :ai, :request, :start],
            %{},
            %{agent_id: "samp-mid-agent", request_id: request_id}
          )

          :telemetry.execute(
            [:jido, :ai, :tool, :complete],
            %{duration_ms: 1},
            %{
              agent_id: "samp-mid-agent",
              request_id: request_id,
              tool_name: "t",
              tool_call_id: "c-#{i}"
            }
          )

          :ok = H.sync_collector()

          # Both events share key {:request, request_id}, so the trace is
          # wholly kept (both events) or wholly dropped — never partial.
          expected_keep = Policy.keep_trace?(policy, {:request, request_id})

          case Trace.for_request(%{agent_id: "samp-mid-agent"}, request_id) do
            {:ok, trace} ->
              assert expected_keep, "kept a trace the policy would drop"
              # request:start + tool:complete, both kept (same trace key).
              assert [_, _] = trace.events

            {:error, :not_found} ->
              refute expected_keep, "dropped a trace the policy would keep"
          end
        end
      end)
    end
  end

  describe "sink selection" do
    test "routes writes to the configured InMemory sink (Postgres untouched)" do
      with_trace_config([sink: Sink.InMemory, persist?: true, sample_rate: 1.0], fn ->
        :ok = Sink.InMemory.reset()
        request_id = "sink-sel-#{System.unique_integer([:positive])}"

        :telemetry.execute(
          [:jido, :ai, :request, :start],
          %{},
          %{agent_id: "sink-sel-agent", request_id: request_id}
        )

        # The InMemory write/2 is an async cast one hop past the collector,
        # so the collector barrier alone is not enough.
        :ok = H.sync_collector()
        :ok = H.sync_sink()

        written = Sink.InMemory.written(request_id)
        assert written != []
        assert Enum.all?(written, fn {_event, trace} -> trace.trace_id == request_id end)
      end)

      :ok = Sink.InMemory.reset()
    end
  end

  describe "crash recovery" do
    test "Collector survives a crash without duplicate telemetry handlers" do
      pid = Process.whereis(Collector)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        1_000 -> flunk("Collector did not exit")
      end

      :ok = wait_for_restart(20)

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: "recovered", request_id: "recovered-req"}
      )

      :ok = H.sync_collector()
      assert {:ok, _trace} = Trace.for_request("recovered", "recovered-req")
    end
  end

  # Sampling + sink are snapshotted at Collector init, so a config change
  # only takes effect after a restart (same pattern the max_traces test
  # uses). persist? stays a live read and rides along here too.
  defp with_trace_config(overrides, fun) do
    previous = Application.get_env(:jido_claw, :trace)
    Application.put_env(:jido_claw, :trace, Keyword.merge(previous || [], overrides))
    :ok = restart_collector()

    try do
      fun.()
    after
      if previous do
        Application.put_env(:jido_claw, :trace, previous)
      else
        Application.delete_env(:jido_claw, :trace)
      end

      :ok = restart_collector()
    end
  end

  defp restart_collector do
    pid = Process.whereis(Collector)

    if pid do
      ref = Process.monitor(pid)
      Supervisor.terminate_child(JidoClaw.InfraSupervisor, Collector)
      Supervisor.restart_child(JidoClaw.InfraSupervisor, Collector)

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
    case Process.whereis(Collector) do
      nil ->
        Process.sleep(10)
        wait_for_restart(retries - 1)

      _pid ->
        :ok
    end
  end

  describe "AR-2 Phase 2b — sensitive digest (sink vi)" do
    test "a marked request_id redacts EVERY metadata-derived column (P1a)" do
      request_id = "trace-marked-#{System.unique_integer([:positive])}"
      secret = "ZZTRACESECRETZZ-#{System.unique_integer([:positive])}"
      mark(request_id, true)

      # Plant the secret in each metadata-derived sink: agent_id (→ name),
      # trace_id, span_id, parent_span_id, plus a phase + free metadata/measurements.
      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{secret_measure: 99},
        %{
          agent_id: secret,
          request_id: request_id,
          trace_id: secret,
          span_id: secret,
          parent_span_id: secret,
          phase: :reviewing,
          secret_field: secret
        }
      )

      :ok = H.sync_collector()

      assert {:ok, trace} = Trace.for_request(%{agent_id: "ignored"}, request_id)
      [event | _] = trace.events

      # The trusted correlation key survives; every metadata-derived column is
      # collapsed to it, redacted, or dropped.
      assert event.request_id == request_id
      assert event.name == "[composer-sensitive:redacted]"
      assert event.phase == nil
      assert event.trace_id == request_id
      assert event.run_id == request_id
      assert event.span_id == nil
      assert event.parent_span_id == nil
      assert event.metadata == %{"redacted" => true}
      assert event.measurements == %{"redacted" => true}
      refute inspect(event) =~ secret
    end

    test "a marked span DROPS span_id/parent_span_id even when hex/UUID-shaped (no shape-gate leak)" do
      request_id = "trace-marked-hex-#{System.unique_integer([:positive])}"
      # An all-hex value that would have passed a `[0-9a-f]{8,64}` shape gate —
      # a sensitive value can be hex (a hash, a hex token). Both span ids are
      # metadata-derived with no trusted provenance, so both are dropped.
      hex_secret = "0123456789abcdef0123456789abcdef"
      mark(request_id, true)

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{
          agent_id: "marked-agent",
          request_id: request_id,
          span_id: hex_secret,
          parent_span_id: Ash.UUID.generate()
        }
      )

      :ok = H.sync_collector()

      assert {:ok, trace} = Trace.for_request(%{agent_id: "ignored"}, request_id)
      [event | _] = trace.events
      # No metadata-derived span id survives on a marked span, regardless of shape.
      assert event.span_id == nil
      assert event.parent_span_id == nil
      refute inspect(event) =~ hex_secret
    end

    test "an unmarked request_id passes name + trace_id + metadata through (control)" do
      request_id = "trace-unmarked-#{System.unique_integer([:positive])}"
      secret = "ZZTRACEKEEPZZ-#{System.unique_integer([:positive])}"
      mark(request_id, false)

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{
          agent_id: secret,
          request_id: request_id,
          trace_id: secret,
          span_id: secret,
          kept_field: secret
        }
      )

      :ok = H.sync_collector()

      assert {:ok, trace} = Trace.for_request(%{agent_id: "ignored"}, request_id)
      [event | _] = trace.events
      refute event.metadata == %{"redacted" => true}
      assert event.name == secret
      assert event.trace_id == secret
      # Unmarked keeps span_id — the drop is :marked-only.
      assert event.span_id == secret
      assert inspect(event.metadata) =~ secret
    end

    test "an unknown request_id (no correlation row) passes through — fail-open" do
      request_id = "trace-unknown-#{System.unique_integer([:positive])}"
      secret = "ZZTRACEUNKNOWNZZ-#{System.unique_integer([:positive])}"
      # No cache entry, no durable row → :unknown → NOT digested.

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: secret, request_id: request_id, trace_id: secret, kept_field: secret}
      )

      :ok = H.sync_collector()

      assert {:ok, trace} = Trace.for_request(%{agent_id: "ignored"}, request_id)
      [event | _] = trace.events
      refute event.metadata == %{"redacted" => true}
      assert event.name == secret
      assert event.trace_id == secret
      assert inspect(event.metadata) =~ secret
    end
  end

  defp mark(request_id, marked?) do
    Cache.put(request_id, %{
      session_id: nil,
      tenant_id: "trace-tenant",
      workspace_id: nil,
      user_id: nil,
      sanitize_sensitive_context: marked?
    })
  end
end
