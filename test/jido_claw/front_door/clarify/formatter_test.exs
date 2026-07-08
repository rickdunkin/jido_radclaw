defmodule JidoClaw.FrontDoor.Clarify.FormatterTest do
  @moduledoc """
  Rendering shapes for the clarify acks + the two compose-time projections
  (bounded digest, full transcript), and the deterministic override check.
  Pure — no LLM, no DB.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.FrontDoor.Clarify.Formatter
  alias JidoClaw.FrontDoor.Clarify.State

  defp item(question, opts) do
    %{
      "question" => question,
      "why_it_matters" => Keyword.get(opts, :why, ""),
      "risk_if_unanswered" => "",
      "recommended_default_assumption" => Keyword.get(opts, :default, ""),
      "user_input_required" => Keyword.get(opts, :required, true),
      "status" => Keyword.get(opts, :status, "open"),
      "user_answer" => Keyword.get(opts, :answer, nil)
    }
  end

  defp state(ledger, extra \\ []) do
    struct!(
      %State{original_message: "make it faster", ledger: ledger},
      extra
    )
  end

  describe "override?/1" do
    test "affirmative forms fire deterministically — case/whitespace/punctuation tolerant" do
      assert Formatter.override?("proceed with defaults")
      assert Formatter.override?("  Proceed   WITH defaults, please")
      assert Formatter.override?("ok — proceed\nwith defaults")
      assert Formatter.override?("yes please proceed with defaults!")
    end

    test "negated forms NEVER fire — they fall through to the scorer" do
      refute Formatter.override?("do not proceed with defaults")
      refute Formatter.override?("don't proceed with defaults")
      refute Formatter.override?("never proceed with defaults")
      refute Formatter.override?("no, proceed with defaults")
    end

    test "mixed content NEVER fires — the extra ask must reach the scorer, not be dropped" do
      refute Formatter.override?("proceed with defaults but skip the tests")
      refute Formatter.override?("proceed with defaults and add retries to the client")
    end

    test "absent, partial, or broken-up phrase never fires" do
      refute Formatter.override?("proceed")
      refute Formatter.override?("use the defaults")
      refute Formatter.override?("proceed with the defaults")
      refute Formatter.override?(nil)
    end
  end

  describe "questions/3" do
    test "renders round X/N, the top open question with why/default, and the override" do
      ledger = [
        item("Which endpoint?", why: "targets the work", default: "the slowest one"),
        item("Latency or throughput?", default: "p95 latency"),
        item("answered one", status: "answered", answer: "yes")
      ]

      out = Formatter.questions(state(ledger), 1, 12)

      assert out =~ "a question (round 1/12)"
      assert out =~ "Which endpoint?"
      assert out =~ "why it matters: targets the work"
      assert out =~ "default if skipped: the slowest one"
      refute out =~ "Latency or throughput?"
      refute out =~ "answered one"
      assert out =~ Formatter.override_phrase()
    end

    test "asks exactly one question per round — the first OPEN item" do
      ledger = [
        item("resolved head", status: "answered", answer: "x"),
        item("q1?", []),
        item("q2?", [])
      ]

      out = Formatter.questions(state(ledger), 2, 12)

      assert out =~ "q1?"
      refute out =~ "q2?"
      refute out =~ "resolved head"
    end

    test "with NO open item it falls back to the recap — never a \"(none)\" round" do
      ledger = [item("done", status: "answered", answer: "x")]

      out = Formatter.questions(state(ledger, updated_intent: "crisp intent"), 3, 12)

      refute out =~ "(none)"
      assert out =~ "Intent: crisp intent"
      assert out =~ Formatter.override_phrase()
    end
  end

  describe "recap/1" do
    test "restates the updated intent and the working answers/assumptions" do
      ledger = [
        item("Which endpoint?", status: "answered", answer: "/search"),
        item("Budget?", status: "assumed", default: "no budget cap")
      ]

      out = Formatter.recap(state(ledger, updated_intent: "speed up /search p95"))

      assert out =~ "Intent: speed up /search p95"
      assert out =~ "Which endpoint? → /search"
      assert out =~ "Budget? → (assumed) no budget cap"
      assert out =~ Formatter.override_phrase()
    end

    test "falls back to the original message when no updated intent exists" do
      assert Formatter.recap(state([])) =~ "Intent: make it faster"
    end
  end

  describe "hold/1" do
    test "lists only the unresolved REQUIRED questions plus the accept instruction" do
      ledger = [
        item("required open", required: true),
        item("assumable open", required: false),
        item("done", status: "answered", answer: "x")
      ]

      out = Formatter.hold(state(ledger))

      assert out =~ "required open"
      refute out =~ "assumable open"
      assert out =~ Formatter.override_phrase()
      assert out =~ "degraded"
    end
  end

  describe "scorer_failure_ack/1" do
    test "first failure invites a re-send; from the second, override-only" do
      first = Formatter.scorer_failure_ack(1)
      assert first =~ "Re-send"
      assert first =~ Formatter.override_phrase()

      second = Formatter.scorer_failure_ack(2)
      refute second =~ "Re-send"
      assert second =~ Formatter.override_phrase()
    end
  end

  describe "digest/1" do
    test "renders resolved Q/A pairs, assumed entries labeled" do
      ledger = [
        item("Which endpoint?", status: "answered", answer: "/search"),
        item("Budget?", status: "assumed", default: "none"),
        item("still open", [])
      ]

      digest = Formatter.digest(state(ledger))

      assert digest =~ "Which endpoint? => /search"
      assert digest =~ "Budget? => (assumed) none"
      refute digest =~ "still open"
    end

    test "stays within the 560-byte budget on whole entries" do
      long = String.duplicate("a", 300)

      ledger =
        for n <- 1..10 do
          item("q#{n} #{long}?", status: "answered", answer: long)
        end

      digest = Formatter.digest(state(ledger))

      assert byte_size(digest) <= 560
      # Whole entries only — never a mid-entry byte split (every kept entry
      # carries its "=>" separator).
      assert digest == "" or digest =~ " => "
    end

    test "empty when nothing is resolved" do
      assert Formatter.digest(state([item("open q", [])])) == ""
    end
  end

  describe "transcript/1" do
    test "renders the full resolved Q/A list" do
      ledger = [
        item("Which endpoint?", status: "answered", answer: "/search"),
        item("Budget?", status: "assumed", default: "none")
      ]

      transcript = Formatter.transcript(state(ledger))

      assert transcript =~ "Q: Which endpoint?\nA: /search"
      assert transcript =~ "Q: Budget?\nA: (assumed) none"
    end

    test "empty when nothing is resolved" do
      assert Formatter.transcript(state([item("open", [])])) == ""
    end
  end
end
