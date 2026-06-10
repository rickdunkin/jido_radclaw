defmodule JidoClaw.Web.CacheBodyReader do
  @moduledoc false

  # Only cache the raw body for paths that need signature verification.
  # This avoids doubling memory for every parsed request.
  @cached_path_prefixes ["/webhooks"]

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok | :more, binary(), Plug.Conn.t()} | {:error, term()}
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

  @spec raw_body(Plug.Conn.t()) :: {:ok, binary()} | {:error, :not_cached}
  def raw_body(conn) do
    case conn.private[:raw_body] do
      nil ->
        {:error, :not_cached}

      parts ->
        body =
          parts
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        {:ok, body}
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
