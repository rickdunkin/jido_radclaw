defmodule JidoClaw.Tools.GitCommit do
  # Item 5 (camus C1-6a, commit.sh facts): the tool output carries ENGINE
  # facts, never a relayed claim — `git rev-parse HEAD` before/after (full
  # shas, never --short: the sha is what a later verify binds against),
  # `committed` ⇔ the head actually moved, and a staged-empty commit is an
  # explicit `no_changes` SUCCESS naming the live head (never an error, never
  # a silent "done"). `add_failed` stays distinct from `commit_failed` — a
  # failing add stages NOTHING, and falling through to the empty-stage check
  # would report a false `no_changes`.
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "git_commit",
    description:
      "Stage specific files and create a git commit. Always use git_status first to see what changed.",
    category: "git",
    tags: ["vcs", "write"],
    output_schema: [
      output: [type: :string, required: true],
      status: [type: :string, required: true],
      committed: [type: :boolean, required: true],
      sha: [type: :string, required: false],
      head_before: [type: :string, required: false]
    ],
    schema: [
      message: [type: :string, required: true, doc: "Commit message"],
      files: [
        type: {:list, :string},
        required: true,
        doc: "List of file paths to stage and commit"
      ]
    ]

  alias JidoClaw.Orchestration.Verify
  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Tools.MCPScope

  @impl Jido.Action
  def run(%{message: message, files: files} = params, context) do
    MCPScope.wrap(:git_commit, params, context, fn enriched ->
      project_dir = JidoClaw.ToolContext.project_dir(enriched)
      cmd_opts = [cd: project_dir, stderr_to_stdout: true, env: Env.scrubbed_cmd_env()]
      head_before = Verify.Git.head(project_dir)

      with :ok <- stage_files(files, cmd_opts) do
        if staged_empty?(cmd_opts) do
          no_changes(project_dir, head_before)
        else
          commit(message, cmd_opts, project_dir, head_before)
        end
      end
    end)
  end

  # `--quiet` exits 0 on an empty index, 1 when changes are staged.
  defp staged_empty?(cmd_opts) do
    match?({_output, 0}, System.cmd("git", ["diff", "--cached", "--quiet"], cmd_opts))
  end

  # An empty stage is an explicit SUCCESS outcome, never an error and never a
  # silent "committed": the work (if any) is a PRIOR commit, so the live head
  # is named for a later verify to bind against.
  defp no_changes(project_dir, head_before) do
    {:ok,
     head_facts(
       %{
         output: "no changes staged; nothing to commit",
         status: "no_changes",
         committed: false
       },
       project_dir,
       head_before
     )}
  end

  defp commit(message, cmd_opts, project_dir, head_before) do
    case System.cmd("git", ["commit", "-m", message], cmd_opts) do
      {output, 0} ->
        {:ok,
         head_facts(
           %{output: String.trim(output), status: "committed", committed: true},
           project_dir,
           head_before
         )}

      {output, _} ->
        {:error, "git commit failed: #{String.trim(output)}"}
    end
  end

  # Nil facts (an unborn HEAD / a git blip) are OMITTED, never present-nil —
  # the output schema types both as strings, and a downstream reader must see
  # "no fact" rather than a typed nil.
  defp head_facts(base, project_dir, head_before) do
    [sha: Verify.Git.head(project_dir), head_before: head_before]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(base)
  end

  defp stage_files(files, cmd_opts) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case System.cmd("git", ["add", "--", file], cmd_opts) do
        {_output, 0} ->
          {:cont, :ok}

        {output, code} ->
          message = "git add failed for #{inspect(file)} (exit #{code}): #{String.trim(output)}"
          {:halt, {:error, message}}
      end
    end)
  end
end
