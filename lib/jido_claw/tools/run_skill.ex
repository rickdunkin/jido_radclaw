defmodule JidoClaw.Tools.RunSkill do
  @moduledoc """
  Runs a named multi-step skill by compiling its YAML to a Reactor and running
  it through the durable `WorkflowRun` envelope.

  The cached skill (`.jido/skills/*.yaml`) is compiled to a `%Reactor{}` by
  `JidoClaw.Skills.Compiler` and executed via
  `JidoClaw.Orchestration.ReactorRunner`, so every chat-initiated skill run
  gains a `WorkflowRun` row + event timeline + dashboard visibility + crash
  recovery — uniformly with developer-authored reactors. The compiler picks the
  construction from the skill's mode (`:sequential` | `:dag` | `:iterative`);
  the reactor's terminal `CollectStep` produces the tool's result map.
  """

  use JidoClaw.Tools.Action,
    name: "run_skill",
    description:
      "Run a named multi-step skill that orchestrates multiple agents. Each step spawns an agent; the skill is compiled to a Reactor and every run is a durable WorkflowRun (tracked in /workflows). Use /skills to list available skills.",
    category: "skills",
    tags: ["skills", "exec"],
    output_schema: [
      skill: [type: :string, required: true],
      steps_completed: [type: :integer, required: true],
      synthesis_prompt: [type: :string],
      results: [type: :string, required: true],
      message: [type: :string, required: true]
    ],
    schema: [
      skill: [
        type: :string,
        required: true,
        doc: "Skill name to run (e.g. full_review, refactor_safe, explore_codebase)"
      ],
      context: [
        type: :string,
        required: false,
        doc: "Additional context or instructions appended to each step's task"
      ]
    ]

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Skills.Compiler
  alias JidoClaw.Tools.MCPScope

  @impl true
  def run(params, context) do
    MCPScope.wrap(:run_skill, params, context, fn enriched -> do_run(params, enriched) end)
  end

  defp do_run(params, context) do
    skill_name = params.skill
    extra_context = Map.get(params, :context, "") || ""
    tool_context = Map.get(context, :tool_context, %{}) || %{}
    project_dir = Map.get(tool_context, :project_dir) || File.cwd!()
    scope = scope_context(tool_context)

    with {:ok, skill} <- JidoClaw.Skills.get(skill_name, project_dir),
         {:ok, reactor} <- Compiler.compile(skill),
         {:ok, tenant} <- resolve_tenant(tool_context),
         actor = resolve_actor(tool_context, tenant),
         {:ok, value, _run} <-
           ReactorRunner.run(reactor, %{extra_context: extra_context},
             tenant: tenant,
             actor: actor,
             name: skill.name,
             async?: true,
             context: scope
           ) do
      {:ok, value}
    else
      # Missing tenant — never call Actor.system(nil); fail cleanly.
      {:error, :missing_tenant} -> {:error, :missing_tenant}
      # ReactorRunner's run-carrying error envelope.
      {:error, reason, _run} -> {:error, reason}
      # Skills.get / Compiler.compile error.
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Test seam: pluck the canonical scope keys out of `tool_context` for
  forwarding into the compiled reactor's context (and from there into every
  spawned child agent). The full set (minus `:agent_id`, which each step
  assigns) propagates so child agents inherit the parent's
  tenant/session/workspace/user UUIDs and `:actor` for tenant-actor policy
  enforcement on Ash writes/reads.
  """
  def scope_context(tool_context) when is_map(tool_context) do
    Map.take(tool_context, [
      :tenant_id,
      :session_id,
      :session_uuid,
      :workspace_id,
      :workspace_uuid,
      :project_dir,
      :user_id,
      :actor
    ])
  end

  # Tenant is required for the WorkflowRun. `MCPScope.wrap/4` injects the MCP
  # default scope (which carries tenant_id) and the chat main agent threads its
  # own; if it's genuinely absent, fail cleanly rather than call
  # `Actor.system(nil)`.
  defp resolve_tenant(tool_context) do
    case Map.get(tool_context, :tenant_id) do
      tenant when is_binary(tenant) and tenant != "" -> {:ok, tenant}
      _ -> {:error, :missing_tenant}
    end
  end

  defp resolve_actor(tool_context, tenant) do
    Map.get(tool_context, :actor) || Actor.system(tenant)
  end
end
