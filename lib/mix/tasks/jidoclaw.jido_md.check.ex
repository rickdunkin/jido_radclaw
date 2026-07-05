defmodule Mix.Tasks.Jidoclaw.JidoMd.Check do
  @moduledoc """
  Checks that the committed `.jido/JIDO.md` matches the registered platform
  truth: app version, tool name set, agent-template detail/summary name sets,
  built-in skill name set, no machine-absolute paths, live entry-point paths.

  Validation is `JidoClaw.JidoMd.Check.problems/2`; expected values are
  derived here from the same sources the generator uses. Wired into the
  `precommit` alias next to `jidoclaw.system_prompt.check`.
  """

  use Mix.Task

  alias JidoClaw.Agent.Templates
  alias JidoClaw.JidoMd.Check

  @shortdoc "Checks .jido/JIDO.md drift against registered tools/templates/skills"

  @jido_md Path.join(".jido", "JIDO.md")

  @impl Mix.Task
  def run(_args) do
    # Populates Application.spec(:jido_claw, :vsn); the checked values are
    # otherwise pure module reads, so the app never needs to be started.
    _ = Application.load(:jido_claw)

    case File.read(@jido_md) do
      {:ok, content} -> check(content)
      {:error, reason} -> Mix.raise("cannot read #{@jido_md}: #{inspect(reason)}")
    end
  end

  defp check(content) do
    opts = expected()

    case Check.problems(content, opts) do
      [] ->
        [tools, templates, skills] =
          Enum.map([:tool_names, :template_names, :skill_names], &length(opts[&1]))

        Mix.shell().info(
          "JIDO.md in sync (version #{opts[:version]}, #{tools} tools, " <>
            "#{templates} templates, #{skills} skills)."
        )

      problems ->
        shell = Mix.shell()
        Enum.each(problems, &shell.error("#{@jido_md}: #{&1}"))
        Mix.raise("JIDO.md drift detected — update .jido/JIDO.md (see JidoClaw.JidoMd)")
    end
  end

  defp expected do
    tool_names =
      JidoClaw.Agent.tool_modules()
      |> Enum.map(& &1.name())
      |> Enum.sort()

    [
      version: to_string(Application.spec(:jido_claw, :vsn)),
      tool_names: tool_names,
      template_names: Enum.sort(Templates.names()),
      spawnable_names: Templates.spawnable_names(),
      skill_names: JidoClaw.Skills.default_skill_names()
    ]
  end
end
