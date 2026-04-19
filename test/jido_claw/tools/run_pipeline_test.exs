defmodule JidoClaw.Tools.RunPipelineTest do
  # async: false — writes reasoning_outcomes rows and uses the supervised
  # StrategyStore for alias resolution.
  use ExUnit.Case, async: false

  alias JidoClaw.Reasoning.Resources.Outcome
  alias JidoClaw.Tools.RunPipeline

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Stub runners
  # ---------------------------------------------------------------------------

  defmodule OkRunner do
    @moduledoc false

    def run(%{prompt: prompt}, _ctx) do
      {:ok,
       %{
         output: "OK: #{prompt}",
         usage: %{input_tokens: 10, output_tokens: 5}
       }}
    end
  end

  defmodule ErrorAtStageTwoRunner do
    @moduledoc false

    def run(%{prompt: prompt}, _ctx) do
      cond do
        String.contains?(prompt, "Prior stage output") ->
          {:error, %{output: "stage 2 boom", usage: %{input_tokens: 2, output_tokens: 0}}}

        true ->
          {:ok, %{output: "stage 1 ok", usage: %{input_tokens: 3, output_tokens: 4}}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_pipeline_rows(name) do
    [:debugging, :verification, :qa, :planning, :refactoring, :exploration, :open_ended]
    |> Enum.flat_map(fn tt ->
      case Outcome.list_by_task_type(tt, :pipeline_run) do
        {:ok, rows} -> rows
        _ -> []
      end
    end)
    |> Enum.filter(fn r -> r.pipeline_name == name end)
    |> Enum.sort_by(fn r ->
      Map.get(r.metadata, "stage_index") || Map.get(r.metadata, :stage_index)
    end)
  end

  # ---------------------------------------------------------------------------
  # Pre-execution validation (fail-fast)
  # ---------------------------------------------------------------------------

  describe "validation" do
    test "rejects empty stages list" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{pipeline_name: "p", prompt: "x", stages: []},
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "non-empty"
    end

    test "rejects unknown strategy" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: "p",
                   prompt: "x",
                   stages: [%{"strategy" => "not_a_strategy"}]
                 },
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "unknown strategy"
    end

    test "rejects a stage whose strategy resolves to react" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: "p",
                   prompt: "x",
                   stages: [%{"strategy" => "react"}]
                 },
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "resolves to react"
    end

    test "rejects a stage with strategy: 'auto'" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: "p",
                   prompt: "x",
                   stages: [%{"strategy" => "auto"}]
                 },
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "auto"
      assert msg =~ "selector"
    end

    test "rejects a stage with strategy: 'adaptive'" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: "p",
                   prompt: "x",
                   stages: [%{"strategy" => "adaptive"}]
                 },
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "adaptive"
      assert msg =~ "selector"
    end

    test "rejects stage with non-string strategy key" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: "p",
                   prompt: "x",
                   stages: [%{"strategy" => 123}]
                 },
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "strategy"
    end

    test "rejects stage with invalid context_mode" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: "p",
                   prompt: "x",
                   stages: [%{"strategy" => "cot", "context_mode" => "nope"}]
                 },
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "context_mode"
    end
  end

  # ---------------------------------------------------------------------------
  # Stage-map key normalization
  # ---------------------------------------------------------------------------

  describe "stage key normalization" do
    test "accepts atom-keyed stage maps (Elixir caller style)" do
      assert {:ok, _} =
               RunPipeline.run(
                 %{
                   pipeline_name: "atomkeys",
                   prompt: "seed",
                   stages: [%{strategy: "cot"}]
                 },
                 %{reasoning_runner: OkRunner}
               )
    end

    test "accepts string-keyed stage maps (JSON-routed style)" do
      assert {:ok, _} =
               RunPipeline.run(
                 %{
                   pipeline_name: "stringkeys",
                   prompt: "seed",
                   stages: [%{"strategy" => "cot"}]
                 },
                 %{reasoning_runner: OkRunner}
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path + telemetry
  # ---------------------------------------------------------------------------

  describe "execution" do
    test "runs stages sequentially and persists one row per stage with padded pipeline_stage" do
      name = "plan_then_explore_#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "Design a caching layer",
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "previous"},
                     %{"strategy" => "tot", "context_mode" => "previous"}
                   ]
                 },
                 %{reasoning_runner: OkRunner}
               )

      assert result.pipeline_name == name
      assert length(result.stages) == 2
      assert result.final_output =~ "OK:"
      assert result.usage.input_tokens == 20
      assert result.usage.output_tokens == 10

      rows = find_pipeline_rows(name)
      assert length(rows) == 2

      [r1, r2] = rows
      assert r1.pipeline_stage == "001/002"
      assert r2.pipeline_stage == "002/002"
      assert r1.base_strategy == "cot"
      assert r2.base_strategy == "tot"
      assert r1.execution_kind == :pipeline_run
      assert stage_index(r1) == 1
      assert stage_index(r2) == 2
      assert stage_total(r1) == 2
      assert stage_total(r2) == 2
    end

    test "zero-pads pipeline_stage to at least 3 digits" do
      name = "padding_test_#{System.unique_integer([:positive])}"

      RunPipeline.run(
        %{
          pipeline_name: name,
          prompt: "seed",
          stages: [%{"strategy" => "cot"}]
        },
        %{reasoning_runner: OkRunner}
      )

      [row] = find_pipeline_rows(name)
      assert row.pipeline_stage == "001/001"
    end

    test "mid-pipeline error persists earlier rows + failing row with status :error" do
      name = "fail_midway_#{System.unique_integer([:positive])}"

      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "seed",
                   stages: [
                     %{"strategy" => "cot"},
                     %{"strategy" => "tot"}
                   ]
                 },
                 %{reasoning_runner: ErrorAtStageTwoRunner}
               )

      assert msg =~ "stage 2"

      rows = find_pipeline_rows(name)
      assert length(rows) == 2
      [r1, r2] = rows
      assert r1.status == :ok
      assert r2.status == :error
      assert r1.pipeline_stage == "001/002"
      assert r2.pipeline_stage == "002/002"
    end
  end

  # ---------------------------------------------------------------------------
  # compose_prompt behavior via integration
  # ---------------------------------------------------------------------------

  defmodule EchoRunner do
    @moduledoc false

    def run(%{prompt: prompt}, _ctx) do
      {:ok, %{output: prompt, usage: %{input_tokens: 0, output_tokens: 0}}}
    end
  end

  describe "context composition" do
    test "previous mode feeds only the immediately prior stage" do
      name = "ctx_prev_#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "previous"},
                     %{"strategy" => "tot", "context_mode" => "previous"}
                   ]
                 },
                 %{reasoning_runner: EchoRunner}
               )

      [s1, s2] = result.stages
      assert s1.output == "INITIAL"
      assert s2.output =~ "Prior stage output"
      assert s2.output =~ "INITIAL"
    end

    test "accumulate mode joins all prior stage outputs" do
      name = "ctx_acc_#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"},
                     %{"strategy" => "tot", "context_mode" => "accumulate"},
                     %{"strategy" => "cod", "context_mode" => "accumulate"}
                   ]
                 },
                 %{reasoning_runner: EchoRunner}
               )

      [_, _, s3] = result.stages
      # Stage 3 sees headers for stage 1 and stage 2.
      assert s3.output =~ "## Stage 1 output"
      assert s3.output =~ "## Stage 2 output"
    end

    test "prompt_override wins over context_mode" do
      name = "ctx_override_#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   stages: [
                     %{"strategy" => "cot"},
                     %{
                       "strategy" => "tot",
                       "context_mode" => "accumulate",
                       "prompt_override" => "ABSOLUTELY_OVERRIDE"
                     }
                   ]
                 },
                 %{reasoning_runner: EchoRunner}
               )

      [_, s2] = result.stages
      assert s2.output == "ABSOLUTELY_OVERRIDE"
    end
  end

  # ---------------------------------------------------------------------------
  # Alias resolution
  # ---------------------------------------------------------------------------

  describe "alias resolution" do
    defp with_user_strategy(yaml, fun) do
      project_dir = Application.get_env(:jido_claw, :project_dir, File.cwd!())
      dir = Path.join([project_dir, ".jido", "strategies"])
      File.mkdir_p!(dir)

      path = Path.join(dir, "pipeline_test_alias_#{System.unique_integer([:positive])}.yaml")
      File.write!(path, yaml)

      try do
        JidoClaw.Reasoning.StrategyStore.reload()
        fun.()
      after
        File.rm(path)
        JidoClaw.Reasoning.StrategyStore.reload()
      end
    end

    test "non-react alias resolves to base_strategy in telemetry" do
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        """,
        fn ->
          name = "alias_ok_#{System.unique_integer([:positive])}"

          assert {:ok, _} =
                   RunPipeline.run(
                     %{
                       pipeline_name: name,
                       prompt: "review",
                       stages: [%{"strategy" => "fast_reviewer"}]
                     },
                     %{reasoning_runner: OkRunner}
                   )

          [row] = find_pipeline_rows(name)
          assert row.strategy == "fast_reviewer"
          assert row.base_strategy == "cot"
        end
      )
    end

    test "react-aliased strategy is rejected at validation" do
      with_user_strategy(
        """
        name: deep_debug
        base: react
        """,
        fn ->
          assert {:error, msg} =
                   RunPipeline.run(
                     %{
                       pipeline_name: "should_fail",
                       prompt: "x",
                       stages: [%{"strategy" => "deep_debug"}]
                     },
                     %{reasoning_runner: OkRunner}
                   )

          assert msg =~ "resolves to react"
        end
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata integer round-trip
  # ---------------------------------------------------------------------------

  defp stage_index(row),
    do: Map.get(row.metadata, "stage_index") || Map.get(row.metadata, :stage_index)

  defp stage_total(row),
    do: Map.get(row.metadata, "stage_total") || Map.get(row.metadata, :stage_total)
end
