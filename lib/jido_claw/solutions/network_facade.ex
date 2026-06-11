defmodule JidoClaw.Solutions.NetworkFacade do
  @moduledoc """
  Facade between the network protocol layer and the Solutions resource.

  All inbound and outbound network operations go through this module so
  the protocol code never imports the Ash resource directly. Two
  responsibilities:

    * **Inbound** — `store_inbound/3` receives a payload map, the
      verified sender's agent id, and the Network.Node state, resolves
      workspace + tenant, forces `sharing: :shared` and `agent_id`
      (attribution always comes from the verified sender, never the
      payload), clears any sender-supplied scope, embedding, and trust
      keys (`:trust_score`/`:verification` — trust is earned locally
      via `verify_certificate`, never peer-asserted), and calls
      `Solution.store/1`.
    * **Outbound** — `find_local/2` (by id) and `find_local_by_signature/2`
      look up rows scoped to the receiving workspace's tenant. Used by
      `broadcast_solution/1` and `handle_solution_requested/2` paths.

  `to_wire/1` deliberately omits `trust_score`/`verification`:
  receivers force-drop them, so transmitting them is dead weight that
  would only invite a future receiver to trust them.
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.MapKeys
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
    :embedding_model,
    :trust_score,
    :verification,
    # Attribution is forced to the verified sender, never payload-asserted.
    :agent_id
  ]

  @doc """
  Store an inbound network solution payload.

  `from` is the verified sender's agent id (signature-checked by
  Network.Node before dispatch); `agent_id` is forced to it — a
  payload-asserted `agent_id` (string or atom key) is dropped, so a
  trusted peer cannot attribute a solution to another agent.
  `node_state` carries `:tenant_id` and `:workspace_id` (resolved at
  Network.Node startup). Sharing is forced to `:shared`; any scope,
  embedding-state, or trust keys (`trust_score`/`verification`)
  supplied by the sender are stripped before passing to
  `Solution.store/1` — inbound rows start at the attribute defaults
  (`trust_score: 0.0`, `verification: %{}`) and earn trust locally.
  """
  @spec store_inbound(map(), String.t(), map()) :: {:ok, Solution.t()} | {:error, term()}
  def store_inbound(payload, from, node_state)
      when is_map(payload) and is_binary(from) and is_map(node_state) do
    tenant_id = Map.fetch!(node_state, :tenant_id)
    workspace_id = Map.fetch!(node_state, :workspace_id)

    attrs =
      payload
      |> MapKeys.normalize_keys(:atom_existing, drop_unknown: true)
      |> Map.drop(@forced_inbound_keys)
      |> Map.put(:sharing, :shared)
      |> Map.put(:workspace_id, workspace_id)
      |> Map.put(:agent_id, from)

    Solution.store(attrs, tenant: tenant_id, actor: Actor.system(tenant_id))
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

    case Solution.by_id(solution_id, tenant: tenant_id, actor: Actor.system(tenant_id)) do
      {:ok, %Solution{workspace_id: ^workspace_id, sharing: sharing} = sol}
      when sharing in [:local, :shared, :public] ->
        {:ok, sol}

      {:ok, %Solution{sharing: :public} = sol} ->
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
           [:local, :shared, :public],
           [:public],
           tenant: tenant_id,
           actor: Actor.system(tenant_id)
         ) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  Convert a `%Solution{}` to a plain map suitable for JSON serialization
  over the wire. Replaces the legacy `Solution.to_map/1` struct helper.

  Trust fields (`trust_score`/`verification`) are intentionally not
  transmitted — see the moduledoc.
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
      "sharing" => to_string(s.sharing),
      "inserted_at" => s.inserted_at,
      "updated_at" => s.updated_at
    }
  end
end
