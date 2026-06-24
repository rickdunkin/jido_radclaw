defmodule JidoClaw.Tools.ReadFile do
  @moduledoc """
  Read file contents via the VFS resolver.

  Supports local paths and remote URIs:
  - `github://owner/repo/path` — reads from GitHub
  - `s3://bucket/key`          — reads from S3
  - `git://repo-path//file`    — reads from a Git repository
  - All other paths             — reads from the local filesystem
  """

  use JidoClaw.Tools.Action,
    name: "read_file",
    description:
      "Read file contents. Always read a file before editing it. Returns numbered lines. Supports github://, s3://, git:// URIs.",
    category: "filesystem",
    tags: ["io", "read"],
    output_schema: [
      path: [type: :string, required: true],
      content: [type: :string, required: true],
      total_lines: [type: :integer, required: true]
    ],
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "Absolute or relative file path, or remote URI (github://, s3://, git://)"
      ],
      offset: [type: :non_neg_integer, default: 0, doc: "Start line (0-indexed)"],
      limit: [type: :non_neg_integer, default: 2000, doc: "Max lines to read"]
    ]

  alias JidoClaw.Tools.FilePayloadLimit
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.VFS.Resolver
  alias JidoClaw.VFS.Sandbox

  @impl Jido.Action
  def run(%{path: path} = params, context) do
    MCPScope.wrap(:read_file, params, context, fn enriched ->
      with {:ok, opts} <- Sandbox.resolver_opts(get_in(enriched, [:tool_context])) do
        read_numbered(path, opts, Map.get(params, :offset, 0), Map.get(params, :limit, 2000))
      end
    end)
  end

  @doc """
  The pure read core, shared by `read_file` (sandbox/cwd opts) and
  `read_real_file` (real-tree opts, AR-8b-2 F3): bound-check → `FilePayloadLimit`
  cap → read → number lines. Takes already-derived `Resolver` opts so the opts
  source (and the owning tool's own `MCPScope.wrap`/approval/redaction pipeline)
  stays with each surface. Returns the `read_file` result shape or `{:error, _}`.
  """
  @spec read_numbered(String.t(), keyword(), integer(), integer()) ::
          {:ok, %{path: String.t(), content: String.t(), total_lines: non_neg_integer()}}
          | {:error, term()}
  def read_numbered(_path, _opts, offset, _limit) when offset < 0,
    do: {:error, "offset must be non-negative"}

  def read_numbered(_path, _opts, _offset, limit) when limit < 0,
    do: {:error, "limit must be non-negative"}

  def read_numbered(path, opts, offset, limit) do
    # Two-layer read cap (the write cap, 5 MB): the pre-read stat refuses
    # oversized local files before they reach the heap; the unconditional
    # post-read check closes the stat→read race and covers remote/VFS branches
    # (materialized before the check — bounding the fetch needs backend
    # streaming).
    with :ok <- FilePayloadLimit.validate_read(path, opts),
         {:ok, content} <- read_with_content_cap(path, opts) do
      lines = String.split(content, "\n")
      total = length(lines)

      numbered =
        lines
        |> Enum.with_index(1)
        |> Enum.slice(offset, limit)
        |> Enum.map_join("\n", fn {line, n} ->
          "#{String.pad_leading(Integer.to_string(n), 4)} │ #{line}"
        end)

      {:ok, %{path: path, content: numbered, total_lines: total}}
    end
  end

  defp read_with_content_cap(path, opts) do
    case Resolver.read(path, opts) do
      {:ok, content} ->
        with :ok <- FilePayloadLimit.validate_read_content(path, content) do
          {:ok, content}
        end

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{inspect(reason)}"}
    end
  end
end
