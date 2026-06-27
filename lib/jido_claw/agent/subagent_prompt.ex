defmodule JidoClaw.Agent.SubagentPrompt do
  @moduledoc "Assembles the system prompt injected into a spawned sub-agent (AR-5)."

  alias JidoClaw.Agent.{PromptSections, Templates}
  alias JidoClaw.Doctrine
  alias JidoClaw.Memory
  alias JidoClaw.Memory.Scope
  alias JidoClaw.Persona

  # Ash CRUD + Postgrex faults the Scope-resolve + Block-tier read can hit; narrowed
  # so a real bug surfaces instead of silently dropping the Block tier (mirrors
  # prompt.ex:23 / memory.ex).
  @db_errors JidoClaw.Core.AshErrors.db_errors()

  # AR-6 persona section toggle, checked WITHIN this assembly point — independent of
  # `:doctrine` (the master injection gate in `Startup.inject_subagent_prompt`). When
  # off, the `## PSYCHOLOGY` block is omitted; the rest of the prompt is unchanged.
  @psychology_defaults [enabled?: true]

  @doc """
  Build a sub-agent system prompt for `template_name` from the worker's `tool_context`
  (carries project_dir + scope keys). Composition: role (worker module `description/0`) +
  `## DOCTRINE` (`Doctrine.for_template/1`, the mandatory contract) + `## PSYCHOLOGY`
  (`Persona`, the advisory voice — AR-6, gated by `:psychology`) + reused Memory blocks
  (scope resolved from the tool_context, best-effort) + reused JIDO.md. `catalog_stage_name`
  is the composer stage the worker runs as (`nil` for a direct spawn / follow-up /
  non-composer skill step) and only steers persona resolution. Total/never-raises: unknown
  template → generic role line; unresolvable/absent scope → no Block tier (mirrors the
  main-agent nil-scope path).
  """
  @spec build(String.t(), map(), String.t() | nil) :: String.t()
  def build(template_name, tool_context, catalog_stage_name \\ nil)
      when is_binary(template_name) and is_map(tool_context) do
    project_dir = Map.get(tool_context, :project_dir) || File.cwd!()

    role_section(template_name) <>
      doctrine_section(template_name) <>
      persona_section(template_name, catalog_stage_name) <>
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

  # AR-6: the advisory persona voice (`Persona.render_for/2` prepends its own
  # `## PSYCHOLOGY: <Name>` header + appends the single-sourced conflict rule). Omit
  # the block when the persona layer is off or no persona resolves. Gated HERE — the
  # `:doctrine` master gate in `Startup` still governs whether ANY prompt is injected.
  defp persona_section(template_name, catalog_stage_name) do
    if psychology_enabled?() do
      case Persona.render_for(catalog_stage_name, template_name) do
        "" -> ""
        text -> "\n" <> text <> "\n"
      end
    else
      ""
    end
  end

  defp psychology_enabled? do
    :jido_claw
    |> Application.get_env(:psychology, [])
    |> Keyword.get(:enabled?, @psychology_defaults[:enabled?])
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
