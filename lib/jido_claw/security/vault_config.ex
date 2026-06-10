defmodule JidoClaw.Security.VaultConfig do
  @moduledoc false

  @vault JidoClaw.Security.Vault
  @default_key_file "~/.config/jidoclaw/cloak.key"

  @spec ensure_configured!() :: :ok
  def ensure_configured! do
    if configured?() do
      :ok
    else
      configure_from_runtime_key!()
    end
  end

  @spec configured?() :: boolean()
  def configured? do
    :jido_claw
    |> Application.get_env(@vault, [])
    |> Keyword.get(:ciphers, [])
    |> Keyword.get(:default)
    |> configured_cipher?()
  end

  defp configured_cipher?({Cloak.Ciphers.AES.GCM, opts}) when is_list(opts) do
    match?(key when is_binary(key) and byte_size(key) in [16, 24, 32], Keyword.get(opts, :key))
  end

  defp configured_cipher?(_), do: false

  defp configure_from_runtime_key! do
    case load_key() do
      {:ok, key} ->
        Application.put_env(:jido_claw, @vault, vault_config(key))
        :ok

      {:error, :missing} ->
        raise """
        CLOAK_KEY is required to start JidoClaw.

        Set CLOAK_KEY to a base64-encoded 16, 24, or 32 byte AES key, or set \
        CLOAK_KEY_FILE to a file containing that value. The default key file is \
        #{Path.expand(@default_key_file)}.
        """

      {:error, reason} ->
        raise "Invalid CLOAK_KEY: #{inspect(reason)}"
    end
  end

  defp load_key do
    with {:error, :missing} <- load_env_key(),
         {:error, :missing} <- load_file_key() do
      {:error, :missing}
    end
  end

  defp load_env_key do
    case System.get_env("CLOAK_KEY") do
      key when is_binary(key) and key != "" -> decode_key(key)
      _ -> {:error, :missing}
    end
  end

  defp load_file_key do
    path = System.get_env("CLOAK_KEY_FILE") || @default_key_file

    case File.read(Path.expand(path)) do
      {:ok, key} ->
        key
        |> String.trim()
        |> decode_key()

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, {:key_file, reason}}
    end
  end

  defp decode_key(encoded) do
    with {:ok, key} <- Base.decode64(encoded),
         true <- byte_size(key) in [16, 24, 32] do
      {:ok, key}
    else
      :error -> {:error, :invalid_base64}
      false -> {:error, :invalid_key_length}
    end
  end

  defp vault_config(key) do
    [
      ciphers: [
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1", key: key, iv_length: 12
        }
      ]
    ]
  end
end
