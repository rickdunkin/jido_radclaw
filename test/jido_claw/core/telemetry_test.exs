defmodule JidoClaw.TelemetryTest do
  @moduledoc """
  Pins the `event_name:` wiring on the metrics whose display name and source
  event diverge (1.2). `Telemetry.Metrics` derives a metric's event from all
  but the last name segment, so `summary("jido_claw.session.duration")` would
  listen on `[:jido_claw, :session]` — an event nothing emits. The emitters
  fire `[:jido_claw, :session, :stop]` (measurement `%{duration: …}`), so each
  divergent metric must carry an explicit `event_name:` or its LiveDashboard
  tile can never fire.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Telemetry

  defp metric_by_name(name), do: Enum.find(Telemetry.metrics(), &(&1.name == name))

  describe "metrics/0 — event_name wiring" do
    # The duration summaries carry a `unit:` conversion, so `measurement`
    # becomes a wrapper fn (not the bare `:duration`) — only the `event_name`
    # wiring is asserted here; the emitted-measurement key is covered by the
    # emit helpers themselves.
    test "session.duration listens on the session :stop event" do
      assert metric_by_name([:jido_claw, :session, :duration]).event_name ==
               [:jido_claw, :session, :stop]
    end

    test "provider.request.duration listens on the request :stop event" do
      assert metric_by_name([:jido_claw, :provider, :request, :duration]).event_name ==
               [:jido_claw, :provider, :request, :stop]
    end

    test "tool.execute.duration listens on the execute :stop event" do
      assert metric_by_name([:jido_claw, :tool, :execute, :duration]).event_name ==
               [:jido_claw, :tool, :execute, :stop]
    end

    test "cron.job.duration listens on the job :stop event" do
      assert metric_by_name([:jido_claw, :cron, :job, :duration]).event_name ==
               [:jido_claw, :cron, :job, :stop]
    end

    test "tenant.count is a last_value on the tenant :count event with the :count measurement" do
      m = metric_by_name([:jido_claw, :tenant, :count])
      assert m.event_name == [:jido_claw, :tenant, :count]
      assert m.measurement == :count
    end
  end

  describe "metrics/0 — orchestration lease counters (WS6 Phase 4)" do
    # All five lease-lifecycle events emit `%{count: 1}`, so each counter must
    # carry `measurement: :count` — the name-inferred `:total` would never fire.
    test "the five lease counters read :count off their orchestration events" do
      for event <- [:claimed, :renewed, :reclaimed, :fenced_out, :recovered] do
        metric = metric_by_name([:jido_claw, :orchestration, event, :total])
        assert metric, "missing counter for #{inspect(event)}"
        assert metric.event_name == [:jido_claw, :orchestration, event]
        assert metric.measurement == :count
      end
    end

    test "fenced_out tags :reason; recovered tags :branch" do
      assert metric_by_name([:jido_claw, :orchestration, :fenced_out, :total]).tags == [:reason]
      assert metric_by_name([:jido_claw, :orchestration, :recovered, :total]).tags == [:branch]
    end
  end
end
