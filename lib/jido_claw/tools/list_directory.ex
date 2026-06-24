defmodule JidoClaw.Tools.ListDirectory do
  @moduledoc """
  List files and directories via the VFS resolver.

  Supports local paths and remote URIs:
  - `github://owner/repo/path` — lists GitHub directory contents
  - `s3://bucket/prefix`       — lists S3 prefix
  - `git://repo-path//dir`     — lists Git tree entries
  - All other paths             — lists the local filesystem

  Note: glob patterns are only supported for local paths.
  """

  use JidoClaw.Tools.Action,
    name: "list_directory",
    description:
      "List files and directories at a path. Returns file names with type indicators. Supports github://, s3://, git:// URIs.",
    category: "filesystem",
    tags: ["io", "read"],
    output_schema: [
      path: [type: :string, required: true],
      entries: [type: :string, required: true],
      total: [type: :integer, required: true]
    ],
    schema: [
      path: [
        type: :string,
        default: ".",
        doc: "Directory path to list, or remote URI (github://, s3://, git://)"
      ],
      pattern: [type: :string, doc: "Optional glob pattern for local paths (e.g. '**/*.ex')"],
      max_results: [type: :integer, default: 200, doc: "Max entries to return"]
    ]

  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.VFS.Resolver
  alias JidoClaw.VFS.Sandbox

  @impl Jido.Action
  def run(params, context) do
    MCPScope.wrap(:list_directory, params, context, fn enriched ->
      case Sandbox.resolver_opts(get_in(enriched, [:tool_context])) do
        {:ok, ws_opts} -> list(params, ws_opts)
        {:error, message} -> {:error, message}
      end
    end)
  end

  @doc """
  The pure listing core, shared by `list_directory` (sandbox/cwd opts) and
  `list_real_directory` (real-tree opts, AR-8b-2 F3). Takes already-derived
  `Resolver` opts so the opts source (and the owning tool's own
  `MCPScope.wrap`/approval/redaction pipeline) stays with each surface. Its
  remote branch is already gated by `local_only`, so a real-tree caller (which
  passes `local_only: true`) is jailed to the local real tree. Returns the
  `list_directory` result shape or `{:error, _}`.
  """
  @spec list(map(), keyword()) ::
          {:ok, %{path: String.t(), entries: String.t(), total: non_neg_integer()}}
          | {:error, term()}
  def list(params, ws_opts) do
    path = Map.get(params, :path, ".")
    max_results = Map.get(params, :max_results, 200)
    entries = fetch_entries(path, params, ws_opts)
    format_entries(entries, path, max_results)
  end

  # The remote branch calls `Resolver.ls(path)` with no opts, bypassing the
  # `local_only` funnel, so gate it directly here (AR-8b sketch jail).
  defp fetch_entries(path, params, ws_opts) do
    cond do
      Keyword.get(ws_opts, :local_only, false) and Resolver.remote?(path) ->
        {:error, "Cannot list #{path}: remote schemes are forbidden in the sketch sandbox"}

      Resolver.remote?(path) ->
        list_remote(path)

      true ->
        list_workspace_or_local(path, params, ws_opts)
    end
  end

  # Remote URI paths: delegate entirely to VFS resolver (no glob support)
  defp list_remote(path) do
    case Resolver.ls(path) do
      {:ok, names} -> Enum.map(names, fn name -> "entry  #{name}" end)
      {:error, reason} -> {:error, "Cannot list #{path}: #{inspect(reason)}"}
    end
  end

  # Bootstrap the workspace first so we never mask a bootstrap
  # failure by falling through to `list_local/2`.
  defp list_workspace_or_local(path, params, ws_opts) do
    case Resolver.ensure_workspace_ready(path, ws_opts) do
      :ok ->
        list_mounted_or_local(path, params, ws_opts)

      {:error, reason} ->
        {:error, "Cannot list #{path}: #{inspect(reason)}"}
    end
  end

  defp list_mounted_or_local(path, params, ws_opts) do
    if Resolver.under_workspace_mount?(path, ws_opts) do
      list_workspace_mount(path, ws_opts)
    else
      list_local(path, Map.get(params, :pattern), ws_opts)
    end
  end

  defp list_workspace_mount(path, ws_opts) do
    case Resolver.ls(path, ws_opts) do
      {:ok, names} -> Enum.map(names, fn name -> "entry  #{name}" end)
      {:error, reason} -> {:error, "Cannot list #{path}: #{inspect(reason)}"}
    end
  end

  defp format_entries({:error, _} = err, _path, _max_results), do: err

  defp format_entries(list, path, max_results) do
    truncated = Enum.take(list, max_results)
    total = length(list)
    content = Enum.join(truncated, "\n")

    note =
      if total > max_results,
        do: "\n(#{total - max_results} more entries truncated)",
        else: ""

    {:ok, %{path: path, entries: content <> note, total: total}}
  end

  # -- Private ----------------------------------------------------------------

  defp list_local(path, nil, ws_opts) do
    with {:ok, local_path} <- Resolver.local_path(path, ws_opts, :read),
         {:ok, files} <- File.ls(local_path) do
      format_local_entries(files, local_path)
    else
      {:error, reason} ->
        {:error, "Cannot list #{path}: #{inspect(reason)}"}
    end
  end

  defp list_local(path, glob, ws_opts) do
    with :ok <- validate_glob(glob),
         {:ok, local_path} <- Resolver.local_path(path, ws_opts, :read) do
      local_path
      |> Path.join(glob)
      |> Path.wildcard()
      |> Enum.filter(&match?({:ok, _}, Resolver.local_path(&1, ws_opts, :read)))
      |> Enum.sort()
      |> Enum.map(fn f ->
        rel = Path.relative_to(f, local_path)
        type = if File.dir?(f), do: "dir", else: "file"
        "#{type}  #{rel}"
      end)
    else
      {:error, reason} ->
        {:error, "Cannot list #{path}: #{inspect(reason)}"}
    end
  end

  defp format_local_entries(files, local_path) do
    files
    |> Enum.sort()
    |> Enum.map(fn f ->
      full = Path.join(local_path, f)
      type = if File.dir?(full), do: "dir", else: "file"
      "#{type}  #{f}"
    end)
  end

  defp validate_glob(glob) do
    cond do
      Path.type(glob) == :absolute ->
        {:error, :absolute_glob_not_allowed}

      String.starts_with?(glob, "~") ->
        {:error, :glob_outside_project}

      Enum.any?(Path.split(glob), &(&1 == "..")) ->
        {:error, :glob_outside_project}

      true ->
        :ok
    end
  end
end
