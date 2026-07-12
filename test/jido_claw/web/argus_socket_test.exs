defmodule JidoClaw.Web.ArgusSocketTest do
  @moduledoc """
  Connect-path coverage for the key-only argus socket: authToken header
  auth (missing/invalid/valid), the connect-time tenant activity gate
  (inactive / infra-down, fail closed), the per-tenant socket id, the
  audit contract (valid, invalid, and missing token each emit exactly
  one `:auth_event` row), and the capability boundary in both
  directions (`rpc:*` unroutable over ArgusSocket; API keys never
  authenticate `UserSocket`). The endpoint mount itself is pinned via
  `__sockets__/0` — the `connect/3` tests inject `connect_info`
  themselves and would pass with the `auth_token: true` option omitted.
  """
  # async: false — start_supervised!(JidoClaw.Web.Endpoint) registers the
  # fixed app-owned Endpoint name; any two endpoint-starter files running
  # concurrently would collide on it, so the cohort stays sync (grep
  # `start_supervised!(JidoClaw.Web.Endpoint)` for the current members).
  use JidoClaw.TenantCase, async: false

  import Phoenix.ChannelTest

  alias AshAuthentication.Plug.Helpers
  alias JidoClaw.Accounts.ApiKey
  alias JidoClaw.Accounts.User
  alias JidoClaw.Audit.Event
  alias JidoClaw.Tenants.Access
  alias JidoClaw.Web.ArgusSocket
  alias JidoClaw.Web.UserSocket

  @endpoint JidoClaw.Web.Endpoint

  defmodule InfraDownAccess do
    @moduledoc false

    @spec ensure_active(String.t()) :: {:error, :db_down}
    def ensure_active(_tenant_id), do: {:error, :db_down}
  end

  setup do
    start_supervised!(JidoClaw.Web.Endpoint)

    previous = Application.fetch_env(:jido_claw, :tenant_access_module)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_claw, :tenant_access_module, value)
        :error -> Application.delete_env(:jido_claw, :tenant_access_module)
      end
    end)

    :ok
  end

  describe "connect/3 over the authToken header" do
    test "a valid key connects, assigns identity, and provisions the tenant row" do
      %{user: user, key: key, tenant_id: tenant_id} = register_actor!()

      assert {:ok, socket} = connect(ArgusSocket, %{}, connect_info: %{auth_token: key})

      assert socket.assigns.current_user.id == user.id
      assert socket.assigns.current_actor == %{user_id: user.id, tenant_id: tenant_id}
      assert socket.assigns.auth_method == :api_key
      assert socket.id == "argus_socket:#{tenant_id}"
      assert :ok = Access.active?(tenant_id)
    end

    test "an invalid key is refused and audited" do
      {:ok, _} = Tenant.ensure("default")
      baseline = auth_event_count()

      assert {:error, :invalid_api_key} =
               connect(ArgusSocket, %{}, connect_info: %{auth_token: "not-a-real-key"})

      :ok = eventually(fn -> auth_event_count() - baseline == 1 end)

      latest = latest_auth_event()
      assert latest.target_id == "api_key_sign_in_failure"
      assert latest.actor_kind == :system
      assert is_nil(latest.actor_id)
      assert payload_get(latest.payload, :reason) == "invalid_api_key"
    end

    test "a missing token is refused and audited" do
      {:ok, _} = Tenant.ensure("default")
      baseline = auth_event_count()

      assert {:error, :missing_api_key} = connect(ArgusSocket, %{})

      :ok = eventually(fn -> auth_event_count() - baseline == 1 end)

      latest = latest_auth_event()
      assert latest.target_id == "api_key_sign_in_failure"
      assert latest.actor_kind == :system
      assert is_nil(latest.actor_id)
      assert payload_get(latest.payload, :reason) == "missing_api_key"
    end

    test "a params-carried key never authenticates and is audited as missing" do
      %{key: key} = register_actor!()
      {:ok, _} = Tenant.ensure("default")
      baseline = auth_event_count()

      assert {:error, :missing_api_key} = connect(ArgusSocket, %{"api_key" => key})

      :ok = eventually(fn -> auth_event_count() - baseline == 1 end)

      latest = latest_auth_event()
      assert latest.target_id == "api_key_sign_in_failure"
      assert payload_get(latest.payload, :reason) == "missing_api_key"
    end

    test "a suspended tenant's valid key is refused" do
      %{key: key, tenant_id: tenant_id} = register_actor!()
      {:ok, _} = Tenant.ensure(tenant_id)
      {:ok, tenant} = Tenant.by_id(tenant_id)
      {:ok, _} = Tenant.suspend(tenant)

      assert {:error, :tenant_inactive} =
               connect(ArgusSocket, %{}, connect_info: %{auth_token: key})
    end

    test "an activity-check infra failure is refused (fail closed)" do
      %{key: key} = register_actor!()
      Application.put_env(:jido_claw, :tenant_access_module, InfraDownAccess)

      assert {:error, :tenant_unavailable} =
               connect(ArgusSocket, %{}, connect_info: %{auth_token: key})
    end

    test "a key connect emits the api_key_sign_in_success audit event" do
      {:ok, _} = Tenant.ensure("default")
      baseline = auth_event_count()

      %{user: user, key: key} = register_actor!()

      assert {:ok, _socket} = connect(ArgusSocket, %{}, connect_info: %{auth_token: key})

      :ok = eventually(fn -> auth_event_count() - baseline == 1 end)

      latest = latest_auth_event()
      assert latest.target_id == "api_key_sign_in_success"
      assert latest.actor_kind == :user
      assert latest.actor_id == to_string(user.id)
    end
  end

  describe "capability boundary" do
    test "rpc:* is unroutable over ArgusSocket" do
      socket = socket(ArgusSocket, "argus_socket:t", %{current_actor: actor_for(seed_tenant())})

      assert_raise RuntimeError, ~r/no channel found for topic "rpc:lobby"/, fn ->
        subscribe_and_join(socket, "rpc:lobby")
      end
    end

    test "API key params never authenticate UserSocket; sessions still do" do
      %{user: user, key: key} = register_actor!()

      assert {:error, :unauthorized} = connect(UserSocket, %{"api_key" => key})

      assert {:ok, user_socket} =
               connect(UserSocket, %{}, connect_info: %{session: session_for(user)})

      assert {:ok, _reply, _socket} = subscribe_and_join(user_socket, "rpc:lobby")
    end
  end

  describe "suspension force-disconnect" do
    test "Tenant.suspend broadcasts disconnect on the tenant's socket topic" do
      %{key: key, tenant_id: tenant_id} = register_actor!()
      assert {:ok, _socket} = connect(ArgusSocket, %{}, connect_info: %{auth_token: key})

      topic = "argus_socket:#{tenant_id}"
      :ok = Phoenix.PubSub.subscribe(JidoClaw.PubSub, topic)

      {:ok, tenant} = Tenant.by_id(tenant_id)
      {:ok, _} = Tenant.suspend(tenant)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}
    end

    test "disconnect_tenant/1 broadcasts without a running Endpoint" do
      stop_supervised!(JidoClaw.Web.Endpoint)

      tenant_id = unique_tenant_id(:argus_disconnect)
      topic = "argus_socket:#{tenant_id}"
      :ok = Phoenix.PubSub.subscribe(JidoClaw.PubSub, topic)

      assert :ok = ArgusSocket.disconnect_tenant(tenant_id)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}
    end
  end

  describe "endpoint mount" do
    test "/argus/ws serves ArgusSocket with the auth_token transport enabled" do
      assert {"/argus/ws", ArgusSocket, opts} =
               List.keyfind(@endpoint.__sockets__(), "/argus/ws", 0)

      # Socket-level option — the endpoint macro clobbers a nested
      # `websocket: [auth_token: ...]` entry, so this is the only form
      # that actually enables the Sec-WebSocket-Protocol transport.
      assert opts[:auth_token] == true
      assert Keyword.get(opts, :websocket, true) != false
    end
  end

  defp register_actor! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "argus-socket-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )

    {:ok, api_key} = ApiKey.create(user.id, authorize?: false)
    plaintext = Ash.Resource.get_metadata(api_key, :plaintext_api_key)
    tenant_id = to_string(user.id)

    %{user: user, key: plaintext, tenant_id: tenant_id}
  end

  defp session_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
    |> Plug.Conn.get_session()
  end

  defp auth_event_count do
    {:ok, rows} = Event.read(tenant: "default", authorize?: false)
    Enum.count(rows, &(&1.event_kind == :auth_event))
  end

  defp latest_auth_event do
    {:ok, rows} = Event.read(tenant: "default", authorize?: false)

    [latest | _] =
      rows
      |> Enum.filter(&(&1.event_kind == :auth_event))
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    latest
  end

  # Payload keys are JSONB-encoded — tolerate atom or string keys.
  defp payload_get(payload, key) do
    Map.get(payload, key) || Map.get(payload, to_string(key))
  end

  defp eventually(fun, deadline_ms \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("eventually condition not met within timeout")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end
end
