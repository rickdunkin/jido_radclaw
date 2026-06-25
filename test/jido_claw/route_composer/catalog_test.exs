defmodule JidoClaw.RouteComposer.CatalogTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.CatalogValidator
  alias JidoClaw.RouteComposer.Stage
  alias JidoClaw.RouteComposer.TestFixtures

  test "the starter catalog validates clean" do
    assert CatalogValidator.validate(Catalog.all()) == []
  end

  test "all/0 returns every stage keyed by its own name" do
    all = Catalog.all()
    assert map_size(all) == length(Catalog.names())
    assert Enum.all?(all, fn {name, stage} -> match?(%Stage{name: ^name}, stage) end)
  end

  test "get/1 returns a Stage for a known name and nil otherwise" do
    assert %Stage{name: "triage"} = Catalog.get("triage")
    assert Catalog.get("ghost") == nil
  end

  test "names/0 lists the stage names" do
    names = Catalog.names()
    assert "implementer" in names
    assert "fixer" in names
  end

  test "valid?/1 reflects catalog membership" do
    assert Catalog.valid?("plan-gate")
    refute Catalog.valid?("ghost")
  end

  test "the AR-8b sketch-build stage is pinned" do
    stage = Catalog.get("sketch-build")
    assert %Stage{unit: {:worker_template, "sketch_build"}} = stage
    assert stage.routes == ["sketch"]
    # AR-8b-2 F2 (D4-B): retargeted off the seed `request-received` onto the
    # `sketch-plain` discriminator (mutually exclusive with `sketch-build-exec`).
    assert stage.subscribes == ["sketch-plain"]
    assert stage.input == %{required: ["request"], optional: []}
    # No lens (skips the clean:/findings: validator requirement) and no lock.
    assert stage.lens == nil
    assert stage.lock == []
    assert "scope-shift" in stage.publishes
  end

  test "the AR-8b-2 F2 sketch-build-exec stage is pinned" do
    stage = Catalog.get("sketch-build-exec")
    assert %Stage{unit: {:worker_template, "sketch_build_exec"}} = stage
    assert stage.routes == ["sketch"]
    # Subscribes the `must-execute` discriminator (D4-B) — runs INSTEAD OF
    # `sketch-build` on a must-execute sketch.
    assert stage.subscribes == ["must-execute"]
    assert stage.input == %{required: ["request"], optional: []}
    # Produces the SAME `prototype` artifact `sketch-build` does (so `sketch-review`
    # orders after either). No lens, no lock.
    assert stage.output == ["prototype"]
    assert stage.lens == nil
    assert stage.lock == []
    assert "scope-shift" in stage.publishes
  end

  test "the AR-8b-2 sketch-review stage is pinned" do
    stage = Catalog.get("sketch-review")
    assert %Stage{unit: {:worker_template, "sketch_reviewer"}} = stage
    assert stage.lens == "correctness"
    assert stage.routes == ["sketch"]
    # Subscribes the SEED signal (no stage publishes `prototype`); depends on the
    # `prototype` artifact via input.required (produced by `sketch-build`).
    assert stage.subscribes == ["request-received"]
    assert stage.input == %{required: ["prototype"], optional: []}
    # emit :default + lens declares BOTH verdict families + scope-shift.
    assert "findings:correctness" in stage.publishes
    assert "clean:correctness" in stage.publishes
    assert "scope-shift" in stage.publishes
  end

  test "AR-8c: the plan-gate is dropped from the system path (routes: [code] only)" do
    assert %Stage{routes: ["code"]} = Catalog.get("plan-gate")
    # The planner still serves both paths.
    assert "system" in Catalog.get("planner").routes
    assert "code" in Catalog.get("planner").routes
  end

  test "AR-8c: the safety-gate stage is pinned" do
    stage = Catalog.get("safety-gate")
    assert %Stage{unit: {:gate, "safety"}} = stage
    assert stage.routes == ["system"]
    assert stage.subscribes == ["plan-ready"]
    assert stage.input == %{required: ["plan"], optional: []}
    assert stage.output == ["approved-change"]
    assert "safety-approved" in stage.publishes
    assert "scope-shift" in stage.publishes
  end

  test "AR-8c: the system-executor stage is pinned (held until safety-approved, optional verify-feedback)" do
    stage = Catalog.get("system-executor")
    assert %Stage{unit: {:worker_template, "system_executor"}} = stage
    assert stage.routes == ["system"]
    assert stage.subscribes == ["plan-ready"]
    assert stage.input == %{required: ["plan"], optional: ["verify-feedback"]}
    assert stage.output == ["system-change"]
    assert stage.lock == [%{while: "plan-ready", until: "safety-approved"}]
    refute stage.reverse_verify
  end

  test "AR-8c: the system-verifier stage is pinned (reverse_verify, lens: system)" do
    stage = Catalog.get("system-verifier")
    assert %Stage{unit: {:worker_template, "system_verifier"}} = stage
    assert stage.lens == "system"
    assert stage.reverse_verify
    assert stage.routes == ["system"]
    # The `system` path signal (always live) triggers it; the data edge on
    # `system-change` orders it after the executor.
    assert stage.subscribes == ["system"]
    assert stage.input == %{required: ["system-change"], optional: []}
    assert "findings:system" in stage.publishes
    assert "clean:system" in stage.publishes
    assert "scope-shift" in stage.publishes
  end

  describe "to_map/from_map serialization (Phase 2d — durable catalog)" do
    test "round-trips the built-in catalog (incl. the :seed + :gate units)" do
      assert Catalog.from_map(Catalog.to_map(Catalog.all())) == Catalog.all()
    end

    test "round-trips the phase-1 catalog" do
      phase1 = TestFixtures.phase1_catalog()
      assert Catalog.from_map(Catalog.to_map(phase1)) == phase1
    end

    test "Stage.to_map/from_map round-trips every closed-enum variant" do
      variants = [
        TestFixtures.stage(name: "seed-stage", unit: {:seed, "triage"}),
        TestFixtures.stage(name: "wt", unit: {:worker_template, "coder"}),
        TestFixtures.stage(name: "skill", unit: {:skill, "my-skill"}),
        TestFixtures.stage(name: "gate", unit: {:gate, "plan"}),
        TestFixtures.stage(name: "mapper", emit: {:mapper, "m"}),
        TestFixtures.stage(name: "sticky", guard: :sticky),
        TestFixtures.stage(name: "tiered", model: :fast, effort: :high),
        TestFixtures.stage(
          name: "locked",
          lock: [%{while: "a", until: "b"}],
          req: ["x"],
          opt: ["y"]
        ),
        # AR-8c: the reverse_verify boolean must survive the JSONB round-trip.
        TestFixtures.stage(name: "rv", reverse_verify: true, lens: "system", req: ["c"]),
        TestFixtures.stage(name: "bare")
      ]

      for stage <- variants do
        assert Stage.from_map(Stage.to_map(stage)) == stage
      end
    end

    test "from_map(nil) is nil and a non-map is nil" do
      assert Catalog.from_map(nil) == nil
      assert Catalog.from_map("not a map") == nil
      assert Stage.from_map(nil) == nil
      assert Stage.from_map("not a map") == nil
    end

    test "an unknown closed tag fails the whole decode → nil, and creates no atom" do
      # A globally-unique, never-before-seen tag string: if `from_map` round-tripped
      # it through `String.to_atom`, the atom would exist afterward.
      bogus = "definitely_not_a_unit_tag_#{System.unique_integer([:positive])}"

      assert Stage.from_map(%{"unit" => %{"tag" => bogus, "name" => "x"}}) == nil
      assert Catalog.from_map(%{"s" => %{"unit" => %{"tag" => bogus, "name" => "x"}}}) == nil

      # One malformed stage fails the WHOLE catalog decode (recovery treats it as
      # un-recoverable, identical to absent).
      assert Catalog.from_map(%{
               "ok" =>
                 Stage.to_map(TestFixtures.stage(name: "ok", unit: {:worker_template, "c"})),
               "bad" => %{"unit" => %{"tag" => bogus, "name" => "x"}}
             }) == nil

      # The bogus tag was never atomized.
      assert_raise ArgumentError, fn -> String.to_existing_atom(bogus) end
    end

    test "an unknown guard / emit value fails the decode → nil" do
      assert Stage.from_map(%{"guard" => "loud"}) == nil
      assert Stage.from_map(%{"emit" => %{"unknown" => "x"}}) == nil
      assert Stage.from_map(%{"model" => "turbo"}) == nil
      assert Stage.from_map(%{"effort" => "extreme"}) == nil
    end

    test "reverse_verify coerces atom-safely: only literal true is true, else false" do
      assert %Stage{reverse_verify: true} = Stage.from_map(%{"reverse_verify" => true})
      assert %Stage{reverse_verify: false} = Stage.from_map(%{"reverse_verify" => false})
      # A non-boolean value (atom-unsafe garbage) does NOT fail the decode — it
      # falls back to the struct default `false` (a degenerate-but-atom-safe map).
      assert %Stage{reverse_verify: false} = Stage.from_map(%{"reverse_verify" => "yes"})
      assert %Stage{reverse_verify: false} = Stage.from_map(%{})
    end

    test "a structurally-empty stage map decodes (atom-safe) but is NOT validator-clean" do
      # `from_map` rejects only atom-unsafe input (unknown closed tags); a structurally
      # empty stage map decodes to a default %Stage{}, so coherence needs CatalogValidator.
      catalog = Catalog.from_map(%{"bad" => %{}})
      assert %{"bad" => %Stage{name: nil, unit: nil, routes: []}} = catalog
      assert CatalogValidator.validate(catalog) != []
    end

    test "decode_config_catalog classifies absent / valid / invalid" do
      valid = TestFixtures.phase1_catalog()
      assert RouteComposer.decode_config_catalog(nil) == :absent
      assert RouteComposer.decode_config_catalog(Catalog.to_map(valid)) == {:ok, valid}
      # structural
      assert RouteComposer.decode_config_catalog(%{"bad" => %{}}) == :invalid
      # zero-stage
      assert RouteComposer.decode_config_catalog(%{}) == :invalid
      bogus = %{"s" => %{"unit" => %{"tag" => "nope", "name" => "x"}}}
      # atom-unsafe
      assert RouteComposer.decode_config_catalog(bogus) == :invalid
    end

    test "phase1_catalog validates clean (recovery-guard invariant)" do
      assert CatalogValidator.validate(TestFixtures.phase1_catalog()) == []
    end
  end
end
