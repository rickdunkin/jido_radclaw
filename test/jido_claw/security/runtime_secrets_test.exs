defmodule JidoClaw.Security.RuntimeSecretsTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Security.RuntimeSecrets

  @endpoint JidoClaw.Web.Endpoint

  setup do
    old_secret_key_base_env = System.get_env("SECRET_KEY_BASE")
    old_token_env = System.get_env("TOKEN_SIGNING_SECRET")
    old_endpoint_config = Application.get_env(:jido_claw, @endpoint)
    old_token_config = Application.get_env(:jido_claw, :token_signing_secret)

    on_exit(fn ->
      restore_env("SECRET_KEY_BASE", old_secret_key_base_env)
      restore_env("TOKEN_SIGNING_SECRET", old_token_env)
      restore_app_env(@endpoint, old_endpoint_config)
      restore_app_env(:token_signing_secret, old_token_config)
    end)

    :ok
  end

  test "configures secrets from environment variables" do
    secret_key_base = String.duplicate("s", 64)
    token_signing_secret = String.duplicate("t", 64)

    System.put_env("SECRET_KEY_BASE", secret_key_base)
    System.put_env("TOKEN_SIGNING_SECRET", token_signing_secret)
    Application.put_env(:jido_claw, @endpoint, [])
    Application.delete_env(:jido_claw, :token_signing_secret)

    assert :ok = RuntimeSecrets.ensure_configured!()

    assert :jido_claw
           |> Application.get_env(@endpoint)
           |> Keyword.fetch!(:secret_key_base) == secret_key_base

    assert Application.fetch_env!(:jido_claw, :token_signing_secret) == token_signing_secret
  end

  test "raises when secret_key_base is missing" do
    System.delete_env("SECRET_KEY_BASE")
    System.put_env("TOKEN_SIGNING_SECRET", String.duplicate("t", 64))
    Application.put_env(:jido_claw, @endpoint, [])
    Application.delete_env(:jido_claw, :token_signing_secret)

    assert_raise RuntimeError, ~r/SECRET_KEY_BASE is required/, fn ->
      RuntimeSecrets.ensure_configured!()
    end
  end

  test "raises when token signing secret is missing" do
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
    System.delete_env("TOKEN_SIGNING_SECRET")
    Application.put_env(:jido_claw, @endpoint, [])
    Application.delete_env(:jido_claw, :token_signing_secret)

    assert_raise RuntimeError, ~r/TOKEN_SIGNING_SECRET is required/, fn ->
      RuntimeSecrets.ensure_configured!()
    end
  end

  test "raises when a configured secret is too short" do
    System.delete_env("SECRET_KEY_BASE")
    System.delete_env("TOKEN_SIGNING_SECRET")
    Application.put_env(:jido_claw, @endpoint, secret_key_base: "short")
    Application.put_env(:jido_claw, :token_signing_secret, String.duplicate("t", 64))

    assert_raise RuntimeError, ~r/SECRET_KEY_BASE must be at least 64 bytes/, fn ->
      RuntimeSecrets.ensure_configured!()
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_app_env(key, value), do: Application.put_env(:jido_claw, key, value)
end
