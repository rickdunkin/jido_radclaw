defmodule JidoClaw.MCP.EndpointConfig do
  # Mints the endpoint-id atom from the operator-declared server name (validated
  # `^[a-z][a-z0-9_]*$`); the atom set is bounded by the small number of
  # configured servers, not attacker/LLM input. The single `String.to_atom/1`
  # site is the only unsafe-atom usage here.
  # credo:disable-for-this-file Credo.Check.Warning.UnsafeToAtom
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
  """

  alias Jido.MCP.Endpoint
  alias JidoClaw.MCP.ServerSpec

  @name_re ~r/^[a-z][a-z0-9_]*$/
  # Explicit string→atom mapping (NOT String.to_atom) — the transport set is
  # fixed, so no dynamic atom creation.
  @transport_atoms %{"stdio" => :stdio, "sse" => :sse, "streamable_http" => :streamable_http}
  @transport_values [:stdio, :sse, :streamable_http]

  @doc """
  Parse a raw `mcp_servers:` list into `{[%ServerSpec{}], [warning]}`.

  Non-list input yields `{[], []}` (inert).
  """
  @spec parse(term()) :: {[ServerSpec.t()], [String.t()]}
  def parse(raw_list) when is_list(raw_list) do
    {specs, warnings} =
      Enum.reduce(raw_list, {[], []}, fn raw, {specs, warnings} ->
        case parse_entry(raw) do
          {:ok, spec} -> {[spec | specs], warnings}
          {:error, warning} -> {specs, [warning | warnings]}
        end
      end)

    {Enum.reverse(specs), Enum.reverse(warnings)}
  end

  def parse(_other), do: {[], []}

  defp parse_entry(raw) when is_map(raw) do
    with {:ok, name} <- validate_name(get_field(raw, :name)),
         {:ok, transport} <- validate_transport_type(get_field(raw, :transport)),
         {:ok, require_approval} <- validate_require_approval(get_field(raw, :require_approval)),
         {:ok, templates} <- validate_templates(get_field(raw, :templates)),
         {:ok, transport_tuple} <- build_transport(transport, raw),
         {:ok, endpoint} <- build_endpoint(name, transport_tuple) do
      {:ok,
       %ServerSpec{
         name: name,
         endpoint: endpoint,
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

  defp validate_templates({:ok, list}) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: {:error, {:invalid_templates, list}}
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

  defp build_endpoint(name, transport_tuple) do
    # See the file-level note on the bounded atom set.
    # reach:disable-next-line unsafe_atom_creation
    id = String.to_atom(name)

    case Endpoint.new(id, transport: transport_tuple, client_info: client_info()) do
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
