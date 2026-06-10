defmodule JidoClaw.Authorization.Checks.ActorTenantMatches do
  @moduledoc """
  Simple check: actor's `:tenant_id` matches the action's tenant.

  Used for create/update/destroy policies on tenant-scoped resources
  where `expr(tenant_id == ^actor(:tenant_id))` would surface as
  `Ash.Error.Forbidden.CannotFilterCreates` — Ash filter checks can't
  reference would-be attributes during create. A simple check sidesteps
  that by evaluating against the changeset/query tenant directly.

  For reads, prefer `expr(tenant_id == ^actor(:tenant_id))` so the
  policy applies as a SQL filter rather than a hard deny.
  """

  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor's tenant_id matches the action tenant"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, %{changeset: %Ash.Changeset{} = cs}, _opts) do
    tenant_match?(actor, cs.tenant || Ash.Changeset.get_attribute(cs, :tenant_id))
  end

  def match?(actor, %{query: %Ash.Query{} = q}, _opts) do
    tenant_match?(actor, q.tenant)
  end

  def match?(actor, %{action_input: %Ash.ActionInput{} = ai}, _opts) do
    tenant_match?(actor, ai.tenant)
  end

  def match?(_, _, _), do: false

  defp tenant_match?(%{tenant_id: actor_tenant}, tenant)
       when is_binary(actor_tenant) and is_binary(tenant),
       do: actor_tenant == tenant

  defp tenant_match?(_, _), do: false
end
