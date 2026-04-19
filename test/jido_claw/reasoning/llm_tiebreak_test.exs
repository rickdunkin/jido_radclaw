defmodule JidoClaw.Reasoning.LLMTiebreakerTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.LLMTiebreaker

  defmodule OkRunner do
    @moduledoc false

    # Return the tail candidate name as the LLM's answer. Used to prove
    # LLMTiebreaker actually parses the runner's output into the chosen name.
    def run(%{prompt: prompt}, _ctx) do
      # Pull the candidate CSV from the prompt's final instruction line.
      last =
        case Regex.run(~r/nothing else:\s*([\w\-_, ]+)/, prompt) do
          [_, names] ->
            names
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> List.last()

          _ ->
            "cot"
        end

      {:ok, %{output: last, usage: %{input_tokens: 5, output_tokens: 1}}}
    end
  end

  defmodule ErrorRunner do
    @moduledoc false
    def run(_params, _ctx), do: {:error, :simulated_failure}
  end

  defmodule RationaleRunner do
    @moduledoc false

    # Emit a response with rationale before the final name — tiebreaker should
    # still parse the last token correctly.
    def run(_params, _ctx) do
      {:ok, %{output: "Given the complexity, the right pick is tot"}}
    end
  end

  defmodule UnparseableRunner do
    @moduledoc false

    def run(_params, _ctx) do
      {:ok, %{output: "I am unsure — maybe neither works here, let me think more."}}
    end
  end

  describe "choose/3" do
    test "returns {:ok, chosen} when the runner picks a listed candidate" do
      assert {:ok, "tot"} =
               LLMTiebreaker.choose("plan something", ["cot", "tot"], runner: OkRunner)
    end

    test "handles runner :error with {:error, reason}" do
      assert {:error, :simulated_failure} =
               LLMTiebreaker.choose("plan", ["cot", "tot"], runner: ErrorRunner)
    end

    test "parses the last token when the LLM adds rationale before the name" do
      assert {:ok, "tot"} =
               LLMTiebreaker.choose("plan", ["cot", "tot"], runner: RationaleRunner)
    end

    test "returns :unparseable when the LLM output doesn't mention any candidate" do
      assert {:error, :unparseable} =
               LLMTiebreaker.choose("plan", ["cot", "tot"], runner: UnparseableRunner)
    end

    test "emits telemetry on invocation and choice" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "tiebreak-test-#{System.unique_integer([:positive])}",
        [
          [:jido_claw, :reasoning, :tiebreak, :invoked],
          [:jido_claw, :reasoning, :tiebreak, :chose]
        ],
        fn event, _m, meta, _ -> send(test_pid, {ref, event, meta}) end,
        nil
      )

      LLMTiebreaker.choose("plan", ["cot", "tot"], runner: OkRunner)

      assert_receive {^ref, [:jido_claw, :reasoning, :tiebreak, :invoked], _}
      assert_receive {^ref, [:jido_claw, :reasoning, :tiebreak, :chose], %{chosen: "tot"}}
    end
  end
end
