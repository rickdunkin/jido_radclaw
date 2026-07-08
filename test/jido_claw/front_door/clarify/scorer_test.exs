defmodule JidoClaw.FrontDoor.Clarify.ScorerTest do
  @moduledoc """
  The scorer's LLM boundary via a canned `:clarify_generate` seam: happy
  normalization, malformed/error/raise handling (never raises out), the
  untrusted-evidence framing, and knob forwarding. No real LLM.

  Non-async: mutates `:clarify_generate` / `:clarify_model` app env.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.FrontDoor.Clarify.Scorer

  setup do
    on_exit(fn ->
      Application.delete_env(:jido_claw, :clarify_generate)
      Application.delete_env(:jido_claw, :clarify_model)
    end)

    :ok
  end

  defp resp(object) do
    %ReqLLM.Response{id: "test", model: "test", context: nil, object: object}
  end

  defp stub(fun), do: Application.put_env(:jido_claw, :clarify_generate, fun)

  defp args(extra \\ %{}) do
    Map.merge(
      %{
        original_message: "make it faster",
        latest_message: "the /search endpoint",
        ledger: [%{"question" => "which endpoint?", "status" => "open"}],
        history: [%{role: "assistant", content: "which part is slow?"}]
      },
      extra
    )
  end

  defp object do
    %{
      "classification" => "answers",
      "clarity" => %{
        "goal" => 0.9,
        "constraints" => 0.7,
        "success_criteria" => 0.75,
        "context" => 0.8
      },
      "ambiguity" => 0.05,
      "updated_intent" => "speed up /search",
      "ledger" => [
        %{
          "question" => "which endpoint?",
          "status" => "answered",
          "user_answer" => "/search",
          "user_input_required" => true
        }
      ]
    }
  end

  test "happy path: normalizes classification/clarity/ledger and computes ambiguity" do
    stub(fn _input, _schema, _opts -> {:ok, resp(object())} end)

    assert {:ok, result} = Scorer.score(args())
    assert result.classification == :answers
    assert result.clarity["goal"] == 0.9
    assert result.updated_intent == "speed up /search"
    assert [%{"status" => "answered", "user_answer" => "/search"}] = result.ledger

    # computed = 1 − (0.9·0.35 + 0.7·0.25 + 0.75·0.25 + 0.8·0.15) = 0.2025;
    # the reported 0.05 under-reports, so the computed channel wins.
    assert result.llm_ambiguity == 0.2025
  end

  test "the reported ambiguity wins when HIGHER than the computed one" do
    stub(fn _input, _schema, _opts -> {:ok, resp(%{object() | "ambiguity" => 0.9})} end)

    assert {:ok, %{llm_ambiguity: 0.9}} = Scorer.score(args())
  end

  test "typed premises fields normalize at the boundary (item 9); absent reads as []" do
    typed =
      Map.merge(object(), %{
        "acceptance_criteria" => ["  `mix test` passes ", "", 42],
        "evaluation_principles" => [
          %{"name" => "correctness", "description" => "must be right", "weight" => 1.7},
          "junk"
        ],
        "exit_conditions" => ["stop after 3 attempts"]
      })

    stub(fn _input, _schema, _opts -> {:ok, resp(typed)} end)

    assert {:ok, result} = Scorer.score(args())
    assert result.acceptance_criteria == ["`mix test` passes"]

    assert result.evaluation_principles == [
             %{"name" => "correctness", "description" => "must be right", "weight" => 1.0}
           ]

    assert result.exit_conditions == ["stop after 3 attempts"]

    # Absent fields normalize to [] (fold keeps the prior round's lists).
    stub(fn _input, _schema, _opts -> {:ok, resp(object())} end)

    assert {:ok, result} = Scorer.score(args())
    assert result.acceptance_criteria == []
    assert result.evaluation_principles == []
    assert result.exit_conditions == []
  end

  test "classification enum: atoms (Zoi-validated) and strings both normalize; unknown ⇒ :answers" do
    for {wire, expected} <- [
          {:override, :override},
          {"new_ask", :new_ask},
          {"garbage", :answers},
          {nil, :answers}
        ] do
      stub(fn _input, _schema, _opts -> {:ok, resp(%{object() | "classification" => wire})} end)
      assert {:ok, %{classification: ^expected}} = Scorer.score(args())
    end
  end

  test "a malformed object is infra ({:error, :malformed_object}), never a fabricated result" do
    # Missing clarity/ledger entirely.
    stub(fn _input, _schema, _opts -> {:ok, resp(%{"garbage" => true})} end)
    assert {:error, :malformed_object} = Scorer.score(args())

    # Not a map at all (unwrap_object passes any non-nil object through).
    stub(fn _input, _schema, _opts -> {:ok, resp(["not", "a", "map"])} end)
    assert {:error, :malformed_object} = Scorer.score(args())

    # Junk clarity.
    stub(fn _input, _schema, _opts -> {:ok, resp(%{object() | "clarity" => "high"})} end)
    assert {:error, :malformed_object} = Scorer.score(args())

    # Junk ledger.
    stub(fn _input, _schema, _opts -> {:ok, resp(%{object() | "ledger" => "none"})} end)
    assert {:error, :malformed_object} = Scorer.score(args())
  end

  test "a result that would wipe a non-empty prior ledger is {:error, :ledger_wiped}" do
    # Raw empty result ledger against the non-empty prior in args().
    stub(fn _input, _schema, _opts -> {:ok, resp(%{object() | "ledger" => []})} end)
    assert {:error, :ledger_wiped} = Scorer.score(args())

    # A non-empty raw list whose items ALL normalize away (no question) is a
    # wipe too — the check runs post-`Ledger.normalize/1`.
    stub(fn _input, _schema, _opts ->
      {:ok, resp(%{object() | "ledger" => [%{"status" => "open"}]})}
    end)

    assert {:error, :ledger_wiped} = Scorer.score(args())
  end

  test "an empty result ledger against an empty prior passes (nothing to wipe)" do
    stub(fn _input, _schema, _opts -> {:ok, resp(%{object() | "ledger" => []})} end)
    assert {:ok, %{ledger: []}} = Scorer.score(args(%{ledger: []}))
  end

  test "new_ask is exempt from the wipe guard — the pivot path discards the ledger by design" do
    stub(fn _input, _schema, _opts ->
      {:ok, resp(%{object() | "classification" => "new_ask", "ledger" => []})}
    end)

    assert {:ok, %{classification: :new_ask}} = Scorer.score(args())
  end

  test "provider error passes through as {:error, _}" do
    stub(fn _input, _schema, _opts -> {:error, :timeout} end)
    assert {:error, :timeout} = Scorer.score(args())
  end

  test "a raise/throw inside generate never escapes (infra, not a crash)" do
    stub(fn _input, _schema, _opts -> raise "kaboom" end)
    assert {:error, :scorer_failed} = Scorer.score(args())

    stub(fn _input, _schema, _opts -> throw(:thrown) end)
    assert {:error, :scorer_failed} = Scorer.score(args())
  end

  test "non-tuple returns normalize to {:error, {:unexpected, _}}" do
    stub(fn _input, _schema, _opts -> :weird end)
    assert {:error, {:unexpected, :weird}} = Scorer.score(args())
  end

  test "input carries the untrusted BEGIN/END framing with every section, history redacted" do
    parent = self()

    stub(fn input, _schema, _opts ->
      send(parent, {:input, input})
      {:ok, resp(object())}
    end)

    secret_history = [%{role: "user", content: "my key is sk-ant-abcdefghijklmnopqrstuvwx"}]
    assert {:ok, _} = Scorer.score(args(%{history: secret_history}))

    assert_receive {:input, [%{role: :user, content: content}]}
    assert content =~ "BEGIN UNTRUSTED CONVERSATION EVIDENCE"
    assert content =~ "END UNTRUSTED CONVERSATION EVIDENCE"
    assert content =~ "ORIGINAL REQUEST:"
    assert content =~ "LATEST USER MESSAGE:"
    assert content =~ "PRIOR LEDGER (JSON):"
    assert content =~ "RECENT CONVERSATION"
    # History is redacted at the scorer boundary — the raw key never rides.
    refute content =~ "sk-ant-abcdefghijklmnopqrstuvwx"
    assert content =~ "[REDACTED:ANTHROPIC_KEY]"
  end

  test "open turn (nil latest, empty ledger) omits those sections" do
    parent = self()

    stub(fn input, _schema, _opts ->
      send(parent, {:input, input})
      {:ok, resp(object())}
    end)

    assert {:ok, _} = Scorer.score(args(%{latest_message: nil, ledger: [], history: []}))

    assert_receive {:input, [%{role: :user, content: content}]}
    assert content =~ "ORIGINAL REQUEST:"
    refute content =~ "LATEST USER MESSAGE:"
    refute content =~ "PRIOR LEDGER"
  end

  test "forwards the knobs: model (default :capable + override), temp 0.1, timeout, max_tokens" do
    parent = self()

    stub(fn _input, _schema, opts ->
      send(parent, {:opts, opts})
      {:ok, resp(object())}
    end)

    assert {:ok, _} = Scorer.score(args())
    assert_receive {:opts, opts}
    assert opts[:model] == :capable
    assert opts[:temperature] == 0.1
    assert opts[:timeout] == 30_000
    assert opts[:max_tokens] == 2_000
    assert is_binary(opts[:system_prompt])

    Application.put_env(:jido_claw, :clarify_model, "anthropic:claude-sonnet-5")
    assert {:ok, _} = Scorer.score(args())
    assert_receive {:opts, opts2}
    assert opts2[:model] == "anthropic:claude-sonnet-5"
  end

  test "invalid args refuse without calling the LLM" do
    stub(fn _input, _schema, _opts -> flunk("must not be called") end)
    assert {:error, :invalid_scorer_args} = Scorer.score(%{original_message: nil})
  end
end
