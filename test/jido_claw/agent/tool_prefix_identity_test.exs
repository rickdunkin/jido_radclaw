defmodule JidoClaw.Agent.ToolPrefixIdentityTest do
  @moduledoc """
  CC2-2 tools-half: the provider prompt cache's other keyed segment is the
  tools array, whose wire order is `Map.values` over the ReAct config's tool
  map (`Config.reqllm_tools/1` — NOT the sorted `fingerprint/1`, which is a
  different artifact).

  Scope, honestly: this pins the NATIVE/no-MCP tool prefix (deterministic
  wire order for `JidoClaw.Agent.tool_modules()`) plus resume-neutrality (a
  resume emits no register/unregister signals, so it cannot shift the
  last-tool cache breakpoint — the `deferred_tools_delta` regression class).
  Mid-session external-MCP attach can still extend the tool map by design —
  pre-existing behavior, independent of resume.
  """
  use JidoClaw.TenantCase, async: false

  alias Jido.AI.Reasoning.ReAct.Config, as: ReactConfig
  alias JidoClaw.Conversations.ContextRestore
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Startup
  alias JidoClaw.Test.CapturingAgent

  test "reqllm_tools wire order is deterministic across two Config builds" do
    tools = JidoClaw.Agent.tool_modules()

    build = fn ->
      %{tools: tools, model: "anthropic:claude-haiku-4-5"}
      |> ReactConfig.new()
      |> ReactConfig.reqllm_tools()
    end

    first = build.()
    second = build.()

    # The identical ordered tool list, on the real wire artifact.
    assert Enum.map(first, & &1.name) == Enum.map(second, & &1.name)
    assert length(first) == length(tools)
  end

  test "resume is tool-neutral: inject + restore emit no (un)register_tool signals" do
    %{tenant_id: tenant_id, session: session} =
      seed_full(
        tenant_label: "tool-neutral",
        session: [kind: :cli_run, metadata: %{"prompt_snapshot" => "SNAP"}]
      )

    actor = actor_for(tenant_id)

    {:ok, _} =
      Message.append(
        %{session_id: session.id, role: :user, content: "hi", request_id: "req-t"},
        tenant: tenant_id,
        actor: actor
      )

    {:ok, pid} = CapturingAgent.start_link(self())

    assert :ok = Startup.inject_system_prompt(pid, File.cwd!(), session)
    assert :ok = ContextRestore.restore(pid, session, File.cwd!(), actor: actor)

    # The two expected signals arrive...
    assert_receive {:injected_prompt, _}, 2_000
    assert_receive {:context_modify, _}, 2_000

    # ...and nothing else does — resume cannot move the tools breakpoint.
    refute_receive {:signal, "ai.react.register_tool", _}, 200
    refute_receive {:signal, "ai.react.unregister_tool", _}, 100
    refute_receive {:signal, _, _}, 100
  end
end
