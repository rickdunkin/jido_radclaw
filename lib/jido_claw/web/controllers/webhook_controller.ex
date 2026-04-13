defmodule JidoClaw.Web.WebhookController do
  use Phoenix.Controller, formats: [:json]
  require Logger

  def github(conn, _params) do
    {:ok, raw_body} = JidoClaw.Web.CacheBodyReader.raw_body(conn)

    case JidoClaw.GitHub.WebhookPipeline.process(conn, raw_body) do
      {:ok, _} ->
        conn |> put_status(200) |> json(%{status: "ok"})

      {:error, :signature_mismatch} ->
        conn |> put_status(401) |> json(%{error: "invalid_signature"})

      {:error, :missing_webhook_secret} ->
        conn |> put_status(500) |> json(%{error: "webhook_not_configured"})

      {:error, reason} ->
        Logger.warning("[WebhookController] Error: #{inspect(reason)}")
        conn |> put_status(422) |> json(%{error: "unprocessable"})
    end
  end
end
