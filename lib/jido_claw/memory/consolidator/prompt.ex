defmodule JidoClaw.Memory.Consolidator.Prompt do
  @moduledoc """
  Renders the consolidator system prompt from a gated/clustered
  RunServer state. Output is a single string passed to the harness via
  `runner_config.prompt`; both `Runners.ClaudeCode` and `Runners.Codex`
  read it into `state.prompt` during `init/2`.

  ## Bounded body

  This builder renders cluster id/type/size only — never full
  message/fact bodies. The model has `list_clusters` /
  `get_cluster` MCP tools to fetch detail on-demand. Inlining
  bodies would balloon prompts unbounded with the input set,
  increase token cost without proportional benefit, and pull more
  user content into the model's context than necessary.
  """

  alias JidoClaw.Memory.Scope

  @link_relations ~w(supports contradicts supersedes duplicates depends_on related)

  @spec build(state :: map()) :: String.t()
  def build(state) do
    """
    You are the JidoClaw memory consolidator. Your job is to review the
    clustered memory inputs below and propose mutations using the
    available MCP tools, then commit them.

    ## Scope
    #{render_scope(state.scope)}

    ## Available tools (MCP server "consolidator")
    - list_clusters / get_cluster — inspect clusters
    - get_active_blocks — see existing block-level summaries
    - find_similar_facts — dedup against existing facts
    - propose_add / propose_update / propose_delete — fact mutations
    - propose_block_update — block-level summary writes
    - propose_link — fact↔fact links (#{Enum.join(@link_relations, ", ")})
    - defer_cluster — postpone a cluster to a later run
    - commit_proposals — call EXACTLY ONCE when done; this finalises the run

    ## Clusters in this run
    #{render_clusters(state.clusters || [])}

    Behaviour:
    - Inspect clusters with list_clusters / get_cluster before proposing.
    - Use find_similar_facts to avoid duplicates.
    - When done, call commit_proposals once. Do not keep iterating after.
    """
  end

  defp render_scope(%{scope_kind: kind} = scope) do
    "#{kind} (tenant=#{scope.tenant_id}, fk=#{Scope.primary_fk(scope)})"
  end

  defp render_clusters([]), do: "(none)"

  defp render_clusters(clusters) do
    clusters
    |> Enum.map(&render_cluster/1)
    |> Enum.join("\n")
  end

  defp render_cluster(cluster) do
    id = Map.get(cluster, :id)
    type = Map.get(cluster, :type)
    size = cluster_size(cluster)
    "- #{id} (type=#{type}, size=#{size})"
  end

  defp cluster_size(%{fact_ids: ids}) when is_list(ids), do: length(ids)
  defp cluster_size(%{message_ids: ids}) when is_list(ids), do: length(ids)
  defp cluster_size(_), do: 0
end
