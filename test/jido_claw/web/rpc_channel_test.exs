defmodule JidoClaw.Web.RpcChannelTest do
  @moduledoc """
  Tenant isolation on `JidoClaw.Web.RpcChannel` (code-review H3).

  `sessions.list` and `gateway.status` must only surface sessions
  belonging to the authenticated user's tenant — never the whole
  `SessionRegistry` — and any `rpc:*` subtopic other than `rpc:lobby`
  must be rejected at join.

  Boots the real endpoint (`server: false`, see `config/test.exs`) and
  builds the socket directly with the assigns `UserSocket.connect/3`
  would set, bypassing session-cookie authentication.
  """
  use JidoClaw.TenantCase, async: false

  import Phoenix.ChannelTest

  alias JidoClaw.Accounts.User
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Web.RpcChannel
  alias JidoClaw.Web.UserSocket

  @endpoint JidoClaw.Web.Endpoint

  setup do
    start_supervised!(JidoClaw.Web.Endpoint)

    user = register_user!()
    {:ok, _reply, socket} = join_lobby(user)

    {:ok, user: user, socket: socket, tenant_id: to_string(user.id)}
  end

  test "sessions.list returns only the caller's tenant sessions",
       %{socket: socket, tenant_id: tenant_id} do
    own_ids = for _ <- 1..2, do: "sess-#{System.unique_integer([:positive])}"
    foreign_tenant = "tenant-foreign-#{System.unique_integer([:positive])}"
    foreign_ids = for _ <- 1..2, do: "sess-#{System.unique_integer([:positive])}"

    for id <- own_ids, do: register_session!(tenant_id, id)
    for id <- foreign_ids, do: register_session!(foreign_tenant, id)

    ref = push(socket, "sessions.list", %{})
    assert_reply(ref, :ok, %{sessions: sessions})

    # Registry order is not contractual — compare as sets.
    assert MapSet.new(sessions, & &1.session_id) == MapSet.new(own_ids)
    assert Enum.all?(sessions, &(&1.tenant_id == tenant_id))
  end

  test "gateway.status counts only the caller's tenant sessions",
       %{socket: socket, tenant_id: tenant_id} do
    foreign_tenant = "tenant-foreign-#{System.unique_integer([:positive])}"

    for _ <- 1..2, do: register_session!(tenant_id, "sess-#{System.unique_integer([:positive])}")
    register_session!(foreign_tenant, "sess-#{System.unique_integer([:positive])}")

    ref = push(socket, "gateway.status", %{})
    assert_reply(ref, :ok, %{sessions: count})

    assert count == 2
  end

  test "joining any rpc:* subtopic other than rpc:lobby is rejected", %{user: user} do
    socket = build_socket(user)

    assert {:error, %{reason: "unauthorized topic"}} =
             subscribe_and_join(socket, RpcChannel, "rpc:other")
  end

  defp register_user! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "rpc-channel-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )

    user
  end

  defp build_socket(user) do
    socket(UserSocket, "user_socket:#{user.id}", %{
      current_user: user,
      current_actor: Actor.build(user)
    })
  end

  defp join_lobby(user) do
    user
    |> build_socket()
    |> subscribe_and_join(RpcChannel, "rpc:lobby")
  end

  # Registers a fake `{tenant_id, session_id}` entry in the (global)
  # SessionRegistry via an UNLINKED holder process — `:kill` through a link
  # would take the test process down with it. Blocks on an explicit ack so
  # a channel push can't race the registration; the entry disappears when
  # the holder dies (explicit on_exit kill).
  defp register_session!(tenant_id, session_id) do
    test_pid = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(JidoClaw.SessionRegistry, {tenant_id, session_id}, nil)
        send(test_pid, {:registered, ref})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive({:registered, ^ref})
    pid
  end
end
