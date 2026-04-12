defmodule JidoClaw.Web.Plugs.ApiKeyAuth do
  @moduledoc false
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, api_key} <- extract_api_key(conn),
         {:ok, user} <- authenticate(api_key) do
      conn
      |> assign(:current_user, user)
      |> assign(:auth_method, :api_key)
    else
      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: reason}))
        |> halt()
    end
  end

  defp extract_api_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] ->
        {:ok, key}

      _ ->
        case get_req_header(conn, "x-api-key") do
          [key] when byte_size(key) > 0 -> {:ok, key}
          _ -> {:error, "missing_api_key"}
        end
    end
  end

  defp authenticate(api_key) do
    case AshAuthentication.Strategy.ApiKey.Actions.sign_in(
           JidoClaw.Accounts.User,
           :api_key,
           %{api_key: api_key}
         ) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, "invalid_api_key"}
    end
  end
end
