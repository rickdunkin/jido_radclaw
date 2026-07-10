defmodule JidoClaw.MCP.ProxyGeneratorTest do
  @moduledoc """
  Proves a runtime-compiled proxy routes through the full `JidoClaw.Tools.Action`
  pipeline — the static wrapper-coverage sweep can't reach runtime modules
  (`feedback_permanent_test_over_spot_check`). Covers the three coverage
  markers, outbound arg scrub, inbound redact+cap, collision-proof `mcp_`-rooted
  names, description sanitization, JSON-Schema pass-through, regeneration, cap.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.AI.ToolAdapter
  alias JidoClaw.MCP.ProxyGenerator

  setup do
    prior = Application.get_env(:jido_claw, :mcp_stub)
    on_exit(fn -> restore(:mcp_stub, prior) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)

  defp stub(map), do: Application.put_env(:jido_claw, :mcp_stub, map)

  defp tool(name, extra \\ %{}), do: Map.merge(%{"name" => name}, extra)

  defp build_one(tool), do: hd(build_many([tool]))

  defp build_many(tools), do: ProxyGenerator.build_modules("svc", :svc, tools)

  describe "wrapper coverage (markers)" do
    test "generated modules export all three __jidoclaw_tool_*__ markers" do
      module = build_one(tool("ping"))

      assert module.__jidoclaw_tool_output_redacted__()
      assert module.__jidoclaw_tool_mcp_scoped__()
      assert module.__jidoclaw_tool_approval_gated__()
    end
  end

  describe "outbound arg scrub" do
    test "the proxy redacts secret-shaped args before the remote call" do
      test_pid = self()

      stub(%{
        call_tool: fn _id, name, args ->
          send(test_pid, {:stub_call, name, args})
          {:ok, %{"ok" => true}}
        end
      })

      module = build_one(tool("echo"))

      assert {:ok, _result} = module.run(%{"token" => "ghp_supersecret", "q" => "hi"}, %{})

      assert_received {:stub_call, "echo", args}
      assert args == %{"token" => "[REDACTED]", "q" => "hi"}
    end
  end

  describe "inbound redact + cap (inherited from the wrapper)" do
    test "a secret + oversized result is redacted and prefix-capped" do
      stub(%{
        call_tool: fn _id, _name, _args ->
          {:ok, %{"api_key" => "sk-leak-me", "big" => String.duplicate("x", 40_000)}}
        end
      })

      module = build_one(tool("dump"))

      assert {:ok, data} = module.run(%{}, %{})
      assert data["api_key"] == "[REDACTED]"
      assert String.contains?(data["big"], "tool output truncated")
      assert byte_size(data["big"]) <= 32 * 1024
    end
  end

  describe "collision-proof, mcp_-rooted names" do
    test "remotes that sanitize alike get distinct names and both register" do
      [m1, m2] = build_many([tool("get-user"), tool("get_user")])

      assert m1.name() != m2.name()
      assert String.starts_with?(m1.name(), "mcp_")
      assert String.starts_with?(m2.name(), "mcp_")

      # ToolAdapter raises on duplicate tool names — assert it does not here.
      tools = ToolAdapter.from_actions([m1, m2])
      assert Enum.count(tools) == 2
    end

    test "a remote cannot preoccupy another tool's first collision suffix" do
      suffix =
        "foo~"
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)

      modules = build_many([tool("foo"), tool("foo_#{suffix}"), tool("foo~")])
      names = Enum.map(modules, & &1.name())

      assert Enum.count(names) == 3
      assert Enum.count(Enum.uniq(names)) == 3
      assert "mcp_svc_foo" in names
      assert "mcp_svc_foo_#{suffix}" in names

      # ToolAdapter is the provider-facing duplicate-name failure boundary.
      assert Enum.count(ToolAdapter.from_actions(modules)) == 3
    end

    test "long server names with the same capped prefix keep distinct tool namespaces" do
      shared = "server_" <> String.duplicate("x", 80)
      server_a = shared <> "a"
      server_b = shared <> "b"

      [module_a] = ProxyGenerator.build_modules(server_a, :long_server_a, [tool("ping")])
      [module_b] = ProxyGenerator.build_modules(server_b, :long_server_b, [tool("ping")])

      refute module_a.name() == module_b.name()
      assert byte_size(module_a.name()) <= 64
      assert byte_size(module_b.name()) <= 64
      assert String.starts_with?(module_a.name(), "mcp_")
      assert String.starts_with?(module_b.name(), "mcp_")
    end

    test "aggregate boundary names survive cold-boot config and endpoint-slot reorder" do
      stage_a = ProxyGenerator.stage_modules("a", :cold_slot_one, [tool("b_ping")])
      stage_a_b = ProxyGenerator.stage_modules("a_b", :cold_slot_two, [tool("ping")])
      stage_safe = ProxyGenerator.stage_modules("safe", :cold_slot_three, [tool("ping")])

      # Simulate a fresh endpoint registry assigning the same two servers the
      # opposite bounded atoms because their configuration order changed.
      cold_a_b = ProxyGenerator.stage_modules("a_b", :cold_slot_one, [tool("ping")])
      cold_a = ProxyGenerator.stage_modules("a", :cold_slot_two, [tool("b_ping")])
      cold_safe = ProxyGenerator.stage_modules("safe", :cold_slot_three, [tool("ping")])

      staged_digests =
        Map.new([stage_a, stage_a_b], fn stage ->
          [definition] = stage.definitions
          {stage.server_name, definition.digest}
        end)

      snapshot = fn stages ->
        module_lists = ProxyGenerator.commit_stages(stages)

        stages
        |> Enum.zip(module_lists)
        |> Map.new(fn {stage, [module]} ->
          definition = ProxyGenerator.definition!(module)

          {stage.server_name,
           %{
             module: module,
             endpoint: definition.endpoint_id,
             name: module.name(),
             digest: ProxyGenerator.definition_digest(module)
           }}
        end)
      end

      first = snapshot.([stage_a, stage_a_b, stage_safe])
      cold_reordered = snapshot.([cold_safe, cold_a_b, cold_a])

      provider_names = fn snapshot ->
        Map.new(snapshot, fn {server_name, entry} -> {server_name, entry.name} end)
      end

      assert provider_names.(cold_reordered) == provider_names.(first)
      assert first["safe"].name == "mcp_safe_ping"
      refute first["a"].endpoint == cold_reordered["a"].endpoint
      refute first["a_b"].endpoint == cold_reordered["a_b"].endpoint
      refute first["a"].module == cold_reordered["a"].module
      refute first["a_b"].module == cold_reordered["a_b"].module

      names = [first["a"].name, first["a_b"].name]
      assert Enum.count(Enum.uniq(names)) == 2
      refute "mcp_a_b_ping" in names
      assert Enum.all?(names, &(byte_size(&1) <= 64 and String.starts_with?(&1, "mcp_")))

      # Renaming rebuilds the complete definition, including its digest; the
      # runtime registry never advertises a digest for the ambiguous staged name.
      refute first["a"].digest == staged_digests["a"]
      refute first["a_b"].digest == staged_digests["a_b"]
    end

    test "every generated name is mcp_-rooted" do
      modules = build_many([tool("a"), tool("weird name!!"), tool("UPPER")])
      assert Enum.all?(modules, &String.starts_with?(&1.name(), "mcp_"))
    end

    test "names are capped at the 64-char provider limit" do
      long = String.duplicate("z", 200)
      module = build_one(tool(long))
      assert byte_size(module.name()) <= 64
      assert String.starts_with?(module.name(), "mcp_")
    end
  end

  describe "description sanitization" do
    test "control chars are stripped and length is capped" do
      desc = "hello" <> <<0, 7>> <> "world" <> String.duplicate("a", 5_000)
      module = build_one(tool("d", %{"description" => desc}))

      refute String.contains?(module.description(), <<0>>)
      refute String.contains?(module.description(), <<7>>)
      assert String.starts_with?(module.description(), "helloworld")
      assert String.length(module.description()) <= 2_000
    end

    test "missing description falls back to a generated one" do
      module = build_one(tool("noted"))
      assert module.description() == "MCP proxy tool noted"
    end
  end

  describe "schema (JSON-Schema pass-through)" do
    test "a remote inputSchema with properties is advertised to the model" do
      schema = %{
        "type" => "object",
        "properties" => %{"q" => %{"type" => "string"}},
        "required" => ["q"]
      }

      module = build_one(tool("search", %{"inputSchema" => schema}))

      # Pass-through: the action schema is the remote JSON Schema verbatim.
      assert module.schema() == schema

      # ToolAdapter advertises the real property (NOT an empty no-args object).
      reqllm_tool = ToolAdapter.from_action(module)
      assert is_map(get_in(reqllm_tool.parameter_schema, ["properties", "q"]))
    end

    test "a to_zoi-unsupported keyword (oneOf) stays provider-visible" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "val" => %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
        }
      }

      module = build_one(tool("poly", %{"inputSchema" => schema}))

      assert module.schema() == schema
      reqllm_tool = ToolAdapter.from_action(module)
      assert is_list(get_in(reqllm_tool.parameter_schema, ["properties", "val", "oneOf"]))
    end

    test "absent or non-object inputSchema normalizes to an empty object (no args)" do
      assert build_one(tool("none")).schema() == %{"type" => "object", "properties" => %{}}

      assert build_one(tool("bad", %{"inputSchema" => "garbage"})).schema() ==
               %{"type" => "object", "properties" => %{}}
    end

    test "a dynamic object schema (additionalProperties: true) is warn-logged" do
      schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => true}

      log =
        capture_log(fn ->
          module = build_one(tool("dynamic", %{"inputSchema" => schema}))
          assert module.schema() == schema
        end)

      assert log =~ "dynamic"
    end
  end

  describe "stable runtime definition updates" do
    test "changing a remote tool's schema reuses the module and changes its strong digest" do
      m1 = build_one(tool("rev", %{"inputSchema" => %{"type" => "object", "properties" => %{}}}))
      digest1 = ProxyGenerator.definition_digest(m1)

      m2 =
        build_one(
          tool("rev", %{
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{"x" => %{"type" => "string"}}
            }
          })
        )

      digest2 = ProxyGenerator.definition_digest(m2)
      assert m1 == m2
      assert digest1 != digest2
      assert m2.schema()["properties"]["x"] == %{"type" => "string"}
    end

    test "staging is inert until the accepted aggregate is committed" do
      original =
        build_one(tool("staged", %{"inputSchema" => %{"type" => "object", "properties" => %{}}}))

      original_digest = ProxyGenerator.definition_digest(original)
      identity_count = ProxyGenerator.identity_count()

      staged =
        ProxyGenerator.stage_modules("svc", :svc, [
          tool("staged", %{
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{"fresh" => %{"type" => "boolean"}}
            }
          }),
          tool("not_committed_yet")
        ])

      # Discovery may be abandoned or hard-killed here: neither live metadata
      # nor the bounded identity registry has changed.
      assert ProxyGenerator.definition_digest(original) == original_digest
      assert original.schema()["properties"] == %{}
      assert ProxyGenerator.identity_count() == identity_count

      [committed] = ProxyGenerator.commit_stages([staged])
      same_original = Enum.find(committed, &(&1.name() == "mcp_svc_staged"))
      newly_committed = Enum.find(committed, &(&1.name() == "mcp_svc_not_committed_yet"))

      assert same_original == original
      assert same_original.schema()["properties"]["fresh"] == %{"type" => "boolean"}
      assert newly_committed.name() == "mcp_svc_not_committed_yet"
      assert ProxyGenerator.identity_count() == identity_count + 1
    end

    test "a collision flip allocates once for the unseen plain name; reverts reuse identities" do
      # Round 1: aggregate boundary collision (`flipa`+`b_ping` vs
      # `flipa_b`+`ping` both stage `mcp_flipa_b_ping`) — every member gets a
      # suffixed identity.
      stage_a = ProxyGenerator.stage_modules("flipa", :flip_slot_a, [tool("b_ping")])
      stage_a_b = ProxyGenerator.stage_modules("flipa_b", :flip_slot_b, [tool("ping")])
      [[collided_a], [collided_a_b]] = ProxyGenerator.commit_stages([stage_a, stage_a_b])

      assert collided_a.name() =~ ~r/^mcp_flipa_b_ping_/
      assert collided_a_b.name() =~ ~r/^mcp_flipa_b_ping_/
      refute collided_a.name() == collided_a_b.name()
      count_after_collision = ProxyGenerator.identity_count()

      # Round 2 (the flip): the collision partner disappears, so the survivor
      # takes the PLAIN name — a previously-unseen local name, allocating
      # exactly one identity. The suffixed identity is retained (inactive),
      # never reclaimed.
      solo = ProxyGenerator.stage_modules("flipa", :flip_slot_a, [tool("b_ping")])
      [[plain]] = ProxyGenerator.commit_stages([solo])

      assert plain.name() == "mcp_flipa_b_ping"
      refute plain == collided_a
      assert ProxyGenerator.identity_count() == count_after_collision + 1

      # Repeating the flip hits an already-seen name: no further growth.
      solo_again = ProxyGenerator.stage_modules("flipa", :flip_slot_a, [tool("b_ping")])
      [[plain_again]] = ProxyGenerator.commit_stages([solo_again])
      assert plain_again == plain
      assert ProxyGenerator.identity_count() == count_after_collision + 1

      # Round 3 (the revert): restoring the collision re-activates the ORIGINAL
      # disambiguated identities — reuse, not allocation.
      stage_a2 = ProxyGenerator.stage_modules("flipa", :flip_slot_a, [tool("b_ping")])
      stage_a_b2 = ProxyGenerator.stage_modules("flipa_b", :flip_slot_b, [tool("ping")])
      [[reverted_a], [reverted_a_b]] = ProxyGenerator.commit_stages([stage_a2, stage_a_b2])

      assert reverted_a == collided_a
      assert reverted_a_b == collided_a_b
      assert ProxyGenerator.identity_count() == count_after_collision + 1
    end
  end

  describe "tool-count cap" do
    test "more than 200 tools yields 200 modules and a warning" do
      tools = for i <- 0..249, do: tool("t" <> String.pad_leading(Integer.to_string(i), 3, "0"))

      {modules, log} = with_log(fn -> build_many(tools) end)

      assert Enum.count(modules) == 200
      assert log =~ "cap"
      # Deterministic first-N by sorted name: t000 kept, t249 dropped.
      assert Enum.any?(modules, &(&1.name() == "mcp_svc_t000"))
      refute Enum.any?(modules, &(&1.name() == "mcp_svc_t249"))
    end
  end

  # jido_mcp promotes a domain `isError: true` result to
  # `{:error, %{type: :tool_error, details: <raw result map>}}`; the proxy
  # re-surfaces THAT (and only that) to `{:ok, data}` so it reaches the generic
  # MCP shaper as data instead of being mangled by `Error.normalize`. The `%{}`
  # context is tenant-less, so the shaper is a no-op — isolating the proxy.
  describe "domain error re-surfacing" do
    test "a domain :tool_error carrying the isError contract is re-surfaced to {:ok, data}" do
      data = %{"content" => [%{"text" => "boom detail"}], "isError" => true}

      stub(%{
        call_tool: fn _id, _name, _args -> {:error, %{type: :tool_error, details: data}} end
      })

      module = build_one(tool("boom"))

      assert {:ok, ^data} = module.run(%{}, %{})
    end

    test "a non-domain (transport) error stays {:error, _}" do
      stub(%{
        call_tool: fn _id, _name, _args ->
          {:error, %{type: :transport, message: "server down"}}
        end
      })

      module = build_one(tool("down"))

      # Only :tool_error is re-surfaced; transport/protocol/validation stay errors.
      assert {:error, error} = module.run(%{}, %{})
      assert error.message =~ "server down"
    end

    test "a :tool_error lacking the isError contract stays {:error, _}" do
      stub(%{
        call_tool: fn _id, _name, _args ->
          {:error, %{type: :tool_error, details: %{"note" => "no isError key"}}}
        end
      })

      module = build_one(tool("partial"))

      # The tighter `%{"isError" => true}` match guards a :tool_error that does
      # not actually carry the MCP domain-error contract from being re-surfaced.
      assert {:error, _} = module.run(%{}, %{})
    end
  end
end
