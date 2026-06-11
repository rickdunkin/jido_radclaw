defmodule JidoClaw.Network.PeerDirectory do
  @moduledoc """
  Allowlist of trusted peer Ed25519 public keys for the solution-sharing
  network.

  Source: the `:network_peer_keys` Application env (list of base64-encoded
  public keys — the test seam, takes precedence) or the
  `JIDOCLAW_NETWORK_PEERS` env var (comma-separated base64). The config is
  read and parsed per call rather than cached at boot because
  `JidoClaw.Application.load_dotenv/0` populates `.env` values after
  runtime config has evaluated — the same rationale as
  `JidoClaw.Web.AdminAccess`; per-message parse cost is negligible since
  inbound network messages are rare.

  Peer agent ids are always **derived** from the configured key via
  `JidoClaw.Agent.Identity.derive_agent_id/1` — operators configure only
  keys, never id:key pairs, so a mistyped id cannot mismap a key. Invalid
  entries (bad base64, wrong key size) are logged and skipped so one bad
  key does not kill all inbound.
  """

  require Logger

  alias JidoClaw.Agent.Identity

  @app_env_key :network_peer_keys
  @env_var "JIDOCLAW_NETWORK_PEERS"
  @ed25519_key_bytes 32

  @doc """
  True when at least one **valid** peer key is configured — not merely
  when raw config is non-empty, so an invalid-only allowlist still reads
  as unconfigured and triggers the connect-time "inbound will be
  dropped" warning.
  """
  @spec configured?() :: boolean()
  def configured?, do: map_size(peer_keys()) > 0

  @doc """
  Fetch the raw Ed25519 public key for a peer agent id.
  """
  @spec fetch(String.t()) :: {:ok, binary()} | :error
  def fetch(agent_id) when is_binary(agent_id) do
    Map.fetch(peer_keys(), agent_id)
  end

  defp peer_keys do
    raw = Application.get_env(:jido_claw, @app_env_key) || System.get_env(@env_var)

    raw
    |> entries()
    |> Enum.flat_map(&decode_entry/1)
    |> Map.new()
  end

  defp decode_entry(entry) do
    case decode_key(entry) do
      {:ok, key} ->
        [{Identity.derive_agent_id(key), key}]

      :error ->
        Logger.warning(
          "[Network.PeerDirectory] Skipping invalid peer key entry (expected base64 32-byte Ed25519 public key)"
        )

        []
    end
  end

  defp entries(nil), do: []
  defp entries(raw) when is_binary(raw), do: normalize_entries(String.split(raw, ","))
  defp entries(raw) when is_list(raw), do: normalize_entries(Enum.map(raw, &to_string/1))

  defp normalize_entries(entries) do
    entries
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp decode_key(entry) do
    case Base.decode64(entry) do
      {:ok, key} when byte_size(key) == @ed25519_key_bytes -> {:ok, key}
      _ -> :error
    end
  end
end
