defmodule JidoClaw.Workspaces.Resolver do
  @moduledoc """
  Lazy upserter for `JidoClaw.Workspaces.Workspace` rows.

  Every surface (REPL, web controller, RPC channel, Discord/Telegram
  adapter, cron worker, MCP — though MCP is enum-only in Phase 0) calls
  `ensure_workspace/3` before dispatching to the agent so downstream
  consumers can attach to a real UUID rather than an opaque string.

  Resolvers are the only callers that opt into upsert; direct
  `Workspace.register/1` calls behave as a normal create and surface a
  unique-constraint error on conflict.

  ## v0.6.4 — tenant FK ensure

  Step 0 of `ensure_workspace/3` calls `Tenants.Tenant.ensure/1` so the
  parent `tenants(id)` row exists before any FK-bearing write hits
  Postgres. The action's `upsert_fields([:updated_at])` semantics make
  concurrent first-writes for the same id collapse onto the same row
  without re-activating a `:suspended` tenant.
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Workspace

  @spec ensure_workspace(String.t(), String.t(), keyword()) ::
          {:ok, Workspace.t()} | {:error, term()}
  def ensure_workspace(tenant_id, project_dir, opts \\ [])
      when is_binary(tenant_id) and is_binary(project_dir) and is_list(opts) do
    with {:ok, _tenant} <- Tenant.ensure(tenant_id) do
      do_register(tenant_id, project_dir, opts)
    end
  end

  defp do_register(tenant_id, project_dir, opts) do
    expanded = Path.expand(project_dir)
    user_id = Keyword.get(opts, :user_id)
    name = Keyword.get(opts, :name) || Path.basename(expanded)
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

    upsert_identity =
      if user_id, do: :unique_user_path_authed, else: :unique_user_path_cli

    attrs = %{
      path: expanded,
      name: name,
      user_id: user_id,
      project_id: Keyword.get(opts, :project_id),
      embedding_policy: Keyword.get(opts, :embedding_policy, :disabled),
      consolidation_policy: Keyword.get(opts, :consolidation_policy, :disabled),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    Workspace
    |> Ash.Changeset.for_create(:register, attrs, tenant: tenant_id, actor: actor)
    |> Ash.create(upsert?: true, upsert_identity: upsert_identity, actor: actor)
  end
end
