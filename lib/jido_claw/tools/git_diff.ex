defmodule JidoClaw.Tools.GitDiff do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "git_diff",
    description: "Show git diff output. Can show staged or unstaged changes.",
    category: "git",
    tags: ["vcs", "read"],
    output_schema: [
      diff: [type: :string, required: true]
    ],
    schema: [
      staged: [type: :boolean, default: false, doc: "Show staged changes (--cached)"],
      path: [type: :string, doc: "Optional file path to limit diff"]
    ]

  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Tools.MCPScope

  @impl Jido.Action
  def run(params, context) do
    MCPScope.wrap(:git_diff, params, context, fn enriched ->
      project_dir = JidoClaw.ToolContext.project_dir(enriched)
      staged = Map.get(params, :staged, false)

      args = ["diff"] ++ if(staged, do: ["--cached"], else: [])

      args =
        args ++
          case Map.get(params, :path) do
            nil -> []
            p -> ["--", p]
          end

      case System.cmd("git", args,
             cd: project_dir,
             stderr_to_stdout: true,
             env: Env.scrubbed_cmd_env()
           ) do
        {output, 0} ->
          truncated =
            if byte_size(output) > 15_000 do
              String.slice(output, 0, 15_000) <> "\n... (diff truncated)"
            else
              output
            end

          {:ok, %{diff: truncated}}

        {output, _} ->
          {:error, "git diff failed: #{String.trim(output)}"}
      end
    end)
  end
end
