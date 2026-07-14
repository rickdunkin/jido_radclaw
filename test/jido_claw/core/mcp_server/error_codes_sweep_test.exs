defmodule JidoClaw.MCPServer.ErrorCodesSweepTest do
  @moduledoc """
  PD1-2 supplemental lint: a quoted-AST sweep over the published tool
  modules' sources plus the pinned envelope-producer files, collecting
  literal error-code emissions and set-checking them against the
  `JidoClaw.MCPServer.ErrorCodes` registry in BOTH directions.

  This is LINT — the boundary's unregistered-code fallback is the closure
  proof; `Error.normalize`'s legacy funnel forwards ANY atom under
  `code:`/`status:` keys, so the emitted set is formally open.

  Collection kinds (expression side only — pattern positions are pruned):

    * `:map` — a literal map carrying `code: <literal atom>`
    * `:envelope_call` — a local `envelope(<literal atom>, ...)` call
    * `:bare_tuple` — a literal `{:error, <literal atom>}` tuple

  Every non-envelope literal the walker cannot structurally exclude is
  pinned in `@non_envelope_literals` with an exact occurrence COUNT —
  filtered node-wise BEFORE projecting to code sets, so a bare file-scoped
  atom subtraction can never swallow a FUTURE genuine envelope, and a
  duplicated/moved literal fails loudly instead of false-greening.
  """

  # async: false — Code.ensure_loaded on live modules in setup.
  use ExUnit.Case, async: false

  alias JidoClaw.MCPServer
  alias JidoClaw.MCPServer.ErrorCodes

  # Envelope-producer files swept BESIDE the published tools' own sources.
  @pinned_producer_files [
    "lib/jido_claw/security/tool_approval.ex",
    "lib/jido_claw/agent/loop_guard.ex",
    "lib/jido_claw/tools/lua/runner.ex",
    "lib/jido_claw/tools/run_command/forge_bridge.ex",
    "lib/jido_claw/tools/error.ex"
  ]

  # Non-literal `code:` sites, declared with their full possible atom sets.
  @indirect_producers %{
    # run_command's deadline_error_code/1 (`code: deadline_error_code(kind)`).
    "lib/jido_claw/tools/run_command.ex" => [:host_deadline_exceeded, :host_command_timeout]
  }

  # Residual open catch-all forwards (site-level; no atoms to enumerate —
  # the boundary fallback + drift log cover them).
  @open_forwarders [
    # network_share.ex — normalize_share_result/2's residual {:error, reason}.
    "lib/jido_claw/tools/network_share.ex",
    # run_skill.ex — the Compiler.compile {:error, reason} forward.
    "lib/jido_claw/tools/run_skill.ex"
  ]

  # View-layer relays: atoms originated outside the swept files, forwarded
  # verbatim by served tools (variables at the tool layer — invisible to a
  # literal sweep).
  @relayed_codes %{
    # agent_view.ex resolve/lookup errors riding agent_status/inspect_agent.
    "lib/jido_claw/agent_view.ex" => [
      :session_not_found,
      :session_id_mismatch,
      :session_not_resolved
    ],
    # workflow_view.ex reads riding workflow_status/workflow_events/inspect_workflow.
    "lib/jido_claw/workflow_view.ex" => [:not_found, :event_feed_unavailable, :tenant_required],
    # inspection.ex targets riding inspect_agent.
    "lib/jido_claw/inspection.ex" => [:unknown_target, :handoff_not_found, :not_found],
    # runtime_scope.ex — require_tenant's :tenant_required, relayed by the
    # scope-requiring tools.
    "lib/jido_claw/runtime_scope.ex" => [:tenant_required]
  }

  # Known NON-envelope literals: exact occurrences (file + enclosing
  # function + kind + atom) with pinned expected counts. Staleness rule:
  # every entry must match EXACTLY its declared count.
  @non_envelope_literals [
    # Tools.Error's details-level child-summary sub-codes — inside
    # details.errors[] construction, never a top-level envelope code.
    {"lib/jido_claw/tools/error.ex", :child_error_summary, :map, :foreign, 1},
    {"lib/jido_claw/tools/error.ex", :child_error_summary, :map, :unknown, 1},
    # Tool approval's mount-config read tags — internal tuples collapsed to
    # a fail-closed boolean before any envelope (tool_approval.ex:455).
    {"lib/jido_claw/security/tool_approval.ex", :read_mount_config, :bare_tuple,
     :mount_config_unreadable, 2},
    {"lib/jido_claw/security/tool_approval.ex", :read_mount_config, :bare_tuple,
     :mount_config_not_regular, 1}
  ]

  setup_all do
    {:module, _} = Code.ensure_loaded(MCPServer)
    Enum.each(MCPServer.published_tool_modules(), &Code.ensure_loaded/1)
    :ok
  end

  test "collected literal codes and the registry cover each other" do
    files = swept_files()
    occurrences = Enum.flat_map(files, &collect_file/1)

    {excluded, kept} = split_excluded(occurrences)
    assert_exclusion_counts!(excluded)

    kept_codes = MapSet.new(kept, &elem(&1, 3))

    declared =
      (Map.values(@indirect_producers) ++ Map.values(@relayed_codes))
      |> List.flatten()
      |> MapSet.new()

    # Direction 1: everything emitted or declared must be registered.
    unregistered =
      kept_codes
      |> MapSet.union(declared)
      |> MapSet.difference(ErrorCodes.all())

    assert MapSet.size(unregistered) == 0,
           "codes emitted by swept producers but missing from the registry " <>
             "(register them WITH docs, or pin them in @non_envelope_literals " <>
             "with a justification): #{inspect(MapSet.to_list(unregistered))}\n" <>
             "occurrences: #{inspect(Enum.filter(kept, &(elem(&1, 3) in unregistered)))}"

    # Direction 2: every registered code must be traceable — a literal
    # collection, a declaration, or the normalization family (emitted via
    # Tools.Error's struct_code/code_from_value returns, not literal
    # envelopes).
    normalization =
      ErrorCodes.families()
      |> Map.fetch!(:normalization)
      |> Map.keys()
      |> MapSet.new()

    orphaned =
      ErrorCodes.all()
      |> MapSet.difference(kept_codes)
      |> MapSet.difference(declared)
      |> MapSet.difference(normalization)

    assert MapSet.size(orphaned) == 0,
           "registered codes with no traceable producer " <>
             "(stale registry entry?): #{inspect(MapSet.to_list(orphaned))}"
  end

  test "open forwarders + relays reference real files" do
    for file <- @open_forwarders ++ Map.keys(@relayed_codes) ++ Map.keys(@indirect_producers) do
      assert File.exists?(file), "declared sweep site moved: #{file}"
    end
  end

  describe "collector self-tests (each kind MUST collect)" do
    test "a literal code: map collects" do
      ast = quote do: {:error, %{code: :self_test_map, message: "m", details: %{}}}
      occurrences = collect_ast(ast, "self.ex")
      assert {"self.ex", :unknown_fn, :map, :self_test_map} in occurrences
    end

    test "a local envelope(...) call's first-arg atom collects" do
      ast = quote do: envelope(:self_test_envelope, "msg", %{})
      occurrences = collect_ast(ast, "self.ex")
      assert {"self.ex", :unknown_fn, :envelope_call, :self_test_envelope} in occurrences
    end

    test "a bare {:error, atom} tuple collects" do
      ast = quote do: {:error, :self_test_bare}
      occurrences = collect_ast(ast, "self.ex")
      assert {"self.ex", :unknown_fn, :bare_tuple, :self_test_bare} in occurrences
    end

    test "pattern positions are pruned: -> LHS, <- LHS, def heads, attributes" do
      ast =
        quote do
          @attr {:error, :attr_code}
          def handle({:error, :head_code}) do
            with {:error, :bind_code} <- source(),
                 {:error, :second_bind} <- next() do
              :ok
            else
              {:error, :clause_code} -> {:error, :kept_code}
            end
          end
        end

      occurrences = collect_ast(ast, "self.ex")
      codes = Enum.map(occurrences, &elem(&1, 3))

      assert :kept_code in codes
      refute :attr_code in codes
      refute :head_code in codes
      refute :bind_code in codes
      refute :second_bind in codes
      refute :clause_code in codes
    end
  end

  # ── Sweep sources ─────────────────────────────────────────────────────────

  defp swept_files do
    tool_sources =
      Enum.map(MCPServer.published_tool_modules(), fn module ->
        module.__info__(:compile)
        |> Keyword.fetch!(:source)
        |> List.to_string()
        |> Path.relative_to(File.cwd!())
      end)

    Enum.uniq(tool_sources ++ @pinned_producer_files)
  end

  defp collect_file(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!(file: file)
    |> collect_ast(file)
  end

  # ── Exclusion filtering (node-wise, count-pinned) ────────────────────────

  defp split_excluded(occurrences) do
    Enum.split_with(occurrences, fn {file, fun, kind, code} ->
      Enum.any?(@non_envelope_literals, fn {xfile, xfun, xkind, xcode, _count} ->
        file == xfile and fun == xfun and kind == xkind and code == xcode
      end)
    end)
  end

  defp assert_exclusion_counts!(excluded) do
    for {xfile, xfun, xkind, xcode, expected} <- @non_envelope_literals do
      actual = Enum.count(excluded, &(&1 == {xfile, xfun, xkind, xcode}))

      assert actual == expected,
             "@non_envelope_literals staleness: #{xfile} #{xfun}/#{xkind}/#{inspect(xcode)} " <>
               "expected #{expected} occurrence(s), found #{actual} — " <>
               "a moved/duplicated literal must be re-justified, not silently absorbed"
    end
  end

  # ── The walker ────────────────────────────────────────────────────────────

  # Occurrence: {file, enclosing_function :: atom, kind, code_atom}.
  defp collect_ast(ast, file), do: walk(ast, file, :unknown_fn, [])

  # Attributes are pattern/declaration space — skip entirely.
  defp walk({:@, _meta, _args}, _file, _fun, acc), do: acc

  # def/defp: skip the HEAD (patterns + guards), walk the body under the
  # function's name.
  defp walk({defkind, _meta, [head, body]}, file, _fun, acc) when defkind in [:def, :defp] do
    walk(body, file, head_name(head), acc)
  end

  defp walk({defkind, _meta, [_head]}, _file, _fun, acc) when defkind in [:def, :defp], do: acc

  # Clause arrows: skip the LHS patterns, walk the RHS.
  defp walk({:->, _meta, [_lhs, rhs]}, file, fun, acc), do: walk(rhs, file, fun, acc)

  # with/for binds: skip the LHS pattern, walk the source expression.
  defp walk({:<-, _meta, [_lhs, rhs]}, file, fun, acc), do: walk(rhs, file, fun, acc)

  # Local envelope(...) call with a literal first-arg atom.
  defp walk({:envelope, _meta, [code | rest]} = _node, file, fun, acc) when is_atom(code) do
    acc = [{file, fun, :envelope_call, code} | acc]
    walk(rest, file, fun, acc)
  end

  # Literal map with a literal-atom code: value.
  defp walk({:%{}, _meta, pairs} = _node, file, fun, acc) when is_list(pairs) do
    acc =
      case List.keyfind(pairs, :code, 0) do
        {:code, code} when is_atom(code) and not is_nil(code) -> [{file, fun, :map, code} | acc]
        _absent_or_dynamic -> acc
      end

    walk(pairs, file, fun, acc)
  end

  # Generic 3-tuple AST node: walk args.
  defp walk({form, _meta, args}, file, fun, acc) when is_list(args) do
    walk_all([form | args], file, fun, acc)
  end

  defp walk({form, _meta, context}, _file, _fun, acc) when is_atom(context),
    do: walk_leaf(form, acc)

  # Literal {:error, atom} 2-tuple (2-tuples self-quote).
  defp walk({:error, code}, file, fun, acc) when is_atom(code) and not is_nil(code) do
    [{file, fun, :bare_tuple, code} | acc]
  end

  # Other literal 2-tuples: walk both sides.
  defp walk({left, right}, file, fun, acc) do
    walk(right, file, fun, walk(left, file, fun, acc))
  end

  defp walk(list, file, fun, acc) when is_list(list), do: walk_all(list, file, fun, acc)

  defp walk(_leaf, _file, _fun, acc), do: acc

  defp walk_all(nodes, file, fun, acc) do
    Enum.reduce(nodes, acc, fn node, acc -> walk(node, file, fun, acc) end)
  end

  defp walk_leaf(_form, acc), do: acc

  # Function name from a def head, seeing through guards.
  defp head_name({:when, _meta, [inner | _guards]}), do: head_name(inner)
  defp head_name({name, _meta, _args}) when is_atom(name), do: name
  defp head_name(_other), do: :unknown_fn
end
