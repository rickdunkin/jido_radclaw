defmodule JidoClaw.Tools.GitDiff do
  use Jido.Action,
    name: "git_diff",
    description: "Show git diff output. Can show staged or unstaged changes.",
    schema: [
      staged: [type: :boolean, default: false, doc: "Show staged changes (--cached)"],
      path: [type: :string, doc: "Optional file path to limit diff"]
    ]

  @impl true
  def run(params, _context) do
    staged = Map.get(params, :staged, false)

    args = ["diff"] ++ if(staged, do: ["--cached"], else: [])

    args =
      args ++
        case Map.get(params, :path) do
          nil -> []
          p -> ["--", p]
        end

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        truncated =
          if String.length(output) > 15_000 do
            String.slice(output, 0, 15_000) <> "\n... (diff truncated)"
          else
            output
          end

        {:ok, %{diff: truncated}}

      {output, _} ->
        {:error, "git diff failed: #{String.trim(output)}"}
    end
  end
end
