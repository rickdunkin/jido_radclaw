defmodule JidoClaw.Cron do
  @moduledoc """
  Ash domain for persistent cron-job definitions.

  Replaces the v0.5.x `.jido/cron.yaml` file-store with a Postgres
  resource so scheduled jobs survive restarts via the same multi-tenant
  Postgres path as every other state in v0.6. The `Job` resource is
  scoped by `tenant_id` (FK to `tenants(id)`); identity is the
  composite `(tenant_id, job_id)` so a tenant's job_id namespace
  doesn't collide across tenants.

  Auto-disable from worker-side failures (3 consecutive errors)
  persists `disabled_at` on the row so a process restart doesn't
  re-enable failing jobs.
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Cron.Job)
  end
end
