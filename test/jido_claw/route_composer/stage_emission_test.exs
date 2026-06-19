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
end
