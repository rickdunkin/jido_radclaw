defmodule JidoClaw.FrontDoor.Clarify do
  @moduledoc """
  The bounded conversation-axis clarify loop (queue item 8 — ouroboros OB1-1
  + orca OR2-5): when triage flags an ambiguous `code`/`system` ask, score →
  ask one question at a time → fold answers → re-score instead of composing
  on a misread ask, then compose with the answers folded into premises — or with
  an honest `degraded: true` + `unresolved_slots` labeling. Port provenance:
  `docs/exploration/ouroboros/PORT-OB1-1.md`.

  This module is the DECISION layer: it redacts at lane entry, drives the
  scorer, folds `Clarify.State`, and returns directives. `JidoClaw.FrontDoor`
  owns persistence (the result-checked `pending_clarify` writes) and the
  composer launch.

  ## Lane-entry redaction

  Every incoming message — open, continue, AND the one-shot degraded path —
  passes `Patterns.redact_with_count/1` BEFORE scoring and before any ledger
  persist, so persisted `user_answer`s, the Q/A digest, and the seed
  transcript are built from redacted material. A nonzero count sets the
  sticky `sensitive` bit the compose ORs into `mark_sensitive` (answers can
  introduce secrets AFTER triage's `:secrets` signal was decided).

  ## Directives (`continue/5`)

    * `{:questions, state, ack}` — a question round OR the streak-1
      recap-confirm round; persist state, reply `ack`.
    * `{:hold, state, ack}` — at the round cap with required unknowns open;
      persist, reply the accept-assumptions ack. Never auto-composes.
    * `{:compose, spec}` — launch the composer from `spec` (clean, degraded,
      or override — see `t:spec/0`).
    * `:new_ask` — the message pivoted; clear state and fall through to
      fresh triage.
    * `{:failure, state, ack}` — scorer infra failure (transport error,
      malformed/ledger-wiping result, or a non-qualifying result with zero
      open items — infra ≠ verdict: never reads as clarified, never folds);
      persist the failure count, reply the bounded ack (override-only from
      the 2nd consecutive failure).
  """

  alias JidoClaw.FrontDoor.Clarify.Formatter
  alias JidoClaw.FrontDoor.Clarify.Ledger
  alias JidoClaw.FrontDoor.Clarify.Score
  alias JidoClaw.FrontDoor.Clarify.Scorer
  alias JidoClaw.FrontDoor.Clarify.State
  alias JidoClaw.Security.Redaction.Patterns
  alias JidoClaw.Triage.Verdict

  # One question is asked per round; the cap is the source `auto` pipeline's.
  @default_round_cap 12

  @typedoc """
  The compose payload: the final state, the intent/signals-adjusted verdict
  (`:ambiguous` dropped on clean, kept on degraded), the clarify premises,
  the transcript-enriched seed, the sticky sensitivity bit, and the compose
  `origin` (`:streak | :cap | :override | :one_shot` — telemetry only).
  """
  @type spec :: %{
          state: State.t(),
          verdict: Verdict.t(),
          degraded?: boolean(),
          origin: :streak | :cap | :override | :one_shot,
          premises: map(),
          seed: String.t(),
          sensitive?: boolean()
        }

  @doc """
  The loop's start gate (OQ-4, signal-gated): an `:ambiguous` early signal on
  a `code`/`system` verdict. Sketch is never gated — it IS the
  clarify-by-doing lane.
  """
  @spec trigger?(Verdict.t()) :: boolean()
  def trigger?(%Verdict{path: path, signals: signals}),
    do: path in [:code, :system] and :ambiguous in signals

  @doc "The question-round cap (knob `:clarify_round_cap`, default #{@default_round_cap})."
  @spec round_cap() :: pos_integer()
  def round_cap, do: Application.get_env(:jido_claw, :clarify_round_cap, @default_round_cap)

  @doc """
  Read the session's pending clarify state: `:none` (absent or unparseable-
  absent), `{:live, state}`, or `{:expired, state_or_nil}` (TTL passed, or a
  junk shape that must be lazily cleared).
  """
  @spec load_pending(term(), DateTime.t()) ::
          :none | {:live, State.t()} | {:expired, State.t() | nil}
  def load_pending(%{metadata: %{"pending_clarify" => %{} = raw}}, %DateTime{} = now) do
    case State.from_metadata(raw) do
      {:ok, state} -> if State.expired?(state, now), do: {:expired, state}, else: {:live, state}
      :error -> {:expired, nil}
    end
  end

  def load_pending(_session, _now), do: :none

  @doc """
  The open turn: redact, score once over (original message, empty ledger,
  history), and return the first round — questions, or the recap-confirm
  round when the very first score already qualifies (streak 1 of 2; no
  fabricated question). The CALLER persists the state and only shows the ack
  on a successful write. Scorer failure — or a non-qualifying result with
  zero open items (`{:error, :no_open_questions}`: nothing to ask, nothing
  honest to compose) — is `{:error, reason}`: fail open to the standard
  composer.
  """
  @spec open(String.t(), Verdict.t(), [map()], DateTime.t()) ::
          {:ok, State.t(), String.t()} | {:error, term()}
  def open(message, %Verdict{} = verdict, history, %DateTime{} = now) do
    {redacted, hits} = Patterns.redact_with_count(message)

    with {:ok, result} <- score(redacted, nil, [], history),
         {:ok, qualifying?} <- askable(result) do
      state =
        redacted
        |> State.new(verdict, now)
        |> State.mark_sensitive(hits > 0)
        |> State.fold_score(result, qualifying?, now)
        |> State.record_round(now)

      {:ok, state, round_ack(state, qualifying?)}
    end
  end

  @doc """
  A continue turn against live pending state. The deterministic override
  phrase is checked FIRST (it must work while the scorer is down); otherwise
  one scorer call classifies `answers | override | new_ask`, folds, and
  re-scores. See the moduledoc for the directive vocabulary.
  """
  @spec continue(State.t(), String.t(), [map()], DateTime.t(), pos_integer()) ::
          {:questions, State.t(), String.t()}
          | {:hold, State.t(), String.t()}
          | {:compose, spec()}
          | :new_ask
          | {:failure, State.t(), String.t()}
  def continue(%State{} = state, message, history, %DateTime{} = now, cap) do
    {redacted, hits} = Patterns.redact_with_count(message)
    state = State.mark_sensitive(state, hits > 0)

    if Formatter.override?(redacted) do
      {:compose, override_spec(state)}
    else
      continue_scored(state, redacted, history, now, cap)
    end
  end

  @doc """
  The `:one_shot` degraded path: one scorer call for slots/score (nothing
  persisted — no loop to correlate), composing immediately with the
  degraded labeling. The surface skipped the loop, so the compose is ALWAYS
  `degraded: true` (`:ambiguous` kept — never confirmed resolved). Scorer
  failure — including `{:error, :no_open_questions}` (a degraded compose
  with `readiness: ready_for_tasks` and no slots from that scorer-failure
  class would be incoherent) — is `{:error, reason}`: compose as today.
  """
  @spec score_once_for_slots(String.t(), Verdict.t(), [map()], DateTime.t()) ::
          {:ok, spec()} | {:error, term()}
  def score_once_for_slots(message, %Verdict{} = verdict, history, %DateTime{} = now) do
    {redacted, hits} = Patterns.redact_with_count(message)

    with {:ok, result} <- score(redacted, nil, [], history),
         {:ok, qualifying?} <- askable(result) do
      state =
        redacted
        |> State.new(verdict, now)
        |> State.mark_sensitive(hits > 0)
        |> State.fold_score(result, qualifying?, now)

      {:ok, compose_spec(state, true, :one_shot)}
    end
  end

  # ---------------------------------------------------------------------------
  # Continue-turn routing
  # ---------------------------------------------------------------------------

  defp continue_scored(state, redacted, history, now, cap) do
    case score(state.original_message, redacted, state.ledger, history) do
      {:ok, %{classification: :new_ask}} ->
        :new_ask

      {:ok, %{classification: :override} = result} ->
        merged = merge_ledger(state, result)
        {:compose, override_spec(State.fold_score(state, merged, qualifies?(merged), now))}

      {:ok, result} ->
        continue_folded(state, merge_ledger(state, result), now, cap)

      {:error, _reason} ->
        scorer_failure(state, now)
    end
  end

  # Fold-time preservation: the result ledger wins, but items the scorer
  # DROPPED are re-appended from the prior ledger BEFORE the gate and the
  # fold read it — a dropped item can neither vanish from the accumulated
  # Q/A nor lower the deterministic floor.
  defp merge_ledger(state, result) do
    %{result | ledger: Ledger.merge_preserved(state.ledger, result.ledger)}
  end

  # The empty-open guard runs BEFORE the fold: folding first would zero the
  # consecutive-failure escalation and replace the accumulated ledger with
  # one carrying nothing left to ask.
  defp continue_folded(state, result, now, cap) do
    case askable(result) do
      {:ok, qualifying?} ->
        route_folded(State.fold_score(state, result, qualifying?, now), qualifying?, now, cap)

      {:error, :no_open_questions} ->
        scorer_failure(state, now)
    end
  end

  defp scorer_failure(state, now) do
    failed = State.record_failure(state, now)
    {:failure, failed, Formatter.scorer_failure_ack(failed.scorer_failures)}
  end

  # A non-qualifying score with zero open items can seed neither an honest
  # round (nothing to ask — the round would be question-less) nor an honest
  # compose (degraded with nothing to report) — infra, and the scorer prompt
  # names it a contract violation.
  defp askable(result) do
    case {qualifies?(result), Ledger.open_items(result.ledger)} do
      {false, []} -> {:error, :no_open_questions}
      {qualifying?, _open} -> {:ok, qualifying?}
    end
  end

  defp route_folded(folded, qualifying?, now, cap) do
    cond do
      qualifying? and folded.streak >= Score.streak_required() ->
        {:compose, compose_spec(folded, false, :streak)}

      # Qualifying round 1 of the streak: the recap-confirm round (restate
      # updated intent + assumptions) — never a fabricated question
      # (PORT-OB1-1 divergence (c)).
      qualifying? ->
        shown = State.record_round(folded, now)
        {:questions, shown, Formatter.recap(shown)}

      folded.rounds_shown < cap ->
        shown = State.record_round(folded, now)
        {:questions, shown, Formatter.questions(shown, shown.rounds_shown, cap)}

      # At the cap: a required unknown HOLDS for the explicit
      # accept-assumptions ack (decision 2 — never auto-compose past it);
      # only-assumable items auto-compose degraded.
      Ledger.open_required?(folded.ledger) ->
        {:hold, folded, Formatter.hold(folded)}

      true ->
        {:compose, compose_spec(folded, true, :cap)}
    end
  end

  # Override composes clean ONLY after a qualifying score (streak ≥ 1) with
  # zero unresolved items; anything else is the honest degraded label.
  defp override_spec(state) do
    clean? = state.streak >= 1 and Ledger.open_items(state.ledger) == []
    compose_spec(state, not clean?, :override)
  end

  # ---------------------------------------------------------------------------
  # Compose spec
  # ---------------------------------------------------------------------------

  defp compose_spec(state, degraded?, origin) do
    %{
      state: state,
      verdict: compose_verdict(state, degraded?),
      degraded?: degraded?,
      origin: origin,
      premises: compose_premises(state, degraded?),
      seed: compose_seed(state),
      sensitive?: state.sensitive
    }
  end

  # Intent precedence: scorer `updated_intent` → stored verdict intent → the
  # original ask. `:ambiguous` drops on a clean compose (resolved) and stays
  # on a degraded one (honest); every other signal rides unchanged.
  defp compose_verdict(state, degraded?) do
    verdict = state.verdict

    intent =
      present(state.updated_intent) || present(verdict.intent) || state.original_message

    signals = if degraded?, do: verdict.signals, else: List.delete(verdict.signals, :ambiguous)

    %{verdict | intent: intent, signals: signals}
  end

  defp compose_premises(state, degraded?) do
    counts = Ledger.counts(state.ledger)
    effective = Score.effective_ambiguity(state.llm_ambiguity, Score.deterministic_floor(counts))

    %{"ambiguity_score" => effective, "readiness" => Score.readiness(state.ledger)}
    |> put_present("clarifications", Formatter.digest(state))
    |> put_degraded(degraded?, Ledger.unresolved_slots(state.ledger))
  end

  # The request-seed artifact: the original ask plus the full (redacted) Q/A
  # transcript — the composer starts from what was actually established.
  defp compose_seed(state) do
    case Formatter.transcript(state) do
      "" -> state.original_message
      transcript -> state.original_message <> "\n\n--- Clarification Q/A ---\n" <> transcript
    end
  end

  defp put_present(premises, _key, ""), do: premises
  defp put_present(premises, key, value), do: Map.put(premises, key, value)

  defp put_degraded(premises, false, _slots), do: premises
  defp put_degraded(premises, true, []), do: Map.put(premises, "degraded", true)

  defp put_degraded(premises, true, slots) do
    premises
    |> Map.put("degraded", true)
    |> Map.put("unresolved_slots", slots)
  end

  # ---------------------------------------------------------------------------
  # Scoring plumbing
  # ---------------------------------------------------------------------------

  defp score(original, latest, ledger, history) do
    Scorer.score(%{
      original_message: original,
      latest_message: latest,
      ledger: ledger,
      history: history
    })
  end

  # The pass gate over ONE scorer result: effective ambiguity (max of the LLM
  # score and the deterministic floor over the freshly folded ledger) against
  # the threshold + the four dimension floors.
  defp qualifies?(%{clarity: clarity, llm_ambiguity: llm, ledger: ledger}) do
    floor = Score.deterministic_floor(Ledger.counts(ledger))
    Score.qualifies?(Score.effective_ambiguity(llm, floor), clarity)
  end

  defp round_ack(state, true), do: Formatter.recap(state)
  defp round_ack(state, false), do: Formatter.questions(state, state.rounds_shown, round_cap())

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp present(_value), do: nil
end
