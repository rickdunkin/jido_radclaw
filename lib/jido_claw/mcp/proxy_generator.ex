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
  deduplicated both within a server and across the Consumer's accepted server
  aggregate, then capped at the 64-char provider limit. Aggregate collisions
  give every member an order-independent identity suffix, so a server/tool
  boundary ambiguity cannot bind one backend to another server's approval or
  reach policy; non-colliding historical names remain unchanged.

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

  alias JidoClaw.Core.CanonicalHash

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
  @plain_server_segment_limit 32
  @hashed_server_segment_chars 20
  @server_digest_chars 24
  @empty_object_schema %{"type" => "object", "properties" => %{}}
  @registry_key {__MODULE__, :registry}
  # Cumulative per-VM ceiling. A hostile endpoint may churn remote tool names,
  # but it can no longer grow the atom table/code server without bound.
  @max_proxy_identities 1_024

  @doc """
  Build proxy modules for `tools` discovered from `endpoint_id`/`server_name`.

  Returns the list of compiled (or pre-existing, idempotently reused) modules.

  This direct API retains its historical immediate-publication semantics. The
  Consumer's off-process discovery path uses `stage_modules/3` and publishes a
  complete aggregate only through `commit_stages/1` after the result has been
  correlated and accepted in the Consumer process.
  """
  @spec build_modules(String.t(), atom(), [map()]) :: [module()]
  def build_modules(server_name, endpoint_id, tools)
      when is_binary(server_name) and is_atom(endpoint_id) and is_list(tools) do
    [modules] =
      server_name
      |> stage_modules(endpoint_id, tools)
      |> List.wrap()
      |> commit_stages()

    modules
  end

  @doc """
  Build an inert proxy-definition stage without allocating module atoms or
  changing the live definition registry.

  The returned descriptor contains binaries/maps plus the already-configured
  endpoint atom only. It is safe to construct in a killable discovery process:
  abandoning it cannot change live routing/schema or consume proxy-identity
  capacity. Call `commit_stages/1` only after accepting the whole aggregate.
  """
  @spec stage_modules(String.t(), atom(), [map()]) :: map()
  def stage_modules(server_name, endpoint_id, tools)
      when is_binary(server_name) and is_atom(endpoint_id) and is_list(tools) do
    prefix = server_prefix(server_name)

    {definitions, _used} =
      tools
      |> cap_tools(server_name)
      |> Enum.reduce({[], MapSet.new()}, fn tool, {definitions, used} ->
        remote_name = Map.get(tool, "name")
        description = sanitize_description(Map.get(tool, "description"), remote_name)
        schema = normalize_schema(Map.get(tool, "inputSchema"))
        maybe_warn_dynamic(schema, server_name, remote_name)

        local = local_tool_name(prefix, remote_name, used)
        assert_mcp_root!(local)

        definition = proxy_definition(endpoint_id, remote_name, local, description, schema)

        {[definition | definitions], MapSet.put(used, local)}
      end)

    %{server_name: server_name, definitions: Enum.reverse(definitions)}
  end

  @doc """
  Atomically publish one or more accepted proxy-definition stages.

  Results are lists of modules in the same order as the supplied stages. New
  identities are capacity-checked and allocated only here. All accepted
  definitions are installed with one `:persistent_term.put/2`, so readers see
  either the prior aggregate or the complete accepted aggregate.
  """
  @spec commit_stages([map()]) :: [[module()]]
  def commit_stages(stages) when is_list(stages) do
    stages = disambiguate_aggregate_names(stages)
    lock = {{__MODULE__, :registry, node()}, self()}

    :global.trans(
      lock,
      fn ->
        original = registry()

        {module_lists, updated} =
          Enum.map_reduce(stages, original, fn stage, acc -> commit_stage(stage, acc) end)

        if updated != original, do: :persistent_term.put(@registry_key, updated)
        module_lists
      end,
      [node()]
    )
  end

  # A provider-visible name is the concatenation `mcp_<server>_<tool>`, so the
  # boundary itself can be ambiguous across servers: server `a` / remote
  # `b_ping` and server `a_b` / remote `ping` both stage `mcp_a_b_ping`.
  # Per-server dedupe cannot see that. Resolve only actual aggregate collisions
  # here, before module allocation/publication, and suffix *every* member. This
  # is symmetric (no config-order winner), while reserving all non-colliding
  # names first keeps historical names stable and prevents a suffixed candidate
  # from stealing an existing name.
  defp disambiguate_aggregate_names(stages) do
    entries = aggregate_entries(stages)
    frequencies = Enum.frequencies_by(entries, & &1.definition.local_name)

    reserved =
      entries
      |> Enum.reject(&(Map.fetch!(frequencies, &1.definition.local_name) > 1))
      |> MapSet.new(& &1.definition.local_name)

    {renames, _used} =
      entries
      |> Enum.filter(&(Map.fetch!(frequencies, &1.definition.local_name) > 1))
      |> Enum.sort_by(&aggregate_identity/1)
      |> Enum.reduce({%{}, reserved}, fn entry, {renames, used} ->
        local_name = aggregate_unique_name(entry, used, 1)

        {
          Map.put(renames, {entry.stage_index, entry.definition_index}, local_name),
          MapSet.put(used, local_name)
        }
      end)

    stages
    |> Enum.with_index()
    |> Enum.map(fn {%{definitions: definitions} = stage, stage_index} ->
      renamed =
        definitions
        |> Enum.with_index()
        |> Enum.map(fn {definition, definition_index} ->
          case Map.fetch(renames, {stage_index, definition_index}) do
            {:ok, local_name} -> rename_definition(definition, local_name)
            :error -> definition
          end
        end)

      %{stage | definitions: renamed}
    end)
    |> assert_unique_aggregate_names!()
  end

  defp aggregate_entries(stages) do
    stages
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{server_name: server_name, definitions: definitions}, stage_index} ->
      definitions
      |> Enum.with_index()
      |> Enum.map(fn {definition, definition_index} ->
        %{
          server_name: server_name,
          stage_index: stage_index,
          definition_index: definition_index,
          definition: definition
        }
      end)
    end)
  end

  defp aggregate_identity(entry) do
    definition = entry.definition

    # Endpoint atoms are bounded routing slots, not provider-visible identity:
    # on a fresh VM the same servers may receive opposite slots when config
    # order changes. Keep the suffix stable across that cold-boot permutation;
    # `commit_stage/2` still includes endpoint_id in the backend/module identity.
    {entry.server_name, definition.remote_name, definition.local_name}
  end

  defp aggregate_unique_name(entry, used, attempt) do
    base = entry.definition.local_name
    suffix = aggregate_collision_suffix(aggregate_identity(entry), attempt)
    candidate = cap(base, @provider_name_limit - byte_size(suffix)) <> suffix

    if MapSet.member?(used, candidate) do
      aggregate_unique_name(entry, used, attempt + 1)
    else
      candidate
    end
  end

  defp aggregate_collision_suffix(identity, attempt) do
    digest = compute_digest({:aggregate_name, identity, attempt})
    "_" <> binary_part(digest, 0, 12)
  end

  defp rename_definition(definition, local_name) do
    proxy_definition(
      definition.endpoint_id,
      definition.remote_name,
      local_name,
      definition.description,
      definition.schema
    )
  end

  defp assert_unique_aggregate_names!(stages) do
    names = for stage <- stages, definition <- stage.definitions, do: definition.local_name

    if length(names) != MapSet.size(MapSet.new(names)) do
      raise "JidoClaw.MCP.ProxyGenerator failed to produce unique aggregate tool names"
    end

    stages
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

  # Preserve the historical `mcp_<server>_` prefix for short configured names.
  # Long or normalized names get a 96-bit identity suffix *before* the final
  # 64-byte cap. Therefore two servers sharing a long leading segment cannot
  # collapse to the same provider-visible namespace and overwrite approval or
  # reach policy in the Consumer aggregate.
  defp server_prefix(server_name) do
    segment = sanitize_segment(server_name)

    if segment == server_name and byte_size(segment) <= @plain_server_segment_limit do
      "mcp_" <> segment <> "_"
    else
      "mcp_" <>
        cap(segment, @hashed_server_segment_chars) <>
        "_" <> short_digest(server_name, @server_digest_chars) <> "_"
    end
  end

  defp local_tool_name(prefix, remote_name, used) do
    base = prefix <> sanitize_segment(remote_name)
    unique_local_tool_name(base, remote_name, used, 0)
  end

  defp unique_local_tool_name(base, remote_name, used, attempt) do
    candidate =
      case attempt do
        0 ->
          cap(base, @provider_name_limit)

        positive ->
          suffix = collision_suffix(remote_name, positive)
          cap(base, @provider_name_limit - byte_size(suffix)) <> suffix
      end

    if MapSet.member?(used, candidate) do
      unique_local_tool_name(base, remote_name, used, attempt + 1)
    else
      candidate
    end
  end

  defp collision_suffix(remote_name, 1) do
    "_" <> short_digest(remote_name, 12)
  end

  defp collision_suffix(remote_name, attempt) do
    "_" <> short_digest(remote_name <> "#" <> Integer.to_string(attempt), 12)
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

  # -- Stable module identity + bounded runtime definition registry --

  defp proxy_definition(endpoint_id, remote_name, local_name, description, schema) do
    digest = compute_digest({endpoint_id, remote_name, local_name, description, schema})

    %{
      endpoint_id: endpoint_id,
      remote_name: remote_name,
      local_name: local_name,
      description: description,
      schema: schema,
      digest: digest
    }
  end

  defp commit_stage(%{server_name: server_name, definitions: definitions}, registry)
       when is_binary(server_name) and is_list(definitions) do
    {modules, updated} =
      Enum.reduce(definitions, {[], registry}, fn definition, {modules, acc} ->
        identity =
          {server_name, definition.endpoint_id, definition.remote_name, definition.local_name}

        case Map.fetch(acc.identities, identity) do
          {:ok, module} ->
            {[module | modules], put_registry_definition(acc, module, definition)}

          :error when map_size(acc.identities) >= @max_proxy_identities ->
            Logger.warning(
              "[MCP] proxy identity capacity #{@max_proxy_identities} exhausted; dropping #{server_name}/#{definition.remote_name} until the VM restarts"
            )

            {modules, acc}

          :error ->
            module = module_name(server_name, definition)
            ensure_proxy_module(module, definition.local_name)

            next =
              acc
              |> Map.update!(:identities, &Map.put(&1, identity, module))
              |> put_registry_definition(module, definition)

            {[module | modules], next}
        end
      end)

    {Enum.reverse(modules), updated}
  end

  defp registry do
    :persistent_term.get(@registry_key, %{identities: %{}, definitions: %{}})
  end

  @doc "Returns the currently published proxy definitions keyed by stable module."
  @spec snapshot_definitions() :: map()
  def snapshot_definitions, do: registry().definitions

  @doc "Returns the cumulative number of proxy identities allocated by this VM."
  @spec identity_count() :: non_neg_integer()
  def identity_count, do: map_size(registry().identities)

  defp put_registry_definition(registry, module, definition) do
    Map.update!(registry, :definitions, &Map.put(&1, module, definition))
  end

  defp module_name(server_name, definition) do
    server = Macro.camelize(cap(sanitize_segment(server_name), 40))
    tool = Macro.camelize(cap(sanitize_segment(definition.local_name), 40))

    hash =
      {server_name, definition.endpoint_id, definition.remote_name, definition.local_name}
      |> compute_digest()
      |> binary_part(0, 24)

    # Minted only after the cumulative capacity check above. Definition drift
    # does not create a new atom: metadata lives in the bounded runtime registry.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    Module.concat([JidoClaw, MCP, Proxy, server, "#{tool}#{hash}"])
  end

  defp ensure_proxy_module(module, local_name) do
    if Code.ensure_loaded?(module), do: module, else: create_proxy_module(module, local_name)
  end

  defp create_proxy_module(module, local_name) do
    quoted =
      quote location: :keep do
        alias JidoClaw.MCP.ProxyGenerator
        alias JidoClaw.Tools.OutputRedaction

        use JidoClaw.Tools.Action,
          name: unquote(local_name),
          description: "Runtime-bound external MCP proxy",
          schema: %{"type" => "object", "properties" => %{}},
          runtime_name: true

        defoverridable name: 0,
                       description: 0,
                       schema: 0,
                       to_json: 0,
                       __action_metadata__: 0

        def name, do: ProxyGenerator.definition!(__MODULE__).local_name
        def description, do: ProxyGenerator.definition!(__MODULE__).description
        def schema, do: ProxyGenerator.definition!(__MODULE__).schema

        def to_json do
          super()
          |> Map.put(:name, name())
          |> Map.put(:description, description())
          |> Map.put(:schema, schema())
        end

        def __action_metadata__, do: to_json()

        # NO @impl — the JidoClaw.Tools.Action before_compile wrapper IS the
        # @impl Jido.Action run/2; this run/2 is its `super` target.
        def run(params, _context) do
          definition = ProxyGenerator.definition!(__MODULE__)

          scrubbed = OutputRedaction.redact(params)

          case JidoClaw.MCP.client().call_tool(
                 definition.endpoint_id,
                 definition.remote_name,
                 scrubbed
               ) do
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

  @doc "Returns the committed runtime definition for a stable proxy module."
  @spec definition!(module()) :: map()
  def definition!(module) when is_atom(module) do
    Map.fetch!(registry().definitions, module)
  end

  @doc "Returns the SHA-256 definition digest for a stable proxy module."
  @spec definition_digest(module()) :: String.t()
  def definition_digest(module) when is_atom(module), do: definition!(module).digest

  defp compute_digest(term), do: CanonicalHash.sha256_term(term)

  defp short_digest(value, chars) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, chars)
  end
end
