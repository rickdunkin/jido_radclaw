defmodule JidoClaw.Trace.Sink.PostgresTest do
  # The only file asserting the Postgres sink path; needs a sandbox owner
  # like persistence_test.exs because write/2 delegates to Persistence.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Trace.Event
  alias JidoClaw.Trace.Resources.TraceEvent
  alias JidoClaw.Trace.Resources.TraceRun
  alias JidoClaw.Trace.Sink.Postgres
  alias JidoClaw.TraceTestHelpers, as: H

  setup do
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)

    on_exit(fn ->
      # Drain the global Collector + Persistence before releasing the shared
      # connection — see `H.drain_trace_processes/0` for the race it closes.
      _ = H.drain_trace_processes()
      Sandbox.stop_owner(pid)
    end)

    previous_trace_cfg = Application.get_env(:jido_claw, :trace)
    Application.put_env(:jido_claw, :trace, persist_sync?: true, persist?: true)

    on_exit(fn ->
      if previous_trace_cfg do
        Application.put_env(:jido_claw, :trace, previous_trace_cfg)
      else
        Application.delete_env(:jido_claw, :trace)
      end
    end)

    :ok = H.sync_persistence()
    :ok
  end

  describe "write/2 (delegates to Trace.Persistence)" do
    test "persists a trace_runs + trace_events row" do
      trace_id = "sink-pg-#{System.unique_integer([:positive])}"
      request_id = "sink-pg-req-#{System.unique_integer([:positive])}"

      event = %Event{
        seq: 1,
        at_ms: 100,
        source: :jido_ai,
        category: :request,
        event: :start,
        status: :running,
        request_id: request_id,
        run_id: request_id,
        trace_id: trace_id,
        measurements: %{},
        metadata: %{}
      }

      trace = %JidoClaw.Trace{
        trace_id: trace_id,
        run_id: request_id,
        request_id: request_id,
        status: :running,
        started_at_ms: 100,
        events: [event],
        summary: %{}
      }

      # persist_sync?: true → the delegate blocks until the row commits.
      assert :ok = Postgres.write(event, trace)

      assert {:ok, run} = TraceRun.by_request(request_id)
      assert run != nil
      assert run.trace_id == trace_id

      assert {:ok, [row]} = TraceEvent.for_trace(trace_id)
      assert row.seq == 1
      assert row.category == "request"
    end
  end
end
