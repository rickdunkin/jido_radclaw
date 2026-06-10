defmodule JidoClaw.Web.GatewayExposureTest do
  @moduledoc """
  Coverage for `JidoClaw.Web.GatewayExposure` — `parse_hosts/1` edge cases
  and the `configure/1` endpoint-env merge.

  `async: false`: `configure/1` mutates the global endpoint Application env
  (captured and restored around every test).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Web.GatewayExposure

  @endpoint_key JidoClaw.Web.Endpoint

  describe "parse_hosts/1" do
    test "nil and blank input yield no hosts" do
      assert GatewayExposure.parse_hosts(nil) == []
      assert GatewayExposure.parse_hosts("") == []
      assert GatewayExposure.parse_hosts("  ,  ") == []
    end

    test "a plain host parses with no port" do
      assert GatewayExposure.parse_hosts("box.ts.net") == [{"box.ts.net", nil}]
    end

    test "an explicit port is captured" do
      assert GatewayExposure.parse_hosts("box.ts.net:8443") == [{"box.ts.net", 8443}]
    end

    test "comma lists with whitespace parse in order" do
      assert GatewayExposure.parse_hosts(" a.ts.net , b.ts.net:443 ") ==
               [{"a.ts.net", nil}, {"b.ts.net", 443}]
    end

    test "scheme and path are discarded; scheme-implied ports are not captured" do
      assert GatewayExposure.parse_hosts("https://box.ts.net/path") == [{"box.ts.net", nil}]
      assert GatewayExposure.parse_hosts("https://box.ts.net:443/path") == [{"box.ts.net", 443}]
    end

    test "bracketed IPv6 is kept; unbracketed IPv6 is dropped" do
      assert GatewayExposure.parse_hosts("[fd7a::1]") == [{"fd7a::1", nil}]
      assert GatewayExposure.parse_hosts("[fd7a::1]:8443") == [{"fd7a::1", 8443}]
      assert GatewayExposure.parse_hosts("fd7a::1") == []
    end

    test "unparseable entries are dropped, valid ones kept" do
      assert GatewayExposure.parse_hosts("ho st, box.ts.net, other:junkport") ==
               [{"box.ts.net", nil}]
    end
  end

  describe "configure/1" do
    # The app has already loaded .env and run GatewayExposure.configure!/0
    # (application.ex) by the time tests run, so the live endpoint env may
    # already be exposed (e.g. a dev PHX_HOST). Pin the keys configure/1
    # touches to the config.exs baseline; restore the live config afterwards.
    setup do
      live = Application.get_env(:jido_claw, @endpoint_key, [])

      baseline =
        live
        |> Keyword.update(
          :http,
          [ip: {127, 0, 0, 1}, port: 4000],
          &Keyword.merge(&1, ip: {127, 0, 0, 1}, port: 4000)
        )
        |> Keyword.update(:url, [host: "localhost"], &Keyword.put(&1, :host, "localhost"))
        |> Keyword.put(:check_origin, ["//localhost:4000", "//127.0.0.1:4000", "//[::1]:4000"])

      Application.put_env(:jido_claw, @endpoint_key, baseline)
      on_exit(fn -> Application.put_env(:jido_claw, @endpoint_key, live) end)
      %{original: baseline}
    end

    test "nil is a no-op: loopback bind and base origins stay intact", %{original: original} do
      assert :ok = GatewayExposure.configure(nil)

      config = Application.get_env(:jido_claw, @endpoint_key, [])
      assert config == original
      assert config[:http][:ip] == {127, 0, 0, 1}
    end

    test "blank input is a no-op", %{original: original} do
      assert :ok = GatewayExposure.configure("   ")
      assert Application.get_env(:jido_claw, @endpoint_key, []) == original
    end

    test "junk-only input warns and stays loopback", %{original: original} do
      log =
        capture_log(fn ->
          assert :ok = GatewayExposure.configure("http://garbage path/,")
        end)

      assert log =~ "no valid hosts"
      assert Application.get_env(:jido_claw, @endpoint_key, []) == original
    end

    test "valid hosts extend origins, rebind 0.0.0.0, and set url host", %{original: original} do
      base_origins = Keyword.fetch!(original, :check_origin)

      assert :ok = GatewayExposure.configure("box.ts.net,100.64.0.7:8443")

      config = Application.get_env(:jido_claw, @endpoint_key, [])

      # Host origins pinned to the gateway port unless an explicit port was
      # written; base (loopback) origins preserved.
      assert config[:check_origin] ==
               ["//box.ts.net:4000", "//100.64.0.7:8443"] ++ base_origins

      assert config[:http][:ip] == {0, 0, 0, 0}
      assert config[:http][:port] == original[:http][:port]
      assert config[:url][:host] == "box.ts.net"
    end

    test "explicit host ports never propagate to url", %{original: original} do
      assert :ok = GatewayExposure.configure("box.ts.net:8443")

      config = Application.get_env(:jido_claw, @endpoint_key, [])
      assert config[:url][:host] == "box.ts.net"
      assert config[:url][:port] == original[:url][:port]
    end

    test "IPv6 hosts are re-bracketed in origins" do
      assert :ok = GatewayExposure.configure("[fd7a::1]")

      config = Application.get_env(:jido_claw, @endpoint_key, [])
      assert "//[fd7a::1]:4000" in config[:check_origin]
    end
  end
end
