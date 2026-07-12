defmodule JidoClaw.Web.ArgusController do
  @moduledoc """
  Serves the built argus SPA shell (argus P3). `Plug.Static` (endpoint)
  owns the hashed build assets under `priv/static/argus/`; this controller
  is the catch-all behind it — every non-file `/argus` path gets
  `index.html` so client-side routes survive refresh, and a missing build
  is an honest 404 carrying the build hint, never a silent blank page.
  """

  use Phoenix.Controller, formats: []

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case File.read(Path.join(static_root(), "index.html")) do
      {:ok, shell} ->
        conn
        # The shell references hashed assets a rebuild replaces
        # (emptyOutDir) — browsers must revalidate it on every load, or a
        # cached stale shell points at deleted asset files.
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_content_type("text/html")
        |> send_resp(200, shell)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          404,
          "No argus build found. Run `mix ui.build` to produce priv/static/argus/, then reload."
        )
    end
  end

  # Test seam: tests point the root at per-test tmp dirs — the real
  # app_dir is shared state across the partitioned suite's BEAMs.
  defp static_root do
    Application.get_env(:jido_claw, :argus_static_root) ||
      Application.app_dir(:jido_claw, "priv/static/argus")
  end
end
