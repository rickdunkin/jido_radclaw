defmodule JidoClaw.RouteComposer.RouterTest do
  use ExUnit.Case, async: true

  import JidoClaw.RouteComposer.TestFixtures

  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.TestFixtures

  @lock_cases [
    %{
      name: "U01 active lock holds impl",
      lock: [{"needs-tests", "tests-ready"}],
      live: ["plan-ready", "needs-tests"],
      available: ["plan"],
      held: ["tests-ready"]
    },
    %{
      name: "U03 until live releases the lock",
      lock: [{"needs-tests", "tests-ready"}],
      live: ["plan-ready", "needs-tests", "tests-ready"],
      available: ["plan"],
      held: nil
    },
    %{
      name: "U04 while absent runs normally",
      lock: [{"needs-tests", "tests-ready"}],
      live: ["plan-ready"],
      available: ["plan"],
      held: nil
    },
    %{
      name: "U05 both locks active list both untils",
      lock: [{"needs-tests", "tests-ready"}, {"review-needed", "review-done"}],
      live: ["plan-ready", "needs-tests", "review-needed"],
      available: ["plan"],
      held: ["tests-ready", "review-done"]
    },
    %{
      name: "U06 one resolved keeps only the remaining until",
      lock: [{"needs-tests", "tests-ready"}, {"review-needed", "review-done"}],
      live: ["plan-ready", "needs-tests", "review-needed", "tests-ready"],
      available: ["plan"],
      held: ["review-done"],
      absent: ["tests-ready"]
    },
    %{
      name: "U07 both resolved runs",
      lock: [{"needs-tests", "tests-ready"}, {"review-needed", "review-done"}],
      live: ["plan-ready", "needs-tests", "review-needed", "tests-ready", "review-done"],
      available: ["plan"],
      held: nil
    },
    %{
      name: "U08 family-prefix until releases",
      lock: [{"needs-tests", "tests-ready"}],
      live: ["plan-ready", "needs-tests", "tests-ready:foo"],
      available: ["plan"],
      held: nil
    },
    %{
      name: "U09 family-prefix while activates",
      lock: [{"needs-tests", "tests-ready"}],
      live: ["plan-ready", "needs-tests:logic"],
      available: ["plan"],
      held: ["tests-ready"]
    },
    %{
      name: "U14 cheap path runs with held empty",
      lock: [{"needs-tests", "tests-ready"}],
      live: ["plan-ready"],
      available: ["plan"],
      held: nil
    }
  ]

  @size_cases [
    {0, "empty"},
    {1, "XS"},
    {2, "S"},
    {3, "S"},
    {4, "M"},
    {6, "M"},
    {7, "L"},
    {10, "L"},
    {11, "XL"},
    {15, "XL"},
    {16, "XXL"},
    {42, "XXL"}
  ]

  describe "core routing" do
    setup do
      %{cat: TestFixtures.synthetic_catalog()}
    end

    test "OR subscribe: any subscribed signal triggers the stage", %{cat: cat} do
      assert_in_route(compose(cat, ["auth-surface"], available: ["diff"]), "sec")
      refute "sec" in compose(cat, ["code"], available: ["diff"]).route
    end

    test "AND required: a stage whose required input has no producer drops", %{cat: cat} do
      refute "impl" in compose(cat, ["plan-ready"], available: ["plan"]).route
      assert_in_route(compose(cat, ["plan-ready"], available: ["plan", "tests"]), "impl")
    end

    test "topo order: a producer precedes its consumer", %{cat: cat} do
      order = compose(cat, ["plan-ready", "auth-surface"], available: ["plan", "tests"]).route
      assert Enum.find_index(order, &(&1 == "impl")) < Enum.find_index(order, &(&1 == "sec"))
    end

    test "optional input never drops and orders after its producer", %{cat: cat} do
      assert_in_route(compose(cat, ["plan-needed"], available: ["intent"]), "plan")

      order = compose(cat, ["code", "plan-needed"], available: ["intent"]).route
      assert "plan" in order and "scan" in order
      assert Enum.find_index(order, &(&1 == "scan")) < Enum.find_index(order, &(&1 == "plan"))
    end

    test "routes filter drops an off-path stage", %{cat: cat} do
      on_code = compose(cat, ["code", "ping"], available: ["intent"])
      assert "codeonly" in on_code.route and "both" in on_code.route
      refute "sketchonly" in on_code.route
      assert on_code.dropped["sketchonly"] == :off_path

      on_sketch = compose(cat, ["sketch", "ping"], available: ["intent"])
      assert "sketchonly" in on_sketch.route and "both" in on_sketch.route
      refute "codeonly" in on_sketch.route
      assert on_sketch.dropped["codeonly"] == :off_path
    end

    test "no path signal live skips the routes filter", %{cat: cat} do
      route = compose(cat, ["ping"]).route
      assert Enum.all?(["codeonly", "sketchonly", "both"], &(&1 in route))
    end

    test "a multi-path stage survives on each of its paths", %{cat: cat} do
      assert_in_route(compose(cat, ["code", "ping"], available: ["intent"]), "both")
      assert_in_route(compose(cat, ["sketch", "ping"], available: ["intent"]), "both")
    end

    test "the route grows and shrinks as signals come and go", %{cat: cat} do
      assert compose(cat, ["code"], available: ["intent"]).route == ["scan"]

      grown = compose(cat, ["code", "missing-infra"], available: ["intent"]).route
      assert MapSet.new(grown) == MapSet.new(["scan", "proto"])

      assert compose(cat, ["code"], available: ["intent"]).route == ["scan"]
    end

    test "identical input yields an identical result", %{cat: cat} do
      a = compose(cat, ["plan-ready", "auth-surface"], available: ["plan", "tests"])
      b = compose(cat, ["plan-ready", "auth-surface"], available: ["plan", "tests"])
      assert a == b
    end
  end

  describe "wave scheduling" do
    setup do
      %{cat: TestFixtures.synthetic_catalog()}
    end

    test "waves flatten to the route", %{cat: cat} do
      res = compose(cat, ["plan-ready", "auth-surface"], available: ["plan", "tests"])
      assert Enum.concat(res.waves) == res.route
    end

    test "independent stages share a wave", %{cat: cat} do
      res = compose(cat, ["code", "ping"], available: ["intent"])
      wave = Enum.find(res.waves, fn w -> "codeonly" in w end)
      assert "both" in wave
    end

    test "a producer and its consumer split across waves", %{cat: cat} do
      res = compose(cat, ["plan-ready", "auth-surface"], available: ["plan", "tests"])
      impl_wave = Enum.find_index(res.waves, fn w -> "impl" in w end)
      sec_wave = Enum.find_index(res.waves, fn w -> "sec" in w end)
      assert impl_wave < sec_wave
    end

    test "a single stage is one wave", %{cat: cat} do
      assert compose(cat, ["code"], available: ["intent"]).waves == [["scan"]]
    end

    test "an empty route has empty waves", %{cat: cat} do
      res = compose(cat, [])
      assert res.route == [] and res.waves == []
    end
  end

  describe "optional ordering edges" do
    test "an in-route optional producer orders the consumer even without the artifact" do
      cat = %{
        "alpha" =>
          TestFixtures.stage(
            routes: ["code"],
            out: ["alpha-out"],
            sub: ["go"],
            pub: ["scope-shift"]
          ),
        "beta" =>
          TestFixtures.stage(
            routes: ["code"],
            opt: ["alpha-out"],
            out: ["beta-out"],
            sub: ["go"],
            pub: ["scope-shift"]
          )
      }

      order = compose(cat, ["code", "go"]).route
      assert "alpha" in order and "beta" in order
      assert Enum.find_index(order, &(&1 == "alpha")) < Enum.find_index(order, &(&1 == "beta"))
    end
  end

  describe "family-prefix matching (one-directional)" do
    test "a base subscription matches a qualified live topic" do
      cat = %{
        "fix" =>
          TestFixtures.stage(
            routes: ["code"],
            req: ["findings"],
            out: ["diff"],
            sub: ["findings"],
            pub: ["code-written", "scope-shift"]
          )
      }

      assert_in_route(compose(cat, ["findings:correctness"], available: ["findings"]), "fix")
      assert_in_route(compose(cat, ["findings"], available: ["findings"]), "fix")
    end

    test "a qualified subscription does not match a base live topic" do
      cat = %{
        "q" =>
          TestFixtures.stage(routes: ["code"], sub: ["findings:security"], pub: ["scope-shift"])
      }

      refute "q" in compose(cat, ["code", "findings"]).route
      assert_in_route(compose(cat, ["code", "findings:security"]), "q")
    end
  end

  describe "locks & held (table-driven)" do
    for row <- @lock_cases do
      test "lock/held: #{row.name}" do
        row = unquote(Macro.escape(row))
        lock = Enum.map(row.lock, fn {w, u} -> %{while: w, until: u} end)
        res = compose(TestFixtures.lock_catalog(lock: lock), row.live, available: row.available)
        assert_lock_case(res, row)
      end
    end

    test "U02 route and held are disjoint when a lock is active" do
      cat = TestFixtures.lock_catalog(lock: [%{while: "needs-tests", until: "tests-ready"}])
      res = compose(cat, ["plan-ready", "needs-tests"], available: ["plan"])
      assert MapSet.disjoint?(MapSet.new(res.route), MapSet.new(Map.keys(res.held)))
    end

    test "U10 the held payload is a list of the unmet until signals" do
      cat = TestFixtures.lock_catalog(lock: [%{while: "needs-tests", until: "tests-ready"}])
      res = compose(cat, ["plan-ready", "needs-tests"], available: ["plan"])
      assert is_list(res.held["impl"])
      assert "tests-ready" in res.held["impl"]
    end

    test "U11 held values are signal-name lists, never a deadlock sentinel" do
      cat =
        TestFixtures.lock_catalog(
          lock: [
            %{while: "needs-tests", until: "tests-ready"},
            %{while: "review-needed", until: "review-done"}
          ]
        )

      res = compose(cat, ["plan-ready", "needs-tests", "review-needed"], available: ["plan"])

      for {_name, unmet} <- res.held do
        assert is_list(unmet)
        refute unmet == "deadlock"
      end
    end

    test "U12 a held stage contributes no output so its consumer drops" do
      reviewer =
        TestFixtures.stage(
          routes: ["code"],
          req: ["diff"],
          out: ["findings"],
          sub: ["plan-ready"],
          pub: ["scope-shift"]
        )

      cat =
        TestFixtures.lock_catalog(
          lock: [%{while: "needs-tests", until: "tests-ready"}],
          extra: %{"reviewer" => reviewer}
        )

      res = compose(cat, ["plan-ready", "needs-tests"], available: ["plan"])
      assert Map.has_key?(res.held, "impl")
      refute "reviewer" in res.route
    end

    test "U13 the held key is always present and empty when nothing is locked" do
      res = compose(TestFixtures.lock_catalog(), ["plan-ready"], available: ["plan"])
      assert Map.has_key?(res, :held)
      assert res.held == %{}
    end
  end

  describe "merge_sticky/3" do
    setup do
      %{cat: TestFixtures.synthetic_catalog()}
    end

    test "re-adds a sticky stage that left the route and tags sticky_kept", %{cat: cat} do
      prev = compose(cat, ["code", "auth-surface"], available: ["intent", "diff"])
      now = compose(cat, ["code"], available: ["intent", "diff"])
      refute "sec" in now.route

      merged = Router.merge_sticky(cat, prev.route, now)
      assert "sec" in merged.route
      assert merged.sticky_kept == ["sec"]
    end

    test "carries held/dropped/triggered_by over unchanged", %{cat: cat} do
      prev = compose(cat, ["code", "auth-surface"], available: ["intent", "diff"])
      now = compose(cat, ["code", "auth-surface"], available: ["intent"])
      assert now.dropped == %{"sec" => :unsatisfiable_input}

      merged = Router.merge_sticky(cat, prev.route, now)
      assert "sec" in merged.route
      assert merged.held == now.held
      assert merged.dropped == now.dropped
      assert merged.triggered_by == now.triggered_by
    end

    test "is a no-op when nothing sticky needs re-adding", %{cat: cat} do
      now = compose(cat, ["code"], available: ["intent"])
      merged = Router.merge_sticky(cat, now.route, now)
      assert merged == now
      refute Map.has_key?(merged, :sticky_kept)
    end

    test "tolerates a prev_name absent from the catalog", %{cat: cat} do
      now = compose(cat, ["code"], available: ["intent"])
      merged = Router.merge_sticky(cat, ["ghost-stage" | now.route], now)
      assert merged == now
    end
  end

  describe "size_label/1" do
    for {n, label} <- @size_cases do
      test "size_label(#{n}) == #{label}" do
        assert Router.size_label(unquote(n)) == unquote(label)
      end
    end

    test "the route's size is the label for its length" do
      cat = TestFixtures.synthetic_catalog()
      assert compose(cat, ["code"], available: ["intent"]).size == "XS"
    end
  end

  describe "GAP scenarios — starter catalog" do
    test "GAP-1 both locks hold the implementer with both unmet untils" do
      res = compose(Catalog.all(), ["code", "plan-ready", "needs-tests"], available: ["plan"])
      refute "implementer" in res.route
      assert_held(res, "implementer", ["tests-ready", "plan-approved"])
    end

    test "GAP-2 a stale plan-approved artifact does not release the plan-gate (locks read live)" do
      res = compose(Catalog.all(), ["code", "plan-ready"], available: ["plan", "plan-approved"])
      refute "implementer" in res.route
      assert_held(res, "implementer", ["plan-approved"])
    end

    test "GAP-3 significant-build without needs-tests pulls deep lenses but not test-author" do
      res =
        compose(Catalog.all(), ["code", "significant-build", "code-written"], available: ["diff"])

      assert_in_route(res, "architecture-reviewer")
      assert_in_route(res, "quality-reviewer")
      assert_in_route(res, "correctness-reviewer")
      refute "test-author" in res.route
    end

    test "GAP-4 a family-prefix plan-approved variant releases the plan-gate" do
      res =
        compose(Catalog.all(), ["code", "plan-ready", "plan-approved:auto"], available: ["plan"])

      assert_in_route(res, "implementer")
      refute Map.has_key?(res.held, "implementer")
    end

    test "GAP-5 the AR-8b sketch path composes to [sketch-build, sketch-review] across two waves" do
      res =
        compose(Catalog.all(), ["request-received", "sketch"],
          available: ["request"],
          ran: ["triage"]
        )

      # AR-8b-2 F1: `sketch-review` is NOT dropped in wave 1 — `drop_unsatisfiable/3`
      # counts `prototype` as produced by in-route `sketch-build`, so the data graph
      # orders it producer→consumer into wave 2.
      assert res.route == ["sketch-build", "sketch-review"]
      assert res.waves == [["sketch-build"], ["sketch-review"]]
      assert res.dropped == %{}

      # The code/system pipeline stays out of a sketch route.
      for stage <- ~w(planner implementer test-author fixer quality-reviewer
                      security-reviewer correctness-reviewer architecture-reviewer) do
        refute stage in res.route
      end
    end

    test "GAP-5 the AR-8b-2 sketch-review stage is off-path on a code run" do
      res =
        compose(Catalog.all(), ["request-received", "code", "code-written"],
          available: ["diff"],
          ran: ["triage"]
        )

      refute "sketch-review" in res.route
      refute "sketch-build" in res.route
    end
  end

  defp assert_lock_case(res, %{held: nil}) do
    assert_in_route(res, "impl")
    refute Map.has_key?(res.held, "impl")
  end

  defp assert_lock_case(res, %{held: untils} = row) when is_list(untils) do
    refute "impl" in res.route
    assert_held(res, "impl", untils)
    unmet = Map.fetch!(res.held, "impl")
    Enum.each(Map.get(row, :absent, []), fn signal -> refute signal in unmet end)
  end
end
