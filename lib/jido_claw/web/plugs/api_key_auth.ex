defmodule JidoClaw.Web.Plugs.ApiKeyAuth do
  @moduledoc false
  import Plug.Conn

  alias AshAuthentication.Strategy.ApiKey.Actions
  alias JidoClaw.Audit.AsyncWriter
  alias JidoClaw.Authorization.Actor

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, api_key} <- extract_api_key(conn),
         {:ok, user} <- authenticate(api_key) do
      actor = Actor.build(user)

      emit_auth_event(:api_key_sign_in_success, to_string(user.id), %{})

      conn
      |> assign(:current_user, user)
      |> assign(:current_actor, actor)
      |> assign(:auth_method, :api_key)
      |> Ash.PlugHelpers.set_actor(actor)
    else
      {:error, reason} ->
        emit_auth_event(:api_key_sign_in_failure, nil, %{reason: reason})

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
    strategy = AshAuthentication.Info.strategy!(JidoClaw.Accounts.User, :api_key)

    case Actions.sign_in(strategy, %{api_key: api_key}, []) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, "invalid_api_key"}
    end
  end

  defp emit_auth_event(kind, actor_id, payload) do
    AsyncWriter.cast(%{
      tenant_id: "default",
      event_kind: :auth_event,
      actor_kind: if(actor_id, do: :user, else: :system),
      actor_id: actor_id,
      target_kind: :auth,
      target_id: Atom.to_string(kind),
      payload: payload
    })
  end
end
