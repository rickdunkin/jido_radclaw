defmodule JidoClaw.FrontDoor.Clarify.LedgerTest do
  @moduledoc """
  The OR2-5 ledger item normalization (string keys, string enums, the
  fail-closed `user_input_required` coercion) and the pure projections the
  floor/gate read. Pure — no LLM, no DB.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.FrontDoor.Clarify.Ledger

  describe "normalize/1" do
    test "normalizes a full string-keyed item (the scorer wire shape)" do
      assert [item] =
               Ledger.normalize([
                 %{
                   "question" => "Which auth flow?",
                   "why_it_matters" => "shapes the whole surface",
                   "risk_if_unanswered" => "wrong protocol",
                   "recommended_default_assumption" => "OAuth device flow",
                   "user_input_required" => true,
                   "status" => "open",
                   "user_answer" => nil
                 }
               ])

      assert item["question"] == "Which auth flow?"
      assert item["user_input_required"] == true
      assert item["status"] == "open"
      assert item["user_answer"] == nil
    end

    test "accepts atom-keyed synthetic maps (the Verdict get idiom)" do
      assert [item] =
               Ledger.normalize([%{question: "q?", status: :answered, user_answer: "yes"}])

      assert item["question"] == "q?"
      assert item["status"] == "answered"
      assert item["user_answer"] == "yes"
    end

    test "user_input_required fails CLOSED: only a literal false is assumable" do
      base = %{"question" => "q?"}

      assert [%{"user_input_required" => true}] = Ledger.normalize([base])

      assert [%{"user_input_required" => true}] =
               Ledger.normalize([Map.put(base, "user_input_required", nil)])

      assert [%{"user_input_required" => true}] =
               Ledger.normalize([Map.put(base, "user_input_required", "no")])

      assert [%{"user_input_required" => false}] =
               Ledger.normalize([Map.put(base, "user_input_required", false)])
    end

    test "unknown status coerces to open (unknown means unresolved)" do
      assert [%{"status" => "open"}] =
               Ledger.normalize([%{"question" => "q?", "status" => "resolved!!"}])
    end

    test "question-less or junk items are dropped, non-list input is []" do
      assert Ledger.normalize([%{"status" => "open"}, %{"question" => "   "}, "junk"]) == []
      assert Ledger.normalize(nil) == []
      assert Ledger.normalize(%{}) == []
    end

    test "missing text fields coerce to empty strings (JSON-safe)" do
      assert [item] = Ledger.normalize([%{"question" => "q?"}])
      assert item["why_it_matters"] == ""
      assert item["risk_if_unanswered"] == ""
      assert item["recommended_default_assumption"] == ""
    end
  end

  describe "projections" do
    defp item(question, status, required? \\ true) do
      %{"question" => question, "status" => status, "user_input_required" => required?}
    end

    defp ledger do
      Ledger.normalize([
        item("a?", "open"),
        item("b?", "conflicting", false),
        item("c?", "answered"),
        item("d?", "assumed", false)
      ])
    end

    test "counts/1 tallies open/conflicting/assumed/total" do
      assert Ledger.counts(ledger()) == %{open: 1, conflicting: 1, assumed: 1, total: 4}
      assert Ledger.counts([]) == %{open: 0, conflicting: 0, assumed: 0, total: 0}
    end

    test "open_items/1 is the unresolved set (open + conflicting)" do
      questions =
        ledger()
        |> Ledger.open_items()
        |> Enum.map(& &1["question"])

      assert questions == ["a?", "b?"]
    end

    test "open_required?/1 keys off unresolved ∧ required" do
      assert Ledger.open_required?(ledger())

      # The only unresolved-required item resolved ⇒ no longer blocked.
      refute Ledger.open_required?([
               item("a?", "answered"),
               item("b?", "conflicting", false),
               item("d?", "assumed", false)
             ])
    end

    test "unresolved_slots/1 caps each label at 80 chars" do
      long = String.duplicate("x", 200)
      assert [slot] = Ledger.unresolved_slots([item(long, "open")])
      assert String.length(slot) == 81
      assert String.ends_with?(slot, "…")

      assert Ledger.unresolved_slots(ledger()) == ["a?", "b?"]
    end
  end

  describe "merge_preserved/2" do
    defp answered(question, answer) do
      %{"question" => question, "status" => "answered", "user_answer" => answer}
    end

    test "the result wins by question key; dropped prior items re-append in prior order" do
      prior = Ledger.normalize([answered("q1?", "a1"), item("q2?", "open")])
      result = Ledger.normalize([item("q3?", "open")])

      merged = Ledger.merge_preserved(prior, result)

      assert Enum.map(merged, & &1["question"]) == ["q3?", "q1?", "q2?"]
      assert Enum.at(merged, 1)["user_answer"] == "a1"
    end

    test "matching is case/whitespace-insensitive — an updated item replaces, never duplicates" do
      prior = Ledger.normalize([item("Which  endpoint?", "open")])
      result = Ledger.normalize([answered("which endpoint?", "/search")])

      assert [only] = Ledger.merge_preserved(prior, result)
      assert only["status"] == "answered"
    end

    test "identity when the result covers every prior key, and over an empty prior" do
      prior = Ledger.normalize([item("q1?", "open")])
      result = Ledger.normalize([answered("q1?", "a1"), item("q2?", "open")])

      assert Ledger.merge_preserved(prior, result) == result
      assert Ledger.merge_preserved([], result) == result
    end
  end
end
