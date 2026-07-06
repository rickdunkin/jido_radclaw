defmodule JidoClaw.Eval.PromptCasesTest do
  @moduledoc """
  Seed :prompt eval cases (unadopted-next-five item 5) pinning the post-AR-9
  assembled sub-agent prompt: the `code_doctrine` slice reaching the coder, the
  reviewer-contract prose half + stage-first persona resolution, the AR-9 lens
  planner voice, and the arbiter's tie-break ladder/verdict tokens reaching the
  assembled prompt. Hermetic-live: `SubagentPrompt.build/3` runs for real, with
  a tenant-less tmp `project_dir` (no DB, no Block tier, no JIDO.md) and the
  `:psychology` env armed per test — `async: false`.
  """

  use ExUnit.Case, async: false

  alias JidoClaw.Eval

  # One-liner copy of the reviewer finding-contract field list (prose half);
  # the schema seed file owns the shared canonical statement of the contract.
  @reviewer_finding_fields ~w(title severity confidence location description)

  @rung_tokens ~w(correctness grounding simpler-first validation-rollback cost)
  @verdict_tokens ~w(adopt hybrid revise_first)

  setup do
    project_dir =
      Path.join(System.tmp_dir!(), "eval_prompt_cases_#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)
    on_exit(fn -> File.rm_rf(project_dir) end)

    original = Application.get_env(:jido_claw, :psychology)
    Application.put_env(:jido_claw, :psychology, enabled?: true)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:jido_claw, :psychology)
        val -> Application.put_env(:jido_claw, :psychology, val)
      end
    end)

    {:ok, tool_context: %{project_dir: project_dir}}
  end

  defp run_prompt_case(id, request, assertions) do
    assert {:ok, run} =
             Eval.run_case(%{id: id, kind: :prompt, request: request, assertions: assertions})

    failed = Enum.reject(run.assertions, &(&1.status == :passed))
    assert run.status == :passed, "#{id} failed: #{inspect(failed, pretty: true)}"
    run
  end

  defp backticked(tokens), do: Enum.map(tokens, &("`" <> &1 <> "`"))

  test "coder prompt: role + code-craft/confidence slices + Craftsperson fallback voice",
       %{tool_context: tool_context} do
    run_prompt_case(
      "prompt-coder",
      %{template: "coder", tool_context: tool_context},
      %{
        contains: [
          "# Role",
          "## DOCTRINE",
          "Code craft",
          "Confidence tagging",
          "## PSYCHOLOGY: Craftsperson"
        ],
        not_contains: "Review discipline"
      }
    )
  end

  test "reviewer prompt, stage-first: contract prose + Pragmatist over the Skeptic fallback",
       %{tool_context: tool_context} do
    run_prompt_case(
      "prompt-reviewer-architecture",
      %{template: "reviewer", tool_context: tool_context, stage: "architecture-reviewer"},
      %{
        # The four finding fields in their backticked reviewer_contract.md form —
        # the prose half of the contract S1 pins the schema half of.
        contains:
          ["Reviewer Contract", "action_needed", "## PSYCHOLOGY: Pragmatist"] ++
            backticked(@reviewer_finding_fields),
        # The reviewer family is excluded from the confidence_tagging slice.
        not_contains: "Confidence tagging"
      }
    )
  end

  test "plan_drafter prompt over a lens stage: Detective voice + producer doctrine",
       %{tool_context: tool_context} do
    run_prompt_case(
      "prompt-plan-drafter-lens",
      %{
        template: "plan_drafter",
        tool_context: tool_context,
        stage: "planner-smallest-shippable"
      },
      %{contains: ["## PSYCHOLOGY: Detective", "## DOCTRINE", "Runtime artifacts"]}
    )
  end

  test "plan_arbiter prompt: tie-break ladder + every rung/verdict token + the 10th persona",
       %{tool_context: tool_context} do
    run_prompt_case(
      "prompt-plan-arbiter",
      %{template: "plan_arbiter", tool_context: tool_context, stage: "plan-arbiter"},
      %{
        contains:
          ["Plan arbitration", "Tie-break ladder", "## PSYCHOLOGY: Arbiter"] ++
            backticked(@rung_tokens) ++ backticked(@verdict_tokens)
      }
    )
  end
end
