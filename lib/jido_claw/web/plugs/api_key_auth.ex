defmodule JidoClaw.Web.Plugs.ApiKeyAuth do
  @moduledoc false
  import Plug.Conn

  alias AshAuthentication.Strategy.ApiKey.Actions
  alias JidoClaw.Audit.AsyncWriter
  alias JidoClaw.Audit.EventAttrs
  alias JidoClaw.Authorization.Actor

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, api_key} <- extract_api_key(conn),
         {:ok, user} <- authenticate_api_key(api_key) do
      actor = Actor.build(user)

      conn
      |> assign(:current_user, user)
      |> assign(:current_actor, actor)
      |> assign(:auth_method, :api_key)
      |> Ash.PlugHelpers.set_actor(actor)
    else
      # authenticate_api_key/1 emits its own success/failure audit events;
      # only the never-reached-authentication case goes through
      # missing_api_key_failure/0 here.
      {:error, "missing_api_key"} ->
        {:error, reason} = missing_api_key_failure()
        unauthorized(conn, reason)

      {:error, reason} ->
        unauthorized(conn, reason)
    end
  end

  @doc """
  Authenticate a plaintext API key against the `:api_key` strategy.

  Shared by this plug and `JidoClaw.Web.ArgusSocket` so every key
  authentication attempt — HTTP or WebSocket — emits exactly one
  `:auth_event` audit row (`api_key_sign_in_success` /
  `api_key_sign_in_failure`). Non-binary input is invalid, never a crash.
  Callers that never obtained a key at all (no header, no token) don't
  reach this function — they emit their row via
  `missing_api_key_failure/0` instead, keeping the one-row-per-attempt
  contract over the full attempt surface.
  """
  @spec authenticate_api_key(term()) :: {:ok, JidoClaw.Accounts.User.t()} | {:error, String.t()}
  def authenticate_api_key(api_key) when is_binary(api_key) do
    strategy = AshAuthentication.Info.strategy!(JidoClaw.Accounts.User, :api_key)

    case Actions.sign_in(strategy, %{api_key: api_key}, []) do
      {:ok, user} ->
        emit_auth_event(:api_key_sign_in_success, to_string(user.id), %{})
        {:ok, user}

      {:error, _} ->
        invalid_key_failure()
    end
  end

  def authenticate_api_key(_non_binary), do: invalid_key_failure()

  @doc """
  Emit the missing-key `:auth_event` audit row and return the error.

  The audited refusal for an attempt that never carried a key —
  `authenticate_api_key/1` is never reached, so it can't emit the row.
  Shared by this plug's `call/2` (no Authorization/x-api-key header) and
  `JidoClaw.Web.ArgusSocket.connect/3` (no `authToken`), keeping the
  one-audit-row-per-attempt contract across HTTP and WebSocket.
  """
  @spec missing_api_key_failure() :: {:error, String.t()}
  def missing_api_key_failure do
    reason = "missing_api_key"
    emit_auth_event(:api_key_sign_in_failure, nil, %{reason: reason})
    {:error, reason}
  end

  defp invalid_key_failure do
    reason = "invalid_api_key"
    emit_auth_event(:api_key_sign_in_failure, nil, %{reason: reason})
    {:error, reason}
  end

  defp unauthorized(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: reason}))
    |> halt()
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

  defp emit_auth_event(kind, actor_id, payload) do
    AsyncWriter.cast(
      EventAttrs.new(
        tenant_id: "default",
        event_kind: :auth_event,
        actor_kind: if(actor_id, do: :user, else: :system),
        actor_id: actor_id,
        target_kind: :auth,
        target_id: Atom.to_string(kind),
        payload: payload
      )
    )
  end
end
