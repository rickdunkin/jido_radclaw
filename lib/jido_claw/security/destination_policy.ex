defmodule JidoClaw.Security.DestinationPolicy do
  @moduledoc """
  Host-enforced destination policy for LLM-controlled network egress.

  `browse_web` hands a model-supplied URL to an out-of-process headless
  browser. Without a gate, an injected page can steer the browser at
  internal services — the local dashboard, admin endpoints, cloud
  metadata at 169.254.169.254 — and quote their responses into the
  transcript. `check/2` denies URLs whose destination is loopback,
  RFC 1918 private space, link-local, CGNAT/tailnet (100.64.0.0/10),
  or the unspecified address, plus the IPv6 equivalents (`::1/128`,
  `fe80::/10`, `fc00::/7`, `::/128`) and IPv4-mapped forms like
  `[::ffff:127.0.0.1]`.

  ## Check sequence

  1. Kill switch: `enabled?: false` returns `:ok` before any parsing.
  2. Any backslash in the URL denies outright: WHATWG browsers
     normalize `\\` to `/`, so `http://127.0.0.1\\@example.com/` can
     parse host-side as `example.com` while the browser navigates to
     `127.0.0.1`. No legitimate URL needs one.
  3. `URI.new/1` — parse failures deny (fail closed). The permissive
     `URI.parse/1` is deliberately not used for a browser-bound gate.
  4. Scheme must be `http`/`https` (`file://` would leak local files).
  5. Host must be non-empty (`URI.new("http://")` succeeds with
     `host: ""`).
  6. The host is percent-decoded once, as a browser would. The
     decoded form must be non-empty printable ASCII with no residual
     `%` — encoded controls, double-encoding, and non-ASCII (IDN)
     hosts fail closed. No IDNA mapping is attempted; punycode-form
     URLs are plain ASCII and pass through.
  7. IP-literal hosts classify directly. `:inet.parse_address/1`
     affirmatively normalizes exotic literals — decimal `2130706433`,
     hex `0x7f.0.0.1`, octal `017700000001`, short `127.1` — so those
     are classified and denied, not merely unparseable. A literal that
     fails to parse but ends in `.` retries once with the trailing
     label dropped (WHATWG IPv4-candidate normalization: a browser
     treats `127.0.0.1.` as loopback). The stripped form is used only
     for classification — domain hosts keep their trailing dot.
  8. Remaining hosts must match `[a-zA-Z0-9._-]` (decoded WHATWG
     forbidden host code points such as `/`, `@`, `:`, `?`, `#`, `\\`
     deny outright) and must not end in a numeric label (WHATWG
     ends-in-a-number: browsers force such hosts through IPv4
     parsing, so an IP-like host this gate cannot parse is denied,
     never resolved as a DNS name).
  9. Hostnames resolve via both A and AAAA — the decoded name, FQDN
     trailing dot included, is what the resolver sees. One denied
     address poisons the host (deny-any). `:nxdomain` is a benign
     empty family, but any other resolver error (timeout, servfail)
     fails the whole check closed even if the other family returned
     public addresses — "we don't know where this goes" is not an
     allow. Both families empty also fails closed.

  ## Configuration

      config :jido_claw, :destination_policy,
        enabled?: true,
        allowed_cidrs: []

  `allowed_cidrs` is the single escape hatch: CIDR strings
  (`["127.0.0.0/8", "::1/128"]`) punching holes in the built-in deny
  set. Allow beats deny, and IPv4-mapped IPv6 addresses unwrap before
  the allow check, so `127.0.0.0/8` also permits `[::ffff:127.0.0.1]`.
  Browsing the project's own dashboard on `localhost:4000` requires
  exactly that pair. Invalid entries are logged and ignored — a config
  typo must never crash the tool, and a malformed allow entry grants
  nothing. Options on `check/2` (`:enabled?`, `:allowed_cidrs`,
  `:resolver`) override config so tests stay env-free.

  ## Honest limitations

  Callers should check the URL before navigation and re-check the
  final URL after it (`browse_web` does both). Even then:

    * Redirect *detection* is adapter-dependent: the post-navigation
      check prefers the live browser URL and falls back to navigation
      metadata. Adapters that neither answer `get_url`/`evaluate` nor
      report a real final URL degrade to re-checking the requested
      URL — still catching rebinds, but blind to true redirects.
    * DNS rebinding is mitigated, not closed: the post-navigation
      re-check is unconditional (a string-unchanged final URL is
      still re-resolved), so typical TTL-0 rebinds are caught before
      any response is quoted — but a resolver alternating answers can
      still slip between the two checks, and the internal *request* a
      redirect or rebind triggers is not preventable from the BEAM —
      the browser resolves and fetches independently, out of process.
      Fully closing the request path needs BEAM-routed egress or an
      OS-level proxy.
    * Multicast, broadcast, and other reserved ranges are not in the
      deny set.
    * Denials emit one sanitized `Logger.warning` — scheme, host, and
      denial category only, never the full URL (userinfo/query may
      carry tokens). No telemetry event today; if operators need
      counters, a `[:jido_claw, :security, :destination_policy]` event
      is the natural shape.

  Single caller today (`JidoClaw.Tools.BrowseWeb`); reusable for any
  future LLM-controlled egress surface.
  """

  import Bitwise

  require Logger

  @config_defaults [enabled?: true, allowed_cidrs: []]

  # {network, prefix, denial category}
  @v4_deny [
    {{0, 0, 0, 0}, 8, "unspecified address"},
    {{127, 0, 0, 0}, 8, "loopback"},
    {{10, 0, 0, 0}, 8, "private network, RFC 1918"},
    {{172, 16, 0, 0}, 12, "private network, RFC 1918"},
    {{192, 168, 0, 0}, 16, "private network, RFC 1918"},
    {{169, 254, 0, 0}, 16, "link-local"},
    {{100, 64, 0, 0}, 10, "carrier-grade NAT / tailnet"}
  ]

  @v6_deny [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128, "unspecified address"},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128, "loopback"},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10, "link-local"},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7, "unique local address, IPv6 ULA"}
  ]

  @allow_hint "Operators can permit specific destinations via the " <>
                ":jido_claw, :destination_policy, allowed_cidrs config."

  @type resolver ::
          (charlist(), :inet | :inet6 -> {:ok, [:inet.ip_address()]} | {:error, term()})
  @type opt ::
          {:enabled?, boolean()}
          | {:allowed_cidrs, [String.t()]}
          | {:resolver, resolver()}

  @doc """
  Checks whether `url` names an allowed destination.

  Returns `:ok` or `{:error, reason}` where `reason` is a
  human/LLM-readable string naming the host and denial category.
  """
  @spec check(String.t(), [opt()]) :: :ok | {:error, String.t()}
  def check(url, opts \\ []) when is_binary(url) do
    if enabled?(opts), do: run_checks(url, opts), else: :ok
  end

  defp run_checks(url, opts) do
    with :ok <- reject_backslash(url),
         {:ok, uri} <- parse(url),
         {:ok, scheme} <- check_scheme(uri),
         {:ok, host} <- check_host(uri, scheme),
         {:ok, decoded} <- decode_host(host, scheme) do
      check_destination(decoded, host, scheme, opts)
    end
  end

  defp reject_backslash(url) do
    if String.contains?(url, "\\") do
      deny("the URL contains a backslash and cannot be safely parsed",
        category: "malformed URL"
      )
    else
      :ok
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> deny("the URL could not be parsed", category: "malformed URL")
    end
  end

  # URI.new/1 normalizes scheme case, so plain membership suffices.
  defp check_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: {:ok, scheme}

  defp check_scheme(%URI{scheme: scheme}) do
    deny("scheme #{inspect(scheme)} is not allowed; only http and https URLs can be browsed",
      scheme: scheme,
      category: "blocked scheme"
    )
  end

  defp check_host(%URI{host: host}, _scheme) when is_binary(host) and host != "" do
    {:ok, host}
  end

  defp check_host(_uri, scheme) do
    deny("the URL has no host", scheme: scheme, category: "missing host")
  end

  # Browsers percent-decode the host once before classifying it; without this
  # %31%32%37.0.0.1 (= 127.0.0.1 in a browser) falls through to the DNS branch
  # and the gate rests on resolver failure — which wildcard and
  # NXDOMAIN-hijacking resolvers convert into answers. The decoded form is
  # guarded fail-closed: printable ASCII only (this also keeps
  # String.to_charlist/1 from raising on invalid UTF-8 such as a decoded %ff)
  # and no residual % (double-encoding; % is itself a WHATWG forbidden host
  # code point). Non-ASCII (IDN) hosts fail closed — no IDNA mapping;
  # punycode-form URLs are plain ASCII and pass through.
  defp decode_host(host, scheme) do
    decoded = URI.decode(host)

    cond do
      decoded == "" ->
        deny("the URL has no host", scheme: scheme, category: "missing host")

      not printable_ascii?(decoded) ->
        deny(
          "host #{inspect(host)} decodes to bytes outside printable ASCII; " <>
            "only ASCII hostnames can be classified",
          scheme: scheme,
          host: host,
          category: "non-ASCII host"
        )

      String.contains?(decoded, "%") ->
        deny(
          "host #{inspect(host)} still contains a percent sign after decoding " <>
            "(malformed or double-encoded)",
          scheme: scheme,
          host: host,
          category: "malformed host"
        )

      true ->
        {:ok, decoded}
    end
  end

  # Byte-level on purpose: the decoded form may not be valid UTF-8.
  defp printable_ascii?(binary) do
    Enum.all?(:binary.bin_to_list(binary), &(&1 in 0x21..0x7E))
  end

  defp check_destination(decoded, host, scheme, opts) do
    allow = parse_allow_cidrs(allowed_cidrs(opts))

    case classify_literal(decoded) do
      {:ok, ip} -> check_addresses([ip], host, scheme, allow)
      :error -> check_hostname(decoded, host, scheme, allow, opts)
    end
  end

  defp classify_literal(decoded) do
    case parse_ip(decoded) do
      {:ok, ip} -> {:ok, ip}
      :error -> classify_ipv4_candidate(decoded)
    end
  end

  # WHATWG IPv4-candidate normalization: the browser's IPv4 parser drops one
  # trailing empty label, so 127.0.0.1. is loopback. The stripped form is used
  # only for literal classification — domain hosts keep their trailing dot and
  # resolve as the FQDN.
  defp classify_ipv4_candidate(decoded) do
    if String.ends_with?(decoded, ".") do
      parse_ip(String.replace_suffix(decoded, ".", ""))
    else
      :error
    end
  end

  defp parse_ip(candidate) do
    case :inet.parse_address(String.to_charlist(candidate)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  # Mirrors the WHATWG host parser's order: forbidden host code points fail
  # domain-to-ASCII before the ends-in-a-number check, and a numeric final
  # label forces IPv4 parsing — never DNS. Leaning on resolver rejection for
  # either form would hand the decision to NXDOMAIN-hijacking/wildcard
  # resolvers.
  defp check_hostname(decoded, host, scheme, allow, opts) do
    cond do
      not dns_hostname?(decoded) ->
        deny("host #{inspect(host)} contains characters not allowed in a hostname",
          scheme: scheme,
          host: host,
          category: "forbidden host characters"
        )

      ends_in_number?(decoded) ->
        deny(
          "host #{inspect(host)} ends in a numeric label but does not parse as " <>
            "an IP address; refusing to resolve it as a DNS name",
          scheme: scheme,
          host: host,
          category: "IP-like host"
        )

      true ->
        resolve_and_check(decoded, host, scheme, allow, opts)
    end
  end

  # Charset allow-list for the DNS branch: LDH plus underscore and dot. It
  # strictly subsumes the WHATWG forbidden-host-code-point set (decoded /, @,
  # ?, #, :, \, ...) and also rejects sub-delims never legitimate in DNS. IPv6
  # literals — the only hosts that carry a colon — classified as literals
  # above.
  defp dns_hostname?(decoded) do
    decoded
    |> String.to_charlist()
    |> Enum.all?(&hostname_char?/1)
  end

  defp hostname_char?(ch) when ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9, do: true
  defp hostname_char?(ch), do: ch in ~c"._-"

  # WHATWG "ends in a number": a host whose final label is all ASCII digits
  # (decimal or 0-prefixed octal) or 0x/0X-prefixed hex (bare "0x" counts — it
  # parses as the IPv4 number 0) is forced through the browser's IPv4 parser,
  # never DNS. Reaching this check means our own IPv4 parse already failed, so
  # deny rather than resolve a name a browser would treat as an address.
  defp ends_in_number?(decoded) do
    reversed = Enum.reverse(String.split(decoded, "."))

    case drop_trailing_empty_label(reversed) do
      [] -> false
      [last | _] = remaining -> "" not in remaining and number_label?(last)
    end
  end

  # On the reversed parts list, one leading "" is the host's trailing dot.
  defp drop_trailing_empty_label(["" | rest]), do: rest
  defp drop_trailing_empty_label(parts), do: parts

  defp number_label?(<<prefix::binary-size(2), rest::binary>>) when prefix in ["0x", "0X"] do
    rest == "" or all_chars?(rest, &hex_digit?/1)
  end

  defp number_label?(label), do: label != "" and all_chars?(label, &decimal_digit?/1)

  defp all_chars?(binary, predicate) do
    Enum.all?(String.to_charlist(binary), predicate)
  end

  defp decimal_digit?(ch), do: ch in ?0..?9

  defp hex_digit?(ch), do: ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F

  defp resolve_and_check(decoded, host, scheme, allow, opts) do
    resolver = Keyword.get(opts, :resolver, &:inet.getaddrs/2)
    # The decoded name — FQDN trailing dot included — is what a browser would
    # resolve; denials still report the original parsed host.
    chost = String.to_charlist(decoded)

    with {:ok, v4} <- resolve_family(resolver, chost, :inet, host, scheme),
         {:ok, v6} <- resolve_family(resolver, chost, :inet6, host, scheme) do
      check_resolved(v4 ++ v6, host, scheme, allow)
    end
  end

  defp resolve_family(resolver, chost, family, host, scheme) do
    case resolver.(chost, family) do
      {:ok, addrs} when is_list(addrs) ->
        {:ok, addrs}

      # No record in this family is a benign empty contribution. Any other
      # failure (timeout, servfail, garbage) means we don't know where the
      # host goes — deny, even if the other family resolved to public space.
      {:error, :nxdomain} ->
        {:ok, []}

      error ->
        deny(
          "DNS resolution failed for host #{inspect(host)} (#{inspect(error)}); " <>
            "refusing an unverifiable destination",
          scheme: scheme,
          host: host,
          category: "resolution failure"
        )
    end
  end

  defp check_resolved([], host, scheme, _allow) do
    deny("could not resolve host #{inspect(host)}",
      scheme: scheme,
      host: host,
      category: "unresolvable host"
    )
  end

  defp check_resolved(addrs, host, scheme, allow) do
    check_addresses(addrs, host, scheme, allow)
  end

  defp check_addresses(addrs, host, scheme, allow) do
    case Enum.find_value(addrs, &denial_for(&1, allow)) do
      nil ->
        :ok

      {ip, category} ->
        deny(range_message(host, ip, category),
          scheme: scheme,
          host: host,
          category: category
        )
    end
  end

  defp denial_for(addr, allow) do
    ip = unwrap_mapped(addr)

    if allowed?(ip, allow) do
      nil
    else
      case denied_category(ip) do
        nil -> nil
        category -> {ip, category}
      end
    end
  end

  # IPv4-mapped IPv6 unwraps FIRST, so the embedded address feeds both the
  # allow check and the deny classification.
  defp unwrap_mapped({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    {bsr(hi, 8), band(hi, 0xFF), bsr(lo, 8), band(lo, 0xFF)}
  end

  defp unwrap_mapped(ip), do: ip

  defp denied_category({_, _, _, _} = ip) do
    Enum.find_value(@v4_deny, fn {net, prefix, category} ->
      if in_cidr?(ip, net, prefix), do: category
    end)
  end

  defp denied_category({_, _, _, _, _, _, _, _} = ip) do
    Enum.find_value(@v6_deny, fn {net, prefix, category} ->
      if in_cidr?(ip, net, prefix), do: category
    end)
  end

  # A resolver handing back something that is not an IP tuple is a blocked
  # destination — fail closed rather than crash or allow.
  defp denied_category(_other), do: "unrecognized address form"

  defp allowed?(ip, allow) do
    Enum.any?(allow, fn {net, prefix} -> in_cidr?(ip, net, prefix) end)
  end

  defp in_cidr?({_, _, _, _} = ip, {_, _, _, _} = net, prefix) do
    masked_equal?(v4_int(ip), v4_int(net), prefix, 32)
  end

  defp in_cidr?({_, _, _, _, _, _, _, _} = ip, {_, _, _, _, _, _, _, _} = net, prefix) do
    masked_equal?(v6_int(ip), v6_int(net), prefix, 128)
  end

  # Family mismatch — e.g. an IPv4 address against a "::1/128" allow entry.
  defp in_cidr?(_ip, _net, _prefix), do: false

  defp masked_equal?(_ip, _net, 0, _width), do: true

  defp masked_equal?(ip, net, prefix, width) do
    shift = width - prefix
    bsr(ip, shift) == bsr(net, shift)
  end

  @spec v4_int(:inet.ip4_address()) :: non_neg_integer()
  defp v4_int({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

  @spec v6_int(:inet.ip6_address()) :: non_neg_integer()
  defp v6_int(words) do
    words
    |> Tuple.to_list()
    |> Enum.reduce(0, fn word, acc -> bsl(acc, 16) + word end)
  end

  defp parse_allow_cidrs(entries) when is_list(entries) do
    Enum.flat_map(entries, fn entry ->
      case parse_cidr(entry) do
        {:ok, net, prefix} ->
          [{net, prefix}]

        :error ->
          Logger.warning(
            "destination policy: ignoring invalid allowed_cidrs entry #{inspect(entry)}"
          )

          []
      end
    end)
  end

  defp parse_allow_cidrs(other) do
    Logger.warning("destination policy: allowed_cidrs must be a list, got #{inspect(other)}")
    []
  end

  defp parse_cidr(entry) when is_binary(entry) do
    with [addr, prefix_str] <- String.split(entry, "/"),
         {:ok, net} <- :inet.parse_address(String.to_charlist(addr)),
         {prefix, ""} <- Integer.parse(prefix_str),
         true <- prefix in 0..bit_width(net) do
      {:ok, net, prefix}
    else
      _ -> :error
    end
  end

  defp parse_cidr(_other), do: :error

  defp bit_width({_, _, _, _}), do: 32
  defp bit_width(_net), do: 128

  defp range_message(host, ip, category) do
    formatted = format_ip(ip)

    target =
      if formatted == host do
        "host #{inspect(host)}"
      else
        "host #{inspect(host)} (resolves to #{formatted})"
      end

    "#{target} is in a blocked address range (#{category}). #{@allow_hint}"
  end

  defp format_ip(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> inspect(ip)
      chars -> List.to_string(chars)
    end
  end

  # The log line carries scheme/host/category only — never the full URL,
  # whose userinfo/query may hold tokens.
  @spec deny(String.t(), keyword()) :: {:error, String.t()}
  defp deny(message, fields) do
    detail = Enum.map_join(fields, " ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
    Logger.warning("destination policy denied egress: #{detail}")
    {:error, "destination denied: #{message}"}
  end

  defp enabled?(opts), do: opt_or_config(opts, :enabled?)

  defp allowed_cidrs(opts), do: opt_or_config(opts, :allowed_cidrs)

  defp opt_or_config(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        :jido_claw
        |> Application.get_env(:destination_policy, [])
        |> Keyword.get(key, @config_defaults[key])
    end
  end
end
