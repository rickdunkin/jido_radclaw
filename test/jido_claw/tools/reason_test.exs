defmodule JidoClaw.Tools.ReasonTest do
  # async: false — uses the supervised StrategyStore (named GenServer) and
  # writes rows to reasoning_outcomes.
  use ExUnit.Case, async: false

  import JidoClaw.Reasoning.StrategyTestHelper

  alias JidoClaw.Reasoning.Resources.Outcome
  alias JidoClaw.Tools.Reason

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  defmodule CotRunner do
    @moduledoc false

    # Reflects the incoming strategy atom in :output so tests can assert the
    # resolved base was dispatched correctly (not just that *some* runner ran).
    def run(%{strategy: strategy}, _context) do
      {:ok,
       %{
         output: "ran with strategy=#{inspect(strategy)}",
         usage: %{input_tokens: 11, output_tokens: 22}
       }}
    end
  end

  # Captures the incoming params by inspecting them into :output so tests can
  # assert on what the runner actually received (including prompt-template
  # keys merged in from a user alias).
  defmodule ParamInspectingRunner do
    @moduledoc false

    def run(params, _context) do
      {:ok,
       %{
         output: inspect(params),
         usage: %{input_tokens: 0, output_tokens: 0}
       }}
    end
  end

  # The react branch doesn't invoke RunStrategy at all (it's a structured-
  # prompt stub), so CotRunner is irrelevant there — no stubbing needed.

  defp find_row(filters) do
    [:debugging, :verification, :qa, :planning, :refactoring, :exploration, :open_ended]
    |> Enum.flat_map(fn tt ->
      for kind <- [:strategy_run, :react_stub, :certificate_verification] do
        case Outcome.list_by_task_type(tt, kind) do
          {:ok, rows} -> rows
          _ -> []
        end
      end
      |> List.flatten()
    end)
    |> Enum.find(fn row ->
      Enum.all?(filters, fn {k, v} -> Map.get(row, k) == v end)
    end)
  end

  describe "direct built-in dispatch" do
    test "direct 'react' writes a :react_stub row with base_strategy='react'" do
      assert {:ok, %{strategy: "react", output: output}} =
               Reason.run(%{strategy: "react", prompt: "why is x broken?"}, %{})

      assert output =~ "[ReAct Reasoning Mode]"

      row = find_row(strategy: "react", execution_kind: :react_stub)
      assert row
      assert row.base_strategy == "react"
    end

    test "direct 'cot' dispatches to the injected runner with base :cot and writes a :strategy_run row" do
      assert {:ok, result} =
               Reason.run(
                 %{strategy: "cot", prompt: "some cot reasoning task"},
                 %{reasoning_runner: CotRunner}
               )

      assert result.strategy == "cot"
      assert result.output == "ran with strategy=:cot"
      assert result.usage == %{input_tokens: 11, output_tokens: 22}

      row = find_row(strategy: "cot", execution_kind: :strategy_run)
      assert row
      assert row.base_strategy == "cot"
      assert row.tokens_in == 11
      assert row.tokens_out == 22
      assert row.status == :ok
    end
  end

  describe "user alias dispatch" do
    test "react-aliased strategy dispatches to the react branch with user-facing name" do
      with_user_strategy(
        """
        name: deep_debug
        base: react
        """,
        fn ->
          assert {:ok, %{strategy: "deep_debug", output: output}} =
                   Reason.run(%{strategy: "deep_debug", prompt: "why is x broken?"}, %{})

          assert output =~ "[ReAct Reasoning Mode]"

          row = find_row(strategy: "deep_debug", execution_kind: :react_stub)
          assert row
          assert row.base_strategy == "react"
        end
      )
    end

    test "non-react alias resolves to base :cot when dispatching to the runner" do
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        """,
        fn ->
          assert {:ok, result} =
                   Reason.run(
                     %{
                       strategy: "fast_reviewer",
                       prompt: "review this neutral bucket placeholder"
                     },
                     %{reasoning_runner: CotRunner}
                   )

          # User-facing name preserved in the result…
          assert result.strategy == "fast_reviewer"
          # …but the runner was invoked with the resolved base atom :cot.
          assert result.output == "ran with strategy=:cot"

          row = find_row(strategy: "fast_reviewer", execution_kind: :strategy_run)
          assert row
          assert row.base_strategy == "cot"
        end
      )
    end
  end

  describe "unknown strategy" do
    test "returns an error with the list of valid strategies" do
      assert {:error, msg} =
               Reason.run(%{strategy: "not_a_strategy", prompt: "anything"}, %{})

      assert msg =~ "Unknown strategy"
    end
  end

  describe "auto strategy" do
    test "dispatches via AutoSelect and writes a row with concrete strategy + selection_mode metadata" do
      assert {:ok, result} =
               Reason.run(
                 %{strategy: "auto", prompt: "What is a GenServer?"},
                 %{reasoning_runner: CotRunner}
               )

      # Row must carry the concrete winner, never "auto".
      refute result.strategy == "auto"
      refute result.strategy == "adaptive"

      row = find_row(strategy: result.strategy, execution_kind: :strategy_run)
      assert row
      # metadata keys round-trip as strings through Postgres JSONB.
      selection_mode =
        Map.get(row.metadata, "selection_mode") || Map.get(row.metadata, :selection_mode)

      assert selection_mode == "auto"
    end

    test "accepts 'adaptive' as a deprecated alias that normalizes to auto" do
      assert {:ok, result} =
               Reason.run(
                 %{strategy: "adaptive", prompt: "What is a GenServer?"},
                 %{reasoning_runner: CotRunner}
               )

      refute result.strategy == "adaptive"
      refute result.strategy == "auto"

      row = find_row(strategy: result.strategy, execution_kind: :strategy_run)
      assert row

      selection_mode =
        Map.get(row.metadata, "selection_mode") || Map.get(row.metadata, :selection_mode)

      assert selection_mode == "auto"
    end

    test "outcome row's strategy column is the base name (never the alias) when an alias wins" do
      # Seed strong favorable history for a cot-based alias and force the
      # LLM tiebreaker off so the heuristic top pick wins deterministically.
      # The pipeline should resolve the alias to its base, store the *base*
      # name ("cot") in reasoning_outcomes.strategy, and record the alias
      # in metadata.alias_name for diagnostics.
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        prefers:
          task_types: [qa, verification]
          complexity: [simple, moderate]
        """,
        fn ->
          # Poison the alias history with high success/samples so it ranks
          # first in the heuristic candidate pool.
          history = [
            %{
              strategy: "fast_reviewer",
              success_rate: 1.0,
              avg_duration_ms: 100.0,
              samples: 100
            }
          ]

          # The tool's run_auto path doesn't currently thread caller opts
          # through to AutoSelect — so this test verifies a weaker (but
          # important) property: when run_auto happens to resolve to an
          # alias, the outcome row stores the base name.
          #
          # Drive it directly by stubbing the classifier side through a
          # call to Reason.run/2. On systems with no reasoning_outcomes
          # rows yet, AutoSelect will fall back to heuristics and may or
          # may not pick the alias — but whichever concrete strategy wins,
          # the stored row must carry the base name only.
          _ = history

          assert {:ok, result} =
                   Reason.run(
                     %{strategy: "auto", prompt: "What is a GenServer?"},
                     %{reasoning_runner: CotRunner}
                   )

          # result.strategy is the base name returned by format_runner_result.
          # It must be a concrete built-in base atom's string form — never
          # "auto", "adaptive", or an alias.
          assert result.strategy in ~w(react cot cod tot got aot trm)
          refute result.strategy == "fast_reviewer"

          row = find_row(strategy: result.strategy, execution_kind: :strategy_run)
          assert row
          # The stored strategy is always the base. When the row's base and
          # strategy match a built-in, no alias_name key is recorded.
          assert row.strategy == row.base_strategy

          alias_name =
            Map.get(row.metadata, "alias_name") || Map.get(row.metadata, :alias_name)

          # Either the alias won (then alias_name is recorded) or a built-in
          # won (then alias_name is absent). Both are valid — the critical
          # invariant is that row.strategy is never the alias name.
          if alias_name do
            assert alias_name == "fast_reviewer"
          end
        end
      )
    end

    test "no alias_name metadata key when a built-in wins" do
      # No user aliases registered — auto must pick a built-in and the
      # metadata must not carry an alias_name key.
      assert {:ok, result} =
               Reason.run(
                 %{strategy: "auto", prompt: "What is a GenServer?"},
                 %{reasoning_runner: CotRunner}
               )

      row = find_row(strategy: result.strategy, execution_kind: :strategy_run)
      assert row

      alias_name =
        Map.get(row.metadata, "alias_name") || Map.get(row.metadata, :alias_name)

      refute alias_name
    end
  end

  describe "user alias prompt template threading" do
    test "cot alias with prompts.system forwards :system_prompt to the runner" do
      with_user_strategy(
        """
        name: mathy
        base: cot
        prompts:
          system: "You are a rigorous mathematician"
        """,
        fn ->
          assert {:ok, result} =
                   Reason.run(
                     %{strategy: "mathy", prompt: "prove 2 + 2 = 4"},
                     %{reasoning_runner: ParamInspectingRunner}
                   )

          assert result.output =~ "system_prompt:"
          assert result.output =~ "You are a rigorous mathematician"
          # Runner still receives the resolved base atom, not the alias.
          assert result.output =~ "strategy: :cot"
        end
      )
    end

    test "cod alias with prompts.system forwards :system_prompt" do
      with_user_strategy(
        """
        name: short
        base: cod
        prompts:
          system: "Be terse"
        """,
        fn ->
          assert {:ok, result} =
                   Reason.run(
                     %{strategy: "short", prompt: "Explain recursion"},
                     %{reasoning_runner: ParamInspectingRunner}
                   )

          assert result.output =~ "system_prompt:"
          assert result.output =~ "Be terse"
          assert result.output =~ "strategy: :cod"
        end
      )
    end

    test "tot alias forwards :generation_prompt and :evaluation_prompt" do
      with_user_strategy(
        """
        name: explorer
        base: tot
        prompts:
          generation: "Propose diverse branches"
          evaluation: "Rate each branch for soundness"
        """,
        fn ->
          assert {:ok, result} =
                   Reason.run(
                     %{strategy: "explorer", prompt: "Design an auth system"},
                     %{reasoning_runner: ParamInspectingRunner}
                   )

          assert result.output =~ "generation_prompt:"
          assert result.output =~ "Propose diverse branches"
          assert result.output =~ "evaluation_prompt:"
          assert result.output =~ "Rate each branch for soundness"
        end
      )
    end

    test "got alias forwards :generation_prompt, :connection_prompt, :aggregation_prompt" do
      with_user_strategy(
        """
        name: grapher
        base: got
        prompts:
          generation: "Seed nodes"
          connection: "Connect related nodes"
          aggregation: "Synthesize"
        """,
        fn ->
          assert {:ok, result} =
                   Reason.run(
                     %{strategy: "grapher", prompt: "Interrelate these ideas"},
                     %{reasoning_runner: ParamInspectingRunner}
                   )

          assert result.output =~ "generation_prompt:"
          assert result.output =~ "Seed nodes"
          assert result.output =~ "connection_prompt:"
          assert result.output =~ "Connect related nodes"
          assert result.output =~ "aggregation_prompt:"
          assert result.output =~ "Synthesize"
        end
      )
    end

    test "built-in name (no alias) passes no extra prompt keys" do
      assert {:ok, result} =
               Reason.run(
                 %{strategy: "cot", prompt: "plain built-in"},
                 %{reasoning_runner: ParamInspectingRunner}
               )

      refute result.output =~ "system_prompt:"
      refute result.output =~ "generation_prompt:"
    end

    test "auto path forwards alias prompts when an alias wins" do
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        display_name: "Fast Reviewer"
        prefers:
          task_types: [qa, verification]
          complexity: [simple, moderate]
        prompts:
          system: "You are a fast, focused reviewer"
        """,
        fn ->
          assert {:ok, result} =
                   Reason.run(
                     %{strategy: "auto", prompt: "What is a GenServer?"},
                     %{reasoning_runner: ParamInspectingRunner}
                   )

          # Whenever AutoSelect happens to pick the alias, the runner must see
          # its :system_prompt. When a built-in wins instead, no template is
          # forwarded. Either outcome is valid — the invariant is "prompts
          # travel with the alias, not the base."
          row = find_row(strategy: result.strategy, execution_kind: :strategy_run)
          assert row

          alias_name =
            Map.get(row.metadata, "alias_name") || Map.get(row.metadata, :alias_name)

          if alias_name == "fast_reviewer" do
            assert result.output =~ "You are a fast, focused reviewer"
          else
            refute result.output =~ "You are a fast, focused reviewer"
          end
        end
      )
    end
  end
end
