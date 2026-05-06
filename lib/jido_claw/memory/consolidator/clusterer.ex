defmodule JidoClaw.Memory.Consolidator.Clusterer do
  @moduledoc """
  Deterministic clustering for the consolidator's input pre-flight.

  Two stream types feed the harness — Facts and Messages. Each is
  bucketed independently and emitted as the same `cluster` shape with
  a `type` discriminator and disjoint `fact_ids` / `message_ids`
  member lists, so the run server can carry a single `state.clusters`
  list across both streams. The discriminator is what lets the
  harness `defer_cluster` either kind without misadvancing watermarks.

  Facts group by `label` (preferring populated labels) and fall back
  to a single `unlabeled` bucket. Messages group by `session_id`,
  ordered ascending by `sequence` so the harness sees a session's
  history in chronological order.

  A real clustering implementation (HDBSCAN over embeddings) is
  deferred to a later phase — for 3b, the harness sees inputs grouped
  so the prompt doesn't blow past `max_clusters_per_run`.
  """

  @type cluster :: %{
          id: String.t(),
          label: String.t() | nil,
          type: :facts | :messages,
          fact_ids: [Ecto.UUID.t()],
          message_ids: [Ecto.UUID.t()]
        }

  @doc """
  Cluster a list of `Memory.Fact` rows. Returns at most `max_clusters`
  buckets, each carrying the fact ids that belong to it.
  """
  @spec cluster([struct()], pos_integer()) :: [cluster()]
  def cluster(facts, max_clusters \\ 20) when is_list(facts) and is_integer(max_clusters) do
    facts
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {label, group} ->
      %{
        id: cluster_id(label),
        label: label,
        type: :facts,
        fact_ids: Enum.map(group, & &1.id),
        message_ids: []
      }
    end)
    |> Enum.sort_by(&length(&1.fact_ids), :desc)
    |> Enum.take(max_clusters)
  end

  @doc """
  Cluster a list of `Conversations.Message` rows by `session_id`.
  Each session becomes one cluster with its members ordered by
  `sequence` ascending; clusters are sorted by member count
  descending and capped at `max_clusters`.
  """
  @spec cluster_messages([struct()], pos_integer()) :: [cluster()]
  def cluster_messages(messages, max_clusters \\ 20)
      when is_list(messages) and is_integer(max_clusters) do
    messages
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {session_id, group} ->
      ordered = Enum.sort_by(group, & &1.sequence)

      %{
        id: "messages:#{session_id}",
        label: nil,
        type: :messages,
        fact_ids: [],
        message_ids: Enum.map(ordered, & &1.id)
      }
    end)
    |> Enum.sort_by(&length(&1.message_ids), :desc)
    |> Enum.take(max_clusters)
  end

  defp group_key(%{label: label}) when is_binary(label) and label != "", do: label
  defp group_key(_), do: nil

  defp cluster_id(nil), do: "unlabeled"

  defp cluster_id(label) when is_binary(label) do
    label
    |> :erlang.phash2()
    |> Integer.to_string(16)
    |> String.downcase()
  end
end
