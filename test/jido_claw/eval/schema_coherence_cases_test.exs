defmodule JidoClaw.Eval.SchemaCoherenceCasesTest do
  @moduledoc """
  Seed eval cases (unadopted-next-five item 5) pinning the post-AR-9 worker
  schema surface and its prose↔schema coherence — S1/S2 pin the reviewer
  verdict and arbiter decision-memo schemas (the schema half of the field
  contracts), C1–C3 pin that the `tie_break` / `confidence_tagging` doctrine
  slices and the Zoi enums name the SAME tokens. Pure (`Output.parse` +
  `Doctrine.slice/1` only): DB-free, env-free, async.
  """

  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Workers.PlanArbiter
  alias JidoClaw.Agent.Workers.Reviewer
  alias JidoClaw.Eval

  # The prose half of the reviewer finding contract (reviewer_contract.md's five
  # field names); the prompt seed file carries its own one-liner copy.
  @reviewer_finding_fields ~w(title severity confidence location description)

  defp assert_passed(run, label) do
    assert run.status == :passed,
           "#{label} failed: #{inspect(Enum.reject(run.assertions, &(&1.status == :passed)), pretty: true)}"
  end

  test "S1: reviewer verdict schema — round-trip split + the 5-field finding contract" do
    invalid_samples =
      Enum.map(@reviewer_finding_fields, fn field ->
        update_in(reviewer_sample(), ["findings", Access.at(0)], &Map.delete(&1, field))
      end)

    assert {:ok, run} =
             Eval.run_case(%{
               id: "s1-reviewer-verdict",
               kind: :schema,
               request: %{module: Reviewer, sample: reviewer_sample()},
               assertions: %{
                 valid: true,
                 # The Envelope round-trip split: `overall` parses to an ATOM,
                 # per-finding severity/confidence stay STRING enums.
                 field_equals: [
                   {[:overall], :approve},
                   {[:findings, 0, :severity], "info"},
                   {[:findings, 0, :confidence], "likely"}
                 ],
                 invalid: invalid_samples
               }
             })

    assert_passed(run, "S1")
    assert run.observations.invalid_samples == length(@reviewer_finding_fields)
  end

  test "S2: arbiter decision-memo schema — string verdict/rung enums, atom status, out-of-enum rejected" do
    assert {:ok, run} =
             Eval.run_case(%{
               id: "s2-arbiter-memo",
               kind: :schema,
               request: %{module: PlanArbiter, sample: memo_sample()},
               assertions: %{
                 valid: true,
                 field_equals: [
                   {[:verdict], "adopt"},
                   {[:tie_break_rung], "correctness"},
                   {[:status], :completed}
                 ],
                 invalid: [
                   %{memo_sample() | "verdict" => "maybe"},
                   %{memo_sample() | "tie_break_rung" => "vibes"}
                 ]
               }
             })

    assert_passed(run, "S2")
  end

  test "C1: tie-break ladder — the five rung tokens are identical in prose and schema" do
    assert {:ok, run} =
             Eval.run_case(%{
               id: "c1-tie-break-rungs",
               kind: :coherence,
               request: %{
                 slice: :tie_break,
                 module: PlanArbiter,
                 field: ["tie_break_rung"],
                 base_sample: memo_sample(),
                 tokens: ~w(correctness grounding simpler-first validation-rollback cost),
                 non_token: "vibes"
               },
               assertions: %{
                 prose_contains_tokens: true,
                 schema_accepts_tokens: true,
                 schema_rejects_non_token: true
               }
             })

    assert_passed(run, "C1")
    assert run.observations.token_count == 5
  end

  test "C2: arbiter verdicts — the three verdict tokens are identical in prose and schema" do
    assert {:ok, run} =
             Eval.run_case(%{
               id: "c2-arbiter-verdicts",
               kind: :coherence,
               request: %{
                 slice: :tie_break,
                 module: PlanArbiter,
                 field: ["verdict"],
                 base_sample: memo_sample(),
                 tokens: ~w(adopt hybrid revise_first),
                 non_token: "maybe"
               },
               assertions: %{
                 prose_contains_tokens: true,
                 schema_accepts_tokens: true,
                 schema_rejects_non_token: true
               }
             })

    assert_passed(run, "C2")
  end

  test "C3: confidence tagging — likely/unsure are identical in prose and the finding enum" do
    assert {:ok, run} =
             Eval.run_case(%{
               id: "c3-confidence-tags",
               kind: :coherence,
               request: %{
                 slice: :confidence_tagging,
                 module: Reviewer,
                 field: ["findings", 0, "confidence"],
                 base_sample: reviewer_sample(),
                 tokens: ~w(likely unsure),
                 non_token: "maybe"
               },
               assertions: %{
                 prose_contains_tokens: true,
                 schema_accepts_tokens: true,
                 schema_rejects_non_token: true
               }
             })

    assert_passed(run, "C3")
  end

  # String-keyed samples shaped like a real LLM return, inline in this file
  # (never test/support — reach's fixed_shape_map) and worded distinctly from
  # the worker_output_schemas_test fixtures (ExSlop clone gate).

  defp reviewer_sample do
    %{
      "overall" => "approve",
      "summary" => "Change is sound; one informational note",
      "action_needed" => "none",
      "findings" => [
        %{
          "title" => "moduledoc missing seed-file citation",
          "severity" => "info",
          "confidence" => "likely",
          "location" => "lib/jido_claw/eval.ex:1",
          "description" => "the moduledoc could cite the seed files"
        }
      ]
    }
  end

  defp memo_sample do
    %{
      "summary" => "DECISION MEMO — verdict: adopt. Plan A wins on the correctness rung.",
      "status" => "completed",
      "confidence" => "high",
      "assessments" => [
        %{
          "lens" => "smallest-shippable",
          "steelman" => "proves the value with the least machinery",
          "strengths" => "tight blast radius",
          "blockers" => "none found"
        }
      ],
      "tie_break_rung" => "correctness",
      "selection" => "smallest-shippable",
      "verdict" => "adopt",
      "revision_directive" => "none",
      "artifacts" => %{}
    }
  end
end
