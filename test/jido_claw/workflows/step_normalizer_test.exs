defmodule JidoClaw.Workflows.StepNormalizerTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Workflows.StepNormalizer

  describe "normalize/1" do
    test "string-keyed steps become atom-keyed" do
      steps = [
        %{"name" => "research", "role" => "researcher"},
        %{"name" => "summarize", "role" => "writer"}
      ]

      assert StepNormalizer.normalize(steps) == [
               %{name: "research", role: "researcher"},
               %{name: "summarize", role: "writer"}
             ]
    end

    test "atom-keyed steps pass through unchanged" do
      steps = [%{name: "research", role: "researcher"}]
      assert StepNormalizer.normalize(steps) == steps
    end

    test "mixed-shape steps are unified" do
      steps = [%{"name" => "a"}, %{name: "b"}]
      assert StepNormalizer.normalize(steps) == [%{name: "a"}, %{name: "b"}]
    end

    test "is idempotent" do
      steps = [%{"name" => "a", "depends_on" => ["b"]}]
      once = StepNormalizer.normalize(steps)
      assert StepNormalizer.normalize(once) == once
    end

    test "missing optional fields stay missing" do
      steps = [%{"name" => "solo"}]
      assert StepNormalizer.normalize(steps) == [%{name: "solo"}]
    end

    test "nil input returns []" do
      assert StepNormalizer.normalize(nil) == []
    end

    test "non-list input returns []" do
      assert StepNormalizer.normalize("not a list") == []
      assert StepNormalizer.normalize(%{name: "step"}) == []
    end

    test "leaves non-map step elements alone" do
      # Defensive: an unexpected scalar in the step list should not crash.
      assert StepNormalizer.normalize(["plain"]) == ["plain"]
    end

    test "list ordering is preserved" do
      steps = Enum.map(1..5, fn i -> %{"name" => "s#{i}", "role" => "r#{i}"} end)
      out = StepNormalizer.normalize(steps)
      assert Enum.map(out, & &1.name) == ["s1", "s2", "s3", "s4", "s5"]
    end

    test "normalizes the full canonical step-key set" do
      steps = [
        %{
          "name" => "s",
          "task" => "t",
          "role" => "r",
          "template" => "tmpl",
          "depends_on" => ["a"],
          "produces" => %{x: 1},
          "consumes" => ["b"]
        }
      ]

      [out] = StepNormalizer.normalize(steps)

      assert Enum.sort(Map.keys(out)) ==
               [:consumes, :depends_on, :name, :produces, :role, :task, :template]

      # Lock values too — Map.keys/1 alone only proves the key shape survived,
      # not that values landed under the right atoms.
      assert out.name == "s"
      assert out.task == "t"
      assert out.role == "r"
      assert out.template == "tmpl"
      assert out.depends_on == ["a"]
      assert out.produces == %{x: 1}
      assert out.consumes == ["b"]
    end

    test "drops unknown string keys" do
      assert StepNormalizer.normalize([%{"name" => "ok", "bogus_field_xyz" => 1}]) ==
               [%{name: "ok"}]
    end

    test "drops unknown atom keys" do
      assert StepNormalizer.normalize([%{:__unused__ => 1, :name => "ok"}]) ==
               [%{name: "ok"}]
    end
  end
end
