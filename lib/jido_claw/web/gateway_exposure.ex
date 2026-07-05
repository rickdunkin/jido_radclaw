defmodule JidoClaw.Web.GatewayExposure do
  @moduledoc """
  Opt-in external exposure for the Phoenix gateway via `PHX_HOST`.

  The base endpoint config binds loopback (`127.0.0.1:4000`) with a
  port-pinned WebSocket origin allowlist in **every** env. Setting
  `PHX_HOST=<host>[,<host2>]` (e.g. a Tailscale MagicDNS name and/or
  tailnet IP) opts into exposure: the listener rebinds `0.0.0.0`,
  `url[:host]` becomes the first host, and each host is appended to
  `check_origin` pinned to a port.

  Port policy: a bare `PHX_HOST=box.ts.net` pins origins to the
  configured gateway port (direct access). Fronting with a TLS proxy on
  another port requires spelling it out, e.g. `PHX_HOST=box.ts.net:443`.
  No wildcard-port origins are ever emitted — a port-less `//host` entry
  would let any port on that host open a cookie-bearing socket. Explicit
  ports affect origins only; they are never propagated to `url`.

  `configure!/0` runs from `JidoClaw.Application.start/2` immediately
  after `load_dotenv/0` — `config/runtime.exs` evaluates before the
  application starts, so it can never see `.env`-supplied values.
  (`JidoClaw.Desktop.Sidecar.maybe_configure_endpoint/0` was written to
  the same shape, though nothing invokes it today.)
  """

  require Logger

  @endpoint JidoClaw.Web.Endpoint
  @default_gateway_port 4000

  @doc """
  Read `PHX_HOST` and apply exposure to the endpoint config. No-op when
  unset; warns and stays loopback when set but unparseable.
  """
  @spec configure!() :: :ok
  def configure!, do: configure(System.get_env("PHX_HOST"))

  @doc """
  Apply exposure for a raw `PHX_HOST` value (exposed for tests).
  """
  @spec configure(String.t() | nil) :: :ok
  def configure(nil), do: :ok

  def configure(raw) when is_binary(raw) do
    if String.trim(raw) == "" do
      :ok
    else
      case parse_hosts(raw) do
        [] ->
          Logger.warning(
            "[GatewayExposure] PHX_HOST is set but contains no valid hosts " <>
              "(#{inspect(raw)}) — gateway stays bound to loopback"
          )

          :ok

        hosts ->
          apply_exposure(hosts)
      end
    end
  end

  @doc """
  Parse a raw `PHX_HOST` value into `{host, explicit_port_or_nil}` pairs.

  Entries are comma-separated. Each entry round-trips through `URI.new/1`
  with any `scheme://` prefix stripped first, so a port is captured only
  when explicitly written (never scheme-implied). Paths are discarded.
  Blank, unbracketed-IPv6, and unparseable entries are dropped.
  """
  @spec parse_hosts(String.t() | nil) :: [{String.t(), :inet.port_number() | nil}]
  def parse_hosts(nil), do: []

  def parse_hosts(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&parse_host/1)
  end

  defp parse_host(entry) do
    authority =
      case String.split(entry, "://", parts: 2) do
        [_scheme, rest] -> rest
        [rest] -> rest
      end

    case URI.new("//" <> authority) do
      {:ok, %URI{host: host, port: port}} when is_binary(host) and host != "" ->
        [{host, port}]

      _ ->
        []
    end
  end

  defp apply_exposure([{first_host, _} | _] = hosts) do
    config = Application.get_env(:jido_claw, @endpoint, [])
    gateway_port = config[:http][:port] || @default_gateway_port

    base_origins =
      case Keyword.get(config, :check_origin) do
        origins when is_list(origins) -> origins
        _ -> []
      end

    host_origins = Enum.map(hosts, &origin_for(&1, gateway_port))
    origins = Enum.uniq(host_origins ++ base_origins)

    new_config =
      config
      |> Keyword.put(:check_origin, origins)
      |> Keyword.update(:url, [host: first_host], &Keyword.put(&1, :host, first_host))
      |> Keyword.update(:http, [ip: {0, 0, 0, 0}], &Keyword.put(&1, :ip, {0, 0, 0, 0}))

    Application.put_env(:jido_claw, @endpoint, new_config)

    Logger.info([
      "[GatewayExposure] PHX_HOST set — binding 0.0.0.0, allowed origins: ",
      Enum.join(origins, " ")
    ])

    :ok
  end

  defp origin_for({host, explicit_port}, gateway_port) do
    "//#{format_host(host)}:#{explicit_port || gateway_port}"
  end

  # Re-bracket IPv6 literals when rebuilding origin strings.
  defp format_host(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end
end
