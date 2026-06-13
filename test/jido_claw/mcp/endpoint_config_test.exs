defmodule JidoClaw.MCP.EndpointConfigTest do
  @moduledoc """
  `parse/1`'s `{specs, warnings}` batch contract: valid entries per transport
  yield `%ServerSpec{}`s (with default `client_info`), malformed ones become
  warnings while good siblings survive, and the stdio `command`/`args`/`env`
  shapes translate as documented.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.MCP.EndpointConfig
  alias JidoClaw.MCP.ServerSpec

  test "one valid entry per transport yields a ServerSpec with default client_info" do
    raw = [
      %{"name" => "fs", "transport" => "stdio", "command" => ["npx", "-y", "srv"]},
      %{"name" => "tw", "transport" => "streamable_http", "url" => "http://localhost:4000/mcp"},
      %{"name" => "ev", "transport" => "sse", "url" => "http://localhost:5000/mcp/sse"}
    ]

    {specs, warnings} = EndpointConfig.parse(raw)

    assert warnings == []
    assert Enum.count(specs) == 3
    assert Enum.all?(specs, &match?(%ServerSpec{}, &1))
    assert Enum.all?(specs, fn spec -> spec.endpoint.client_info["name"] == "jido_claw" end)
  end

  test "the stdio command list splits into a string command + args list" do
    {[spec], []} =
      EndpointConfig.parse([
        %{"name" => "fs", "transport" => "stdio", "command" => ["npx", "-y", "srv", "/dir"]}
      ])

    {:stdio, opts} = spec.endpoint.transport
    assert opts[:command] == "npx"
    assert opts[:args] == ["-y", "srv", "/dir"]
  end

  test "the stdio string-command + args form is accepted" do
    {[spec], []} =
      EndpointConfig.parse([
        %{"name" => "fs", "transport" => "stdio", "command" => "npx", "args" => ["-y", "srv"]}
      ])

    {:stdio, opts} = spec.endpoint.transport
    assert opts[:command] == "npx"
    assert opts[:args] == ["-y", "srv"]
  end

  test "stdio env defaults to %{} and carries operator overrides" do
    {[default_spec], []} =
      EndpointConfig.parse([%{"name" => "a", "transport" => "stdio", "command" => "x"}])

    {:stdio, default_opts} = default_spec.endpoint.transport
    assert default_opts[:env] == %{}

    {[override_spec], []} =
      EndpointConfig.parse([
        %{"name" => "b", "transport" => "stdio", "command" => "x", "env" => %{"FOO" => "bar"}}
      ])

    {:stdio, override_opts} = override_spec.endpoint.transport
    assert override_opts[:env] == %{"FOO" => "bar"}
  end

  test "require_approval is carried; absent defaults to nil" do
    {[trusted], []} =
      EndpointConfig.parse([
        %{
          "name" => "t",
          "transport" => "streamable_http",
          "url" => "http://h/mcp",
          "require_approval" => false
        }
      ])

    assert trusted.require_approval == false

    {[default], []} =
      EndpointConfig.parse([
        %{"name" => "d", "transport" => "streamable_http", "url" => "http://h/mcp"}
      ])

    assert default.require_approval == nil
  end

  test "atom-keyed entries are accepted (app-config path)" do
    {[spec], []} =
      EndpointConfig.parse([%{name: "ak", transport: :stdio, command: "x", args: ["a"]}])

    assert spec.name == "ak"
    {:stdio, opts} = spec.endpoint.transport
    assert opts[:args] == ["a"]
  end

  test "malformed entries become warnings while good siblings survive" do
    raw = [
      # invalid name (space)
      %{"name" => "Bad Name", "transport" => "stdio", "command" => "x"},
      # good
      %{"name" => "ok", "transport" => "stdio", "command" => "x"},
      # invalid transport
      %{"name" => "badt", "transport" => "ftp", "command" => "x"},
      # missing url
      %{"name" => "nourl", "transport" => "streamable_http"},
      # missing command
      %{"name" => "nocmd", "transport" => "stdio"},
      # invalid templates
      %{"name" => "badtmpl", "transport" => "stdio", "command" => "x", "templates" => [1, 2]}
    ]

    {specs, warnings} = EndpointConfig.parse(raw)

    assert [spec] = specs
    assert spec.name == "ok"
    assert Enum.count(warnings) == 5
  end

  test "non-list input is inert" do
    assert EndpointConfig.parse(nil) == {[], []}
    assert EndpointConfig.parse("nope") == {[], []}
    assert EndpointConfig.parse([]) == {[], []}
  end
end
