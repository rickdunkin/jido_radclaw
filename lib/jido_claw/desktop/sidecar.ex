defmodule JidoClaw.Desktop.Sidecar do
  @moduledoc false
  require Logger

  @doc "Detect if running as a desktop sidecar (Burrito/Tauri)."
  def desktop_mode? do
    System.get_env("BURRITO_TARGET") != nil or System.get_env("JIDOCLAW_DESKTOP") == "true"
  end

  @doc "Get the port to bind the embedded Phoenix server to."
  def port do
    case System.get_env("JIDOCLAW_PORT") do
      nil -> find_available_port()
      port -> String.to_integer(port)
    end
  end

  @doc "Configure the endpoint for desktop mode if applicable."
  def maybe_configure_endpoint do
    if desktop_mode?() do
      port = port()
      Logger.info("[Desktop] Running as sidecar on port #{port}")

      Application.put_env(
        :jido_claw,
        JidoClaw.Web.Endpoint,
        Keyword.merge(
          Application.get_env(:jido_claw, JidoClaw.Web.Endpoint, []),
          http: [port: port],
          server: true,
          check_origin: false
        )
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
