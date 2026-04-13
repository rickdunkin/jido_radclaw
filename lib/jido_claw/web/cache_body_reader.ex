defmodule JidoClaw.Web.CacheBodyReader do
  @moduledoc false

  # Only cache the raw body for paths that need signature verification.
  # This avoids doubling memory for every parsed request.
  @cached_path_prefixes ["/webhooks"]

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = maybe_cache(conn, body)
        {:ok, body, conn}

      {:more, body, conn} ->
        conn = maybe_cache(conn, body)
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def raw_body(conn) do
    case conn.private[:raw_body] do
      nil -> {:error, :not_cached}
      parts -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp maybe_cache(conn, body) do
    if Enum.any?(@cached_path_prefixes, &String.starts_with?(conn.request_path, &1)) do
      update_in(conn.private[:raw_body], &[body | &1 || []])
    else
      conn
    end
  end
end
