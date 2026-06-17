defmodule JidoClaw.MCP.ProxyGenerator do
  @moduledoc """
  Compiles safe proxy `Jido.Action` modules for an external MCP server's tools.

  The payoff over `jido_mcp`'s own `Jido.MCP.JidoAI.ProxyGenerator`: the
  generated modules `use JidoClaw.Tools.Action` (not bare `Jido.Action`), so
  the full host safety pipeline — `ToolApproval.gate → Error.normalize →
  OutputRedaction → OutputLimit`, inside `MCPScope.wrap` — wraps every call
  automatically. The proxy `run/2` adds **outbound arg scrubbing** and
  **re-surfaces jido_mcp's domain-error promotion** (a spec-`isError: true`
  result, which the dep returns as `{:error, %{type: :tool_error}}`) back to
  `{:ok, data}`, so a tool-execution failure reaches the generic MCP shaper
  (isError lifted + reversible `fetch_output` ref) and the model as data —
  its only failure signal — instead of being mangled by `Error.normalize`.
  The wrapper then redacts + caps the result.

  ## Name safety (load-bearing)

  Every generated tool name is **`mcp_`-rooted** (`mcp_<server>_<tool>`, never
  operator-configurable) and asserted so — this is what keeps the approval
  fail-closed fallback safe: an unknown `mcp_`-prefixed name falls back to the
  gated global default, where a custom prefix would look native. Names are
  deduplicated (distinct remotes that sanitize alike get distinct `.name`s)
  and capped at the 64-char provider limit, reserving the hash-suffix room
  *before* capping so a collision-broken name still fits.

  ## Schema (JSON-Schema pass-through, NOT `Zoi.map()`/`to_zoi`)

  The remote `inputSchema` is used **directly** as the action `schema:`.
  `Jido.Action.Schema` accepts a plain `%{"type"=>"object","properties"=>_}`
  map as an LLM-only pass-through, so `ToolAdapter` advertises the real
  properties. `Zoi.map()` would advertise *no args* (`additionalProperties:
  false`, no properties) and `to_zoi/1` *rejects* unsupported keywords
  (`oneOf`/`$defs`) → also no-args. Local validation is skipped; the **remote
  server** validates at runtime.

  **Limitation:** `ToolAdapter` calls `to_json_schema(strict: true)`, which
  recursively forces `additionalProperties: false`, so a genuinely *dynamic*
  object schema (`additionalProperties: true`) is narrowed — warn-logged.
  """

  require Logger

  # The dep's bound (`sync_tools_to_agent.ex`). The dep *fails the whole sync*
  # past it; we keep a deterministic first-N-by-sorted-name so a chatty server
  # still contributes tools, and warn the dropped count + names (each tool
  # becomes code/atoms/prompt-metadata/registration before approval can help).
  @max_tools 200

  # Description is prompt-trusted before any call (Trust Boundary §2): strip
  # control chars + cap length to blunt description-borne injection / bloat.
  @max_description_chars 2_000
  @control_chars ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/u

  @provider_name_limit 64
  @empty_object_schema %{"type" => "object", "properties" => %{}}

  @doc """
  Build proxy modules for `tools` discovered from `endpoint_id`/`server_name`.

  Returns the list of compiled (or pre-existing, idempotently reused) modules.
  """
  @spec build_modules(String.t(), atom(), [map()]) :: [module()]
  def build_modules(server_name, endpoint_id, tools)
      when is_binary(server_name) and is_atom(endpoint_id) and is_list(tools) do
    prefix = "mcp_" <> server_name <> "_"

    {modules, _used} =
      tools
      |> cap_tools(server_name)
      |> Enum.reduce({[], MapSet.new()}, fn tool, {modules, used} ->
        remote_name = Map.get(tool, "name")
        description = sanitize_description(Map.get(tool, "description"), remote_name)
        schema = normalize_schema(Map.get(tool, "inputSchema"))
        maybe_warn_dynamic(schema, server_name, remote_name)

        local = local_tool_name(prefix, remote_name, used)
        assert_mcp_root!(local)

        module =
          server_name
          |> module_name(endpoint_id, remote_name, local, description, schema)
          |> ensure_proxy_module(endpoint_id, remote_name, local, description, schema)

        {[module | modules], MapSet.put(used, local)}
      end)

    Enum.reverse(modules)
  end

  # -- Tool-count cap (deterministic, first-N by sorted name) --

  defp cap_tools(tools, server_name) do
    {named, unnamed} = Enum.split_with(tools, fn tool -> is_binary(Map.get(tool, "name")) end)

    if unnamed != [] do
      Logger.warning(
        "[MCP] server #{server_name}: dropped #{length(unnamed)} tool(s) with missing/invalid name"
      )
    end

    sorted = Enum.sort_by(named, &Map.get(&1, "name"))

    if length(sorted) > @max_tools do
      {kept, dropped} = Enum.split(sorted, @max_tools)
      names = Enum.map_join(dropped, ", ", &Map.get(&1, "name"))

      Logger.warning(
        "[MCP] server #{server_name}: #{length(dropped)} tool(s) over the #{@max_tools}-tool cap dropped: #{names}"
      )

      kept
    else
      sorted
    end
  end

  # -- Collision-proof, mcp_-rooted, ≤64-char local names --

  defp local_tool_name(prefix, remote_name, used) do
    base = prefix <> sanitize_segment(remote_name)
    candidate = cap(base, @provider_name_limit)

    if MapSet.member?(used, candidate) do
      suffix = collision_suffix(remote_name)
      cap(base, @provider_name_limit - byte_size(suffix)) <> suffix
    else
      candidate
    end
  end

  defp collision_suffix(remote_name) do
    "_" <> String.downcase(Integer.to_string(:erlang.phash2(remote_name), 36))
  end

  # Sanitized names are ASCII ([a-z0-9_]), so byte slicing is char-safe.
  defp cap(string, max) when byte_size(string) <= max, do: string
  defp cap(string, max), do: binary_part(string, 0, max)

  defp sanitize_segment(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "tool"
      normalized -> normalized
    end
  end

  defp assert_mcp_root!(name) do
    unless String.starts_with?(name, "mcp_") do
      raise "JidoClaw.MCP.ProxyGenerator produced a non-mcp_-rooted name: #{inspect(name)}"
    end
  end

  # -- Description / schema normalization --

  defp sanitize_description(description, remote_name) when is_binary(description) do
    description
    |> String.replace(@control_chars, "")
    |> String.slice(0, @max_description_chars)
    |> case do
      "" -> fallback_description(remote_name)
      sanitized -> sanitized
    end
  end

  defp sanitize_description(_description, remote_name), do: fallback_description(remote_name)

  defp fallback_description(remote_name), do: "MCP proxy tool #{remote_name}"

  defp normalize_schema(%{"type" => "object", "properties" => props} = schema)
       when is_map(props),
       do: schema

  defp normalize_schema(%{"type" => "object"} = schema), do: Map.put(schema, "properties", %{})
  defp normalize_schema(_other), do: @empty_object_schema

  defp maybe_warn_dynamic(schema, server_name, remote_name) do
    if open_object?(schema) do
      Logger.warning(
        "[MCP] server #{server_name}: tool #{remote_name} declares dynamic object args " <>
          "(additionalProperties: true); strict-mode tool conversion narrows them to " <>
          "additionalProperties: false — those args may be under-advertised to the model"
      )
    end
  end

  defp open_object?(schema) when is_map(schema) do
    Map.get(schema, "additionalProperties") == true or
      Enum.any?(schema, fn {_key, value} -> open_object?(value) end)
  end

  defp open_object?(list) when is_list(list), do: Enum.any?(list, &open_object?/1)
  defp open_object?(_other), do: false

  # -- Module identity (definition-complete hash) --

  defp module_name(server_name, endpoint_id, remote_name, local_name, description, schema) do
    server = Macro.camelize(sanitize_segment(server_name))
    tool = Macro.camelize(sanitize_segment(local_name))
    hash = definition_hash(endpoint_id, remote_name, local_name, description, schema)

    # Module.concat (not safe_concat) is required — these proxy module atoms are
    # newly minted, so they cannot already exist.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    Module.concat([JidoClaw, MCP, Proxy, server, "#{tool}#{hash}"])
  end

  # The hash covers endpoint, remote name, local name, description, AND schema,
  # so any of those changing yields a new module instead of `Code.ensure_loaded?`
  # keeping a stale proxy.
  defp definition_hash(endpoint_id, remote_name, local_name, description, schema) do
    {endpoint_id, remote_name, local_name, description, schema}
    |> :erlang.phash2()
    |> Integer.to_string(36)
    |> String.upcase()
  end

  # -- Module generation --

  defp ensure_proxy_module(module, endpoint_id, remote_name, local_name, description, schema) do
    if Code.ensure_loaded?(module) do
      module
    else
      create_proxy_module(module, endpoint_id, remote_name, local_name, description, schema)
    end
  end

  defp create_proxy_module(module, endpoint_id, remote_name, local_name, description, schema) do
    quoted =
      quote location: :keep do
        use JidoClaw.Tools.Action,
          name: unquote(local_name),
          description: unquote(description),
          schema: unquote(Macro.escape(schema))

        @endpoint_id unquote(endpoint_id)
        @remote_tool_name unquote(remote_name)

        # NO @impl — the JidoClaw.Tools.Action before_compile wrapper IS the
        # @impl Jido.Action run/2; this run/2 is its `super` target.
        def run(params, _context) do
          # credo:disable-for-next-line Credo.Check.Design.AliasUsage
          scrubbed = JidoClaw.Tools.OutputRedaction.redact(params)

          case JidoClaw.MCP.client().call_tool(@endpoint_id, @remote_tool_name, scrubbed) do
            {:ok, data} ->
              {:ok, data}

            # jido_mcp promotes a domain `isError: true` result (a *successful*
            # MCP response carrying a tool-execution error flag, per spec) to
            # `{:error, %{type: :tool_error, details: <raw result map>}}`.
            # Re-surface it as `{:ok, data}` so the result (incl. `isError`)
            # reaches the generic MCP shaper (isError lifted + reversible
            # fetch_output ref) and the model as data — its only failure signal
            # — instead of being mangled by `Error.normalize` and ref-lessly
            # head-cut by `OutputLimit`. Matching `"isError" => true` in
            # `details` (not just `type: :tool_error`) documents the MCP
            # domain-error contract in code: any `:tool_error` lacking it, plus
            # genuine transport/protocol errors, stay `{:error, _}`.
            {:error, %{type: :tool_error, details: %{"isError" => true} = data}} ->
              {:ok, data}

            {:error, error} ->
              {:error, error}

            other ->
              {:error, {:unexpected_proxy_response, other}}
          end
        end
      end

    {:module, created, _bytecode, _result} =
      Module.create(module, quoted, Macro.Env.location(__ENV__))

    created
  end
end
