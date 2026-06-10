defmodule JidoClaw.Reasoning.Compactor.TurnGrouping do
  @moduledoc """
  Groups a flat list of `JidoClaw.Conversations.Message` rows into turns and
  computes the protected / source / retained slices for a single compaction
  pass.

  A **turn** is the set of messages sharing the same `request_id`. The trim
  boundary always falls between turns, never inside one — `:tool_call` and
  `:tool_result` rows are standalone in this codebase, so role-adjacency
  walks are not safe.

  Nil-`request_id` rows (system messages, hydration, legacy untagged) form a
  single virtual "nil turn" that is *never* counted against
  `protect_first_n_turns` and *never* summarized. They ride along with the
  protected slice for accounting, and the transformer's nil-refs rule keeps
  them in the projected window regardless of where they sit chronologically.

  Consumed by `JidoClaw.Reasoning.Compactor.maybe_compact/3` only; the
  `RequestTransformer` does not call into this module (it only does set
  membership filtering on `refs.request_id`).
  """

  alias JidoClaw.Reasoning.Compactor.Config

  @type message :: %{
          optional(:id) => term(),
          optional(:role) => atom(),
          optional(:sequence) => integer(),
          optional(:request_id) => String.t() | nil,
          optional(:inserted_at) => DateTime.t() | nil,
          optional(any) => any
        }

  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          messages: [message()],
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          started_at_seq: integer() | nil,
          primary_role: atom() | nil
        }

  defstruct [
    :request_id,
    :messages,
    :started_at,
    :ended_at,
    :started_at_seq,
    :primary_role
  ]

  @doc """
  Group a flat list of messages into turns, sorted chronologically by
  earliest sequence within each turn.

  Messages within a turn are sorted by `:sequence` ascending.
  """
  @spec group([message()]) :: [t()]
  def group([]), do: []

  def group(messages) when is_list(messages) do
    messages
    |> Enum.group_by(&Map.get(&1, :request_id))
    |> Enum.map(fn {request_id, msgs} ->
      sorted = Enum.sort_by(msgs, &sequence_key/1)
      build_turn(request_id, sorted)
    end)
    |> Enum.sort_by(&turn_sort_key/1)
  end

  @doc """
  Split a list of turns into `{protected, source, retained}`.

    * `protect_first_n_turns` applies only when `is_first_compaction?` is
      true. On re-compactions it is forced to `0` so the slice (which
      already starts at the last watermark) does not re-protect already-
      summarized material.
    * Nil-`request_id` turns are *always* moved into the protected list,
      regardless of position, and are never counted against the
      `protect_first_n_turns` budget. They are kept downstream by the
      transformer's nil-refs rule.
    * `keep_last_turns` is the minimum number of real turns to retain
      verbatim at the tail.

  Postcondition: `protected ++ source ++ retained` covers every input turn
  exactly once (preserving each list's internal chronological order; the
  nil-turns block sits at the head of `protected`).
  """
  @spec split([t()], Config.t(), boolean()) :: {[t()], [t()], [t()]}
  def split(turns, %Config{} = config, is_first_compaction?)
      when is_list(turns) and is_boolean(is_first_compaction?) do
    {nil_turns, real_turns} = Enum.split_with(turns, &is_nil(&1.request_id))

    effective_p =
      if is_first_compaction?, do: config.protect_first_n_turns, else: 0

    {protected_real, rest} = take_first(real_turns, effective_p)
    keep_k = config.keep_last_turns
    rest_count = Enum.count(rest)

    cond do
      rest == [] ->
        {nil_turns ++ protected_real, [], []}

      rest_count <= keep_k ->
        {nil_turns ++ protected_real, [], rest}

      true ->
        {source, retained} = Enum.split(rest, rest_count - keep_k)
        {nil_turns ++ protected_real, source, retained}
    end
  end

  defp take_first(list, 0), do: {[], list}

  defp take_first(list, n) when is_integer(n) and n > 0 do
    Enum.split(list, n)
  end

  defp build_turn(request_id, [first | _] = sorted_msgs) do
    last = last_of(sorted_msgs, first)

    %__MODULE__{
      request_id: request_id,
      messages: sorted_msgs,
      started_at: Map.get(first, :inserted_at),
      ended_at: Map.get(last, :inserted_at),
      started_at_seq: Map.get(first, :sequence),
      primary_role: primary_role(sorted_msgs)
    }
  end

  defp last_of([elem], _acc), do: elem
  defp last_of([_ | rest], _acc), do: last_of(rest, hd(rest))

  defp primary_role(messages) do
    case Enum.find(messages, fn msg -> Map.get(msg, :role) in [:user, :assistant] end) do
      nil ->
        messages
        |> List.first()
        |> Map.get(:role)

      msg ->
        Map.get(msg, :role)
    end
  end

  defp sequence_key(msg) do
    case Map.get(msg, :sequence) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  # Sort tuple form `{nil_seq_flag, seq, ts_present_flag, ts_micros}` so
  # comparisons are integer-only and stable. Turns without a sequence
  # (synthetic test data) sort after sequenced turns; within each group
  # we further break ties by inserted_at when present.
  defp turn_sort_key(%__MODULE__{started_at_seq: seq, started_at: at}) do
    {seq_flag, seq_value} =
      case seq do
        n when is_integer(n) -> {0, n}
        _ -> {1, 0}
      end

    {ts_flag, ts_value} =
      case at do
        %DateTime{} -> {0, DateTime.to_unix(at, :microsecond)}
        _ -> {1, 0}
      end

    {seq_flag, seq_value, ts_flag, ts_value}
  end
end
