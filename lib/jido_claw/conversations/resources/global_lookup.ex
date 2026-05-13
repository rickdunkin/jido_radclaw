defmodule JidoClaw.Conversations.Resources.GlobalLookup do
  @moduledoc """
  Shared cross-tenant FK validator used by `Conversations.Session`,
  `Conversations.Message`, and `Conversations.RequestCorrelation`.

  Looks up the parent record via its `by_id_global` action (which
  bypasses multitenancy), then either:

    * returns the changeset unchanged when the parent's `tenant_id`
      matches the supplied one;
    * adds `cross_tenant_fk_mismatch` when the parent belongs to a
      different tenant;
    * adds `<resource>_not_found` when the lookup fails.

  This helper is intentionally a plain function — not an
  `Ash.Resource.Change` — so callers can place it inside larger
  `change/2` callbacks that thread additional state (e.g. `Message`'s
  `nil` session_id branch).
  """

  @doc """
  Validate that the FK `id` (under `field`) belongs to `tenant_id`.

  `lookup_fn` is a one-arity function — typically a resource's
  `by_id_global/1` code interface — returning `{:ok, record}` or
  `{:error, term}`. `not_found_message` is the validation message when
  the lookup fails (e.g. `"session_not_found"`).
  """
  @spec validate_tenant_match(
          Ash.Changeset.t(),
          String.t() | nil,
          String.t() | nil,
          atom(),
          (String.t() -> {:ok, map()} | {:error, term()}),
          String.t()
        ) :: Ash.Changeset.t()
  def validate_tenant_match(cs, id, tenant_id, field, lookup_fn, not_found_message)
      when not is_nil(id) and not is_nil(tenant_id) do
    case lookup_fn.(id) do
      {:ok, %{tenant_id: ^tenant_id}} ->
        cs

      {:ok, %{tenant_id: parent_tenant}} ->
        Ash.Changeset.add_error(cs,
          field: field,
          message: "cross_tenant_fk_mismatch",
          vars: [supplied_tenant: tenant_id, parent_tenant: parent_tenant]
        )

      {:error, _} ->
        Ash.Changeset.add_error(cs, field: field, message: not_found_message)
    end
  end

  def validate_tenant_match(cs, _id, _tenant_id, _field, _lookup_fn, _msg), do: cs
end
