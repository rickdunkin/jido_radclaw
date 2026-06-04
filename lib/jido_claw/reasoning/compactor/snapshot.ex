defmodule JidoClaw.Reasoning.Compactor.Snapshot do
  @moduledoc """
  Snapshot of a single compaction run.

  Persisted under `Session.metadata["compactions"][key]` as plain JSON
  (string keys, string status values), where `key` is
  `"<agent_id>::<context_ref|default>"`. The struct itself is the canonical
  in-memory form; `to_jsonb/1` converts it to a JSONB-safe map and
  `from_jsonb/1` parses the round-trip back into a struct.

  Two-handle watermarking:

    * `last_summarized_sequence` — primary, used for DB watermark reads
      via `Message.since_watermark/2`.
    * `summarized_request_ids` — cumulative set of `refs.request_id` values
      consumed by previous compactions, used by `RequestTransformer` to
      filter the projected `Jido.AI.Context.to_messages/1` output. Cumulative:
      every re-compaction merges in the new source IDs and dedupes.
  """

  @type status :: :summarized | :skipped | :error

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          tenant_id: String.t() | nil,
          agent_id: String.t() | nil,
          status: status(),
          strategy: atom(),
          summary: String.t() | nil,
          summary_preview: String.t() | nil,
          source_message_count: non_neg_integer(),
          retained_message_count: non_neg_integer(),
          protected_message_count: non_neg_integer(),
          protected_turn_count: non_neg_integer(),
          last_summarized_sequence: integer() | nil,
          summarized_request_ids: [String.t()],
          last_summarized_request_id: String.t() | nil,
          last_summarized_at_ms: integer() | nil,
          started_at_ms: integer() | nil,
          completed_at_ms: integer() | nil,
          error: String.t() | nil,
          metadata: map()
        }

  defstruct id: nil,
            session_id: nil,
            tenant_id: nil,
            agent_id: nil,
            status: :summarized,
            strategy: :summary,
            summary: nil,
            summary_preview: nil,
            source_message_count: 0,
            retained_message_count: 0,
            protected_message_count: 0,
            protected_turn_count: 0,
            last_summarized_sequence: nil,
            summarized_request_ids: [],
            last_summarized_request_id: nil,
            last_summarized_at_ms: nil,
            started_at_ms: nil,
            completed_at_ms: nil,
            error: nil,
            metadata: %{}

  @doc """
  Converts a `%Snapshot{}` into a plain JSON-friendly map:

    * keys are strings
    * atom status (`:summarized`, `:skipped`, `:error`) becomes a string
    * the strategy atom becomes a string
    * nested `metadata` is passed through unchanged (callers ensure it's
      JSON-safe)

  Suitable for storing in an Ash `:map` attribute (JSONB).
  """
  @spec to_jsonb(t()) :: map()
  def to_jsonb(%__MODULE__{} = snapshot) do
    %{
      "id" => snapshot.id,
      "session_id" => snapshot.session_id,
      "tenant_id" => snapshot.tenant_id,
      "agent_id" => snapshot.agent_id,
      "status" => Atom.to_string(snapshot.status),
      "strategy" => Atom.to_string(snapshot.strategy),
      "summary" => snapshot.summary,
      "summary_preview" => snapshot.summary_preview,
      "source_message_count" => snapshot.source_message_count,
      "retained_message_count" => snapshot.retained_message_count,
      "protected_message_count" => snapshot.protected_message_count,
      "protected_turn_count" => snapshot.protected_turn_count,
      "last_summarized_sequence" => snapshot.last_summarized_sequence,
      "summarized_request_ids" => snapshot.summarized_request_ids,
      "last_summarized_request_id" => snapshot.last_summarized_request_id,
      "last_summarized_at_ms" => snapshot.last_summarized_at_ms,
      "started_at_ms" => snapshot.started_at_ms,
      "completed_at_ms" => snapshot.completed_at_ms,
      "error" => snapshot.error,
      "metadata" => snapshot.metadata
    }
  end

  @doc """
  Parses a stored snapshot back into a `%Snapshot{}` struct.

  Accepts both string-keyed maps (the canonical persisted form) and
  atom-keyed maps (for tests and round-trip helpers). Returns `nil` if the
  input is `nil` or empty.
  """
  @spec from_jsonb(nil | map()) :: t() | nil
  def from_jsonb(nil), do: nil
  def from_jsonb(map) when is_map(map) and map_size(map) == 0, do: nil

  def from_jsonb(map) when is_map(map) do
    %__MODULE__{
      id: get(map, :id),
      session_id: get(map, :session_id),
      tenant_id: get(map, :tenant_id),
      agent_id: get(map, :agent_id),
      status: atomize_status(get(map, :status)),
      strategy: atomize_strategy(get(map, :strategy)),
      summary: get(map, :summary),
      summary_preview: get(map, :summary_preview),
      source_message_count: get(map, :source_message_count, 0),
      retained_message_count: get(map, :retained_message_count, 0),
      protected_message_count: get(map, :protected_message_count, 0),
      protected_turn_count: get(map, :protected_turn_count, 0),
      last_summarized_sequence: get(map, :last_summarized_sequence),
      summarized_request_ids: get(map, :summarized_request_ids, []) |> List.wrap(),
      last_summarized_request_id: get(map, :last_summarized_request_id),
      last_summarized_at_ms: get(map, :last_summarized_at_ms),
      started_at_ms: get(map, :started_at_ms),
      completed_at_ms: get(map, :completed_at_ms),
      error: get(map, :error),
      metadata: get(map, :metadata, %{})
    }
  end

  @doc """
  Builds a short preview from a summary string (first ~200 chars, single line).
  """
  @spec preview(String.t() | nil, pos_integer()) :: String.t() | nil
  def preview(nil, _limit), do: nil

  def preview(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate_with_ellipsis(limit)
  end

  defp truncate_with_ellipsis(string, limit) when is_binary(string) do
    if byte_size(string) <= limit do
      string
    else
      <<head::binary-size(^limit), _rest::binary>> = string
      head <> "…"
    end
  end

  defp get(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp atomize_status(nil), do: :summarized
  defp atomize_status(s) when s in [:summarized, :skipped, :error], do: s
  defp atomize_status("summarized"), do: :summarized
  defp atomize_status("skipped"), do: :skipped
  defp atomize_status("error"), do: :error
  defp atomize_status(_), do: :summarized

  defp atomize_strategy(nil), do: :summary
  defp atomize_strategy(s) when is_atom(s), do: s
  defp atomize_strategy("summary"), do: :summary

  defp atomize_strategy(other) when is_binary(other) do
    case other do
      "summary" -> :summary
      _ -> :summary
    end
  end

  defp atomize_strategy(_), do: :summary
end
