defmodule JidoClaw.ToolContextShapeTest do
  use ExUnit.Case, async: true

  alias JidoClaw.ToolContext

  @canonical_keys [
    :project_dir,
    :tenant_id,
    :session_id,
    :session_uuid,
    :workspace_id,
    :workspace_uuid,
    :agent_id
  ]

  @callers [
    "lib/jido_claw.ex",
    "lib/jido_claw/cli/repl.ex",
    "lib/jido_claw/tools/spawn_agent.ex",
    "lib/jido_claw/tools/send_to_agent.ex",
    "lib/jido_claw/workflows/step_action.ex"
  ]

  describe "ToolContext.build/1" do
    test "returns a map with all seven canonical keys, defaulting absent ones to nil" do
      ctx = ToolContext.build(%{tenant_id: "default", workspace_uuid: "ws-uuid"})

      for key <- @canonical_keys do
        assert Map.has_key?(ctx, key), "expected canonical key #{inspect(key)} to be present"
      end

      assert ctx.tenant_id == "default"
      assert ctx.workspace_uuid == "ws-uuid"
      assert ctx.session_uuid == nil
      assert ctx.project_dir == nil
      assert ctx.agent_id == nil

      # forge_session_key absent from input → absent from output
      refute Map.has_key?(ctx, :forge_session_key)
    end

    test "preserves :forge_session_key when set on input" do
      ctx = ToolContext.build(%{forge_session_key: "forge-abc"})
      assert ctx.forge_session_key == "forge-abc"
    end

    test "key set is a stable golden contract" do
      ctx = ToolContext.build(%{forge_session_key: "k"})
      assert MapSet.new(Map.keys(ctx)) == MapSet.new([:forge_session_key | @canonical_keys])
    end
  end

  describe "ToolContext.child/2" do
    test "inherits parent scope and replaces agent_id" do
      parent = %{
        project_dir: "/tmp/foo",
        tenant_id: "tA",
        session_uuid: "ss",
        workspace_uuid: "ws",
        agent_id: "main"
      }

      child = ToolContext.child(parent, "child_tag")
      assert child.agent_id == "child_tag"
      assert child.tenant_id == "tA"
      assert child.session_uuid == "ss"
      assert child.workspace_uuid == "ws"
      assert child.project_dir == "/tmp/foo"
    end

    test "defaults :project_dir to File.cwd!() for a nil parent" do
      child = ToolContext.child(nil, "tag")
      assert child.project_dir == File.cwd!()
      assert child.agent_id == "tag"
    end

    test "replaces explicit nil :project_dir on parent with File.cwd!()" do
      child = ToolContext.child(%{project_dir: nil}, "tag")
      assert child.project_dir == File.cwd!()
    end

    test "preserves :forge_session_key from parent" do
      child = ToolContext.child(%{forge_session_key: "kk"}, "tag")
      assert child.forge_session_key == "kk"
    end
  end

  describe "static caller check — every Agent.ask* site passes :tool_context" do
    test "all known direct Agent.ask call sites carry a tool_context: option" do
      for path <- @callers do
        absolute = Path.expand(path, File.cwd!())
        assert File.exists?(absolute), "expected to find #{path}"

        source = File.read!(absolute)
        ast = Code.string_to_quoted!(source)

        violations = walk_calls(ast)

        assert violations == [],
               "Agent.ask*/ask_sync* call(s) without `tool_context:` option in #{path}: " <>
                 inspect(violations)
      end
    end
  end

  # Walks an AST and returns a list of {fn_name, arity} for any call to
  # Module.ask/3, Module.ask_sync/3, Module.ask_stream/3 whose options
  # keyword list is missing a :tool_context entry. The check is
  # conservative: any keyword expression form is accepted as long as the
  # `:tool_context` key is present.
  defp walk_calls(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_module, fn_name]}, _meta, args} = node, acc
        when fn_name in [:ask, :ask_sync, :ask_stream] and length(args) == 3 ->
          opts = List.last(args)

          if has_tool_context_keyword?(opts) do
            {node, acc}
          else
            {node, [{fn_name, length(args)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp has_tool_context_keyword?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      {{:__block__, _, [:tool_context]}, _} -> true
      {:tool_context, _} -> true
      _ -> false
    end)
  end

  defp has_tool_context_keyword?(_), do: false
end
