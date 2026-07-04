defmodule JidoClaw.RouteComposer.StageEmissionTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.StageEmission

  test "from_map/1 normalizes atom-keyed and string-keyed maps identically" do
    atom =
      StageEmission.from_map(%{
        stage: "planner",
        signals: ["plan-ready"],
        artifacts: %{"plan" => "p"}
      })

    string =
      StageEmission.from_map(%{
        "stage" => "planner",
        "signals" => ["plan-ready"],
        "artifacts" => %{"plan" => "p"}
      })

    assert atom == string

    assert atom == %StageEmission{
             stage: "planner",
             signals: ["plan-ready"],
             artifacts: %{"plan" => "p"}
           }
  end

  test "from_map/1 defaults missing signals/artifacts" do
    assert StageEmission.from_map(%{"stage" => "x"}) ==
             %StageEmission{stage: "x", signals: [], artifacts: %{}}
  end

  describe "outcome (camus C1-3)" do
    test "absent outcome decodes to :ok (legacy rows + normal emissions)" do
      assert %StageEmission{outcome: :ok} = StageEmission.from_map(%{"stage" => "x"})
    end

    test "round-trips through the WaveCollect encoding shape" do
      for kind <- ["infra", "inconclusive"] do
        emission =
          StageEmission.from_map(%{
            "stage" => "reviewer",
            "signals" => [],
            "artifacts" => %{},
            "outcome" => %{"kind" => kind, "reason" => "invalid_overall: \"maybe\""}
          })

        assert emission.outcome ==
                 {String.to_existing_atom(kind), "invalid_overall: \"maybe\""}
      end
    end

    test "atom-keyed live outcome decodes identically" do
      atom =
        StageEmission.from_map(%{
          stage: "r",
          outcome: %{kind: :infra, reason: "empty_output"}
        })

      string =
        StageEmission.from_map(%{
          "stage" => "r",
          "outcome" => %{"kind" => "infra", "reason" => "empty_output"}
        })

      assert atom == string
      assert atom.outcome == {:infra, "empty_output"}
    end

    test "an unknown present outcome shape fails CLOSED to {:infra, _}, never :ok" do
      for bogus <- [
            "ok",
            :ok,
            42,
            %{"kind" => "success"},
            %{"kind" => "infra"},
            %{"kind" => "infra", "reason" => 42},
            %{"unexpected" => true}
          ] do
        assert %StageEmission{outcome: {:infra, reason}} =
                 StageEmission.from_map(%{"stage" => "x", "outcome" => bogus})

        assert reason =~ "unrecognized_outcome"
      end
    end
  end
end
