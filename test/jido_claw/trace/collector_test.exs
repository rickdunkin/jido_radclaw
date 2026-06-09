defmodule JidoClaw.Trace.CollectorTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Trace
  alias JidoClaw.Trace.Collector
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

      Application.put_env(:jido_claw, :trace, max_traces: 3)
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
end
