defmodule JidoClaw.Web.Plugs.GraphqlTenantGate do
  @moduledoc """
  Tenant **activity gate** for the `/gql` pipeline — not just a tenant
  setter. Must run after `JidoClaw.Web.Plugs.ApiKeyAuth` (which seeds the
  actor via `Ash.PlugHelpers.set_actor/2`) and before `AshGraphql.Plug`
  (which copies actor + tenant into the Absinthe context).

  Why a gate: `Projects.Project` is deliberately global (`actor_present()`
  is its whole policy), so a valid API key of a **suspended** tenant would
  read projects if this plug merely set the tenant. The PostgreSQL tenant
  row is the activity authority (`gateway-runtime-security.md`); this plug
  makes `/gql` honor it for every query, global resources included. The
  activity check may provision a missing tenant row (`ensure_active/1` is a
  read-first upsert) — the one write behind the otherwise read-only surface.

  Outcomes (flat JSON error shape, mirroring ApiKeyAuth's 401):

    * active tenant → `Ash.PlugHelpers.set_tenant/2`, continue
    * inactive tenant → 403 `{"error": "tenant_inactive"}`
    * activity check infra failure → 503 `{"error": "tenant_unavailable"}`
    * missing/malformed actor → 403 `{"error": "invalid_actor"}` (fail
      closed; defense-in-depth behind ApiKeyAuth)

  The access module resolves through the `:tenant_access_module` app-env
  seam (the `LiveUserAuth` precedent) so infra-failure behavior is testable
  through public plug behavior with an injected stub.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Ash.PlugHelpers.get_actor(conn) do
      %{tenant_id: tenant_id} when is_binary(tenant_id) and byte_size(tenant_id) > 0 ->
        gate_on_activity(conn, tenant_id)

      _missing_or_malformed ->
        halt_with(conn, 403, "invalid_actor")
    end
  end

  defp gate_on_activity(conn, tenant_id) do
    case tenant_access().ensure_active(tenant_id) do
      :ok -> Ash.PlugHelpers.set_tenant(conn, tenant_id)
      {:error, {:tenant_inactive, _status}} -> halt_with(conn, 403, "tenant_inactive")
      {:error, _reason} -> halt_with(conn, 503, "tenant_unavailable")
    end
  end

  defp halt_with(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end

  defp tenant_access do
    Application.get_env(:jido_claw, :tenant_access_module, JidoClaw.Tenants.Access)
  end
end
