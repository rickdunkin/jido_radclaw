defmodule JidoClaw.Tools.SearchCode do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "search_code",
    description:
      "Search for a pattern in files using grep. Returns matching lines with file paths and line numbers.",
    category: "filesystem",
    tags: ["io", "read"],
    output_schema: [
      matches: [type: :string, required: true],
      total_matches: [type: :integer, required: true]
    ],
    schema: [
      pattern: [type: :string, required: true, doc: "Search pattern (regex supported)"],
      path: [type: :string, default: ".", doc: "Directory to search in"],
      glob: [type: :string, doc: "File pattern filter (e.g. '*.ex', '*.ts')"],
      max_results: [type: :integer, default: 50, doc: "Max results to return"]
    ]

  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.VFS.Resolver
  alias JidoClaw.VFS.Sandbox

  @impl Jido.Action
  def run(%{pattern: _pattern} = params, context) do
    MCPScope.wrap(:search_code, params, context, fn enriched ->
      with {:ok, opts} <- Sandbox.resolver_opts(get_in(enriched, [:tool_context])) do
        search(params, opts)
      end
    end)
  end

  @doc """
  The pure recursive search core, shared by `search_code` (sandbox/cwd opts) and
  `search_real_code` (real-tree opts, AR-8b-2 F3). Takes already-derived
  `Resolver` opts so the opts source (and the owning tool's own
  `MCPScope.wrap`/approval/redaction pipeline) stays with each surface. Reads via
  `Resolver.read/2` WITHOUT a `FilePayloadLimit` cap, exactly as `search_code`
  does today (adding a cap would change existing behavior — out of scope), so
  `search_real_code` is uncapped, matching its source. Returns the `search_code`
  result shape or `{:error, _}`.
  """
  @spec search(%{required(:pattern) => String.t(), optional(atom()) => term()}, keyword()) ::
          {:ok, %{matches: String.t(), total_matches: non_neg_integer()}} | {:error, term()}
  def search(%{pattern: pattern} = params, opts) do
    with {:ok, regex} <- compile_pattern(pattern),
         {:ok, glob} <- compile_glob(Map.get(params, :glob)),
         {:ok, lines} <- search_path(Map.get(params, :path, "."), regex, glob, opts) do
      max_results = Map.get(params, :max_results, 50)
      truncated = Enum.take(lines, max_results)
      total = length(lines)
      content = Enum.join(truncated, "\n")

      note =
        if total > max_results,
          do: "\n(#{total - max_results} more matches truncated)",
          else: ""

      {:ok, %{matches: content <> note, total_matches: total}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp compile_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, reason} -> {:error, "invalid search pattern: #{inspect(reason)}"}
    end
  end

  defp compile_glob(nil), do: {:ok, nil}

  defp compile_glob(glob) do
    {:ok, GlobEx.compile!(glob)}
  rescue
    error in GlobEx.CompileError -> {:error, "invalid glob: #{Exception.message(error)}"}
  end

  defp search_path(path, regex, glob, opts) do
    case Resolver.ls(path, opts) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          case search_path(join_path(path, name), regex, glob, opts) do
            {:ok, matches} -> {:cont, {:ok, [matches | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, chunks} ->
            matches =
              chunks
              |> Enum.reverse()
              |> Enum.concat()

            {:ok, matches}

          error ->
            error
        end

      {:error, _reason} ->
        search_file(path, regex, glob, opts)
    end
  end

  defp search_file(path, regex, glob, opts) do
    if glob_match?(glob, path) do
      case Resolver.read(path, opts) do
        {:ok, content} when is_binary(content) ->
          {:ok, matching_lines(path, content, regex)}

        {:error, reason} ->
          {:error, "Cannot search #{path}: #{inspect(reason)}"}
      end
    else
      {:ok, []}
    end
  end

  defp glob_match?(nil, _path), do: true
  defp glob_match?(glob, path), do: GlobEx.match?(glob, Path.basename(path))

  defp matching_lines(path, content, regex) do
    if String.valid?(content) do
      content
      |> String.split("\n", trim: false)
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _line_number} -> Regex.match?(regex, line) end)
      |> Enum.map(fn {line, line_number} -> "#{path}:#{line_number}:#{line}" end)
    else
      []
    end
  end

  defp join_path(parent, child) do
    case String.trim_trailing(parent, "/") do
      "" -> child
      "/" -> "/" <> child
      path -> path <> "/" <> child
    end
  end
end
