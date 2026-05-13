defmodule JidoClaw.Web.Plugs.ApiKeyAuthTest do
  @moduledoc """
  Auth-event emission coverage for `JidoClaw.Web.Plugs.ApiKeyAuth`.

  Mirrors the `AuthController` audit-emission test: drives the plug
  directly (no router) and asserts exactly one `:auth_event` audit row
  is appended per call under the `"default"` tenant.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit.Event
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Web.Plugs.ApiKeyAuth

  setup do
    {:ok, _} = Tenant.ensure("default")

    {:ok, baseline_rows} = Event.read(tenant: "default", authorize?: false)
    initial_count = Enum.count(baseline_rows, &(&1.event_kind == :auth_event))
    {:ok, baseline: initial_count}
  end

  describe "valid API key" do
    test "emits :api_key_sign_in_success with actor_kind: :user", %{baseline: baseline} do
      {user, plaintext} = create_user_with_api_key()

      conn =
        Phoenix.ConnTest.build_conn(:get, "/v1/anything", %{})
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)

      _ = ApiKeyAuth.call(conn, ApiKeyAuth.init([]))

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default", authorize?: false)
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      latest = latest_auth_event()

      assert latest.target_kind == :auth
      assert latest.target_id == "api_key_sign_in_success"
      assert latest.actor_kind == :user
      assert latest.actor_id == to_string(user.id)
    end
  end

  describe "invalid API key" do
    test "emits :api_key_sign_in_failure with reason: invalid_api_key", %{baseline: baseline} do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/v1/anything", %{})
        |> Plug.Conn.put_req_header("authorization", "Bearer not-a-real-key")

      _ = ApiKeyAuth.call(conn, ApiKeyAuth.init([]))

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default", authorize?: false)
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      latest = latest_auth_event()

      assert latest.target_kind == :auth
      assert latest.target_id == "api_key_sign_in_failure"
      assert latest.actor_kind == :system
      assert is_nil(latest.actor_id)
      assert payload_get(latest.payload, :reason) == "invalid_api_key"
    end
  end

  describe "missing API key header" do
    test "emits :api_key_sign_in_failure with reason: missing_api_key", %{baseline: baseline} do
      conn = Phoenix.ConnTest.build_conn(:get, "/v1/anything", %{})

      _ = ApiKeyAuth.call(conn, ApiKeyAuth.init([]))

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default", authorize?: false)
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      latest = latest_auth_event()

      assert latest.target_kind == :auth
      assert latest.target_id == "api_key_sign_in_failure"
      assert latest.actor_kind == :system
      assert is_nil(latest.actor_id)
      assert payload_get(latest.payload, :reason) == "missing_api_key"
    end
  end

  defp create_user_with_api_key do
    password = "valid-password-123456"

    user_attrs = %{
      email: "apikey-test-#{System.unique_integer([:positive])}@example.com",
      password: password,
      password_confirmation: password
    }

    {:ok, user} =
      JidoClaw.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, user_attrs)
      |> Ash.create(authorize?: false)

    {:ok, api_key} =
      JidoClaw.Accounts.ApiKey
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create(authorize?: false)

    plaintext = Ash.Resource.get_metadata(api_key, :plaintext_api_key)
    {user, plaintext}
  end

  defp latest_auth_event do
    {:ok, rows} = Event.read(tenant: "default", authorize?: false)
    auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
    [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})
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
