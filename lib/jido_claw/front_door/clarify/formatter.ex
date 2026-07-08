defmodule JidoClaw.FrontDoor.Clarify.Formatter do
  @moduledoc """
  Pure rendering for the clarify loop's user-facing acks and the two
  compose-time projections: the bounded Q/A `digest/1` (a pre-rendered
  premises string — `PremisesContext` inspect-renders non-binaries, so this
  must arrive as a binary) and the full `transcript/1` appended to the
  request-seed artifact.

  Owns the deterministic override phrase — `override?/1` is the check that
  works while the scorer is down, so the phrase and every ack that advertises
  it live in one module.
  """

  alias JidoClaw.FrontDoor.Clarify.Ledger
  alias JidoClaw.FrontDoor.Clarify.State

  @override_phrase "proceed with defaults"
  @override_tokens String.split(@override_phrase, " ")
  @digest_max_bytes 560
  @text_cap 120

  # Tokens tolerated AROUND the phrase — pure acknowledgment/politeness. Any
  # other token (a negation, a condition, mixed content, novel phrasing)
  # drops the message to the scorer, which folds answers first and can still
  # classify `:override` with full context. Fail-closed polarity: a false
  # decline costs one scorer round; a false fire composes a run against the
  # user's intent.
  @affirmative_tokens ~w(ok okay yes yeah yep sure fine alright great good
                         sounds please thanks thank you go ahead now just
                         anyway and do it that's thats right lets let's)

  @doc "The deterministic override phrase the acks advertise."
  @spec override_phrase() :: String.t()
  def override_phrase, do: @override_phrase

  @doc """
  Deterministic override check — strict-affirmative: downcase + tokenize
  (punctuation splits), then require BOTH the contiguous token run
  \"proceed with defaults\" AND every remaining token to be a small-allowlist
  affirmative. \"ok, proceed with defaults!\" overrides even while the scorer
  is down; \"do not proceed with defaults\" or \"proceed with defaults but
  skip the tests\" NEVER fires here — those fall through to the scorer.
  """
  @spec override?(String.t()) :: boolean()
  def override?(message) when is_binary(message) do
    tokens =
      message
      |> String.downcase()
      |> String.split(~r/[^a-z0-9']+/u, trim: true)

    phrase_run?(tokens) and only_affirmatives_around?(tokens)
  end

  def override?(_other), do: false

  defp phrase_run?(tokens) do
    tokens
    |> Enum.chunk_every(length(@override_tokens), 1, :discard)
    |> Enum.member?(@override_tokens)
  end

  defp only_affirmatives_around?(tokens) do
    Enum.all?(tokens -- @override_tokens, &(&1 in @affirmative_tokens))
  end

  @doc """
  A question round: the single most load-bearing open item — the scorer
  orders the ledger, and every fold re-orders what to ask next — with
  why-it-matters + the recommended default, the round X/N header, and the
  override instruction. With no open item left it falls back to the recap
  (belt-and-braces — the decision layer refuses to serve such a round):
  always actionable, never a question-less round.
  """
  @spec questions(State.t(), pos_integer(), pos_integer()) :: String.t()
  def questions(%State{} = state, round, cap) do
    case Enum.take(Ledger.open_items(state.ledger), 1) do
      [] ->
        recap(state)

      [item] ->
        IO.iodata_to_binary([
          "Before I start this build, a question (round #{round}/#{cap}):\n\n",
          question_block(item),
          "\nAnswer it — or say \"#{@override_phrase}\" to compose now with the recommended assumptions."
        ])
    end
  end

  @doc """
  The streak-1 recap-confirm round (PORT-OB1-1 divergence (c)): restate the
  updated intent + the working assumptions instead of fabricating a question.
  """
  @spec recap(State.t()) :: String.t()
  def recap(%State{} = state) do
    IO.iodata_to_binary([
      "Here's my updated understanding — confirm and I'll start:\n\n",
      "Intent: ",
      state.updated_intent || state.original_message || "",
      "\n",
      assumptions_block(state.ledger),
      "\nReply to confirm (or correct anything above), or say \"#{@override_phrase}\"."
    ])
  end

  @doc """
  The hold-for-accept ack at the round cap: the still-open REQUIRED questions
  plus the explicit accept-assumptions instruction (never auto-compose past a
  required unknown — operator decision 2).
  """
  @spec hold(State.t()) :: String.t()
  def hold(%State{} = state) do
    required =
      state.ledger
      |> Ledger.open_items()
      |> Enum.filter(&(&1["user_input_required"] == true))

    IO.iodata_to_binary([
      "I've hit the clarify round cap with required questions still open:\n\n",
      numbered(required),
      "\nAnswer them, or say \"#{@override_phrase}\" to compose anyway with the recommended assumptions (the run will be labeled degraded)."
    ])
  end

  @doc """
  The bounded scorer-failure ack (infra ≠ verdict: failure never reads as
  clarified). From the second consecutive failure the ack offers ONLY the
  deterministic override phrase — the one path that needs no scorer.
  """
  @spec scorer_failure_ack(non_neg_integer()) :: String.t()
  def scorer_failure_ack(failures) when is_integer(failures) and failures >= 2 do
    "I'm still having trouble scoring answers on my side. " <>
      "Say \"#{@override_phrase}\" to compose with the recommended assumptions — that path doesn't need the scorer."
  end

  def scorer_failure_ack(_failures) do
    "I couldn't process that answer (a scoring hiccup on my side, not your message). " <>
      "Re-send it, or say \"#{@override_phrase}\"."
  end

  @doc """
  The bounded Q/A digest for premises (≤ #{@digest_max_bytes} bytes): resolved
  items only, each capped, whole entries accumulated until the budget — never
  a mid-entry byte split. `\"\"` when nothing is resolved (the caller omits
  the premises key).
  """
  @spec digest(State.t()) :: String.t()
  def digest(%State{} = state) do
    state.ledger
    |> Enum.filter(&resolved?/1)
    |> Enum.map(&digest_entry/1)
    |> take_within_budget(@digest_max_bytes)
  end

  @doc """
  The full Q/A transcript appended to the request-seed artifact (unbounded —
  it rides the stored artifact, not prompt context). `\"\"` when nothing is
  resolved.
  """
  @spec transcript(State.t()) :: String.t()
  def transcript(%State{} = state) do
    entries =
      state.ledger
      |> Enum.filter(&resolved?/1)
      |> Enum.map(fn item -> ["Q: ", item["question"], "\nA: ", answer_text(item)] end)

    case entries do
      [] -> ""
      _some -> IO.iodata_to_binary(Enum.intersperse(entries, "\n\n"))
    end
  end

  defp question_block(item) do
    [
      "#{item["question"]}\n",
      detail_line("why it matters", item["why_it_matters"]),
      detail_line("default if skipped", item["recommended_default_assumption"])
    ]
  end

  defp numbered([]), do: ["(none)\n"]

  defp numbered(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, index} ->
      [
        "#{index}. #{item["question"]}\n",
        detail_line("why it matters", item["why_it_matters"]),
        detail_line("default if skipped", item["recommended_default_assumption"])
      ]
    end)
  end

  defp detail_line(_label, text) when text in [nil, ""], do: []
  defp detail_line(label, text), do: ["   — ", label, ": ", text, "\n"]

  defp assumptions_block(ledger) do
    entries =
      ledger
      |> Enum.filter(&resolved?/1)
      |> Enum.map(fn item ->
        ["- ", cap(item["question"]), " → ", cap(answer_text(item)), "\n"]
      end)

    case entries do
      [] -> []
      _some -> ["\nWorking answers/assumptions:\n" | entries]
    end
  end

  defp resolved?(%{"status" => status}), do: status in ["answered", "assumed"]
  defp resolved?(_item), do: false

  defp answer_text(%{"status" => "assumed"} = item),
    do: "(assumed) " <> (item["recommended_default_assumption"] || "")

  defp answer_text(item), do: item["user_answer"] || ""

  defp digest_entry(item) do
    cap(item["question"]) <> " => " <> cap(answer_text(item))
  end

  defp take_within_budget(entries, max_bytes) do
    {kept, _bytes} =
      Enum.reduce_while(entries, {[], 0}, fn entry, {acc, bytes} ->
        # "; " separator costs 2 bytes between entries.
        cost = byte_size(entry) + if(acc == [], do: 0, else: 2)

        if bytes + cost <= max_bytes do
          {:cont, {[entry | acc], bytes + cost}}
        else
          {:halt, {acc, bytes}}
        end
      end)

    kept
    |> Enum.reverse()
    |> Enum.intersperse("; ")
    |> IO.iodata_to_binary()
  end

  defp cap(text) when is_binary(text) do
    case String.slice(text, 0, @text_cap) do
      ^text -> text
      sliced -> sliced <> "…"
    end
  end

  defp cap(_text), do: ""
end
