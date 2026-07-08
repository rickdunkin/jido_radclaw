defmodule JidoClaw.FrontDoor.Clarify.State do
  @moduledoc """
  The durable clarify-loop state, persisted as a string-keyed JSON-safe map
  under `metadata["pending_clarify"]` (via the Session's atomic
  `jsonb_set` metadata action) and reloaded on the next turn.

  Pure: every transition takes the values it needs (`now` comes from the
  caller's `:front_door_clock` seam). The verdict is held as a `%Verdict{}`
  in memory and crosses the JSONB boundary through `Verdict.to_map/1` /
  `from_map/1` (wire strings — hyphenated signals survive the round trip).

  The streak follows ouroboros's rule (PORT-OB1-1): only a qualifying score
  increments it; ANY non-qualifying signal — a weak re-score or a scorer
  failure — resets it to 0. `sensitive` is sticky: once an incoming clarify
  message trips redaction, every later compose marks the run sensitive.
  """

  alias JidoClaw.FrontDoor.Clarify.Ledger
  alias JidoClaw.FrontDoor.Clarify.Score
  alias JidoClaw.RouteComposer.Premises
  alias JidoClaw.Triage.Verdict

  @default_ttl_ms :timer.hours(1)

  @type t :: %__MODULE__{
          original_message: String.t() | nil,
          verdict: Verdict.t() | nil,
          ledger: [Ledger.item()],
          clarity: %{String.t() => float()},
          llm_ambiguity: float(),
          updated_intent: String.t() | nil,
          acceptance_criteria: [String.t()],
          evaluation_principles: [Premises.principle()],
          exit_conditions: [String.t()],
          rounds_shown: non_neg_integer(),
          streak: non_neg_integer(),
          scorer_failures: non_neg_integer(),
          sensitive: boolean(),
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  defstruct original_message: nil,
            verdict: nil,
            ledger: [],
            clarity: %{},
            llm_ambiguity: 1.0,
            updated_intent: nil,
            acceptance_criteria: [],
            evaluation_principles: [],
            exit_conditions: [],
            rounds_shown: 0,
            streak: 0,
            scorer_failures: 0,
            sensitive: false,
            created_at: nil,
            updated_at: nil

  @doc """
  Fresh state for an open turn (nothing scored yet). Clarity starts in the
  canonical all-zero 4-dim shape so `to_metadata |> from_metadata` is
  byte-identical from birth.
  """
  @spec new(String.t(), Verdict.t(), DateTime.t()) :: t()
  def new(message, %Verdict{} = verdict, %DateTime{} = now) do
    iso = DateTime.to_iso8601(now)

    %__MODULE__{
      original_message: message,
      verdict: verdict,
      clarity: Score.normalize_clarity(%{}),
      created_at: iso,
      updated_at: iso
    }
  end

  @doc """
  Fold a normalized scorer result into the state: ledger/clarity/ambiguity
  replaced, `updated_intent` kept when the new one is blank, streak bumped or
  reset by `qualifying?`, and the consecutive-failure counter cleared (a
  successful score IS the recovery signal). Callers folding over a NON-empty
  prior ledger pass a pre-merged result (`Ledger.merge_preserved/2`) so a
  scorer-dropped item is preserved, never lost. The typed premises lists
  (item 9) follow the `updated_intent` rule: a non-empty result replaces,
  an empty one keeps the prior round's — an LLM lapse can't erase them.
  """
  @spec fold_score(t(), map(), boolean(), DateTime.t()) :: t()
  def fold_score(%__MODULE__{} = state, result, qualifying?, %DateTime{} = now)
      when is_map(result) do
    %{
      state
      | ledger: Map.get(result, :ledger, state.ledger),
        clarity: Map.get(result, :clarity, state.clarity),
        llm_ambiguity: Map.get(result, :llm_ambiguity, state.llm_ambiguity),
        updated_intent: present(Map.get(result, :updated_intent)) || state.updated_intent,
        acceptance_criteria:
          keep_if_empty(Map.get(result, :acceptance_criteria), state.acceptance_criteria),
        evaluation_principles:
          keep_if_empty(Map.get(result, :evaluation_principles), state.evaluation_principles),
        exit_conditions: keep_if_empty(Map.get(result, :exit_conditions), state.exit_conditions),
        streak: if(qualifying?, do: state.streak + 1, else: 0),
        scorer_failures: 0,
        updated_at: DateTime.to_iso8601(now)
    }
  end

  @doc "Record that a question/recap round was shown to the user."
  @spec record_round(t(), DateTime.t()) :: t()
  def record_round(%__MODULE__{} = state, %DateTime{} = now) do
    %{state | rounds_shown: state.rounds_shown + 1, updated_at: DateTime.to_iso8601(now)}
  end

  @doc """
  Record a scorer failure: bumps the consecutive-failure counter AND resets
  the streak (a scorer error is a non-qualifying signal — ouroboros's
  `_reset_stale_completion_streak` rule).
  """
  @spec record_failure(t(), DateTime.t()) :: t()
  def record_failure(%__MODULE__{} = state, %DateTime{} = now) do
    %{
      state
      | scorer_failures: state.scorer_failures + 1,
        streak: 0,
        updated_at: DateTime.to_iso8601(now)
    }
  end

  @doc "Sticky sensitivity: sets on a nonzero redaction count, never clears."
  @spec mark_sensitive(t(), boolean()) :: t()
  def mark_sensitive(%__MODULE__{} = state, true), do: %{state | sensitive: true}
  def mark_sensitive(%__MODULE__{} = state, false), do: state

  @doc """
  TTL expiry off the last-activity timestamp (`updated_at`, falling back to
  `created_at`); an unparseable/missing timestamp reads as expired, so junk
  state lazily clears into normal triage. The knob is `:clarify_ttl_ms`
  (default #{@default_ttl_ms}ms).
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{} = state, %DateTime{} = now) do
    case DateTime.from_iso8601(state.updated_at || state.created_at || "") do
      {:ok, dt, _offset} -> DateTime.diff(now, dt, :millisecond) > ttl_ms()
      _invalid -> true
    end
  end

  @doc "The JSON-safe wire form (string keys; verdict via `Verdict.to_map/1`)."
  @spec to_metadata(t()) :: map()
  def to_metadata(%__MODULE__{} = state) do
    %{
      "original_message" => state.original_message,
      "verdict" => state.verdict && Verdict.to_map(state.verdict),
      "ledger" => state.ledger,
      "clarity" => state.clarity,
      "llm_ambiguity" => state.llm_ambiguity,
      "updated_intent" => state.updated_intent,
      "acceptance_criteria" => state.acceptance_criteria,
      "evaluation_principles" => state.evaluation_principles,
      "exit_conditions" => state.exit_conditions,
      "rounds_shown" => state.rounds_shown,
      "streak" => state.streak,
      "scorer_failures" => state.scorer_failures,
      "sensitive" => state.sensitive,
      "created_at" => state.created_at,
      "updated_at" => state.updated_at
    }
  end

  @doc """
  Rebuild from the persisted wire form. `:error` on any shape that can't carry
  a loop (missing original message, unparseable verdict) — the caller treats
  that as no pending state.
  """
  @spec from_metadata(term()) :: {:ok, t()} | :error
  def from_metadata(%{} = raw) do
    with message when is_binary(message) <- raw["original_message"],
         {:ok, %Verdict{} = verdict} <- Verdict.from_map(raw["verdict"]) do
      {:ok,
       %__MODULE__{
         original_message: message,
         verdict: verdict,
         ledger: Ledger.normalize(raw["ledger"]),
         clarity: Score.normalize_clarity(raw["clarity"]),
         llm_ambiguity: number_or(raw["llm_ambiguity"], 1.0),
         updated_intent: binary_or_nil(raw["updated_intent"]),
         acceptance_criteria: Premises.normalize_criteria(raw["acceptance_criteria"]),
         evaluation_principles: Premises.normalize_principles(raw["evaluation_principles"]),
         exit_conditions: Premises.normalize_conditions(raw["exit_conditions"]),
         rounds_shown: int_or(raw["rounds_shown"], 0),
         streak: int_or(raw["streak"], 0),
         scorer_failures: int_or(raw["scorer_failures"], 0),
         sensitive: raw["sensitive"] == true,
         created_at: binary_or_nil(raw["created_at"]),
         updated_at: binary_or_nil(raw["updated_at"])
       }}
    else
      _other -> :error
    end
  end

  def from_metadata(_other), do: :error

  defp ttl_ms, do: Application.get_env(:jido_claw, :clarify_ttl_ms, @default_ttl_ms)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp present(_value), do: nil

  defp keep_if_empty(new, _prior) when is_list(new) and new != [], do: new
  defp keep_if_empty(_new, prior), do: prior

  defp number_or(value, _default) when is_number(value), do: value * 1.0
  defp number_or(_value, default), do: default

  defp int_or(value, _default) when is_integer(value) and value >= 0, do: value
  defp int_or(_value, default), do: default

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil
end
