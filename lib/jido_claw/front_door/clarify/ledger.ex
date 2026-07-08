defmodule JidoClaw.FrontDoor.Clarify.Ledger do
  @moduledoc """
  The clarify loop's question ledger — the orca OR2-5 item shape, normalized
  at the LLM boundary and persisted (string keys, string enums) inside
  `metadata["pending_clarify"]`.

  Open items ARE the questions (PORT-OB1-1 divergence (d): no parallel
  `next_questions` field to drift). An item is **unresolved** while its status
  is `"open"` or `"conflicting"`; `"answered"` and `"assumed"` are resolved.
  """

  @type item :: %{String.t() => term()}

  @statuses ~w(open answered assumed conflicting)
  @unresolved ~w(open conflicting)

  # String→atom key pairs for tolerant reads (the Verdict `get` idiom —
  # accepts the string-keyed JSON `generate_object` returns and atom-keyed
  # synthetic test maps; a FIXED table, never `String.to_atom/1`).
  @atom_keys %{
    "question" => :question,
    "why_it_matters" => :why_it_matters,
    "risk_if_unanswered" => :risk_if_unanswered,
    "recommended_default_assumption" => :recommended_default_assumption,
    "user_input_required" => :user_input_required,
    "status" => :status,
    "user_answer" => :user_answer
  }

  @doc "The status enum (wire strings)."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Normalize a scorer-produced (or reloaded) item list: string keys, string
  status enums (unknown status ⇒ `"open"` — unknown means unresolved), and the
  `user_input_required` present-nil coercion, which FAILS CLOSED: only a
  literal `false` reads as assumable, so an absent/nil/junk flag holds at the
  round cap instead of being auto-assumed past. Items without a question are
  dropped (nothing to ask, nothing to track).
  """
  @spec normalize(term()) :: [item()]
  def normalize(items) when is_list(items) do
    items
    |> Enum.map(&normalize_item/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize(_other), do: []

  @doc """
  Fold-time preservation merge: the RESULT ledger wins item-by-item (the
  scorer re-orders and re-statuses every round), and any prior item whose
  question — normalized key: downcase + whitespace-collapse — is missing
  from the result is re-appended in prior order instead of lost. "Maintain
  the full ledger" is enforced here, not just requested in the scorer
  prompt. Both sides are expected normalized (`normalize/1`).
  """
  @spec merge_preserved([item()], [item()]) :: [item()]
  def merge_preserved(prior, result) when is_list(prior) and is_list(result) do
    result_keys = MapSet.new(result, &question_key/1)
    result ++ Enum.reject(prior, &(question_key(&1) in result_keys))
  end

  @doc """
  Append `items` (normalized here) whose question key — downcase +
  whitespace-collapse, the `merge_preserved/2` key — is not already present.
  The idempotent blocker-seeding write (item 9): re-seeding the same lint
  blocker across composes never duplicates its question.
  """
  @spec append_missing([item()], [term()]) :: [item()]
  def append_missing(ledger, items) when is_list(ledger) and is_list(items) do
    keys = MapSet.new(ledger, &question_key/1)
    ledger ++ Enum.reject(normalize(items), &(question_key(&1) in keys))
  end

  @doc "Status tallies for the deterministic floor: open/conflicting/assumed/total."
  @spec counts([item()]) :: %{
          open: non_neg_integer(),
          conflicting: non_neg_integer(),
          assumed: non_neg_integer(),
          total: non_neg_integer()
        }
  def counts(ledger) when is_list(ledger) do
    Enum.reduce(ledger, %{open: 0, conflicting: 0, assumed: 0, total: 0}, fn item, acc ->
      acc = %{acc | total: acc.total + 1}

      case item["status"] do
        "open" -> %{acc | open: acc.open + 1}
        "conflicting" -> %{acc | conflicting: acc.conflicting + 1}
        "assumed" -> %{acc | assumed: acc.assumed + 1}
        _resolved -> acc
      end
    end)
  end

  @doc "The unresolved (askable) items — status `open` or `conflicting`."
  @spec open_items([item()]) :: [item()]
  def open_items(ledger) when is_list(ledger), do: Enum.filter(ledger, &unresolved?/1)

  @doc "True when any unresolved item requires user input (the hold-at-cap gate)."
  @spec open_required?([item()]) :: boolean()
  def open_required?(ledger) when is_list(ledger) do
    Enum.any?(ledger, fn item ->
      unresolved?(item) and item["user_input_required"] == true
    end)
  end

  @doc "Short labels of the unresolved items — the `\"unresolved_slots\"` premises value."
  @spec unresolved_slots([item()]) :: [String.t()]
  def unresolved_slots(ledger) when is_list(ledger) do
    ledger
    |> open_items()
    |> Enum.map(fn item -> cap(item["question"], 80) end)
  end

  defp unresolved?(%{"status" => status}), do: status in @unresolved
  defp unresolved?(_item), do: false

  defp question_key(%{"question" => question}) when is_binary(question) do
    question
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp question_key(_item), do: ""

  defp normalize_item(%{} = raw) do
    case present(get(raw, "question")) do
      nil ->
        nil

      question ->
        %{
          "question" => question,
          "why_it_matters" => text_or_empty(get(raw, "why_it_matters")),
          "risk_if_unanswered" => text_or_empty(get(raw, "risk_if_unanswered")),
          "recommended_default_assumption" =>
            text_or_empty(get(raw, "recommended_default_assumption")),
          "user_input_required" => get(raw, "user_input_required") != false,
          "status" => normalize_status(get(raw, "status")),
          "user_answer" => text_or_nil(get(raw, "user_answer"))
        }
    end
  end

  defp normalize_item(_other), do: nil

  # Explicit fetch (never `||`): a present `false` for user_input_required must
  # win over the atom-key fallback.
  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, @atom_keys[key])
    end
  end

  defp normalize_status(status) when is_binary(status) do
    if status in @statuses, do: status, else: "open"
  end

  defp normalize_status(status) when is_atom(status) and not is_nil(status),
    do: normalize_status(Atom.to_string(status))

  defp normalize_status(_other), do: "open"

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp present(_other), do: nil

  defp text_or_empty(value) when is_binary(value), do: value
  defp text_or_empty(_other), do: ""

  defp text_or_nil(value) when is_binary(value), do: value
  defp text_or_nil(_other), do: nil

  defp cap(text, max) when is_binary(text) do
    case String.slice(text, 0, max) do
      ^text -> text
      sliced -> sliced <> "…"
    end
  end

  defp cap(_text, _max), do: ""
end
