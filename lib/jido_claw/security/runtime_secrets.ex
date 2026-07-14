defmodule JidoClaw.Security.RuntimeSecrets do
  @moduledoc """
  The SOLE presence + quality enforcement for `SECRET_KEY_BASE` and
  `TOKEN_SIGNING_SECRET`, run at APPLICATION STARTUP (after dotenv loading).
  `config/runtime.exs` is total/configure-only — it sets these values when
  present and never raises (the escript's pre-boot `--third-party-licenses`
  route depends on config evaluation staying raise-free) — so a missing or
  short secret fails HERE, with the same fail-fast timing for releases
  (a release boots the app immediately after config evaluation).
  """

  @endpoint JidoClaw.Web.Endpoint
  @min_secret_bytes 64

  @spec ensure_configured!() :: :ok
  def ensure_configured! do
    secret_key_base = load_secret!("SECRET_KEY_BASE", endpoint_secret_key_base())
    token_signing_secret = load_secret!("TOKEN_SIGNING_SECRET", token_signing_secret())

    configure_secret_key_base(secret_key_base)
    Application.put_env(:jido_claw, :token_signing_secret, token_signing_secret)

    :ok
  end

  defp endpoint_secret_key_base do
    :jido_claw
    |> Application.get_env(@endpoint, [])
    |> Keyword.get(:secret_key_base)
  end

  defp token_signing_secret do
    Application.get_env(:jido_claw, :token_signing_secret)
  end

  defp load_secret!(env_name, configured_value) do
    env_name
    |> System.get_env()
    |> present_or(configured_value)
    |> validate_secret!(env_name)
  end

  defp present_or(value, _configured_value) when is_binary(value) and value != "", do: value
  defp present_or(_value, configured_value), do: configured_value

  defp validate_secret!(secret, _env_name)
       when is_binary(secret) and byte_size(secret) >= @min_secret_bytes,
       do: secret

  defp validate_secret!(secret, env_name) when is_binary(secret) do
    raise """
    #{env_name} must be at least #{@min_secret_bytes} bytes.

    Generate a value with `mix phx.gen.secret` and set it in the shell environment or .env.
    """
  end

  defp validate_secret!(_secret, env_name) do
    raise """
    #{env_name} is required to start JidoClaw.

    Generate a value with `mix phx.gen.secret` and set it in the shell environment or .env.
    """
  end

  defp configure_secret_key_base(secret_key_base) do
    endpoint_config =
      :jido_claw
      |> Application.get_env(@endpoint, [])
      |> Keyword.put(:secret_key_base, secret_key_base)

    Application.put_env(:jido_claw, @endpoint, endpoint_config)
  end
end
