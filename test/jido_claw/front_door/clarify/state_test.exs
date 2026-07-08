defmodule JidoClaw.FrontDoor.Clarify.StateTest do
  @moduledoc """
  The durable clarify state: the JSONB round trip (encode → decode →
  `from_metadata` — the reloaded-path rule), TTL boundary behavior, and the
  streak/round/failure transitions ported from ouroboros. Pure — uses the
  default TTL knob, no app-env mutation.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.FrontDoor.Clarify.State
  alias JidoClaw.Triage.Verdict

  @now ~U[2026-07-07 12:00:00.000000Z]

  defp verdict do
    %Verdict{
      path: :code,
      signals: [:ambiguous, :significant_build],
      est_size: :l,
      intent: "make it faster",
      intent_confirmed?: false,
      multi_plan?: false,
      reasons: %{}
    }
  end

  defp scored(state, qualifying?) do
    State.fold_score(
      state,
      %{
        ledger: [
          %{
            "question" => "faster at what?",
            "why_it_matters" => "targets the work",
            "risk_if_unanswered" => "wrong hot path",
            "recommended_default_assumption" => "p95 request latency",
            "user_input_required" => true,
            "status" => "answered",
            "user_answer" => "API latency"
          }
        ],
        clarity: %{
          "goal" => 0.9,
          "constraints" => 0.8,
          "success_criteria" => 0.8,
          "context" => 0.7
        },
        llm_ambiguity: 0.15,
        updated_intent: "cut API p95 latency"
      },
      qualifying?,
      @now
    )
  end

  describe "JSONB round trip (encode → decode → from_metadata)" do
    test "a scored state survives byte-identical, hyphenated signals included" do
      state =
        "make it faster"
        |> State.new(verdict(), @now)
        |> scored(true)
        |> State.record_round(@now)
        |> State.mark_sensitive(true)

      reloaded =
        state
        |> State.to_metadata()
        |> Jason.encode!()
        |> Jason.decode!()
        |> State.from_metadata()

      assert {:ok, ^state} = reloaded
      # The wire-form trap: the hyphenated signal must survive the round trip.
      assert {:ok, %State{verdict: %Verdict{signals: signals}}} = reloaded
      assert :significant_build in signals
    end

    test "a fresh (unscored) state round-trips too" do
      state = State.new("vague ask", verdict(), @now)

      assert {:ok, ^state} =
               state
               |> State.to_metadata()
               |> Jason.encode!()
               |> Jason.decode!()
               |> State.from_metadata()
    end

    test "from_metadata rejects junk (missing message / bad verdict / non-map)" do
      assert :error = State.from_metadata(%{"verdict" => %{"path" => "code"}})
      assert :error = State.from_metadata(%{"original_message" => "x", "verdict" => %{}})
      assert :error = State.from_metadata(%{"original_message" => "x"})
      assert :error = State.from_metadata("junk")
      assert :error = State.from_metadata(nil)
    end

    test "typed premises lists round-trip and follow the keep-if-empty fold rule (item 9)" do
      folded =
        State.fold_score(
          State.new("ask", verdict(), @now),
          %{
            acceptance_criteria: ["`mix test` passes"],
            evaluation_principles: [
              %{"name" => "correctness", "description" => "must be right", "weight" => 0.9}
            ],
            exit_conditions: ["stop after 3 attempts"]
          },
          true,
          @now
        )

      assert folded.acceptance_criteria == ["`mix test` passes"]

      # A later round whose scorer omitted the lists (normalized to []) keeps
      # the prior round's — an LLM lapse can't erase them.
      refolded =
        State.fold_score(
          folded,
          %{acceptance_criteria: [], evaluation_principles: [], exit_conditions: []},
          true,
          @now
        )

      assert refolded.acceptance_criteria == ["`mix test` passes"]
      assert refolded.evaluation_principles == folded.evaluation_principles
      assert refolded.exit_conditions == ["stop after 3 attempts"]

      # And the whole state — typed lists included — survives the JSONB trip.
      assert {:ok, ^refolded} =
               refolded
               |> State.to_metadata()
               |> Jason.encode!()
               |> Jason.decode!()
               |> State.from_metadata()
    end
  end

  describe "expired?/2 (default 1h TTL off last activity)" do
    test "at exactly the TTL it is still live; past it, expired" do
      state = State.new("ask", verdict(), @now)

      at_ttl = DateTime.add(@now, :timer.hours(1), :millisecond)
      past_ttl = DateTime.add(at_ttl, 1, :millisecond)

      refute State.expired?(state, at_ttl)
      assert State.expired?(state, past_ttl)
    end

    test "activity refreshes the clock (updated_at wins over created_at)" do
      later = DateTime.add(@now, :timer.minutes(50), :millisecond)

      state =
        "ask"
        |> State.new(verdict(), @now)
        |> State.record_round(later)

      probe = DateTime.add(@now, :timer.minutes(70), :millisecond)
      refute State.expired?(state, probe)
    end

    test "unparseable timestamps read as expired (junk lazily clears)" do
      assert State.expired?(%State{updated_at: "not-a-time"}, @now)
      assert State.expired?(%State{}, @now)
    end
  end

  describe "transitions" do
    test "fold_score qualifying increments the streak; non-qualifying resets it" do
      state = State.new("ask", verdict(), @now)

      once = scored(state, true)
      assert once.streak == 1

      twice = scored(once, true)
      assert twice.streak == 2

      reset = scored(twice, false)
      assert reset.streak == 0
    end

    test "fold_score clears the consecutive-failure counter" do
      state =
        "ask"
        |> State.new(verdict(), @now)
        |> State.record_failure(@now)

      assert state.scorer_failures == 1
      assert scored(state, true).scorer_failures == 0
    end

    test "record_failure bumps failures AND resets the streak (non-qualifying signal)" do
      state =
        "ask"
        |> State.new(verdict(), @now)
        |> scored(true)

      assert state.streak == 1

      failed = State.record_failure(state, @now)
      assert failed.scorer_failures == 1
      assert failed.streak == 0

      assert State.record_failure(failed, @now).scorer_failures == 2
    end

    test "fold_score keeps the prior updated_intent when the new one is blank" do
      state =
        "ask"
        |> State.new(verdict(), @now)
        |> scored(true)

      assert state.updated_intent == "cut API p95 latency"

      refolded =
        State.fold_score(state, %{updated_intent: nil}, true, @now)

      assert refolded.updated_intent == "cut API p95 latency"

      refolded_blank = State.fold_score(state, %{updated_intent: "   "}, true, @now)
      assert refolded_blank.updated_intent == "cut API p95 latency"
    end

    test "record_round increments rounds_shown" do
      state = State.new("ask", verdict(), @now)
      assert State.record_round(state, @now).rounds_shown == 1
    end

    test "sensitive is sticky: sets on true, never clears on false" do
      state =
        "ask"
        |> State.new(verdict(), @now)
        |> State.mark_sensitive(true)

      assert state.sensitive
      assert State.mark_sensitive(state, false).sensitive
    end
  end
end
