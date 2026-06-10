defmodule JidoClaw.Desktop.Sidecar do
  @moduledoc false
  require Logger

  @doc "Detect if running as a desktop sidecar (Burrito/Tauri)."
  @spec desktop_mode?() :: boolean()
  def desktop_mode? do
    System.get_env("BURRITO_TARGET") != nil or System.get_env("JIDOCLAW_DESKTOP") == "true"
  end

  @doc "Get the port to bind the embedded Phoenix server to."
  @spec port() :: :inet.port_number()
  def port do
    case System.get_env("JIDOCLAW_PORT") do
      nil -> find_available_port()
      port -> String.to_integer(port)
    end
  end

  @doc "Configure the endpoint for desktop mode if applicable."
  @spec maybe_configure_endpoint() :: {:ok, :inet.port_number()} | :not_desktop
  def maybe_configure_endpoint do
    if desktop_mode?() do
      port = port()
      Logger.info("[Desktop] Running as sidecar on port #{port}")

      # Deep-merge :http so the base config's loopback ip survives —
      # loopback is correct for a desktop sidecar, and a shallow merge
      # would silently fall back to all-interfaces. check_origin must
      # follow the chosen port: the base origins are pinned to the default
      # gateway port and would 403 LiveView/WS connections on any other
      # port. The sidecar binds loopback only, so the loopback trio at the
      # bound port is exactly the valid origin set (replace, don't extend).
      Application.put_env(
        :jido_claw,
        JidoClaw.Web.Endpoint,
        Application.get_env(:jido_claw, JidoClaw.Web.Endpoint, [])
        |> Keyword.update(
          :http,
          [ip: {127, 0, 0, 1}, port: port],
          &Keyword.merge(&1, ip: {127, 0, 0, 1}, port: port)
        )
        |> Keyword.put(:server, true)
        |> Keyword.put(:check_origin, [
          "//localhost:#{port}",
          "//127.0.0.1:#{port}",
          "//[::1]:#{port}"
        ])
      )

      {:ok, port}
    else
      :not_desktop
    end
  end

  defp find_available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
