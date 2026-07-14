defmodule JidoClaw.Tools.RunSkill do
  # The {code, message, details} map is the LLM-facing wire-error contract
  # (shared with JidoClaw.Tools.Error) — an explicit API surface, not
  # incidental duplication.
  # reach:disable-for-this-file fixed_shape_map
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
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Skills.Compiler
  alias JidoClaw.Tools.Error
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.Tools.OutputLimit

  # 256-byte identifier bound for request-input names in messages/details
  # (UTF-8-safe: a split multibyte character must not plant invalid text
  # ahead of OutputRedaction's regex path).
  @identifier_bytes 256

  # reason_head caps: a bounded dot-joined path of the reason's leading
  # atoms — depth 4, 128 bytes.
  @reason_head_max_depth 4
  @reason_head_max_bytes 128

  @impl Jido.Action
  def run(params, context) do
    MCPScope.wrap(:run_skill, params, context, fn enriched -> do_run(params, enriched) end)
  end

  defp do_run(params, context) do
    skill_name = params.skill
    extra_context = Map.get(params, :context, "") || ""
    tool_context = Map.get(context, :tool_context, %{}) || %{}
    project_dir = Map.get(tool_context, :project_dir) || File.cwd!()
    scope = scope_context(tool_context)

    with {:ok, skill} <- fetch_skill(skill_name, project_dir),
         {:ok, reactor} <- Compiler.compile(skill),
         {:ok, tenant} <- resolve_tenant(tool_context),
         actor = resolve_actor(tool_context, tenant),
         {:ok, value, _run} <-
           ReactorRunner.run(reactor, %{extra_context: extra_context},
             tenant: tenant,
             actor: actor,
             name: skill.name,
             async?: true,
             definition_hash: DefinitionFingerprint.for_skill(skill),
             deadline: skill.deadline,
             context: scope
           ) do
      {:ok, value}
    else
      # Missing tenant — never call Actor.system(nil); fail cleanly.
      {:error, :missing_tenant} ->
        {:error, :missing_tenant}

      # Unknown skill: typed envelope + the available-skills hint (PD1-2).
      {:error, :unknown_skill} ->
        {:error, unknown_skill_envelope(skill_name)}

      # ReactorRunner's run-carrying error envelope: normalize the open
      # runner-reason set at this tool boundary (plan §2) — :cancelled →
      # :skill_cancelled, everything else → :skill_run_failed with the
      # bounded original reason under details.reason.
      {:error, reason, _run} ->
        {:error, runner_failure_envelope(skill_name, reason)}

      # Compiler.compile error — deliberate open forwarder; the served-MCP
      # boundary fallback covers genuinely unforeseen atoms.
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Skills.get's only error today is the not-found string; map it to the
  # typed :unknown_skill marker so the else arms can distinguish it from
  # Compiler failures.
  defp fetch_skill(name, project_dir) do
    case JidoClaw.Skills.get(name, project_dir) do
      {:ok, skill} -> {:ok, skill}
      {:error, _not_found} -> {:error, :unknown_skill}
    end
  end

  @doc """
  Test seam: the typed `:unknown_skill` envelope (PD1-2) — the requested
  name bounded to the 256-byte identifier bound, `retry: false`, and the
  canonicalized available-skills hint from `JidoClaw.Skills.list/0`.
  """
  @spec unknown_skill_envelope(String.t()) :: map()
  def unknown_skill_envelope(skill_name) do
    bounded = bound_identifier(skill_name)

    %{
      code: :unknown_skill,
      message: "Skill '#{bounded}' not found.",
      details:
        Error.hint_available(
          JidoClaw.Skills.list(),
          %{retry: false, skill: bounded}
        )
    }
  end

  @doc """
  Test seam: normalize one ReactorRunner failure reason into the typed
  envelope (plan §2) — `:cancelled` → `:skill_cancelled`, everything else →
  `:skill_run_failed` with the bounded original reason under
  `details.reason`. Both envelopes carry `retry: false` (ReactorRunner
  mints a fresh run per call — an unflagged failure would re-launch the
  workflow inside the same call), plus the `skill`/`reason_head` identity
  discriminators.
  """
  @spec runner_failure_envelope(String.t(), term()) :: map()
  def runner_failure_envelope(skill_name, :cancelled) do
    %{
      code: :skill_cancelled,
      message: "Skill '#{bound_identifier(skill_name)}' run was cancelled.",
      details: runner_details(skill_name, :cancelled, %{})
    }
  end

  def runner_failure_envelope(skill_name, reason) do
    head = reason_head(reason)
    suffix = if head == "", do: "", else: " (#{head})"

    %{
      code: :skill_run_failed,
      message: "Skill '#{bound_identifier(skill_name)}' run failed#{suffix}.",
      details: runner_details(skill_name, reason, %{reason: bounded_reason(reason)})
    }
  end

  # Pinned pipeline (plan §2): budgeted JsonSafe first (a tripped budget
  # yields a constant truncation marker, never a full walk), then
  # sanitize_details, THEN the three discriminators — sanitize's truncation
  # rewrite replaces the map and would otherwise drop them. Both envelopes
  # are non-retryable in-call: ReactorRunner mints a fresh run per call, so
  # an unflagged failure would re-launch the workflow inside the same call.
  defp runner_details(skill_name, reason, base) do
    base
    |> Error.sanitize_details()
    |> Map.put(:retry, false)
    |> Map.put(:skill, bound_identifier(skill_name))
    |> Map.put(:reason_head, reason_head(reason))
  end

  defp bounded_reason(reason) do
    case JsonSafe.encode_bounded(reason) do
      {:ok, safe, _bytes} ->
        safe

      {:budget_exceeded, %{observed_at_least: observed}} ->
        %{"truncated" => true, "observed_at_least" => observed}
    end
  end

  # A bounded dot-joined path of the reason's LEADING ATOMS, computed
  # PRE-JsonSafe ({:exit, :timeout} → "exit.timeout") — non-sensitive by
  # construction (atoms are code-level identifiers, never user data).
  defp reason_head(reason) do
    reason
    |> leading_atoms(@reason_head_max_depth)
    |> Enum.map_join(".", &Atom.to_string/1)
    |> bound_reason_head()
  end

  defp leading_atoms(_term, 0), do: []

  defp leading_atoms(atom, _depth) when is_atom(atom) and not is_nil(atom), do: [atom]

  defp leading_atoms(tuple, depth) when is_tuple(tuple) and tuple_size(tuple) >= 1 do
    case elem(tuple, 0) do
      atom when is_atom(atom) and not is_nil(atom) ->
        if tuple_size(tuple) >= 2 do
          [atom | leading_atoms(elem(tuple, 1), depth - 1)]
        else
          [atom]
        end

      _non_atom ->
        []
    end
  end

  defp leading_atoms(_term, _depth), do: []

  defp bound_reason_head(head) when byte_size(head) > @reason_head_max_bytes do
    head
    |> binary_part(0, @reason_head_max_bytes)
    |> OutputLimit.valid_utf8_prefix()
  end

  defp bound_reason_head(head), do: head

  defp bound_identifier(name) when is_binary(name) and byte_size(name) > @identifier_bytes do
    name
    |> binary_part(0, @identifier_bytes)
    |> OutputLimit.valid_utf8_prefix()
  end

  defp bound_identifier(name) when is_binary(name), do: name

  @doc """
  Test seam: pluck the canonical scope keys out of `tool_context` for
  forwarding into the compiled reactor's context (and from there into every
  spawned child agent). The full set (minus `:agent_id`, which each step
  assigns) propagates so child agents inherit the parent's
  tenant/session/workspace/user UUIDs and `:actor` for tenant-actor policy
  enforcement on Ash writes/reads.
  """
  @spec scope_context(map()) :: map()
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
