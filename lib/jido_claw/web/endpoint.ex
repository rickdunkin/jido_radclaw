defmodule JidoClaw.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :jido_claw

  @session_options [
    store: :cookie,
    key: "_jido_claw_key",
    signing_salt: "jidoclaw_lv",
    same_site: "Lax"
  ]

  if Mix.env() == :dev do
    plug Tidewave
  end

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  socket "/ws", JidoClaw.Web.UserSocket,
    websocket: true

  plug Plug.Static,
    at: "/",
    from: :jido_claw,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug JidoClaw.Web.Router
end
