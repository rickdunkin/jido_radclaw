defmodule JidoClaw.Agent.Templates do
  @moduledoc """
  Registry of agent templates for the swarm system.

  Each template maps a name to a configuration that specifies
  which worker agent module to use and its operational parameters.
  """

  @templates %{
    "coder" => %{
      module: JidoClaw.Agent.Workers.Coder,
      description: "Full-capability coding agent with all tools",
      model: :fast
    },
    "test_runner" => %{
      module: JidoClaw.Agent.Workers.TestRunner,
      description: "Runs tests and reports results (read-only)",
      model: :fast
    },
    "reviewer" => %{
      module: JidoClaw.Agent.Workers.Reviewer,
      description: "Reviews code changes for bugs and style issues (read-only)",
      model: :fast
    },
    "docs_writer" => %{
      module: JidoClaw.Agent.Workers.DocsWriter,
      description: "Writes documentation and comments",
      model: :fast
    },
    "researcher" => %{
      module: JidoClaw.Agent.Workers.Researcher,
      description: "Explores and analyzes codebase structure",
      model: :fast
    },
    "refactorer" => %{
      module: JidoClaw.Agent.Workers.Refactorer,
      description: "Refactors code with full tool access",
      model: :fast
    },
    "verifier" => %{
      module: JidoClaw.Agent.Workers.Verifier,
      description:
        "Interactive verification — reads code, runs tests/commands. Returns a structured verdict (`pass`/`fail`), confidence (`low`/`medium`/`high`), and short reasoning.",
      model: :fast
    }
  }

  @doc """
  Returns the config map for a named template.

  Consults `Application.get_env(:jido_claw, :agent_templates_override, %{})`
  before the static `@templates` map. The override hook exists for tests
  that need to register a stub template (see
  `test/jido_claw/workflows/scope_propagation_test.exs`); production code
  never sets the override, so the static map is always consulted.

  This asymmetry — `get/1` honours the override but `list/0`, `names/0`,
  and `exists?/1` do not — is intentional. Listing/existence checks run on
  startup paths and tests don't depend on them recognising stub templates.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get(name) do
    override = Application.get_env(:jido_claw, :agent_templates_override, %{})

    case Map.get(override, name) || Map.get(@templates, name) do
      nil -> {:error, "Unknown template '#{name}'. Available: #{Enum.join(names(), ", ")}"}
      template -> {:ok, hydrate_template(template)}
    end
  end

  @doc "Returns all templates as a map keyed by name."
  @spec list() :: %{String.t() => map()}
  def list, do: Map.new(@templates, fn {name, template} -> {name, hydrate_template(template)} end)

  @doc "Returns all template names."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@templates)

  @doc "Returns true if a template with the given name exists."
  @spec exists?(String.t()) :: boolean()
  def exists?(name), do: Map.has_key?(@templates, name)

  defp hydrate_template(%{max_iterations: max_iterations} = template)
       when is_integer(max_iterations) and max_iterations > 0 do
    template
  end

  defp hydrate_template(%{module: module} = template) do
    Map.put(template, :max_iterations, module_max_iterations(module))
  end

  defp module_max_iterations(module) do
    module.strategy_opts()
    |> Keyword.fetch!(:max_iterations)
  end
end
