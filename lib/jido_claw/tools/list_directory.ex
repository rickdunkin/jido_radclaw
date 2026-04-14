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

  use Jido.Action,
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

  alias JidoClaw.VFS.Resolver

  @impl true
  def run(params, _context) do
    path = Map.get(params, :path, ".")
    max_results = Map.get(params, :max_results, 200)

    entries =
      if Resolver.remote?(path) do
        # Remote paths: delegate entirely to VFS resolver (no glob support)
        case Resolver.ls(path) do
          {:ok, names} ->
            Enum.map(names, fn name -> "entry  #{name}" end)

          {:error, reason} ->
            {:error, "Cannot list #{path}: #{inspect(reason)}"}
        end
      else
        list_local(path, Map.get(params, :pattern))
      end

    case entries do
      {:error, _} = err ->
        err

      list ->
        truncated = Enum.take(list, max_results)
        total = length(list)
        content = Enum.join(truncated, "\n")

        note =
          if total > max_results,
            do: "\n(#{total - max_results} more entries truncated)",
            else: ""

        {:ok, %{path: path, entries: content <> note, total: total}}
    end
  end

  # -- Private ----------------------------------------------------------------

  defp list_local(path, nil) do
    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.sort()
        |> Enum.map(fn f ->
          full = Path.join(path, f)
          type = if File.dir?(full), do: "dir", else: "file"
          "#{type}  #{f}"
        end)

      {:error, reason} ->
        {:error, "Cannot list #{path}: #{inspect(reason)}"}
    end
  end

  defp list_local(path, glob) do
    full_pattern = Path.join(path, glob)

    Path.wildcard(full_pattern)
    |> Enum.sort()
    |> Enum.map(fn f ->
      rel = Path.relative_to(f, path)
      type = if File.dir?(f), do: "dir", else: "file"
      "#{type}  #{rel}"
    end)
  end
end
