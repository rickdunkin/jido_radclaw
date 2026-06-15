defmodule JidoClaw.Agent.Templates do
  @moduledoc """
  Registry of agent templates for the swarm system.

  Each template maps a name to a configuration that specifies
  which worker agent module to use and its operational parameters.

  ## `forward_context` policy

  Every resolved template carries a `:forward_context` key — the
  `JidoClaw.ToolContext.visibility/0` policy applied when this template's
  child agents are built (spawn / follow-up / workflow-step). It defaults
  to `:public` (forward the parent's full scope; zero behavior change),
  and operators tighten an individual template by adding
  `forward_context: {:only, [...]}` / `{:except, [...]}` / `:none` to its
  map. Policy keys are atoms drawn from
  `JidoClaw.ToolContext.policy_controlled_keys/0`; `hydrate_template/1`
  validates the field and fails closed to `:none` (with a warning) on any
  unknown key or malformed value, so a typo can never silently widen scope.

  ## `require_approval` policy

  Every resolved template also carries a `:require_approval` key — a list of
  native tool names this template's agents must clear a human approval for,
  **in addition to** the global `:tool_approval, :require` floor. It can only
  *add* gated tools, never remove them; `:all` gates every tool the template
  can call. The default is `[]` (no per-template gating; zero behavior
  change). `JidoClaw.Security.ToolApproval` reads it for any templated-agent
  surface (handoff / spawn / follow-up / skill step).

  Unlike `forward_context` (which fails closed to `:none`), a malformed
  `:require_approval` falls back to `[]` — the **global floor**, not a
  per-layer fail-closed. This is deliberate: the genuinely dangerous
  capabilities are already covered by the global require-list, so failing the
  per-template overlay *open* (it adds nothing) keeps the system safe, whereas
  failing it to `:all` would gate every benign tool (`read_file`…) for that
  worker — a self-inflicted DoS with no marginal security. `:all` stays a
  valid *explicit* operator value; only the malformed/typo fallback is `[]`.
  """

  require Logger

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
      description: "Explores and analyzes codebase structure, and researches the web (read-only)",
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

  @doc """
  Return the per-template `:require_approval` policy — additional native tools
  this template's agents must clear a human approval for, on top of the global
  require-list. `:all` gates every tool; a list names specific tools.

  Resolves through `get/1` (honouring the `:agent_templates_override` test
  hook). Returns `[]` for an unknown template (e.g. `"main"`, not in
  `@templates`) — also the floor a malformed policy falls back to.
  """
  @spec require_approval(String.t()) :: [String.t()] | :all
  def require_approval(name) do
    case get(name) do
      {:ok, %{require_approval: ra}} -> ra
      _ -> []
    end
  end

  defp hydrate_template(template) do
    template
    |> ensure_max_iterations()
    |> ensure_forward_context()
    |> ensure_require_approval()
  end

  # Two clauses, NO catch-all — preserves today's behavior: a template
  # lacking both :module and a valid :max_iterations still raises
  # FunctionClauseError (loud), rather than returning a partially-hydrated
  # map that crashes less clearly later.
  defp ensure_max_iterations(%{max_iterations: m} = t) when is_integer(m) and m > 0, do: t

  defp ensure_max_iterations(%{module: module} = t),
    do: Map.put(t, :max_iterations, module_max_iterations(module))

  defp ensure_forward_context(%{forward_context: fc} = t),
    do: Map.put(t, :forward_context, validate_fc(fc, t))

  defp ensure_forward_context(t), do: Map.put(t, :forward_context, :public)

  defp validate_fc(fc, _t) when fc in [:public, :none], do: fc

  # Every key must be a known policy-controlled key. This single membership
  # check rejects BOTH string keys ({:only, ["user_id"]}) and typo'd atoms
  # ({:except, [:usr_id]}) — the latter would otherwise fail OPEN for
  # :except. Fail closed to :none + warn on any unknown key.
  defp validate_fc({mode, keys} = fc, t) when mode in [:only, :except] and is_list(keys) do
    allowed = JidoClaw.ToolContext.policy_controlled_keys()
    if Enum.all?(keys, &(&1 in allowed)), do: fc, else: warn_fc(fc, t)
  end

  defp validate_fc(other, t), do: warn_fc(other, t)

  defp warn_fc(bad, t) do
    Logger.warning(
      "[Templates] invalid :forward_context #{inspect(bad)} for " <>
        "#{inspect(Map.get(t, :module))}; failing closed to :none"
    )

    :none
  end

  defp ensure_require_approval(%{require_approval: ra} = t),
    do: Map.put(t, :require_approval, validate_ra(ra, t))

  defp ensure_require_approval(t), do: Map.put(t, :require_approval, [])

  # `:all` and a list of non-empty binaries are the only valid shapes. Anything
  # else (non-list, non-binary or empty-string element, atom footgun) warns and
  # falls back to `[]` — the GLOBAL FLOOR, not a per-layer fail-closed (see the
  # moduledoc for why the asymmetry with forward_context is deliberate).
  defp validate_ra(:all, _t), do: :all

  defp validate_ra(list, t) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")), do: list, else: warn_ra(list, t)
  end

  defp validate_ra(other, t), do: warn_ra(other, t)

  defp warn_ra(bad, t) do
    Logger.warning(
      "[Templates] invalid :require_approval #{inspect(bad)} for " <>
        "#{inspect(Map.get(t, :module))}; falling back to the global floor ([])"
    )

    []
  end

  defp module_max_iterations(module) do
    Keyword.fetch!(module.strategy_opts(), :max_iterations)
  end
end
