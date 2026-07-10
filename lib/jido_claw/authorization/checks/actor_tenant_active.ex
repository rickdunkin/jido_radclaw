defmodule JidoClaw.Authorization.Checks.ActorTenantActive do
  @moduledoc """
  Requires the authorization actor's durable tenant row to be active.

  Missing, suspended, terminating, and unreadable tenant rows all fail
  closed. Deliberate global actions bypass this check through the resource
  macro's earlier bypass policy.
  """

  use Ash.Policy.SimpleCheck

  alias JidoClaw.Tenants.Access

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor tenant is active"

  @impl Ash.Policy.SimpleCheck
  def match?(%{tenant_id: tenant_id}, _context, _opts) when is_binary(tenant_id) do
    Access.active?(tenant_id) == :ok
  end

  def match?(_actor, _context, _opts), do: false
end
