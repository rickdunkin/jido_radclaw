defmodule JidoClaw.Security.CrossTenantFk do
  @moduledoc """
  Shared cross-tenant FK validator for Memory resources.

  Phase 0 / 1 / 2 each inlined their own `Changes.ValidateCrossTenantFk`
  module on the resource that introduced cross-tenant edges
  (`Solutions.Solution`, `Conversations.Session`, `Conversations.Message`).
  Phase 3 introduces 4+ resources that need the same dance, so the
  Memory subsystem factors the helper here. The existing inline copies
  on Solutions / Conversations are intentionally untouched — Phase 3 is
  not a refactor sweep.

  ## Usage

      Ash.Changeset.before_action(changeset, fn cs ->
        JidoClaw.Security.CrossTenantFk.validate(cs, [
          {:workspace_id, JidoClaw.Workspaces.Workspace, JidoClaw.Workspaces},
          {:session_id, JidoClaw.Conversations.Session, JidoClaw.Conversations}
        ])
      end)

  Each tuple is `{fk_attr, parent_resource, parent_domain}`. The validator:

    1. Reads `fk_attr` from the changeset (skip if `nil`).
    2. Loads the parent row via `Ash.get/3`.
    3. Compares parent `tenant_id` to the changeset's `tenant_id`. Adds
       a `cross_tenant_fk_mismatch` error on mismatch.

  ## Untenanted parents

  `JidoClaw.Projects.Project`, `JidoClaw.Accounts.User`, and
  `JidoClaw.Forge.Resources.Session` lack a `tenant_id` column today
  (acknowledged debt — see Phase 0 §0.5.2). For these parents, pass
  `:no_tenant_column` as the parent module and validation skips with a
  `[:jido_claw, :memory, :cross_tenant_fk, :skipped]` telemetry event:

      JidoClaw.Security.CrossTenantFk.validate(cs, [
        {:source_message_id, JidoClaw.Conversations.Message, JidoClaw.Conversations},
        {:created_by_user_id, :no_tenant_column, nil}
      ])

  Telemetry payload: `%{}` measurements, metadata `%{fk_attr: atom, parent: atom}`.
  Operators can wire the event to a counter to track how many writes
  bypass cross-tenant validation while the debt is outstanding.
  """

  require Logger

  @type fk_spec ::
          {atom(), module(), module()}
          | {atom(), :no_tenant_column, nil}

  @doc """
  Validate that every populated FK on the changeset points at a parent
  whose `tenant_id` matches the changeset's `tenant_id`.

  Returns the changeset (with errors added on mismatch) so the caller
  can chain it inside `Ash.Changeset.before_action/2`.
  """
  @spec validate(Ash.Changeset.t(), [fk_spec()]) :: Ash.Changeset.t()
  def validate(changeset, specs) when is_list(specs) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    Enum.reduce(specs, changeset, fn spec, cs ->
      validate_one(cs, tenant_id, spec)
    end)
  end

  defp validate_one(cs, _tenant_id, {fk_attr, :no_tenant_column, _domain}) do
    fk_value = Ash.Changeset.get_attribute(cs, fk_attr)

    if fk_value do
      :telemetry.execute(
        [:jido_claw, :memory, :cross_tenant_fk, :skipped],
        %{},
        %{
          fk_attr: fk_attr,
          parent: :no_tenant_column,
          reason: :tenant_validation_skipped_for_untenanted_parent
        }
      )
    end

    cs
  end

  defp validate_one(cs, tenant_id, {fk_attr, parent_resource, parent_domain})
       when is_atom(parent_resource) and is_atom(parent_domain) do
    fk_value = Ash.Changeset.get_attribute(cs, fk_attr)

    cond do
      is_nil(fk_value) ->
        cs

      is_nil(tenant_id) ->
        Ash.Changeset.add_error(cs,
          field: :tenant_id,
          message: "tenant_id_required_for_cross_tenant_validation"
        )

      true ->
        do_validate(cs, fk_attr, fk_value, parent_resource, parent_domain, tenant_id)
    end
  end

  defp do_validate(cs, fk_attr, fk_value, parent_resource, parent_domain, tenant_id) do
    case Ash.get(parent_resource, fk_value, domain: parent_domain) do
      {:ok, %{tenant_id: ^tenant_id}} ->
        cs

      {:ok, %{tenant_id: parent_tenant}} ->
        Ash.Changeset.add_error(cs,
          field: fk_attr,
          message: "cross_tenant_fk_mismatch",
          vars: [supplied_tenant: tenant_id, parent_tenant: parent_tenant]
        )

      {:error, _} ->
        Ash.Changeset.add_error(cs,
          field: fk_attr,
          message: "parent_not_found"
        )
    end
  end
end
