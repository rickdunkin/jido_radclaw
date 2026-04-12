defmodule JidoClaw.GitHub.WebhookSignature do
  @spec verify(binary(), String.t() | nil) :: :ok | {:error, atom()}
  def verify(_payload, nil), do: {:error, :missing_signature_header}

  def verify(payload, "sha256=" <> hex_digest) when byte_size(hex_digest) == 64 do
    case get_webhook_secret() do
      nil ->
        {:error, :missing_webhook_secret}

      secret ->
        expected = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

        if Plug.Crypto.secure_compare(expected, String.downcase(hex_digest)) do
          :ok
        else
          {:error, :signature_mismatch}
        end
    end
  end

  def verify(_payload, _header), do: {:error, :invalid_signature_header}

  defp get_webhook_secret do
    Application.get_env(:jido_claw, :github_webhook_secret)
  end
end
