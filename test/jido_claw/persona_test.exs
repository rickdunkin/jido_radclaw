defmodule JidoClaw.PersonaTest do
  @moduledoc """
  Pure registry contract for `JidoClaw.Persona` (AR-6). No DB — personas are
  compile-time priv-file text and the stage/template→persona maps are in-code.
  Mirrors `doctrine_test.exs`.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Persona
  alias JidoClaw.RouteComposer.Catalog

  # The conflict-rule literal is hardcoded HERE (not a reference to Persona's private
  # @conflict_rule) so the test proves the rendered PUBLIC contract — a drift in the
  # module attribute itself would fail this, not silently track it.
  @expected_rule "Your role contract is mandatory; persona is advisory voice. " <>
                   "On conflict, the role and the codebase win."

  describe "render/1" do
    test "every persona renders the PSYCHOLOGY header, a Belief section, and the conflict rule" do
      for name <- Persona.names() do
        block = Persona.render(name)

        assert block =~ "## PSYCHOLOGY:"
        assert block =~ "## Belief"
        assert block =~ "## Conflict rule"
        # The advisory safety valve is byte-identical across all 9 and always last.
        assert String.ends_with?(block, @expected_rule),
               "#{name} block must end with the single-sourced conflict rule"
      end
    end

    test "the display name spaces and capitalizes the filename stem" do
      assert Persona.render("user-advocate") =~ "## PSYCHOLOGY: User advocate"
      assert Persona.render("cynic") =~ "## PSYCHOLOGY: Cynic"
    end

    test "an unknown persona renders \"\"" do
      assert Persona.render("does_not_exist") == ""
    end
  end

  describe "resolve/2 — stage-first, template-fallback" do
    test "the four reviewer stages over the single reviewer template get DISTINCT voices" do
      assert Persona.resolve("security-reviewer", "reviewer") == "defender"
      assert Persona.resolve("quality-reviewer", "reviewer") == "craftsperson"
      assert Persona.resolve("correctness-reviewer", "reviewer") == "skeptic"
      assert Persona.resolve("architecture-reviewer", "reviewer") == "pragmatist"
    end

    test "a nil stage falls through to the template persona" do
      assert Persona.resolve(nil, "reviewer") == "skeptic"
      assert Persona.resolve(nil, "coder") == "craftsperson"
    end

    test "an UNMAPPED stage name falls through to the template persona (finding #1)" do
      # A skill step a user happens to name like a catalog stage must NOT inherit a stage
      # persona — only the wave-builder sets `catalog_stage_name`, and only to real stages.
      assert Persona.resolve("not-a-real-stage", "reviewer") == "skeptic"
    end

    test "neither a mapped stage nor a mapped template resolves to \"\"" do
      assert Persona.resolve("not-a-real-stage", "not_a_template") == ""
      assert Persona.resolve(nil, "not_a_template") == ""
    end
  end

  describe "render_for/2" do
    test "renders the stage-resolved block (Defender for security-reviewer/reviewer)" do
      assert Persona.render_for("security-reviewer", "reviewer") =~ "## PSYCHOLOGY: Defender"
    end

    test "renders the template-fallback block when the stage is nil" do
      assert Persona.render_for(nil, "reviewer") =~ "## PSYCHOLOGY: Skeptic"
    end
  end

  describe "registry-drift guard" do
    test "every persona stage name is a real catalog stage" do
      assert Enum.all?(Persona.stage_names(), &Catalog.valid?/1)
    end

    test "the persona template set equals the worker template set, minus main" do
      # A future worker added without a persona mapping (or vice versa) fails here.
      assert Enum.sort(Persona.template_names()) == Enum.sort(Templates.names())
      refute "main" in Persona.template_names()
      assert Enum.all?(Persona.template_names(), &Templates.exists?/1)
    end

    test "every mapped stage and template renders a non-empty persona block" do
      for stage <- Persona.stage_names() do
        # template is irrelevant when the stage maps; pass a real one for the spec guard.
        assert Persona.render_for(stage, "reviewer") != ""
      end

      for template <- Persona.template_names() do
        assert Persona.render_for(nil, template) != ""
      end
    end
  end
end
