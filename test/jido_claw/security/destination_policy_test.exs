defmodule JidoClaw.Security.DestinationPolicyTest do
  # All knobs are injected via check/2 opts — no Application env mutation.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias JidoClaw.Security.DestinationPolicy

  @public_v4 {93, 184, 216, 34}
  @public_v6 {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

  defp public_resolver(_host, _family), do: {:ok, [@public_v4]}

  # For affirmative-classification tests: any DNS attempt is a loud failure.
  defp no_dns_resolver(_host, _family), do: raise("resolver must not be called")

  describe "structural and parser checks" do
    test "allows http and https URLs whose host resolves public" do
      assert :ok = DestinationPolicy.check("https://example.com", resolver: &public_resolver/2)
      assert :ok = DestinationPolicy.check("http://example.com", resolver: &public_resolver/2)
    end

    test "denies non-http(s) schemes" do
      assert {:error, msg} = DestinationPolicy.check("file:///etc/passwd")
      assert msg =~ "scheme"

      assert {:error, msg} = DestinationPolicy.check("ftp://example.com/file")
      assert msg =~ "scheme"
    end

    test "denies a URL with an empty host" do
      assert {:error, msg} = DestinationPolicy.check("http://")
      assert msg =~ "no host"
    end

    test "denies unparseable garbage" do
      assert {:error, _msg} = DestinationPolicy.check("not a url at all")
    end

    test "denies the backslash parser differential before any resolution" do
      # WHATWG browsers navigate this to 127.0.0.1 while lenient parsers see
      # example.com as the host. A public resolver would have allowed the
      # parsed host, so the denial proves the backslash check fired first.
      assert {:error, msg} =
               DestinationPolicy.check("http://127.0.0.1\\@example.com/",
                 resolver: &public_resolver/2
               )

      assert msg =~ "backslash"
    end

    test "fails closed on URI.new rejections: bad port, malformed IPv6, double-@" do
      for url <- ["http://example.com:notaport/", "http://[::1/", "http://a@b@c/"] do
        assert {:error, msg} = DestinationPolicy.check(url, resolver: &public_resolver/2)
        assert msg =~ "could not be parsed"
      end
    end

    test "enabled?: false is a kill switch that skips all checks" do
      assert :ok = DestinationPolicy.check("http://127.0.0.1/", enabled?: false)
      assert :ok = DestinationPolicy.check("file:///etc/passwd", enabled?: false)
    end
  end

  describe "IPv4 literals" do
    test "denies one address per built-in range, with the allowed_cidrs hint" do
      for url <- [
            "http://127.0.0.1/",
            "http://127.255.255.254/",
            "http://10.0.0.5/",
            "http://172.16.0.1/",
            "http://192.168.1.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://100.64.0.1/",
            "http://0.0.0.0/"
          ] do
        assert {:error, msg} = DestinationPolicy.check(url)
        assert msg =~ "blocked address range", "expected range denial for #{url}: #{msg}"
        assert msg =~ "allowed_cidrs"
      end
    end

    test "mask edges: inside 172.16.0.0/12 and 100.64.0.0/10 deny, just outside allow" do
      assert {:error, _} = DestinationPolicy.check("http://172.31.255.255/")
      assert :ok = DestinationPolicy.check("http://172.32.0.1/")

      assert {:error, _} = DestinationPolicy.check("http://100.127.255.255/")
      assert :ok = DestinationPolicy.check("http://100.128.0.1/")
    end

    test "exotic literal forms are affirmatively classified as loopback" do
      # decimal, hex, octal, and short forms all normalize to 127.0.0.1
      for url <- [
            "http://2130706433/",
            "http://0x7f.0.0.1/",
            "http://017700000001/",
            "http://127.1/"
          ] do
        assert {:error, msg} = DestinationPolicy.check(url)
        assert msg =~ "loopback", "expected loopback denial for #{url}: #{msg}"
      end
    end

    test "allows a public IPv4 literal" do
      assert :ok = DestinationPolicy.check("http://8.8.8.8/")
    end
  end

  describe "IPv6 literals" do
    test "denies loopback, link-local, ULA, unspecified, and IPv4-mapped forms" do
      for url <- [
            "http://[::1]/",
            "http://[fe80::1]/",
            "http://[fc00::1]/",
            "http://[::]/",
            "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:10.0.0.1]/"
          ] do
        assert {:error, msg} = DestinationPolicy.check(url)
        assert msg =~ "blocked address range", "expected range denial for #{url}: #{msg}"
      end
    end

    test "allows a public IPv6 literal" do
      assert :ok = DestinationPolicy.check("http://[2606:4700:4700::1111]/")
    end
  end

  describe "allowed_cidrs" do
    test "punches a hole in the deny set (allow beats deny)" do
      assert :ok = DestinationPolicy.check("http://127.0.0.1/", allowed_cidrs: ["127.0.0.0/8"])
      assert :ok = DestinationPolicy.check("http://[::1]/", allowed_cidrs: ["::1/128"])
    end

    test "applies the prefix mask exactly" do
      opts = [allowed_cidrs: ["10.1.2.0/24"]]

      assert :ok = DestinationPolicy.check("http://10.1.2.5/", opts)
      assert {:error, _} = DestinationPolicy.check("http://10.1.3.5/", opts)
    end

    test "an IPv4 allow entry also permits the IPv4-mapped IPv6 form" do
      assert :ok =
               DestinationPolicy.check("http://[::ffff:127.0.0.1]/",
                 allowed_cidrs: ["127.0.0.0/8"]
               )
    end

    test "invalid entries are logged and ignored while valid entries still work" do
      log =
        capture_log(fn ->
          assert :ok =
                   DestinationPolicy.check("http://127.0.0.1/",
                     allowed_cidrs: ["not-a-cidr", "10.0.0.0/99", "127.0.0.0/8"]
                   )
        end)

      assert log =~ "ignoring invalid allowed_cidrs entry"
      assert log =~ "not-a-cidr"
      assert log =~ "10.0.0.0/99"
    end
  end

  describe "hostname resolution" do
    test "denies a host that resolves to a private address, naming host and address" do
      resolver = fn
        _host, :inet -> {:ok, [{10, 0, 0, 5}]}
        _host, :inet6 -> {:error, :nxdomain}
      end

      assert {:error, msg} =
               DestinationPolicy.check("http://internal.example/", resolver: resolver)

      assert msg =~ "internal.example"
      assert msg =~ "10.0.0.5"
      assert msg =~ "allowed_cidrs"
    end

    test "allows public v4 when v6 is nxdomain (benign empty family)" do
      resolver = fn
        _host, :inet -> {:ok, [@public_v4]}
        _host, :inet6 -> {:error, :nxdomain}
      end

      assert :ok = DestinationPolicy.check("http://example.com/", resolver: resolver)
    end

    test "denies when ANY resolved address is private, even alongside public ones" do
      resolver = fn
        _host, :inet -> {:ok, [@public_v4]}
        _host, :inet6 -> {:ok, [{0xFC00, 0, 0, 0, 0, 0, 0, 1}]}
      end

      assert {:error, msg} = DestinationPolicy.check("http://example.com/", resolver: resolver)
      assert msg =~ "blocked address range"
    end

    test "fails closed when both families are empty" do
      resolver = fn _host, _family -> {:error, :nxdomain} end

      assert {:error, msg} = DestinationPolicy.check("http://gone.example/", resolver: resolver)
      assert msg =~ "could not resolve"
    end

    test "a resolver timeout on one family fails the whole check closed" do
      resolver = fn
        _host, :inet -> {:ok, [@public_v4]}
        _host, :inet6 -> {:error, :timeout}
      end

      assert {:error, msg} = DestinationPolicy.check("http://slow.example/", resolver: resolver)
      assert msg =~ "DNS resolution failed"
    end

    test "a resolver returning public addresses in both families allows" do
      resolver = fn
        _host, :inet -> {:ok, [@public_v4]}
        _host, :inet6 -> {:ok, [@public_v6]}
      end

      assert :ok = DestinationPolicy.check("http://example.com/", resolver: resolver)
    end

    test "the default resolver denies localhost (hermetic loopback lookup)" do
      assert {:error, msg} = DestinationPolicy.check("http://localhost/")
      assert msg =~ "destination denied"
    end
  end

  describe "host canonicalization (WHATWG browser parity)" do
    test "trailing-dot and percent-encoded IP literals are affirmatively classified" do
      # Browsers parse all of these as loopback/private literals. Falling to
      # the DNS branch instead would lean on resolver failure — bypassable by
      # NXDOMAIN-hijacking/wildcard resolvers — so the raising resolver proves
      # classification happened without DNS.
      for url <- [
            "http://127.0.0.1./",
            "http://10.0.0.1./",
            "http://0x7f.0.0.1./",
            "http://%31%32%37.0.0.1/",
            "http://127.0.0.1%2e/",
            "http://0177.0.0.1/"
          ] do
        assert {:error, msg} = DestinationPolicy.check(url, resolver: &no_dns_resolver/2)
        assert msg =~ "blocked address range", "expected range denial for #{url}: #{msg}"
      end
    end

    test "hosts ending in a number that do not parse as an IP fail closed without DNS" do
      # A browser forces these through IPv4 parsing (0x7f.0x0.0x0.0x1 IS
      # loopback there; example.123 and example.0x are refused as failed
      # IPv4) — never resolved as DNS names, so neither are they here.
      for url <- [
            "http://0x7f.0x0.0x0.0x1/",
            "http://example.123/",
            "http://example.0x/"
          ] do
        assert {:error, msg} = DestinationPolicy.check(url, resolver: &no_dns_resolver/2)
        assert msg =~ "refusing to resolve", "expected IP-like denial for #{url}: #{msg}"
      end
    end

    test "decoded WHATWG-forbidden host bytes fail closed without DNS" do
      # Hosts decoding to /, @, ?, #, :, \ — forbidden host code points a
      # browser refuses outright; the gate must not lean on resolver
      # rejection for them.
      for url <- [
            "http://a%2Fb/",
            "http://a%40b/",
            "http://a%3Fb/",
            "http://a%23b/",
            "http://a%3Ab/",
            "http://a%5Cb/"
          ] do
        assert {:error, msg} = DestinationPolicy.check(url, resolver: &no_dns_resolver/2)
        assert msg =~ "not allowed in a hostname", "expected charset denial for #{url}: #{msg}"
      end
    end

    test "double-encoded and malformed percent forms fail closed without crashing" do
      # %2531... decodes to a still-encoded literal (double encoding), %zz
      # passes through URI.decode unchanged, and %ff decodes to invalid
      # UTF-8 — the printable-ASCII guard must deny it, not raise.
      for url <- [
            "http://%2531%2532%2537.0.0.1/",
            "http://%zz/",
            "http://ex%ffample.com/"
          ] do
        assert {:error, msg} = DestinationPolicy.check(url, resolver: &no_dns_resolver/2)
        assert msg =~ "destination denied", "expected denial for #{url}: #{msg}"
      end
    end

    test "percent-encoded hostnames resolve by their decoded name" do
      test_pid = self()

      resolver = fn chost, _family ->
        send(test_pid, {:resolved, chost})
        {:ok, [{10, 0, 0, 5}]}
      end

      assert {:error, msg} =
               DestinationPolicy.check("http://%6c%6f%63%61%6c%68%6f%73%74/",
                 resolver: resolver
               )

      assert_received {:resolved, ~c"localhost"}
      assert msg =~ "blocked address range"
    end

    test "a domain trailing dot is preserved through resolution (FQDN form)" do
      # WHATWG keeps trailing dots on domain hosts; only IPv4-literal
      # candidacy drops one. The resolver must see the FQDN dot intact.
      test_pid = self()

      resolver = fn chost, _family ->
        send(test_pid, {:resolved, chost})
        {:ok, [@public_v4]}
      end

      assert :ok = DestinationPolicy.check("http://example.com./", resolver: resolver)
      assert_received {:resolved, ~c"example.com."}
    end

    test "allowed_cidrs punches through on the canonicalized literal" do
      opts = [allowed_cidrs: ["127.0.0.0/8"], resolver: &no_dns_resolver/2]

      assert :ok = DestinationPolicy.check("http://127.0.0.1./", opts)
      assert :ok = DestinationPolicy.check("http://%31%32%37.0.0.1/", opts)
    end
  end

  describe "denial logging" do
    test "logs host and category but never path, query, or userinfo" do
      url = "http://user:hunter2pass@10.0.0.5/secret-path-marker?token=tok123marker"

      log =
        capture_log(fn ->
          assert {:error, _} = DestinationPolicy.check(url)
        end)

      assert log =~ "destination policy denied egress"
      assert log =~ "10.0.0.5"
      assert log =~ "private network"
      refute log =~ "hunter2pass"
      refute log =~ "secret-path-marker"
      refute log =~ "tok123marker"
    end
  end
end
