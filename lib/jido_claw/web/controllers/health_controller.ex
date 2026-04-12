defmodule JidoClaw.Web.HealthController do
  use Phoenix.Controller, formats: [:json]

  def index(conn, _params) do
    uptime =
      System.monotonic_time(:second) -
        Application.get_env(:jido_claw, :started_at, System.monotonic_time(:second))

    session_count =
      case Registry.select(JidoClaw.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [true]}]) do
        list when is_list(list) -> length(list)
        _ -> 0
      end

    tenant_count =
      case Process.whereis(JidoClaw.Tenant.Manager) do
        nil -> 0
        _pid -> JidoClaw.Tenant.Manager.count()
      end

    json(conn, %{
      status: "ok",
      version: JidoClaw.version(),
      uptime_seconds: uptime,
      sessions: session_count,
      tenants: tenant_count,
      node: Node.self(),
      otp_release: List.to_string(:erlang.system_info(:otp_release))
    })
  end
end
