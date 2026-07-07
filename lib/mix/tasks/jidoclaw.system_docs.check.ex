defmodule Mix.Tasks.Jidoclaw.SystemDocs.Check do
  @moduledoc """
  Checks the `docs/system/` documentation layer: every page satisfies the
  frontmatter + source-map contract, intra-corpus links resolve, the README
  index matches the page set, and the AGENTS.md pointers hold in both
  directions (every pointer resolves, every page is cited).

  Validation is `JidoClaw.SystemDocs.Check.problems/1`; this task owns all
  file I/O (pure file reads — the app is never loaded or started). Wired
  into the `precommit` alias next to `jidoclaw.jido_md.check`.
  """

  use Mix.Task

  alias JidoClaw.SystemDocs.Check

  @shortdoc "Checks docs/system/ page contract, index, and AGENTS.md pointer drift"

  @docs_dir Path.join("docs", "system")
  @agents_md "AGENTS.md"

  @impl Mix.Task
  def run(_args) do
    {readme, pages} = read_corpus()
    agents_md = read!(@agents_md)

    case Check.problems(pages: pages, readme: readme, agents_md: agents_md) do
      [] ->
        Mix.shell().info("docs/system in sync (#{length(pages)} pages + README).")

      problems ->
        shell = Mix.shell()
        Enum.each(problems, &shell.error/1)

        Mix.raise(
          "docs/system drift detected — fix the pages/index/AGENTS.md pointers " <>
            "(conventions in #{@docs_dir}/README.md)"
        )
    end
  end

  defp read_corpus do
    docs =
      @docs_dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&%{path: &1, content: read!(&1)})

    case Enum.split_with(docs, &(Path.basename(&1.path) == "README.md")) do
      {[readme], pages} -> {readme, pages}
      {_no_readme, _pages} -> Mix.raise("missing #{@docs_dir}/README.md")
    end
  end

  defp read!(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} -> Mix.raise("cannot read #{path}: #{inspect(reason)}")
    end
  end
end
