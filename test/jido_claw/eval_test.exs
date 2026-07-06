defmodule JidoClaw.EvalTest do
  @moduledoc """
  Unit tests for the deterministic eval harness (`JidoClaw.Eval` +
  `JidoClaw.Eval.{Case, Run}`), driven through the pure kinds (`:schema`,
  `:coherence`) only — DB-free, async. The seed case files under
  `test/jido_claw/eval/` cover the `:prompt` and `:composer` kinds.
  """

  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Workers.PlanArbiter
  alias JidoClaw.Agent.Workers.Reviewer
  alias JidoClaw.Eval
  alias JidoClaw.Eval.Case, as: EvalCase
  alias JidoClaw.Eval.Run

  # Minimal valid reviewer verdict (string-keyed, findings-free) — deliberately
  # smaller than the seed files' enriched samples so the two never clone.
  defp clean_verdict do
    %{
      "overall" => "comment",
      "summary" => "tight scope, one observation",
      "action_needed" => "none",
      "findings" => []
    }
  end

  # clean_verdict() plus one valid finding — shared by the field_equals index
  # walk and the coherence fixtures so the finding literal isn't cloned per test.
  defp verdict_with_finding do
    Map.put(clean_verdict(), "findings", [
      %{
        "title" => "possible off-by-one",
        "severity" => "warning",
        "confidence" => "unsure",
        "location" => "lib/bar.ex:7",
        "description" => "possible off-by-one"
      }
    ])
  end

  defp schema_case(assertions) do
    %{
      kind: :schema,
      request: %{module: Reviewer, sample: clean_verdict()},
      assertions: assertions
    }
  end

  defp coherence_case(field, tokens, assertions) do
    %{
      kind: :coherence,
      request: %{
        slice: :confidence_tagging,
        module: Reviewer,
        field: field,
        base_sample: verdict_with_finding(),
        tokens: tokens,
        non_token: "maybe"
      },
      assertions: assertions
    }
  end

  describe "run_case/2 — pass/fail mapping" do
    test "a valid sample under valid: true maps to :passed with every record :passed" do
      assert {:ok, %Run{} = run} =
               Eval.run_case(schema_case(%{valid: true, field_equals: [{[:overall], :comment}]}))

      assert run.status == :passed
      assert run.kind == :schema
      assert [_, _] = run.assertions
      assert Enum.all?(run.assertions, &(&1.status == :passed))
      assert run.observations.sample_parsed_ok
    end

    test "a sample missing a required field under valid: maps to :failed with expected/actual" do
      broken = Map.delete(clean_verdict(), "summary")

      assert {:ok, run} = Eval.run_case(schema_case(%{valid: [broken]}))

      assert run.status == :failed

      assert [%{name: :valid, status: :failed, expected: :accepted, actual: {:error, _}}] =
               run.assertions

      assert run.observations.valid_samples == 1
    end

    test "field_equals walks integer list indices through the atom-keyed parsed output" do
      assert {:ok, run} =
               Eval.run_case(%{
                 kind: :schema,
                 request: %{module: Reviewer, sample: verdict_with_finding()},
                 assertions: %{field_equals: [{[:findings, 0, :severity], "warning"}]}
               })

      assert run.status == :passed
    end
  end

  describe "Case normalization + validation" do
    test "an injected :id_generator pins the case id" do
      assert {:ok, run} =
               Eval.run_case(schema_case(%{valid: true}), id_generator: fn -> "eval_fixed" end)

      assert run.case_id == "eval_fixed"
    end

    test "a default id is minted with the eval_ prefix" do
      assert {:ok, run} = Eval.run_case(schema_case(%{valid: true}))
      assert String.starts_with?(run.case_id, "eval_")
    end

    test "string-keyed top-level attrs and an exact string kind are accepted" do
      attrs = %{
        "id" => "eval_string_keys",
        "kind" => "schema",
        "request" => %{module: Reviewer, sample: clean_verdict()}
      }

      assert {:ok, %EvalCase{id: "eval_string_keys", kind: :schema}} = EvalCase.new(attrs)
    end

    test "an unknown kind is rejected — atoms and non-exact strings alike" do
      assert {:error, {:invalid_eval_kind, :nope}} = EvalCase.new(%{kind: :nope, request: %{}})

      assert {:error, {:invalid_eval_kind, "Schema"}} =
               EvalCase.new(%{kind: "Schema", request: %{}})

      assert {:error, {:invalid_eval_kind, nil}} = EvalCase.new(%{request: %{}})
    end

    test "an empty or non-binary id is rejected" do
      assert {:error, {:invalid_eval_case_id, ""}} =
               EvalCase.new(%{id: "", kind: :schema, request: %{}})

      assert {:error, {:invalid_eval_case_id, 7}} =
               EvalCase.new(%{id: 7, kind: :schema, request: %{}})
    end

    test "a missing or non-map request is rejected" do
      assert {:error, {:invalid_eval_request, :missing}} = EvalCase.new(%{kind: :schema})

      assert {:error, {:invalid_eval_request, "nope"}} =
               EvalCase.new(%{kind: :schema, request: "nope"})
    end

    test "new!/2 raises ArgumentError on an invalid case" do
      assert_raise ArgumentError, ~r/invalid eval case/, fn ->
        EvalCase.new!(%{kind: :bad, request: %{}})
      end
    end

    test "a hand-built invalid %Case{} is re-validated (and rejected) by from_input/2" do
      invalid = %EvalCase{id: "eval_x", kind: :not_a_kind, request: %{}}

      assert {:error, {:invalid_eval_kind, :not_a_kind}} = EvalCase.from_input(invalid)
      assert {:error, {:invalid_eval_kind, :not_a_kind}} = Eval.run_case(invalid)
    end
  end

  describe "Run validation" do
    test "statuses/0 lists the three run statuses" do
      assert Run.statuses() == [:passed, :failed, :error]
    end

    test "an invalid status is rejected; new!/1 raises" do
      assert {:error, {:invalid_eval_run_status, :maybe}} =
               Run.new(case_id: "eval_x", kind: :schema, status: :maybe)

      assert_raise ArgumentError, ~r/invalid eval run/, fn ->
        Run.new!(case_id: "eval_x", kind: :schema, status: :maybe)
      end
    end

    test "an unknown kind and an empty case_id are rejected" do
      assert {:error, {:invalid_eval_kind, :nope}} =
               Run.new(case_id: "eval_x", kind: :nope, status: :passed)

      assert {:error, {:invalid_eval_case_id, ""}} =
               Run.new(case_id: "", kind: :schema, status: :passed)
    end
  end

  describe "error mapping" do
    test "a :schema case naming a module without strategy_opts/0 yields a :error run" do
      assert {:ok, run} =
               Eval.run_case(%{kind: :schema, request: %{module: JidoClaw.Doctrine, sample: %{}}})

      assert run.status == :error
      assert run.error.reason == :execution_raised
      assert run.assertions == []
    end

    test "a :coherence case with a typo'd field path yields a :error run (fail-loudly put_path)" do
      assert {:ok, run} =
               Eval.run_case(%{
                 kind: :coherence,
                 request: %{
                   slice: :tie_break,
                   module: PlanArbiter,
                   field: ["not_a_field"],
                   base_sample: %{"verdict" => "adopt"},
                   tokens: ["adopt"],
                   non_token: "vibes"
                 }
               })

      assert run.status == :error
      assert run.error.reason == :execution_raised
    end

    test "an out-of-range list index in a coherence field path yields a :error run" do
      assert {:ok, run} =
               Eval.run_case(
                 coherence_case(["findings", 5, "confidence"], ["likely"], %{
                   schema_accepts_tokens: true
                 })
               )

      assert run.status == :error
      assert run.error.reason == :execution_raised
      assert run.error.message =~ "out of range"
    end
  end

  describe "unknown assertion keys fail loudly" do
    test "a typo'd assertion key fails the run with an :unknown_assertion record naming it" do
      assert {:ok, run} =
               Eval.run_case(schema_case(%{valid: true, feild_equals: [{[:overall], :comment}]}))

      assert run.status == :failed

      assert Enum.any?(run.assertions, fn a ->
               a.name == :unknown_assertion and a.status == :failed and a.actual == :feild_equals
             end),
             "expected an :unknown_assertion record naming :feild_equals, got: #{inspect(run.assertions)}"

      assert Enum.any?(run.assertions, &(&1.name == :valid and &1.status == :passed))
    end

    test "a known key with a malformed value fails via :invalid_assertion_value" do
      assert {:ok, run} = Eval.run_case(schema_case(%{valid: true, field_equals: :everything}))

      assert run.status == :failed

      assert Enum.any?(run.assertions, &(&1.name == :invalid_assertion_value)),
             "expected an :invalid_assertion_value record, got: #{inspect(run.assertions)}"
    end

    test "malformed field_equals list items fail per-item via :invalid_assertion_value" do
      assert {:ok, run} =
               Eval.run_case(schema_case(%{field_equals: [:bad_tuple, {"overall", :comment}]}))

      assert run.status == :failed

      invalid = Enum.filter(run.assertions, &(&1.name == :invalid_assertion_value))

      assert match?([_, _], invalid),
             "expected exactly two :invalid_assertion_value records, got: #{inspect(run.assertions)}"

      assert Enum.any?(invalid, &(&1.actual == :bad_tuple))
      assert Enum.any?(invalid, &(&1.actual == {"overall", :comment}))
    end

    test "a raise inside an assertion evaluator fails via :assertion_raised" do
      assert {:ok, run} =
               Eval.run_case(
                 coherence_case(["findings", 0, "confidence"], [123], %{
                   prose_contains_tokens: true
                 })
               )

      assert run.status == :failed

      assert Enum.any?(
               run.assertions,
               &(&1.name == :assertion_raised and &1.expected == :prose_contains_tokens)
             ),
             "expected an :assertion_raised record for :prose_contains_tokens, got: #{inspect(run.assertions)}"
    end
  end
end
