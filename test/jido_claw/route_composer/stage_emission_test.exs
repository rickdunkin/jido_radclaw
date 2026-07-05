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
      for kind <- ["infra", "inconclusive", "tampered"] do
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

  describe "certification (item 5, C1-6)" do
    test "absent certification decodes to nil (worker emissions)" do
      assert %StageEmission{certification: nil} = StageEmission.from_map(%{"stage" => "x"})
    end

    test "a working-tree certification round-trips through the string-keyed boundary" do
      emission =
        StageEmission.from_map(%{
          "stage" => "verify",
          "signals" => ["clean:verify"],
          "certification" => %{"head" => "h1", "tree_digest" => "d1", "mode" => "working_tree"}
        })

      assert emission.certification == %{head: "h1", tree_digest: "d1", mode: :working_tree}
    end

    test "a sealed certification tolerates a nil tree_digest" do
      emission =
        StageEmission.from_map(%{
          "stage" => "verify",
          "certification" => %{"head" => "h1", "tree_digest" => nil, "mode" => "sealed"}
        })

      assert emission.certification == %{head: "h1", tree_digest: nil, mode: :sealed}
    end

    test "malformed certification decodes to nil, never a partial certificate" do
      for bogus <- [
            "certified",
            42,
            %{"head" => "h1"},
            %{"head" => "h1", "mode" => "hostile", "tree_digest" => "d1"},
            %{"head" => nil, "mode" => "working_tree", "tree_digest" => "d1"},
            # working-tree REQUIRES a digest — a digest-less working-tree
            # certificate could never back the tuple re-check.
            %{"head" => "h1", "mode" => "working_tree", "tree_digest" => nil}
          ] do
        assert %StageEmission{certification: nil} =
                 StageEmission.from_map(%{"stage" => "verify", "certification" => bogus})
      end
    end
  end
end
