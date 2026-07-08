defmodule JidoClaw.RouteComposer.PremisesTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Premises

  describe "normalize/1 (the write boundary)" do
    test "passes untyped keys through untouched" do
      premises = %{"path" => "code", "est_size" => "m", "graduated_from" => %{"run_id" => "r1"}}
      assert Premises.normalize(premises) == premises
    end

    test "normalizes list-valued typed keys entry-by-entry" do
      premises = %{
        "acceptance_criteria" => ["  `mix test` passes  ", "", 42, nil, "GET /health returns 200"],
        "exit_conditions" => ["stop after 3 attempts", %{"not" => "a string"}]
      }

      assert %{
               "acceptance_criteria" => ["`mix test` passes", "GET /health returns 200"],
               "exit_conditions" => ["stop after 3 attempts"]
             } = Premises.normalize(premises)
    end

    test "drops a non-list typed value entirely (fail-open, key gone)" do
      premises = %{"path" => "code", "acceptance_criteria" => "not a list"}

      assert Premises.normalize(premises) == %{"path" => "code"}
    end

    test "principles: clamps weight to 0..1, coerces description, drops junk entries" do
      premises = %{
        "evaluation_principles" => [
          %{"name" => "correctness", "description" => "must be right", "weight" => 1.5},
          %{"name" => "speed", "weight" => -2},
          %{"name" => "  ", "description" => "blank name", "weight" => 0.5},
          %{"description" => "no name", "weight" => 0.5},
          %{"name" => "no weight"},
          "not a map"
        ]
      }

      assert %{"evaluation_principles" => principles} = Premises.normalize(premises)

      assert principles == [
               %{"name" => "correctness", "description" => "must be right", "weight" => 1.0},
               %{"name" => "speed", "description" => "", "weight" => 0.0}
             ]
    end

    test "is total: non-map input passes through unchanged" do
      assert Premises.normalize(nil) == nil
      assert Premises.normalize("junk") == "junk"
      assert Premises.normalize(42) == 42
    end

    test "a present-but-empty criteria list survives (the producer's claim is kept)" do
      assert Premises.normalize(%{"acceptance_criteria" => []}) == %{"acceptance_criteria" => []}
    end
  end

  describe "read accessors (tolerant over arbitrary durable state)" do
    test "criteria/1 returns [] for junk, absent, and non-map premises" do
      assert Premises.criteria(%{}) == []
      assert Premises.criteria(%{"acceptance_criteria" => "junk"}) == []
      assert Premises.criteria(nil) == []
      assert Premises.criteria("junk") == []
    end

    test "criteria/1 filters non-binary entries from a durable list" do
      assert Premises.criteria(%{"acceptance_criteria" => ["a", 1, "b"]}) == ["a", "b"]
    end

    test "criteria_with_ids/1 assigns stable 1-based AC ids (orca OQ-2)" do
      premises = %{"acceptance_criteria" => ["first", "second", "third"]}

      assert Premises.criteria_with_ids(premises) == [
               {"AC1", "first"},
               {"AC2", "second"},
               {"AC3", "third"}
             ]

      assert Premises.criteria_with_ids(%{}) == []
    end

    test "principles/1 and exit_conditions/1 read tolerant" do
      assert Premises.principles(%{
               "evaluation_principles" => [%{"name" => "x", "weight" => 0.5}]
             }) ==
               [%{"name" => "x", "description" => "", "weight" => 0.5}]

      assert Premises.principles(nil) == []
      assert Premises.exit_conditions(%{"exit_conditions" => ["done", 7]}) == ["done"]
      assert Premises.exit_conditions(%{}) == []
    end

    test "principles/1 tolerates atom-keyed entries (synthetic test maps)" do
      assert Premises.principles(%{
               "evaluation_principles" => [%{name: "x", description: "d", weight: 0.3}]
             }) == [%{"name" => "x", "description" => "d", "weight" => 0.3}]
    end
  end
end
