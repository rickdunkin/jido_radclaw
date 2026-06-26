defmodule JidoClaw.RouteComposer.LoopTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.Loop
  alias JidoClaw.RouteComposer.TestFixtures

  describe "dispatch_cohort/2" do
    test "first wave minus ran that is non-empty" do
      display = %{waves: [["planner"], ["approver", "implementer"]]}
      assert Loop.dispatch_cohort(display, MapSet.new()) == ["planner"]
    end

    test "skips a fully-ran wave, picks the next non-empty cohort" do
      display = %{waves: [["planner"], ["approver", "implementer"]]}
      assert Loop.dispatch_cohort(display, MapSet.new(["planner"])) == ["approver", "implementer"]
    end

    test "filters ran members within a wave" do
      display = %{waves: [["approver", "implementer"]]}
      assert Loop.dispatch_cohort(display, MapSet.new(["approver"])) == ["implementer"]
    end

    test "nil when nothing unrun remains" do
      display = %{waves: [["planner"]]}
      assert Loop.dispatch_cohort(display, MapSet.new(["planner"])) == nil
    end
  end

  describe "split_solo_gate/2 (Phase 4b)" do
    setup do
      %{
        catalog: TestFixtures.gate_fixture_catalog(),
        # A two-gate-plus-worker catalog for the multi-gate backstop cases (the
        # shipped catalog has only one gate); `split_solo_gate` reads only `unit`.
        multi_gate: %{
          "gate-a" => TestFixtures.stage(name: "gate-a", unit: {:gate, "a"}),
          "gate-b" => TestFixtures.stage(name: "gate-b", unit: {:gate, "b"}),
          "worker" => TestFixtures.stage(name: "worker", unit: {:worker_template, "coder"})
        }
      }
    end

    test "peels a gate out of a mixed cohort", %{catalog: catalog} do
      assert Loop.split_solo_gate(["plan-gate", "implementer"], catalog) == ["plan-gate"]
    end

    test "passes an already-solo gate through", %{catalog: catalog} do
      assert Loop.split_solo_gate(["plan-gate"], catalog) == ["plan-gate"]
    end

    test "passes a worker-only cohort through unchanged", %{catalog: catalog} do
      assert Loop.split_solo_gate(["planner"], catalog) == ["planner"]
    end

    test "passes a multi-gate cohort through unchanged (so the WaveBuilder backstop rejects it)",
         %{multi_gate: catalog} do
      # >1 gate must NOT peel to a lone gate (the buggy `[gate | _]` did); it passes
      # through so WaveBuilder's `:gate_must_be_solo_wave` backstop rejects it.
      assert Loop.split_solo_gate(["gate-a", "gate-b"], catalog) == ["gate-a", "gate-b"]
    end

    test "passes a multi-gate + worker cohort through unchanged", %{multi_gate: catalog} do
      assert Loop.split_solo_gate(["gate-a", "gate-b", "worker"], catalog) ==
               ["gate-a", "gate-b", "worker"]
    end
  end

  describe "terminal/2 + lenses_clean?/3" do
    setup do
      %{catalog: TestFixtures.phase1_catalog()}
    end

    test "converged: nothing held and every ran lens clean", %{catalog: catalog} do
      state = %{
        catalog: catalog,
        ran: MapSet.new(["quality-reviewer", "security-reviewer"]),
        live: MapSet.new(["clean:quality", "clean:security"])
      }

      assert Loop.terminal(%{held: %{}}, state) == :converged
    end

    test "not_converged: a ran lens still has open findings (the fixer-less terminal)", %{
      catalog: catalog
    } do
      # `Loop.terminal/2` is the pure FINAL classifier; the AR-4 fix loop (re-firing
      # the fixer on open findings) runs in the composer BEFORE this is reached, so a
      # lens with open findings reaches here only on a fixer-less path (phase1_catalog
      # has no fixer — the `sketch-review` shape).
      state = %{
        catalog: catalog,
        ran: MapSet.new(["quality-reviewer"]),
        live: MapSet.new(["findings:quality"])
      }

      assert Loop.terminal(%{held: %{}}, state) == :not_converged
    end

    test "deadlock: a non-empty held set with nothing dispatchable", %{catalog: catalog} do
      state = %{catalog: catalog, ran: MapSet.new(), live: MapSet.new()}
      assert Loop.terminal(%{held: %{"implementer" => ["plan-approved"]}}, state) == :deadlock
    end

    test "lenses_clean?/3 ignores ran stages that carry no lens", %{catalog: catalog} do
      assert Loop.lenses_clean?(catalog, MapSet.new(["planner"]), MapSet.new())
    end

    test "lenses_clean?/3 is false when a ran lens has no clean signal", %{catalog: catalog} do
      refute Loop.lenses_clean?(catalog, MapSet.new(["security-reviewer"]), MapSet.new())
    end
  end

  describe "AR-8b-2 F1 sketch-review lens gating (Catalog.all)" do
    setup do
      %{catalog: Catalog.all()}
    end

    test "converged: a ran sketch-review with clean:correctness live", %{catalog: catalog} do
      state = %{
        catalog: catalog,
        ran: MapSet.new(["sketch-build", "sketch-review"]),
        live: MapSet.new(["clean:correctness"])
      }

      assert Loop.terminal(%{held: %{}}, state) == :converged
      assert Loop.lenses_clean?(catalog, state.ran, state.live)
    end

    test "not_converged: a ran sketch-review with findings:correctness (no clean)", %{
      catalog: catalog
    } do
      state = %{
        catalog: catalog,
        ran: MapSet.new(["sketch-build", "sketch-review"]),
        live: MapSet.new(["findings:correctness"])
      }

      assert Loop.terminal(%{held: %{}}, state) == :not_converged
      refute Loop.lenses_clean?(catalog, state.ran, state.live)
    end
  end
end
