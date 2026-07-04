defmodule JidoClaw.RouteComposer.ObserveTest do
  @moduledoc """
  AR-2 Phase 5 (§10.2) — `Observe.summarize/1` builds the seed-free observe view
  from the durable event log: the latest `route_composed` snapshot plus the
  seed-free `ran` / `latest_started_wave_index` / `wave_in_flight` folds. Covers
  both atom-keyed (synthetic) and string-keyed (JSONB-reloaded) payloads, and
  the reviewer's non-load-bearing parked-gate case (NO `wave_paused` recorded).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Observe

  defp event(kind, payload, seq), do: %{kind: kind, payload: payload, seq: seq}

  describe "summarize/1" do
    test "nil when no route_composed event exists yet" do
      assert Observe.summarize([]) == nil
      assert Observe.summarize([event(:run_started, %{}, 1)]) == nil
    end

    test "reads the LATEST route_composed snapshot (latest-wins)" do
      events = [
        event(:route_composed, %{route: ["triage"], size: 1}, 1),
        event(
          :route_composed,
          %{
            route: ["planner", "implementer"],
            size: 2,
            live: ["code"],
            available: ["plan"],
            held: %{"implementer" => "needs-tests"},
            waves: [["planner"], ["implementer"]],
            premises: %{"risk" => "low"}
          },
          2
        )
      ]

      summary = Observe.summarize(events)

      assert summary.route == ["planner", "implementer"]
      assert summary.size == 2
      assert summary.live == ["code"]
      assert summary.available == ["plan"]
      assert summary.held == %{"implementer" => "needs-tests"}
      assert summary.waves == [["planner"], ["implementer"]]
      assert summary.premises == %{"risk" => "low"}
    end

    test "ran = wave_completed stages MINUS stages_invalidated stages (seq order, sorted)" do
      events = [
        event(:route_composed, %{route: ["planner"]}, 1),
        event(:wave_completed, %{wave_index: 0, stages: ["planner"]}, 2),
        event(:wave_completed, %{wave_index: 1, stages: ["reviewer", "implementer"]}, 3),
        event(:stages_invalidated, %{stages: ["reviewer"]}, 4)
      ]

      assert Observe.summarize(events).ran == ["implementer", "planner"]
    end

    test "latest_started_wave_index is the wave_index of the latest wave_started" do
      events = [
        event(:route_composed, %{route: ["planner"]}, 1),
        event(:wave_started, %{wave_index: 0, stages: ["planner"]}, 2),
        event(:route_composed, %{route: ["implementer"]}, 3),
        event(:wave_started, %{wave_index: 1, stages: ["implementer"]}, 4)
      ]

      assert Observe.summarize(events).latest_started_wave_index == 1
    end

    test "wave_in_flight false once the latest wave_started has a matching wave_completed" do
      events = [
        event(:route_composed, %{route: ["planner"]}, 1),
        event(:wave_started, %{wave_index: 0, stages: ["planner"]}, 2),
        event(:wave_completed, %{wave_index: 0, stages: ["planner"]}, 3)
      ]

      assert Observe.summarize(events).wave_in_flight == false
    end

    # Camus C1-3: a `closed_wave_index`-bearing event CLOSES a wave that
    # deliberately never wrote `wave_completed` (`stage_infra` from the
    # wave-error lane; `stages_invalidated` from the reject-parked-gate path).
    # Without this a lane-B wave — including a terminal `review_infra_failed`
    # run — would read as in-flight forever. `stage_infra` never touches `ran`.
    test "wave_in_flight false when a stage_infra closes the wave via closed_wave_index" do
      events = [
        event(:route_composed, %{route: ["quality-reviewer"]}, 1),
        event(:wave_started, %{wave_index: 0, stages: ["quality-reviewer"]}, 2),
        event(:stage_infra, %{stages: ["quality-reviewer"], closed_wave_index: 0}, 3)
      ]

      summary = Observe.summarize(events)
      assert summary.wave_in_flight == false
      assert summary.ran == []
    end

    test "wave_in_flight false when a stages_invalidated closes the wave (string-keyed)" do
      events = [
        event(:route_composed, %{"route" => ["plan-gate"]}, 1),
        event(:wave_started, %{"wave_index" => 1, "stages" => ["plan-gate"]}, 2),
        event(:stages_invalidated, %{"stages" => ["planner"], "closed_wave_index" => 1}, 3)
      ]

      assert Observe.summarize(events).wave_in_flight == false
    end

    test "a Lane A stage_infra (no closed_wave_index) does NOT close the wave" do
      # Lane A's marker rides the same commit as its wave_completed; a synthetic
      # log with only the marker must not read the wave as closed.
      events = [
        event(:route_composed, %{route: ["quality-reviewer"]}, 1),
        event(:wave_started, %{wave_index: 0, stages: ["quality-reviewer"]}, 2),
        event(:stage_infra, %{stages: ["quality-reviewer"]}, 3)
      ]

      assert Observe.summarize(events).wave_in_flight == true
    end

    test "wave_in_flight TRUE for a parked gate even with NO wave_paused recorded" do
      # The reviewer's non-load-bearing case: a gate wave started (index 1) with
      # no wave_completed(1) and deliberately NO wave_paused — wave_in_flight is
      # derived from the missing wave_completed, so it still reads in-flight.
      events = [
        event(:route_composed, %{route: ["planner"]}, 1),
        event(:wave_started, %{wave_index: 0, stages: ["planner"]}, 2),
        event(:wave_completed, %{wave_index: 0, stages: ["planner"]}, 3),
        event(:route_composed, %{route: ["plan-gate"]}, 4),
        event(:wave_started, %{wave_index: 1, stages: ["plan-gate"]}, 5)
      ]

      refute Enum.any?(events, &(&1.kind == :wave_paused))

      summary = Observe.summarize(events)
      assert summary.latest_started_wave_index == 1
      assert summary.wave_in_flight == true
    end

    test "string-keyed (JSONB-reloaded) payloads summarize identically to atom-keyed" do
      events = [
        event(
          :route_composed,
          %{
            "route" => ["planner"],
            "size" => 1,
            "live" => ["code"],
            "available" => ["plan"],
            "held" => %{"implementer" => "needs-tests"},
            "waves" => [["planner"]],
            "dropped" => %{},
            "triggered_by" => %{},
            "premises" => %{}
          },
          1
        ),
        event(:wave_completed, %{"wave_index" => 0, "stages" => ["planner"]}, 2),
        event(:wave_started, %{"wave_index" => 1, "stages" => ["implementer"]}, 3)
      ]

      summary = Observe.summarize(events)

      assert summary.route == ["planner"]
      assert summary.ran == ["planner"]
      assert summary.live == ["code"]
      assert summary.available == ["plan"]
      assert summary.held == %{"implementer" => "needs-tests"}
      assert summary.latest_started_wave_index == 1
      # wave_started(1) with no wave_completed(1) → in flight.
      assert summary.wave_in_flight == true
    end

    test "missing snapshot fields fall back (waves/held/dropped/triggered_by/premises → maps/lists)" do
      summary = Observe.summarize([event(:route_composed, %{route: ["planner"]}, 1)])

      assert summary.route == ["planner"]
      assert summary.waves == []
      assert summary.held == %{}
      assert summary.dropped == %{}
      assert summary.triggered_by == %{}
      assert summary.premises == %{}
      assert summary.live == []
      assert summary.available == []
      assert summary.ran == []
      assert summary.size == nil
      assert summary.latest_started_wave_index == nil
      assert summary.wave_in_flight == false
    end
  end
end
