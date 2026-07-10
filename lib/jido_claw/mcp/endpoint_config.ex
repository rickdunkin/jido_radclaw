defmodule JidoClaw.MCP.EndpointConfig do
  @moduledoc """
  Translates the raw `mcp_servers:` config list into validated
  `JidoClaw.MCP.ServerSpec` structs, fail-closed per entry.

  `parse/1` returns `{specs, warnings}` — a batch contract: every well-formed
  entry yields a spec, every malformed one yields a warning string (and is
  dropped), so one bad server never sinks the others. Mirrors the warn-and-skip
  posture of `JidoClaw.Agent.Templates.validate_fc/2`.

  ## Accepted shapes

  Config keys may be string-keyed (the `.jido/config.yaml` path through
  `YamlElixir`) or atom-keyed (tests / app config); both are read.

      %{name: "fs", transport: "stdio",
        command: ["npx", "-y", "server"], cwd: "/p", env: %{"FOO" => "bar"}}

      %{name: "fs", transport: "stdio", command: "npx", args: ["-y", "server"]}

      %{name: "tw", transport: "streamable_http", url: "http://h/mcp",
        require_approval: false}

  `command` accepts **both** stdio shapes — a `[exe | args]` list (split into a
  string command + arg list) or a string `command` paired with `args` — because
  the transport requires a string command and a list of string args.

  stdio `env:` is the operator **override** map layered on top of the
  default-deny scrub performed by the patched `Jido.MCP.Transport.STDIO`
  (`JidoClaw.Core` patch). Omitting it (default `%{}`) means pure default-deny.

  HTTP transports take a single `url:`; for `sse` it is split into the
  `base_url` + `sse_path` the Anubis SSE transport expects.

  Endpoint IDs come from a fixed 64-atom pool and are bound to server names for
  the VM lifetime under a lock. Reordering config never reassigns an ID, and an
  ID is never reused for a different name because Jido.MCP retains registered
  endpoints. The binding also pins a digest of transport settings: changing a
  URL/command/args/cwd/env/headers under the same name is rejected with a
  restart-required warning; `templates` and `require_approval` remain live.
  """

  alias Jido.MCP.Endpoint
  alias JidoClaw.Core.CanonicalHash
  alias JidoClaw.MCP.ServerSpec

  @name_re ~r/^[a-z][a-z0-9_]*$/
  # Explicit string→atom mapping (NOT String.to_atom) — the transport set is
  # fixed, so no dynamic atom creation.
  @transport_atoms %{"stdio" => :stdio, "sse" => :sse, "streamable_http" => :streamable_http}
  @transport_values [:stdio, :sse, :streamable_http]
  # Jido.MCP requires atom endpoint ids. Use a compile-time fixed pool instead
  # of converting operator server names into permanent VM atoms. The hard cap
  # is deliberately non-configurable: repeated config churn can reuse these ids
  # but can never grow the atom table.
  @max_servers 64
  @endpoint_ids for index <- 0..(@max_servers - 1),
                    do: :"jido_claw_mcp_endpoint_#{index}"
  @endpoint_registry_key {__MODULE__, :endpoint_registry}

  @doc """
  Parse a raw `mcp_servers:` list into `{[%ServerSpec{}], [warning]}`.

  Non-list input yields `{[], []}` (inert).
  """
  @spec parse(term()) :: {[ServerSpec.t()], [String.t()]}
  def parse(raw_list) when is_list(raw_list) do
    duplicate_names = raw_duplicate_names(raw_list)
    {accepted_entries, overflow_entries} = Enum.split(raw_list, @max_servers)

    {candidates, parse_warnings} =
      Enum.reduce(accepted_entries, {[], []}, fn raw, {candidates, warnings} ->
        case parse_entry(raw) do
          {:ok, candidate} -> {[candidate | candidates], warnings}
          {:error, warning} -> {candidates, [warning | warnings]}
        end
      end)

    ordered_candidates = Enum.reverse(candidates)
    ordered_warnings = Enum.reverse(parse_warnings, overflow_warning(overflow_entries))

    {unique_candidates, duplicate_warnings} =
      reject_duplicate_names(ordered_candidates, ordered_warnings, duplicate_names)

    {specs, endpoint_warnings} = materialize_candidates(unique_candidates)
    {specs, duplicate_warnings ++ endpoint_warnings}
  end

  def parse(_other), do: {[], []}

  # A duplicated name means a duplicated endpoint id, local tool prefix, and
  # approval-policy namespace. Keeping either declaration would make behavior
  # order-dependent, so reject every entry carrying that name.
  defp reject_duplicate_names(candidates, warnings, raw_duplicate_names) do
    candidate_duplicate_names =
      candidates
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    duplicate_names = MapSet.union(raw_duplicate_names, candidate_duplicate_names)

    {kept, _rejected} =
      Enum.split_with(candidates, &(!MapSet.member?(duplicate_names, &1.name)))

    duplicate_warnings =
      duplicate_names
      |> Enum.sort()
      |> Enum.map(fn name ->
        "mcp_servers: skipped duplicate server name #{inspect(name)}; names must be unique"
      end)

    {kept, warnings ++ duplicate_warnings}
  end

  # Scan names across the complete raw list before applying the 64-entry work
  # cap. Otherwise a conflicting declaration at position 65 could be hidden as
  # overflow while the first declaration was accepted, restoring order-dependent
  # endpoint/policy behavior. Only syntactically valid names participate; deeper
  # entry validation remains bounded to the admitted prefix below.
  defp raw_duplicate_names(raw_list) do
    raw_list
    |> Enum.flat_map(fn
      raw when is_map(raw) ->
        case validate_name(get_field(raw, :name)) do
          {:ok, name} -> [name]
          {:error, _reason} -> []
        end

      _other ->
        []
    end)
    |> Enum.frequencies()
    |> Enum.reduce(MapSet.new(), fn
      {name, count}, acc when count > 1 -> MapSet.put(acc, name)
      {_name, _count}, acc -> acc
    end)
  end

  defp parse_entry(raw) when is_map(raw) do
    with {:ok, name} <- validate_name(get_field(raw, :name)),
         {:ok, transport} <- validate_transport_type(get_field(raw, :transport)),
         {:ok, require_approval} <- validate_require_approval(get_field(raw, :require_approval)),
         {:ok, templates} <- validate_templates(get_field(raw, :templates)),
         {:ok, transport_tuple} <- build_transport(transport, raw),
         :ok <- validate_endpoint_transport(transport_tuple) do
      {:ok,
       %{
         raw: raw,
         name: name,
         transport: transport_tuple,
         transport_digest: transport_digest(transport_tuple),
         require_approval: require_approval,
         templates: templates
       }}
    else
      {:error, reason} -> {:error, warning_for(raw, reason)}
    end
  end

  defp parse_entry(other) do
    {:error, "mcp_servers: skipped non-map entry #{inspect(other)}"}
  end

  defp overflow_warning([]), do: []

  defp overflow_warning(entries) do
    [
      "mcp_servers: skipped #{length(entries)} entries beyond the hard #{@max_servers}-server limit"
    ]
  end

  # -- Stable bounded endpoint identity --------------------------------------

  # Jido.MCP endpoint registration is keyed solely by the atom id and treats an
  # already-registered id as success. Therefore IDs cannot be positional or
  # reused: doing so can silently query an old backend under a new name/policy.
  # The VM-persistent mapping is cumulative and bounded by the predeclared pool.
  defp materialize_candidates([]), do: {[], []}

  defp materialize_candidates(candidates) do
    candidates
    |> reserve_endpoint_ids()
    |> Enum.reduce({[], []}, fn
      {:ok, candidate, endpoint_id}, {specs, warnings} ->
        case build_endpoint(endpoint_id, candidate.transport) do
          {:ok, endpoint} ->
            spec = %ServerSpec{
              name: candidate.name,
              endpoint: endpoint,
              require_approval: candidate.require_approval,
              templates: candidate.templates
            }

            {[spec | specs], warnings}

          {:error, reason} ->
            {specs, [warning_for(candidate.raw, reason) | warnings]}
        end

      {:error, candidate, reason}, {specs, warnings} ->
        {specs, [warning_for(candidate.raw, reason) | warnings]}
    end)
    |> then(fn {specs, warnings} -> {Enum.reverse(specs), Enum.reverse(warnings)} end)
  end

  defp reserve_endpoint_ids(candidates) do
    lock = {{__MODULE__, :endpoint_registry, node()}, self()}

    :global.trans(
      lock,
      fn ->
        original = endpoint_registry()
        used = MapSet.new(Map.values(original), & &1.id)
        available = Enum.reject(@endpoint_ids, &MapSet.member?(used, &1))

        {results, updated, _remaining} =
          Enum.reduce(candidates, {[], original, available}, fn candidate,
                                                                {results, registry, ids} ->
            case Map.fetch(registry, candidate.name) do
              {:ok, %{id: id, transport_digest: digest}}
              when digest == candidate.transport_digest ->
                {[{:ok, candidate, id} | results], registry, ids}

              {:ok, %{}} ->
                reason = {:endpoint_transport_changed, :restart_required}
                {[{:error, candidate, reason} | results], registry, ids}

              :error ->
                reserve_new_endpoint(candidate, results, registry, ids)
            end
          end)

        if updated != original, do: :persistent_term.put(@endpoint_registry_key, updated)
        Enum.reverse(results)
      end,
      [node()]
    )
  end

  defp reserve_new_endpoint(candidate, results, registry, [id | remaining]) do
    entry = %{id: id, transport_digest: candidate.transport_digest}

    {
      [{:ok, candidate, id} | results],
      Map.put(registry, candidate.name, entry),
      remaining
    }
  end

  defp reserve_new_endpoint(candidate, results, registry, []) do
    reason = {:endpoint_identity_capacity_exhausted, @max_servers}
    {[{:error, candidate, reason} | results], registry, []}
  end

  defp endpoint_registry, do: :persistent_term.get(@endpoint_registry_key, %{})

  @doc "Returns the VM-persistent server-name to endpoint-identity registry."
  @spec snapshot_endpoint_registry() :: map()
  def snapshot_endpoint_registry, do: endpoint_registry()

  # This mutation seam is compiled only in MIX_ENV=test. A production caller
  # must never erase bindings: Jido.MCP retains registered endpoints, so reuse
  # could route a new name through an old backend and bypass the transport fence.
  if Mix.env() == :test do
    @doc "Restores the endpoint-identity registry during isolated tests."
    @spec restore_endpoint_registry(map()) :: :ok
    def restore_endpoint_registry(snapshot) when is_map(snapshot) do
      lock = {{__MODULE__, :endpoint_registry, node()}, self()}

      :global.trans(
        lock,
        fn -> :persistent_term.put(@endpoint_registry_key, snapshot) end,
        [node()]
      )

      :ok
    end
  end

  defp transport_digest(transport), do: CanonicalHash.sha256_term(transport)

  # -- Field reads (string key wins, atom key falls back; `false`-safe) --

  defp get_field(map, key) do
    string_key = to_string(key)

    cond do
      Map.has_key?(map, string_key) -> {:ok, Map.get(map, string_key)}
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      true -> :error
    end
  end

  # -- Common field validation --

  defp validate_name({:ok, name}) when is_binary(name) do
    if Regex.match?(@name_re, name), do: {:ok, name}, else: {:error, {:invalid_name, name}}
  end

  defp validate_name(_), do: {:error, :missing_or_invalid_name}

  defp validate_transport_type({:ok, transport}) when is_binary(transport) do
    case Map.fetch(@transport_atoms, transport) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_transport, transport}}
    end
  end

  defp validate_transport_type({:ok, transport}) when transport in @transport_values do
    {:ok, transport}
  end

  defp validate_transport_type({:ok, other}), do: {:error, {:invalid_transport, other}}
  defp validate_transport_type(:error), do: {:error, :missing_transport}

  defp validate_require_approval(:error), do: {:ok, nil}
  defp validate_require_approval({:ok, nil}), do: {:ok, nil}
  defp validate_require_approval({:ok, value}) when is_boolean(value), do: {:ok, value}
  defp validate_require_approval({:ok, other}), do: {:error, {:invalid_require_approval, other}}

  defp validate_templates(:error), do: {:ok, []}
  defp validate_templates({:ok, nil}), do: {:ok, []}

  # Match `require_approval`'s non-empty-string posture: an empty-string element
  # is a silent "allowlisted to nobody" footgun, so reject the whole entry.
  defp validate_templates({:ok, list}) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: {:ok, list},
      else: {:error, {:invalid_templates, list}}
  end

  defp validate_templates({:ok, other}), do: {:error, {:invalid_templates, other}}

  # -- Transport translation --

  defp build_transport(:stdio, raw) do
    with {:ok, command, args} <- build_stdio_command(raw),
         {:ok, cwd} <- validate_cwd(get_field(raw, :cwd)),
         {:ok, env} <- validate_env(get_field(raw, :env)) do
      opts = [command: command, args: args, env: env] ++ maybe_kw(:cwd, cwd)
      {:ok, {:stdio, opts}}
    end
  end

  defp build_transport(:streamable_http, raw) do
    with {:ok, url} <- validate_url(get_field(raw, :url)),
         {:ok, headers} <- validate_headers(get_field(raw, :headers)) do
      {:ok, {:streamable_http, [url: url] ++ maybe_kw(:headers, headers)}}
    end
  end

  defp build_transport(:sse, raw) do
    with {:ok, url} <- validate_url(get_field(raw, :url)),
         {:ok, headers} <- validate_headers(get_field(raw, :headers)) do
      {base_url, sse_path} = split_sse_url(url)
      {:ok, {:sse, [base_url: base_url, sse_path: sse_path] ++ maybe_kw(:headers, headers)}}
    end
  end

  defp build_stdio_command(raw) do
    case get_field(raw, :command) do
      {:ok, [exe | rest]} when is_binary(exe) ->
        if Enum.all?(rest, &is_binary/1),
          do: {:ok, exe, rest},
          else: {:error, {:invalid_command, [exe | rest]}}

      {:ok, exe} when is_binary(exe) ->
        with {:ok, args} <- validate_args(get_field(raw, :args)), do: {:ok, exe, args}

      {:ok, other} ->
        {:error, {:invalid_command, other}}

      :error ->
        {:error, :missing_command}
    end
  end

  defp validate_args(:error), do: {:ok, []}
  defp validate_args({:ok, nil}), do: {:ok, []}

  defp validate_args({:ok, list}) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: {:error, {:invalid_args, list}}
  end

  defp validate_args({:ok, other}), do: {:error, {:invalid_args, other}}

  defp validate_cwd(:error), do: {:ok, nil}
  defp validate_cwd({:ok, nil}), do: {:ok, nil}
  defp validate_cwd({:ok, cwd}) when is_binary(cwd), do: {:ok, cwd}
  defp validate_cwd({:ok, other}), do: {:error, {:invalid_cwd, other}}

  defp validate_env(:error), do: {:ok, %{}}
  defp validate_env({:ok, nil}), do: {:ok, %{}}
  defp validate_env({:ok, env}) when is_map(env), do: {:ok, env}
  defp validate_env({:ok, other}), do: {:error, {:invalid_env, other}}

  defp validate_url({:ok, url}) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, {:invalid_url, url}}
    end
  end

  defp validate_url(_), do: {:error, :missing_url}

  defp validate_headers(:error), do: {:ok, nil}
  defp validate_headers({:ok, nil}), do: {:ok, nil}
  defp validate_headers({:ok, headers}) when is_map(headers), do: {:ok, headers}
  defp validate_headers({:ok, other}), do: {:error, {:invalid_headers, other}}

  # Split a full SSE URL into the base_url + sse_path the Anubis SSE
  # transport reads (it builds `base_url <> base_path <> sse_path`).
  defp split_sse_url(url) do
    uri = URI.parse(url)
    path = if is_binary(uri.path) and uri.path != "", do: uri.path, else: "/sse"

    sse_path =
      if is_binary(uri.query) and uri.query != "", do: path <> "?" <> uri.query, else: path

    base_url =
      uri
      |> Map.put(:path, nil)
      |> Map.put(:query, nil)
      |> Map.put(:fragment, nil)
      |> URI.to_string()

    {base_url, sse_path}
  end

  defp maybe_kw(_key, nil), do: []
  defp maybe_kw(key, value), do: [{key, value}]

  # -- Endpoint construction --

  defp validate_endpoint_transport(transport_tuple) do
    case build_endpoint(hd(@endpoint_ids), transport_tuple) do
      {:ok, _endpoint} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_endpoint(endpoint_id, transport_tuple) do
    case Endpoint.new(endpoint_id, transport: transport_tuple, client_info: client_info()) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, reason} -> {:error, {:invalid_endpoint, reason}}
    end
  end

  # Default `client_info` is an enforced `Endpoint.new/2` key; a plain dep-API
  # map (not a domain record).
  # reach:disable-next-line fixed_shape_map
  defp client_info, do: %{name: "jido_claw", version: vsn()}

  defp vsn, do: to_string(Application.spec(:jido_claw, :vsn) || "dev")

  # Only ever called with a map `raw` (the `parse_entry/1` map clause).
  defp warning_for(raw, reason) do
    label =
      case get_field(raw, :name) do
        {:ok, name} when is_binary(name) -> name
        _ -> inspect(raw)
      end

    "mcp_servers: skipped #{label}: #{inspect(reason)}"
  end
end
