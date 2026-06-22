defmodule JidoClaw.Agent.SubagentPrompt do
  @moduledoc "Assembles the system prompt injected into a spawned sub-agent (AR-5)."

  alias JidoClaw.Agent.{PromptSections, Templates}
  alias JidoClaw.Doctrine
  alias JidoClaw.Memory
  alias JidoClaw.Memory.Scope

  # Ash CRUD + Postgrex faults the Scope-resolve + Block-tier read can hit; narrowed
  # so a real bug surfaces instead of silently dropping the Block tier (mirrors
  # prompt.ex:23 / memory.ex).
  @db_errors JidoClaw.Core.AshErrors.db_errors()

  @doc """
  Build a sub-agent system prompt for `template_name` from the worker's `tool_context`
  (carries project_dir + scope keys). Composition: role (worker module `description/0`) +
  `## DOCTRINE` (`Doctrine.for_template/1`) + reused Memory blocks (scope resolved from the
  tool_context, best-effort) + reused JIDO.md. Total/never-raises: unknown template →
  generic role line; unresolvable/absent scope → no Block tier (mirrors the main-agent
  nil-scope path).
  """
  @spec build(String.t(), map()) :: String.t()
  def build(template_name, tool_context)
      when is_binary(template_name) and is_map(tool_context) do
    project_dir = Map.get(tool_context, :project_dir) || File.cwd!()

    role_section(template_name) <>
      doctrine_section(template_name) <>
      PromptSections.blocks_section(blocks_for_context(tool_context)) <>
      PromptSections.jido_md_section(PromptSections.load_jido_md(project_dir))
  end

  # The worker's full role text comes from its module `description/0` (guarded by
  # ensure_loaded?/function_exported? — the agent_runner.ex precedent), not the short
  # parent-facing Templates label. Unknown template / no description → generic line.
  defp role_section(template_name) do
    "# Role\n" <> role_text(template_name) <> "\n"
  end

  defp role_text(template_name) do
    case Templates.get(template_name) do
      {:ok, %{module: module}} ->
        if Code.ensure_loaded?(module) and function_exported?(module, :description, 0) do
          module.description()
        else
          "You are a specialized sub-agent."
        end

      _ ->
        "You are a specialized sub-agent."
    end
  end

  # Omit the `## DOCTRINE` header entirely when the template maps to no doctrine.
  defp doctrine_section(template_name) do
    case Doctrine.for_template(template_name) do
      "" -> ""
      text -> "\n## DOCTRINE\n\n" <> text <> "\n"
    end
  end

  # Reuse the main-agent Block-tier read via the flat tool_context the spawn paths
  # already carry. Scope.resolve/1 derives the scope_kind + ancestors; an unresolvable
  # or absent scope yields no blocks. Best-effort: Scope.resolve's session/workspace
  # lookups touch the DB, so narrow on @db_errors / :exit and fall back to [].
  defp blocks_for_context(tool_context) do
    case Scope.resolve(tool_context) do
      {:ok, scope} -> Memory.list_blocks_for_scope_chain(scope)
      _ -> []
    end
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      []
  catch
    :exit, _ -> []
  end
end
