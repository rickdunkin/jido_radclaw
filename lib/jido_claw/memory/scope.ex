defmodule JidoClaw.Memory.Scope do
  @moduledoc """
  Scope resolution + advisory-lock keys for Memory.

  `JidoClaw.ToolContext` deliberately keeps a flat canonical key set
  (`:tenant_id`, `:user_id`, `:workspace_uuid`, `:session_uuid`, etc.)
  with no `:scope_kind` discriminator — Memory derives the kind here at
  call time, walking inward from the most specific FK populated on the
  context. This keeps the rest of the codebase from churning every time
  we add a new memory tier.

  ## `scope_kind` derivation

  Inward-out: `:session` → `:project` → `:workspace` → `:user`. The most
  specific populated FK wins. Resolver walks ancestors so the returned
  record carries the full chain (e.g. a `:session` scope still carries
  `workspace_id`, `user_id`, etc.) — the retrieval layer needs every
  ancestor to build the precedence chain.

  ## `chain/1`

  Returns the scope chain in the order Retrieval uses for source-and-
  scope precedence: most specific first. A `:session` scope produces

      [
        {:session, session_id},
        {:project, project_id_or_nil},
        {:workspace, workspace_id},
        {:user, user_id_or_nil}
      ]

  with `nil` ancestors filtered out. The session level is always
  included even if its column is `nil`, since the caller asked for that
  level — but the retrieval SQL defends against `nil` by predicating on
  `IS NOT NULL` per scope kind.

  ## `lock_key/3`

  `pg_try_advisory_lock` takes a single bigint. We squash
  `(tenant_id, scope_kind, fk_id)` into one via `:erlang.phash2/2` and
  mask to a 63-bit signed bigint range. Collisions are theoretical
  (~2^63 keyspace) and the worst case is two consolidator runs on
  unrelated scopes serializing — annoying, not incorrect.
  """

  alias JidoClaw.Conversations.Session, as: ConvSession
  alias JidoClaw.Workspaces.Workspace

  @type scope_kind :: :session | :project | :workspace | :user
  @type scope_record :: %{
          tenant_id: String.t(),
          scope_kind: scope_kind(),
          user_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          session_id: Ecto.UUID.t() | nil
        }

  @max_bigint Bitwise.bsl(1, 63) - 1

  @doc """
  Resolve a scope record from a `tool_context` map.

  Returns `{:ok, scope_record}` on success or
  `{:error, :tenant_required}` when `tenant_id` is missing — a hard
  invariant for every Memory write.

  Walks ancestors from the most-specific populated FK so the returned
  record carries the full chain. If `:session_uuid` is set but the
  Session row's `workspace_id` differs from the supplied
  `:workspace_uuid`, the supplied value wins and a telemetry event
  fires (`[:jido_claw, :memory, :scope, :ancestor_mismatch]`) so
  operators can spot the divergence.
  """
  @spec resolve(map()) :: {:ok, scope_record()} | {:error, atom()}
  def resolve(tool_context) when is_map(tool_context) do
    tenant_id = Map.get(tool_context, :tenant_id)

    cond do
      is_nil(tenant_id) or tenant_id == "" ->
        {:error, :tenant_required}

      true ->
        do_resolve(tenant_id, tool_context)
    end
  end

  def resolve(nil), do: {:error, :tenant_required}

  defp do_resolve(tenant_id, ctx) do
    user_id = Map.get(ctx, :user_id)
    workspace_id = Map.get(ctx, :workspace_uuid)
    session_id = Map.get(ctx, :session_uuid)
    project_id = Map.get(ctx, :project_id)

    {workspace_id, user_id, project_id} =
      maybe_load_session_ancestors(session_id, workspace_id, user_id, project_id)

    {workspace_id, user_id, project_id} =
      maybe_load_workspace_ancestors(workspace_id, user_id, project_id)

    scope_kind = derive_kind(session_id, project_id, workspace_id, user_id)

    if is_nil(scope_kind) do
      {:error, :scope_kind_unresolvable}
    else
      {:ok,
       %{
         tenant_id: tenant_id,
         scope_kind: scope_kind,
         user_id: user_id,
         workspace_id: workspace_id,
         project_id: project_id,
         session_id: session_id
       }}
    end
  end

  defp derive_kind(session_id, _, _, _) when is_binary(session_id), do: :session
  defp derive_kind(_, project_id, _, _) when is_binary(project_id), do: :project
  defp derive_kind(_, _, workspace_id, _) when is_binary(workspace_id), do: :workspace
  defp derive_kind(_, _, _, user_id) when is_binary(user_id), do: :user
  defp derive_kind(_, _, _, _), do: nil

  defp maybe_load_session_ancestors(nil, ws, u, p), do: {ws, u, p}

  defp maybe_load_session_ancestors(session_id, supplied_ws, supplied_user, project_id) do
    case ConvSession.by_id(session_id) do
      {:ok, %{workspace_id: ws_id, user_id: user_id_from_session}} ->
        ws = supplied_ws || ws_id

        if supplied_ws && ws_id && supplied_ws != ws_id do
          :telemetry.execute(
            [:jido_claw, :memory, :scope, :ancestor_mismatch],
            %{},
            %{supplied: supplied_ws, ancestor: ws_id, kind: :workspace}
          )
        end

        {ws, supplied_user || user_id_from_session, project_id}

      _ ->
        {supplied_ws, supplied_user, project_id}
    end
  end

  defp maybe_load_workspace_ancestors(nil, u, p), do: {nil, u, p}

  defp maybe_load_workspace_ancestors(ws_id, supplied_user, supplied_project) do
    case Ash.get(Workspace, ws_id, domain: JidoClaw.Workspaces) do
      {:ok, %{user_id: user_id_from_ws, project_id: project_id_from_ws}} ->
        {ws_id, supplied_user || user_id_from_ws, supplied_project || project_id_from_ws}

      _ ->
        {ws_id, supplied_user, supplied_project}
    end
  end

  @doc """
  Return the scope chain in retrieval-precedence order: most specific
  first. Pass through to retrieval SQL as a list of `{kind, fk_id}`
  tuples. `nil` ancestors are filtered out so only populated levels
  participate in the precedence cascade.
  """
  @spec chain(scope_record()) :: [{scope_kind(), Ecto.UUID.t()}]
  def chain(%{scope_kind: kind} = scope) do
    [
      {:session, scope[:session_id]},
      {:project, scope[:project_id]},
      {:workspace, scope[:workspace_id]},
      {:user, scope[:user_id]}
    ]
    |> drop_below_kind(kind)
    |> Enum.reject(fn {_, fk} -> is_nil(fk) end)
  end

  defp drop_below_kind(pairs, :session), do: pairs

  defp drop_below_kind(pairs, :project),
    do: Enum.reject(pairs, fn {kind, _} -> kind == :session end)

  defp drop_below_kind(pairs, :workspace),
    do: Enum.reject(pairs, fn {kind, _} -> kind in [:session, :project] end)

  defp drop_below_kind(pairs, :user),
    do: Enum.reject(pairs, fn {kind, _} -> kind in [:session, :project, :workspace] end)

  @doc """
  Compute a deterministic 63-bit signed bigint from
  `(tenant_id, scope_kind, fk_id)` for `pg_try_advisory_lock`.

  Used by the consolidator to acquire a per-scope session-level lock
  with `pg_try_advisory_lock(lock_key)` so a long-running harness window
  serializes against itself without holding a database transaction
  open for the entire run.
  """
  @spec lock_key(String.t(), atom(), String.t() | nil) :: integer()
  def lock_key(tenant_id, scope_kind, fk_id)
      when is_binary(tenant_id) and is_atom(scope_kind) do
    hash = :erlang.phash2({tenant_id, scope_kind, fk_id || ""})
    Bitwise.band(hash, @max_bigint)
  end
end
