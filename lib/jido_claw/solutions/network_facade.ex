defmodule JidoClaw.Solutions.NetworkFacade do
  @moduledoc """
  Facade between the network protocol layer and the Solutions resource.

  All inbound and outbound network operations go through this module so
  the protocol code never imports the Ash resource directly. Two
  responsibilities:

    * **Inbound** — `store_inbound/2` receives a payload map plus the
      Network.Node state, resolves workspace + tenant, forces
      `sharing: :shared`, clears any sender-supplied scope keys, and
      calls `Solution.store/1`.
    * **Outbound** — `find_local/2` (by id) and `find_local_by_signature/2`
      look up rows scoped to the receiving workspace's tenant. Used by
      `broadcast_solution/1` and `handle_solution_requested/2` paths.
  """

  alias JidoClaw.Solutions.Solution

  @forced_inbound_keys [
    :tenant_id,
    :workspace_id,
    :session_id,
    :created_by_user_id,
    :id,
    :inserted_at,
    :updated_at,
    :deleted_at,
    :embedding,
    :embedding_status,
    :embedding_attempt_count,
    :embedding_next_attempt_at,
    :embedding_last_error,
    :embedding_model
  ]

  @doc """
  Store an inbound network solution payload.

  `node_state` carries `:tenant_id` and `:workspace_id` (resolved at
  Network.Node startup). Sharing is forced to `:shared`; any scope or
  embedding-state keys supplied by the sender are stripped before
  passing to `Solution.store/1`.
  """
  @spec store_inbound(map(), map()) :: {:ok, Solution.t()} | {:error, term()}
  def store_inbound(payload, node_state) when is_map(payload) and is_map(node_state) do
    tenant_id = Map.fetch!(node_state, :tenant_id)
    workspace_id = Map.fetch!(node_state, :workspace_id)

    attrs =
      payload
      |> normalize_keys()
      |> Map.drop(@forced_inbound_keys)
      |> Map.put(:sharing, :shared)
      |> Map.put(:tenant_id, tenant_id)
      |> Map.put(:workspace_id, workspace_id)

    Solution.store(attrs)
  end

  @doc """
  Look up a local solution by id, scoped to the node's tenant **and**
  workspace + sharing visibility.

  Within the caller's workspace, `:local | :shared | :public` rows are
  returned; across workspaces in the same tenant, only `:public` rows
  are admitted. A `:local` row in a different workspace is `:not_found`
  even when the caller knows its UUID — preventing the broadcast leak
  identified in Phase 1 review (Finding 5).
  """
  @spec find_local(String.t(), map()) :: {:ok, Solution.t()} | :not_found
  def find_local(solution_id, node_state) when is_binary(solution_id) and is_map(node_state) do
    tenant_id = Map.fetch!(node_state, :tenant_id)
    workspace_id = Map.fetch!(node_state, :workspace_id)

    case Ash.get(Solution, solution_id, domain: JidoClaw.Solutions.Domain) do
      {:ok, %Solution{tenant_id: ^tenant_id, workspace_id: ^workspace_id, sharing: sharing} = sol}
      when sharing in [:local, :shared, :public] ->
        {:ok, sol}

      {:ok, %Solution{tenant_id: ^tenant_id, sharing: :public} = sol} ->
        {:ok, sol}

      _ ->
        :not_found
    end
  end

  @doc """
  Look up local solutions by signature, scoped to the node's
  workspace and tenant. Used when responding to `:solution_requested`
  broadcasts.
  """
  @spec find_local_by_signature(String.t(), map()) :: [Solution.t()]
  def find_local_by_signature(signature, node_state)
      when is_binary(signature) and is_map(node_state) do
    tenant_id = Map.fetch!(node_state, :tenant_id)
    workspace_id = Map.fetch!(node_state, :workspace_id)

    case Solution.by_signature(
           signature,
           workspace_id,
           tenant_id,
           [:local, :shared, :public],
           [:public]
         ) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  Convert a `%Solution{}` to a plain map suitable for JSON serialization
  over the wire. Replaces the legacy `Solution.to_map/1` struct helper.
  """
  @spec to_wire(Solution.t()) :: map()
  def to_wire(%Solution{} = s) do
    %{
      "id" => s.id,
      "problem_signature" => s.problem_signature,
      "solution_content" => s.solution_content,
      "language" => s.language,
      "framework" => s.framework,
      "runtime" => s.runtime,
      "agent_id" => s.agent_id,
      "tags" => s.tags,
      "verification" => s.verification,
      "trust_score" => s.trust_score,
      "sharing" => to_string(s.sharing),
      "inserted_at" => s.inserted_at,
      "updated_at" => s.updated_at
    }
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError ->
      # Drop any unrecognized atoms — they can't be valid Solution attrs.
      map
      |> Enum.flat_map(fn
        {k, v} when is_atom(k) ->
          [{k, v}]

        {k, v} when is_binary(k) ->
          case safe_existing_atom(k) do
            {:ok, atom} -> [{atom, v}]
            :error -> []
          end
      end)
      |> Map.new()
  end

  defp safe_existing_atom(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> :error
  end
end
