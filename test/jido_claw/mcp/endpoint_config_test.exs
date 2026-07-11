defmodule JidoClaw.MCP.EndpointConfigTest do
  @moduledoc """
  `parse/1`'s `{specs, warnings}` batch contract: valid entries per transport
  yield `%ServerSpec{}`s (with default `client_info`), malformed ones become
  warnings while good siblings survive, and the stdio `command`/`args`/`env`
  shapes translate as documented.
  """
  # async: false — the endpoint-id registry is a GLOBAL :persistent_term
  # (endpoint_config.ex @endpoint_registry_key) that parse/1 mutates on
  # every call; tests snapshot/wipe/restore it and assert stable id
  # assignment across parses, impossible with concurrent parsers.
  use ExUnit.Case, async: false

  alias JidoClaw.MCP.EndpointConfig
  alias JidoClaw.MCP.ServerSpec

  setup do
    snapshot = EndpointConfig.snapshot_endpoint_registry()
    :ok = EndpointConfig.restore_endpoint_registry(%{})
    on_exit(fn -> EndpointConfig.restore_endpoint_registry(snapshot) end)
    :ok
  end

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

  test "duplicate server names reject every conflicting declaration" do
    {specs, warnings} =
      EndpointConfig.parse([
        %{"name" => "dup", "transport" => "stdio", "command" => "first"},
        %{
          "name" => "unique",
          "transport" => "streamable_http",
          "url" => "http://localhost/mcp"
        },
        %{"name" => "dup", "transport" => "stdio", "command" => "second"}
      ])

    assert Enum.map(specs, & &1.name) == ["unique"]
    assert [warning] = warnings
    assert warning =~ ~s(duplicate server name "dup")
  end

  test "endpoint ids come from a fixed pool and excess config is rejected" do
    raw =
      for index <- 1..1_000 do
        %{"name" => "server_#{index}", "transport" => "stdio", "command" => "x"}
      end

    {specs, warnings} = EndpointConfig.parse(raw)

    assert Enum.count(specs) == 64
    assert Enum.count(Enum.uniq_by(specs, & &1.endpoint.id)) == 64
    assert Enum.any?(warnings, &(&1 =~ "beyond the hard 64-server limit"))
  end

  test "random server-name binaries never become endpoint atoms" do
    name = "atom_probe_#{System.unique_integer([:positive, :monotonic])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    {[spec], []} =
      EndpointConfig.parse([%{"name" => name, "transport" => "stdio", "command" => "x"}])

    assert String.starts_with?(Atom.to_string(spec.endpoint.id), "jido_claw_mcp_endpoint_")
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "name-to-endpoint ids survive reorder plus valid and invalid insertion" do
    alpha = %{"name" => "alpha", "transport" => "stdio", "command" => "alpha"}
    beta = %{"name" => "beta", "transport" => "stdio", "command" => "beta"}
    gamma = %{"name" => "gamma", "transport" => "stdio", "command" => "gamma"}
    invalid = %{"name" => "invalid", "transport" => "stdio"}

    {first, []} = EndpointConfig.parse([alpha, beta])
    first_ids = Map.new(first, &{&1.name, &1.endpoint.id})

    {reordered, []} = EndpointConfig.parse([beta, alpha])
    reordered_ids = Map.new(reordered, &{&1.name, &1.endpoint.id})

    {with_new, []} = EndpointConfig.parse([gamma, beta, alpha])
    inserted_new_ids = Map.new(with_new, &{&1.name, &1.endpoint.id})

    {with_invalid, [warning]} = EndpointConfig.parse([invalid, beta, alpha])
    inserted_ids = Map.new(with_invalid, &{&1.name, &1.endpoint.id})

    assert reordered_ids == first_ids
    assert Map.take(inserted_new_ids, ["alpha", "beta"]) == first_ids
    assert inserted_new_ids["gamma"] not in Map.values(first_ids)
    assert inserted_ids == first_ids
    assert warning =~ "invalid"
    refute Map.has_key?(EndpointConfig.snapshot_endpoint_registry(), "invalid")
  end

  test "concurrent parses converge on one stable id per name" do
    alpha = %{"name" => "alpha", "transport" => "stdio", "command" => "alpha"}
    beta = %{"name" => "beta", "transport" => "stdio", "command" => "beta"}

    id_maps =
      1..20
      |> Task.async_stream(
        fn index ->
          config = if rem(index, 2) == 0, do: [alpha, beta], else: [beta, alpha]
          {specs, []} = EndpointConfig.parse(config)
          Map.new(specs, &{&1.name, &1.endpoint.id})
        end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, ids} -> ids end)

    alpha_ids =
      id_maps
      |> Enum.map(& &1["alpha"])
      |> Enum.uniq()

    beta_ids =
      id_maps
      |> Enum.map(& &1["beta"])
      |> Enum.uniq()

    assert [_alpha_id] = alpha_ids
    assert [_beta_id] = beta_ids
    refute hd(id_maps)["alpha"] == hd(id_maps)["beta"]
  end

  test "a duplicate beyond the raw entry cap rejects the admitted declaration too" do
    duplicate = %{"name" => "dup", "transport" => "stdio", "command" => "x"}

    middle =
      for index <- 1..63 do
        %{"name" => "unique_#{index}", "transport" => "stdio", "command" => "x"}
      end

    {specs, warnings} = EndpointConfig.parse([duplicate | middle] ++ [duplicate])

    refute Enum.any?(specs, &(&1.name == "dup"))
    assert Enum.count(specs) == 63
    assert Enum.any?(warnings, &(&1 =~ ~s(duplicate server name "dup")))
    assert Enum.any?(warnings, &(&1 =~ "beyond the hard 64-server limit"))
  end

  test "same-name transport changes require restart while policy/reach changes stay live" do
    original = %{
      "name" => "stable",
      "transport" => "streamable_http",
      "url" => "http://one.test/mcp"
    }

    {[first], []} = EndpointConfig.parse([original])

    {[], [warning]} =
      EndpointConfig.parse([
        Map.merge(original, %{"url" => "http://two.test/mcp", "require_approval" => false})
      ])

    assert warning =~ "endpoint_transport_changed"
    assert warning =~ "restart_required"

    {[updated_policy], []} =
      EndpointConfig.parse([
        Map.merge(original, %{"require_approval" => false, "templates" => ["coder"]})
      ])

    assert updated_policy.endpoint.id == first.endpoint.id
    assert updated_policy.require_approval == false
    assert updated_policy.templates == ["coder"]
  end

  test "non-list input is inert" do
    assert EndpointConfig.parse(nil) == {[], []}
    assert EndpointConfig.parse("nope") == {[], []}
    assert EndpointConfig.parse([]) == {[], []}
  end

  test "a non-empty templates allowlist is carried onto the ServerSpec" do
    {[spec], []} =
      EndpointConfig.parse([
        %{
          "name" => "fs",
          "transport" => "stdio",
          "command" => "x",
          "templates" => ["main", "coder"]
        }
      ])

    assert spec.templates == ["main", "coder"]
  end

  test "an empty-string templates element is rejected (allowlisted-to-nobody footgun)" do
    {specs, warnings} =
      EndpointConfig.parse([
        %{
          "name" => "empties",
          "transport" => "stdio",
          "command" => "x",
          "templates" => ["coder", ""]
        }
      ])

    assert specs == []
    assert [warning] = warnings
    assert warning =~ "empties"
    assert warning =~ "invalid_templates"
  end
end
