defmodule JidoClaw.Tenants do
  @moduledoc """
  Ash domain for the tenant registry.

  Phase 4 promotes the Phase 0–3 `tenant_id` text columns to a real FK
  pointing at this domain's `Tenant` resource. Every tenant-scoped row in
  the system now references a `tenants(id)` row.

  The legacy `JidoClaw.Tenant` struct in `lib/jido_claw/platform/tenant.ex`
  is preserved for the supervisor-tree boot path; the v0.6.4 cutover keeps
  `Tenant.Manager`'s ETS cache as a hot lookup for the per-tenant
  `Tenant.InstanceSupervisor`. The Postgres `tenants` table is the
  source of truth for FK validity; the ETS cache is best-effort.
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Tenants.Tenant)
  end
end
