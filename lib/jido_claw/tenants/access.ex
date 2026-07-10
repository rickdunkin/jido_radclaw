defmodule JidoClaw.Tenants.Access do
  @moduledoc """
  Durable tenant activity gate.

  PostgreSQL is authoritative: routine ensure calls may create a missing
  tenant but never reactivate an existing suspended/terminating row. Ensure
  is read-first — the provisioning upsert runs only when the row does not
  exist yet, so steady-state activity checks issue no writes.
  """

  alias JidoClaw.Tenants.Tenant

  @spec ensure_active(String.t()) :: :ok | {:error, {:tenant_inactive, atom()} | term()}
  def ensure_active(tenant_id) when is_binary(tenant_id) do
    # Read-first: steady state is a single SELECT. The upsert runs only on a
    # first-ever provision, so a routine activity check no longer bumps
    # `updated_at` on every call — and never writes to a suspended row.
    case Tenant.by_id(tenant_id, not_found_error?: false) do
      {:ok, nil} ->
        with {:ok, tenant} <- Tenant.ensure(tenant_id) do
          active?(tenant)
        end

      {:ok, tenant} ->
        active?(tenant)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec active?(String.t() | Tenant.t()) ::
          :ok | {:error, {:tenant_inactive, atom()} | term()}
  def active?(tenant_id) when is_binary(tenant_id) do
    case Tenant.by_id(tenant_id) do
      {:ok, tenant} -> active?(tenant)
      {:error, reason} -> {:error, reason}
    end
  end

  def active?(%Tenant{status: :active}), do: :ok
  def active?(%Tenant{status: status}), do: {:error, {:tenant_inactive, status}}
end
