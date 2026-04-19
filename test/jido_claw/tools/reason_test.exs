defmodule JidoClaw.Tools.ReasonTest do
  # async: false — uses the supervised StrategyStore (named GenServer) and
  # writes rows to reasoning_outcomes.
  use ExUnit.Case, async: false

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

  # The react branch doesn't invoke RunStrategy at all (it's a structured-
  # prompt stub), so CotRunner is irrelevant there — no stubbing needed.

  defp with_user_strategy(yaml, fun) do
    project_dir = Application.get_env(:jido_claw, :project_dir, File.cwd!())
    dir = Path.join([project_dir, ".jido", "strategies"])
    File.mkdir_p!(dir)

    path = Path.join(dir, "reason_test_alias_#{System.unique_integer([:positive])}.yaml")
    File.write!(path, yaml)

    try do
      JidoClaw.Reasoning.StrategyStore.reload()
      fun.()
    after
      File.rm(path)
      JidoClaw.Reasoning.StrategyStore.reload()
    end
  end

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
end
