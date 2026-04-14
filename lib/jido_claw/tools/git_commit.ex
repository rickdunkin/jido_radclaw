defmodule JidoClaw.Tools.GitCommit do
  use Jido.Action,
    name: "git_commit",
    description:
      "Stage specific files and create a git commit. Always use git_status first to see what changed.",
    category: "git",
    tags: ["vcs", "write"],
    output_schema: [
      output: [type: :string, required: true],
      status: [type: :string, required: true]
    ],
    schema: [
      message: [type: :string, required: true, doc: "Commit message"],
      files: [
        type: {:list, :string},
        required: true,
        doc: "List of file paths to stage and commit"
      ]
    ]

  @impl true
  def run(%{message: message, files: files}, _context) do
    # Stage files
    Enum.each(files, fn file ->
      System.cmd("git", ["add", file], stderr_to_stdout: true)
    end)

    # Commit
    case System.cmd("git", ["commit", "-m", message], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, %{output: String.trim(output), status: "committed"}}

      {output, _} ->
        {:error, "git commit failed: #{String.trim(output)}"}
    end
  end
end
