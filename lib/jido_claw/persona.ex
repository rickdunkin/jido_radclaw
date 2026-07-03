defmodule JidoClaw.Persona do
  @moduledoc """
  AR-6 psychology persona registry: an advisory `## PSYCHOLOGY: <Name>` voice block injected
  into spawned sub-agents' system prompts via the AR-5 `SubagentPrompt` seam. Personas are
  authored-once priv-file text, resolved STAGE-FIRST (catalog stage name) with a TEMPLATE-name
  fallback — so the four reviewer stages over the single `reviewer` template get distinct voices.
  Advisory only: the renderer appends the single-sourced mandatory conflict rule ("the role and
  the codebase win") to every block. Independently gated by `config :jido_claw, :psychology`
  (checked in `SubagentPrompt`).
  """

  # Load the 10 uniform persona files with ONE comprehension over @persona_names — deliberately
  # unlike Doctrine's per-slice @xxx_priv attributes, so the two registries never form an ExDNA
  # clone family. Each file is an @external_resource (recompile on edit).
  @persona_dir Path.join([__DIR__, "..", "..", "priv", "defaults", "persona"])
  @persona_names ~w(arbiter craftsperson cynic defender detective optimist pragmatist skeptic teacher user-advocate)

  # The advisory safety valve — single-sourced HERE, not duplicated in the 10 files. Guarantees
  # every rendered persona carries the byte-identical role-wins rule; impossible to drift.
  @conflict_rule "Your role contract is mandatory; persona is advisory voice. " <>
                   "On conflict, the role and the codebase win."

  for name <- @persona_names do
    @external_resource Path.join(@persona_dir, name <> ".md")
  end

  @personas (for name <- @persona_names, into: %{} do
               {name, String.trim(File.read!(Path.join(@persona_dir, name <> ".md")))}
             end)

  # Catalog STAGE name → persona. The four reviewer stages (all the single `reviewer` template)
  # get DISTINCT voices — the whole point of per-stage keying.
  @stage_persona %{
    "planner" => "detective",
    "test-author" => "skeptic",
    "implementer" => "craftsperson",
    "security-reviewer" => "defender",
    "quality-reviewer" => "craftsperson",
    "correctness-reviewer" => "skeptic",
    "architecture-reviewer" => "pragmatist",
    "fixer" => "cynic",
    "sketch-build" => "optimist",
    "sketch-build-exec" => "optimist",
    "sketch-review" => "skeptic",
    "system-executor" => "teacher",
    "system-verifier" => "detective",
    # AR-9: the multi-plan wave. The lens planners keep the planner-class voice
    # (the lens is a TASK bias, not a persona); the challengers judge like the
    # reviewer stages; the arbiter gets the dedicated 10th persona.
    "planner-smallest-shippable" => "detective",
    "planner-risk-first" => "detective",
    "planner-reuse-first" => "detective",
    "challenger-smallest-shippable" => "skeptic",
    "challenger-risk-first" => "skeptic",
    "challenger-reuse-first" => "skeptic",
    "plan-arbiter" => "arbiter"
  }

  # TEMPLATE name → persona — the fallback for a direct spawn / follow-up / non-catalog step.
  # Total over all 16 worker templates (the drift guard asserts equality with `Templates.names/0`).
  @template_persona %{
    "coder" => "craftsperson",
    "fixer" => "cynic",
    "test_runner" => "skeptic",
    "reviewer" => "skeptic",
    "docs_writer" => "teacher",
    "researcher" => "detective",
    "refactorer" => "cynic",
    "verifier" => "skeptic",
    "sketch_build" => "optimist",
    "sketch_reviewer" => "skeptic",
    "sketch_build_exec" => "optimist",
    "system_executor" => "teacher",
    "system_verifier" => "detective",
    "plan_drafter" => "detective",
    "plan_challenger" => "skeptic",
    "plan_arbiter" => "arbiter"
  }

  @doc """
  Pick the persona name for a worker: the `@stage_persona` entry for `catalog_stage_name` when
  present, else the `@template_persona` entry for `template_name`, else `""`. `catalog_stage_name`
  is `nil` for a direct spawn / follow-up / non-composer skill step.
  """
  @spec resolve(String.t() | nil, String.t()) :: String.t()
  def resolve(catalog_stage_name, template_name) when is_binary(template_name) do
    stage_persona(catalog_stage_name) || Map.get(@template_persona, template_name, "")
  end

  @doc "Render one persona's `## PSYCHOLOGY: <Display>` block (4 sections + the appended conflict rule), or `\"\"`."
  @spec render(String.t()) :: String.t()
  def render(persona) when is_binary(persona) do
    case Map.get(@personas, persona) do
      nil -> ""
      body -> render_block(persona, body)
    end
  end

  @doc "Resolve `catalog_stage_name`/`template_name` to a persona and render its block (`\"\"` when none)."
  @spec render_for(String.t() | nil, String.t()) :: String.t()
  def render_for(catalog_stage_name, template_name) when is_binary(template_name) do
    render(resolve(catalog_stage_name, template_name))
  end

  @doc "Every persona name — one per `priv/defaults/persona/*.md`; the universe `render/1` accepts."
  @spec names() :: [String.t()]
  def names, do: @persona_names

  @doc "Catalog stage names that carry a persona — public surface for the drift test."
  @spec stage_names() :: [String.t()]
  def stage_names, do: Map.keys(@stage_persona)

  @doc "Worker templates that carry a fallback persona — equals `Templates.names/0` (drift test)."
  @spec template_names() :: [String.t()]
  def template_names, do: Map.keys(@template_persona)

  defp stage_persona(name) when is_binary(name), do: Map.get(@stage_persona, name)
  defp stage_persona(_other), do: nil

  defp render_block(persona, body) do
    "## PSYCHOLOGY: " <>
      display(persona) <>
      "\n\n" <>
      body <>
      "\n\n## Conflict rule\n" <>
      @conflict_rule
  end

  defp display(persona) do
    persona
    |> String.replace("-", " ")
    |> String.capitalize()
  end
end
