defmodule JidoClaw.Tools.RunPipelineTest do
  # async: false — writes reasoning_outcomes rows and uses the supervised
  # StrategyStore for alias resolution.
  use ExUnit.Case, async: false

  import JidoClaw.Reasoning.StrategyTestHelper

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
  # pipeline_ref resolution (v0.4.6)
  # ---------------------------------------------------------------------------

  describe "pipeline_ref resolution" do
    test "executes stages loaded from .jido/pipelines/ when only pipeline_ref is supplied" do
      with_user_pipeline(
        """
        name: ref_only
        description: a tiny CoT chain
        stages:
          - strategy: cot
          - strategy: cod
            context_mode: accumulate
        """,
        fn ->
          caller_name = "ref_only_call_#{System.unique_integer([:positive])}"

          assert {:ok, result} =
                   RunPipeline.run(
                     %{
                       pipeline_name: caller_name,
                       prompt: "hello",
                       pipeline_ref: "ref_only"
                     },
                     %{reasoning_runner: OkRunner}
                   )

          assert length(result.stages) == 2

          # Caller-supplied pipeline_name wins over the YAML `name` for
          # telemetry correlation.
          rows = find_pipeline_rows(caller_name)
          assert length(rows) == 2
          assert find_pipeline_rows("ref_only") == []
        end
      )
    end

    test "inline stages win over pipeline_ref when both supplied" do
      # pipeline_ref points at a non-existent name — the inline stages must
      # execute anyway, never surfacing an "unknown pipeline" error.
      caller_name = "inline_wins_#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               RunPipeline.run(
                 %{
                   pipeline_name: caller_name,
                   prompt: "hello",
                   pipeline_ref: "definitely_does_not_exist",
                   stages: [%{"strategy" => "cot"}]
                 },
                 %{reasoning_runner: OkRunner}
               )

      assert length(result.stages) == 1
    end

    test "empty inline stages + valid pipeline_ref — fails on empty-inline, never falls through" do
      with_user_pipeline(
        """
        name: fallthrough_guard
        stages:
          - strategy: cot
        """,
        fn ->
          assert {:error, msg} =
                   RunPipeline.run(
                     %{
                       pipeline_name: "p",
                       prompt: "x",
                       pipeline_ref: "fallthrough_guard",
                       stages: []
                     },
                     %{reasoning_runner: OkRunner}
                   )

          assert msg =~ "non-empty"
        end
      )
    end

    test "malformed inline stages + valid pipeline_ref — fails on bad inline stage" do
      with_user_pipeline(
        """
        name: fallthrough_guard_bad
        stages:
          - strategy: cot
        """,
        fn ->
          assert {:error, msg} =
                   RunPipeline.run(
                     %{
                       pipeline_name: "p",
                       prompt: "x",
                       pipeline_ref: "fallthrough_guard_bad",
                       stages: [%{"strategy" => "definitely_not_a_strategy"}]
                     },
                     %{reasoning_runner: OkRunner}
                   )

          assert msg =~ "unknown strategy"
        end
      )
    end

    test "unknown pipeline_ref — explicit error" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{pipeline_name: "p", prompt: "x", pipeline_ref: "not_registered"},
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "unknown pipeline 'not_registered'"
    end

    test "neither stages nor pipeline_ref supplied — explicit error" do
      assert {:error, msg} =
               RunPipeline.run(
                 %{pipeline_name: "p", prompt: "x"},
                 %{reasoning_runner: OkRunner}
               )

      assert msg =~ "must supply pipeline_ref or stages"
    end
  end

  # ---------------------------------------------------------------------------
  # max_context_bytes cap (v0.4.7)
  # ---------------------------------------------------------------------------

  describe "max_context_bytes cap" do
    # Fixed-body runner — stable byte count per output so the cap math is
    # predictable.
    defmodule FixedBodyRunner do
      @moduledoc false
      # Emits a 400-byte body regardless of prompt. Stage output = body.
      @body_400 String.duplicate("a", 400)
      def run(%{prompt: _}, _ctx) do
        {:ok, %{output: @body_400, usage: %{input_tokens: 0, output_tokens: 0}}}
      end
    end

    defmodule BigBodyRunner do
      @moduledoc false
      # Emits a 5 KB body — useful for irreducible-cap failure cases.
      @body_5k String.duplicate("a", 5_000)
      def run(%{prompt: _}, _ctx) do
        {:ok, %{output: @body_5k, usage: %{input_tokens: 0, output_tokens: 0}}}
      end
    end

    test "drops oldest stages to fit the cap and records metadata" do
      name = "cap_happy_#{System.unique_integer([:positive])}"

      # 3 accumulate stages × 400-byte bodies. Stage 3's uncapped prompt is
      # initial + s1 + s2 ≈ 847 bytes. Cap of 500 forces stage 3 to drop
      # stage 1 (keeping only s2 + elision notice ≈ 484 bytes).
      assert {:ok, result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   max_context_bytes: 500,
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"},
                     %{"strategy" => "tot", "context_mode" => "accumulate"},
                     %{"strategy" => "cod", "context_mode" => "accumulate"}
                   ]
                 },
                 %{reasoning_runner: FixedBodyRunner}
               )

      assert length(result.stages) == 3

      rows = find_pipeline_rows(name)
      assert length(rows) == 3

      stage_3_row = Enum.find(rows, fn r -> stage_index(r) == 3 end)
      assert stage_3_row

      # Cap metadata round-trips through JSONB as string keys.
      md = stage_3_row.metadata
      pre_cap = Map.get(md, "accumulated_context_bytes_pre_cap")
      post_cap = Map.get(md, "accumulated_context_bytes_post_cap")
      dropped = Map.get(md, "dropped_stage_indexes")

      assert is_integer(pre_cap)
      assert is_integer(post_cap)
      assert pre_cap > post_cap
      assert post_cap <= 500
      # Must have dropped at least stage 1.
      assert is_list(dropped)
      assert 1 in dropped
    end

    test "cap failure persists :error row on the failing stage with failure metadata" do
      name = "cap_fail_#{System.unique_integer([:positive])}"

      # BigBodyRunner emits 5 KB per stage. With cap = 2 KB, stage 2's
      # composed prompt is initial + stage_1_output (5 KB), which already
      # exceeds 2 KB even when reduced to initial + newest-stage + notice.
      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   max_context_bytes: 2000,
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"},
                     %{"strategy" => "tot", "context_mode" => "accumulate"}
                   ]
                 },
                 %{reasoning_runner: BigBodyRunner}
               )

      # Error message form is a consumer contract per moduledoc.
      assert msg =~
               "stage 2: max_context_bytes (2000) exceeded by initial prompt + most-recent stage output alone"

      rows = find_pipeline_rows(name)
      # Stage 1 was successful; stage 2 failed via cap.
      assert length(rows) == 2

      s1 = Enum.find(rows, fn r -> stage_index(r) == 1 end)
      s2 = Enum.find(rows, fn r -> stage_index(r) == 2 end)
      assert s1.status == :ok
      assert s2.status == :error

      md = s2.metadata
      failure_reason = Map.get(md, "failure_reason") || Map.get(md, :failure_reason)
      pre_cap = Map.get(md, "accumulated_context_bytes_pre_cap")
      dropped = Map.get(md, "dropped_stage_indexes")

      assert failure_reason =~ "max_context_bytes"
      assert is_integer(pre_cap) and pre_cap > 0
      assert is_list(dropped)
    end

    test "previous mode ignores the cap (warning path)" do
      name = "cap_prev_ignore_#{System.unique_integer([:positive])}"

      # Even with a tiny 500-byte cap, `previous` mode doesn't apply it.
      assert {:ok, result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   max_context_bytes: 500,
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "previous"},
                     %{"strategy" => "tot", "context_mode" => "previous"}
                   ]
                 },
                 %{reasoning_runner: FixedBodyRunner}
               )

      # Both stages ran to completion — nothing was capped or dropped.
      assert length(result.stages) == 2

      rows = find_pipeline_rows(name)
      s2 = Enum.find(rows, fn r -> stage_index(r) == 2 end)
      md = s2.metadata
      # No cap metadata on previous-mode stages.
      refute Map.has_key?(md, "accumulated_context_bytes_pre_cap")
      refute Map.has_key?(md, "dropped_stage_indexes")
    end

    test "stage-level cap overrides top-level cap" do
      name = "cap_stage_override_#{System.unique_integer([:positive])}"

      # Top-level cap 100 would force drops; stage 2's own cap 100_000 stays
      # permissive, so no drops occur and no cap metadata is recorded on
      # stage 2.
      assert {:ok, _result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   max_context_bytes: 100,
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"},
                     %{
                       "strategy" => "tot",
                       "context_mode" => "accumulate",
                       "max_context_bytes" => 100_000
                     }
                   ]
                 },
                 %{reasoning_runner: FixedBodyRunner}
               )

      rows = find_pipeline_rows(name)
      s2 = Enum.find(rows, fn r -> stage_index(r) == 2 end)
      refute Map.has_key?(s2.metadata, "accumulated_context_bytes_pre_cap")
    end

    test "final prompt always fits within the cap when drops occurred" do
      name = "cap_boundary_#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   max_context_bytes: 500,
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"},
                     %{"strategy" => "tot", "context_mode" => "accumulate"},
                     %{"strategy" => "cod", "context_mode" => "accumulate"}
                   ]
                 },
                 %{reasoning_runner: FixedBodyRunner}
               )

      rows = find_pipeline_rows(name)
      s3 = Enum.find(rows, fn r -> stage_index(r) == 3 end)
      post_cap = Map.get(s3.metadata, "accumulated_context_bytes_post_cap")
      # Explicit: final prompt bytes (including notice) fit under the cap.
      assert post_cap <= 500
    end

    test "absent cap = unbounded (no metadata on stages, no drops)" do
      name = "cap_absent_#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"},
                     %{"strategy" => "tot", "context_mode" => "accumulate"}
                   ]
                 },
                 %{reasoning_runner: FixedBodyRunner}
               )

      rows = find_pipeline_rows(name)
      s2 = Enum.find(rows, fn r -> stage_index(r) == 2 end)
      refute Map.has_key?(s2.metadata, "accumulated_context_bytes_pre_cap")
      refute Map.has_key?(s2.metadata, "dropped_stage_indexes")
    end

    test "first accumulate stage fails fast when initial prompt alone exceeds the cap" do
      name = "cap_first_stage_fail_#{System.unique_integer([:positive])}"
      big_prompt = String.duplicate("x", 2_000)

      assert {:error, msg} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: big_prompt,
                   max_context_bytes: 500,
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"},
                     %{"strategy" => "tot", "context_mode" => "accumulate"}
                   ]
                 },
                 %{reasoning_runner: FixedBodyRunner}
               )

      assert msg =~ "stage 1: max_context_bytes (500) exceeded by initial prompt alone"

      rows = find_pipeline_rows(name)
      assert length(rows) == 1
      s1 = Enum.find(rows, fn r -> stage_index(r) == 1 end)
      assert s1.status == :error

      md = s1.metadata
      failure_reason = Map.get(md, "failure_reason") || Map.get(md, :failure_reason)
      pre_cap = Map.get(md, "accumulated_context_bytes_pre_cap")
      dropped = Map.get(md, "dropped_stage_indexes")
      assert failure_reason =~ "initial prompt alone"
      assert pre_cap == byte_size(big_prompt)
      # Locks in the "no drops were possible" metadata shape — there are no
      # prior stages to drop when stage 1 overflows.
      assert dropped == []
    end

    test "first accumulate stage passes through when initial prompt fits the cap" do
      name = "cap_first_stage_ok_#{System.unique_integer([:positive])}"

      assert {:ok, _result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   max_context_bytes: 500,
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"}
                   ]
                 },
                 %{reasoning_runner: FixedBodyRunner}
               )

      rows = find_pipeline_rows(name)
      s1 = Enum.find(rows, fn r -> stage_index(r) == 1 end)
      # No drops occurred — no cap metadata recorded, matching existing
      # "success without drops" convention.
      refute Map.has_key?(s1.metadata, "accumulated_context_bytes_pre_cap")
      refute Map.has_key?(s1.metadata, "dropped_stage_indexes")
    end

    test "elision notice bytes factor into cap budget" do
      name = "cap_notice_#{System.unique_integer([:positive])}"

      assert {:ok, _result} =
               RunPipeline.run(
                 %{
                   pipeline_name: name,
                   prompt: "INITIAL",
                   max_context_bytes: 500,
                   stages: [
                     %{"strategy" => "cot", "context_mode" => "accumulate"},
                     %{"strategy" => "tot", "context_mode" => "accumulate"},
                     %{"strategy" => "cod", "context_mode" => "accumulate"}
                   ]
                 },
                 %{reasoning_runner: FixedBodyRunner}
               )

      # Post-cap bytes INCLUDE the elision notice bytes — the notice is
      # budgeted against the cap, so the final prompt never silently overruns.
      rows = find_pipeline_rows(name)
      s3 = Enum.find(rows, fn r -> stage_index(r) == 3 end)
      dropped = Map.get(s3.metadata, "dropped_stage_indexes")
      post_cap = Map.get(s3.metadata, "accumulated_context_bytes_post_cap")
      assert is_list(dropped) and dropped != []
      assert post_cap <= 500
      # Body alone (initial + s2 header + 400-byte output) is ~427 bytes; the
      # post_cap value must be larger because the notice is appended.
      assert post_cap > 427
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
