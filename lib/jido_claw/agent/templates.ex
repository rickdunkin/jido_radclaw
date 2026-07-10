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

  ## `sandbox` policy (AR-8b)

  Every resolved template also carries a `:sandbox` key — the isolation tier
  this template's agents run under. `:none` (the default) is unchanged
  behavior; `:prototype` is the throwaway-sketch capability boundary, which
  drives four independent, structural enforcements (no external MCP tools, no
  remote file schemes, a validated `.prototypes/<uuid>/` sandbox root, and
  composer-private instantiation). `:docker` (AR-8b-2 F2) layers OS-level
  execution isolation on top of that same `.prototypes/<uuid>/` file jail: its
  `run_command` calls route into a Forge Docker microVM session instead of the
  host shell, so a sketch can actually *run* its tracer-bullet without the
  spawned shell escaping the jail. It shares `:prototype`'s capability boundary
  (no external MCP tools, remote schemes forbidden, validated sandbox root,
  composer-private), so `external_tools?/1` excludes it too. Like
  `forward_context`, the policy fails **closed**: a malformed *present* value
  sandboxes *harder* (to `:prototype`), never weaker, so a registry typo can
  only over-isolate. `external_tools?/1` is the derived reader the MCP
  `Consumer` gates on.

  ## `composer_private` policy (AR-8c)

  Every resolved template also carries a `:composer_private` boolean (default
  `false`). Composer-privacy is the single source of truth every *reachability*
  surface gates on — direct spawn, follow-up turn, handoff, handoff
  routing/recovery, and durable-metadata rehydration all refuse a
  composer-private template, so it is instantiable **only** through the
  composer's wave-builder path. A template is private when it is sandboxed
  (`sandbox/1 in [:prototype, :docker]`) **or** the explicit flag is set. The
  flag is the AR-8c channel: the `system_executor` / `system_verifier` workers
  run on the **real** machine (`sandbox: :none` — that is the point), so the
  sandbox-tier checks do not cover them; the flag keeps them un-spawnable past
  the safety gate and external-MCP-tool-free (`external_tools?/1` is
  `not composer_private?/1`) without sandboxing the host shell they must use.

  Two predicate shapes share one definition. `composer_private?/1` takes a
  **name**, resolves it through `get/1`, and is what the canonical surfaces
  (handoff, router, worker rehydration) and `external_tools?/1` gate on.
  `composer_private_template?/1` takes an **already-resolved map** — for the
  provider-seam surfaces (`spawn_agent` / `send_to_agent`, which launch through
  the configurable `:agent_templates` provider): they gate on the map their
  provider actually returned, never re-resolving the name against this canonical
  registry, so an overridden provider can't slip a private template past a guard
  that checked a different source. `composer_private?/1` delegates to it.

  ## `executor` binding (item 7, camus C1-1)

  Every resolved template carries an `:executor` key — WHERE this template's
  step work runs: `:in_process` (the default; today's in-process `Jido.AI`
  worker) or `{:forge, :fake | :shell | :codex | :claude_code | :custom}` (a
  real Forge session driven by `JidoClaw.Skills.Steps.ForgeExecutor`;
  `:fake`/`:shell` are PR-1, the vendor kinds `:codex`/`:claude_code` are
  PR-2, and `:custom` hydrates but stays refused at dispatch).
  `:executor_config` is the per-executor config map (hydrates to `%{}`):
  `{:forge, :shell}` uses `%{command: <binary>}` — the operator-declared
  shell command (the `verify_cmd` trust class; the stage *task* is never the
  command) — and the vendor kinds accept `workspace:` (`:repo` default |
  `:scratch` | `:none`), `access:` (`:read_only` default | `:write`) and
  `session_sandbox:` (`:local` default | `:docker`) — all three defaults
  written back into the hydrated config — plus optional
  `model`/`thinking_effort` (non-blank binaries) and `max_turns`/`timeout_ms`
  (positive integers), with any OTHER key refused. `access: :write` requires
  `session_sandbox: :docker` (PR-4's write⇒sandbox invariant: a write-capable
  vendor session must be docker-backed — write+local refuses at hydration),
  and `session_sandbox: :docker` dispatches the vendor session into an sbx
  microVM (the docker write build: `JidoClaw.Skills.Steps.ForgeExecutor` —
  `access: :write` there means an rw same-path repo mount and the runner's
  `:full` arm; the microVM is the boundary). A `workspace:` key on any
  non-vendor kind refuses too.

  Unlike the other policies, a malformed value **raises** `ArgumentError` (the
  `:max_iterations` loud posture, not the warn+fail-closed one): fc/ra/sandbox
  fail closed to a *tighter runnable* value, but for the executor the tight
  direction is *refuse to run* — silently mapping a typo to `:in_process`
  would hand execution to the wrong executor. A `{:forge, _}` executor also
  refuses a `:prototype`/`:docker` `:sandbox` policy (the in-process VFS-jail
  axis is meaningless for a forge session — the `session_sandbox:` knob lives
  in `:executor_config`, a different axis), and `{:forge, :shell}` without a
  non-empty `:executor_config` `command` refuses at hydration — the earliest,
  loudest point, before any Forge slot is consumed.
  """

  require Logger

  @templates %{
    "coder" => %{
      module: JidoClaw.Agent.Workers.Coder,
      description: "Full-capability coding agent with all tools",
      model: :fast
    },
    # AR-4: the self-heal fixer — a dedicated template (not a `coder` reuse) for its
    # DIFFERENT contract: `fixer_result/0`'s **required** `signals` (vs the coder's
    # optional `coder_result/0` one — self-reporting the touched domains IS the
    # fixer's whole job) plus its own `fixer_contract` doctrine slice (doctrine is
    # keyed by template name). See `JidoClaw.Agent.Workers.Fixer`.
    "fixer" => %{
      module: JidoClaw.Agent.Workers.Fixer,
      description: "Resolves open review findings, then self-reports the domains it touched",
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
    },
    "sketch_build" => %{
      module: JidoClaw.Agent.Workers.SketchBuild,
      description: "Builds a throwaway prototype in an isolated sandbox (file tools only)",
      model: :fast,
      # AR-8b: the capability boundary. Drives the four structural enforcements
      # (no external MCP tools, no remote file schemes, validated `.prototypes/`
      # root, composer-private instantiation). No reason to widen its scope.
      forward_context: :none,
      sandbox: :prototype
    },
    "sketch_reviewer" => %{
      module: JidoClaw.Agent.Workers.SketchReviewer,
      description: "Reviews a throwaway prototype in the sandbox (read-only, file tools)",
      model: :fast,
      # AR-8b-2 F1: the light-lens correctness reviewer. Same `:prototype`
      # capability boundary as `sketch_build` (runs jailed to the same
      # `.prototypes/<uuid>/` root), composer-private (`forward_context: :none`).
      forward_context: :none,
      sandbox: :prototype
    },
    "sketch_build_exec" => %{
      module: JidoClaw.Agent.Workers.SketchBuildExec,
      description: "Builds AND runs a throwaway prototype in a Docker-isolated sandbox",
      model: :fast,
      # AR-8b-2 F2: the exec sketch builder. Shares `sketch_build`'s
      # `.prototypes/<uuid>/` file jail, but its `run_command` routes into a Forge
      # Docker microVM (`sandbox: :docker`). `forward_context: {:only,
      # [:forge_session_key]}` (D5) keeps strict isolation but lets the session key
      # through to the jailed worker. `external_tools?/1` excludes `:docker`, so —
      # like `:prototype` — it gets no external MCP tools and is composer-private.
      forward_context: {:only, [:forge_session_key]},
      sandbox: :docker
    },
    # AR-8c: the two system-path workers. They run on the REAL machine
    # (`sandbox: :none` — that is the point), so the sandbox-tier privacy checks
    # do NOT cover them; instead they carry the explicit `composer_private: true`
    # flag, which `composer_private?/1` honours independently of `sandbox/1`. That
    # makes them (1) un-spawnable directly by the LLM (every reachability surface
    # routes through `composer_private?/1`, so the safety gate cannot be bypassed)
    # and (2) external-MCP-tool-free (`external_tools?/1` → `not composer_private?`),
    # a fixed, auditable toolset. The composer drives them through the wave-builder
    # path, which is unaffected. `forward_context: :none` keeps their scope tight.
    "system_executor" => %{
      module: JidoClaw.Agent.Workers.SystemExecutor,
      description: "Applies an approved change to the machine/environment (full mutating tools)",
      model: :fast,
      forward_context: :none,
      composer_private: true
    },
    "system_verifier" => %{
      module: JidoClaw.Agent.Workers.SystemVerifier,
      description:
        "Verifies a system/environment change took on the real machine (read + operator-approved run)",
      model: :fast,
      forward_context: :none,
      composer_private: true,
      # The reverse-verifier's verdict is authoritative for system routes and it
      # necessarily inspects the real host. Prompt-level "read-only" guidance is
      # not a capability boundary, so every shell command must clear a durable,
      # argument-bound operator approval before it can execute.
      require_approval: ["run_command"]
    },
    # AR-9: the three plan-wave workers (the multi-plan judge panel). Like the
    # AR-8c system workers they carry the explicit `composer_private: true` flag
    # with `sandbox: :none` (plain read-only tools; privacy rides the flag, not a
    # sandbox tier) — instantiable ONLY through the composer's wave-builder,
    # never by spawn/handoff, and external-MCP-tool-free. `forward_context:
    # :none` keeps their scope tight. The TIER is a STAGE declaration (PR-4: the
    # `plan-arbiter` stage runs `model: :capable, effort: :high`), so all three
    # TEMPLATES stay `model: :fast`.
    "plan_drafter" => %{
      module: JidoClaw.Agent.Workers.PlanDrafter,
      description:
        "Drafts ONE competing implementation plan under a stage-named bias (read-only)",
      model: :fast,
      forward_context: :none,
      sandbox: :none,
      composer_private: true
    },
    "plan_challenger" => %{
      module: JidoClaw.Agent.Workers.PlanChallenger,
      description:
        "Critiques ONE competing plan — blockers/concerns/strengths for the arbiter (read-only)",
      model: :fast,
      forward_context: :none,
      sandbox: :none,
      composer_private: true
    },
    "plan_arbiter" => %{
      module: JidoClaw.Agent.Workers.PlanArbiter,
      description: "Adjudicates the competing plans + critiques into a decision memo (read-only)",
      model: :fast,
      forward_context: :none,
      sandbox: :none,
      composer_private: true
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

  @doc """
  Returns the sorted names of the spawnable (non-composer-private) templates —
  the **single source** for every spawnable-list surface: the `spawn_agent` /
  `handoff` tool metadata (compile-time interpolated), the JIDO.md generator
  and drift check, and the system-prompt drift check.

  Classifies the **raw** `@templates` entries: the privacy fields (`:sandbox`,
  `:composer_private`) are static on the raw maps and
  `composer_private_template?/1` reads them defensively, so classification is
  identical to the hydrated path *without* hydration — hydration calls
  `module.strategy_opts()`, which at compile time would drag all 16 worker
  modules into the callers' compile deps. (Known nuance: a *malformed* sandbox
  value would classify public here vs private hydrated — the static registry
  is clean and pinned by tests.)
  """
  @spec spawnable_names() :: [String.t()]
  def spawnable_names do
    @templates
    |> Enum.reject(fn {_name, template} -> composer_private_template?(template) end)
    |> Enum.map(fn {name, _template} -> name end)
    |> Enum.sort()
  end

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

  @doc """
  Return the per-template `:sandbox` isolation tier
  (`:none` | `:prototype` | `:docker`).

  Resolves through `get/1` (honouring the `:agent_templates_override` test
  hook). Returns `:none` for an unknown template (e.g. `"main"`, not in
  `@templates`) — the unsandboxed default.
  """
  @spec sandbox(String.t()) :: :none | :prototype | :docker
  def sandbox(name) do
    case get(name) do
      {:ok, %{sandbox: s}} -> s
      _ -> :none
    end
  end

  @doc """
  True when a template's agents are **composer-private** — instantiable ONLY by
  the composer's wave-builder path, never by an LLM-driven reachability surface
  (direct spawn, follow-up turn, handoff, handoff recovery, or durable-metadata
  rehydration). Resolves the **name** through `get/1`, then delegates to the
  map-based `composer_private_template?/1` (the single definition of "private").
  An unknown template (`"main"`) resolves to `{:error, _}` → `false`.

  The name-based guard for the canonical reachability surfaces (handoff, router,
  worker rehydration) and `external_tools?/1` — all of which resolve through
  `JidoClaw.Agent.Templates`. The provider-seam surfaces (`spawn_agent` /
  `send_to_agent`) instead gate on `composer_private_template?/1` against the
  template their configurable provider actually returns.
  """
  @spec composer_private?(String.t()) :: boolean()
  def composer_private?(name) do
    case get(name) do
      {:ok, template} -> composer_private_template?(template)
      _ -> false
    end
  end

  @doc """
  True when an **already-resolved** template map is composer-private — sandboxed
  (`:sandbox in [:prototype, :docker]`) or carrying the explicit
  `:composer_private` flag. The map-shaped companion to `composer_private?/1`,
  for the reachability surfaces that resolve a template through a configurable
  provider (`spawn_agent` / `send_to_agent`'s `:agent_templates` seam): they must
  gate on the *resolved* map, not re-resolve the name against the canonical
  registry, or an overridden provider could launch a private template the
  name-based guard never saw.

  **The standalone definition** — it reads the `:sandbox` / `:composer_private`
  fields directly, NOT in terms of `external_tools?/1`, so the
  `external_tools?/1` → `not composer_private?/1` redefinition below cannot
  recurse. Reads keys defensively (`Map.get/3` defaults) so an un-hydrated
  provider map with no `:sandbox` / `:composer_private` keys defaults to public.
  Intentionally atom-shaped only (`:prototype` / `:docker` values, atom keys) —
  the provider contract is atom-keyed maps; it does not coerce string keys/values.
  """
  @spec composer_private_template?(map()) :: boolean()
  def composer_private_template?(template) when is_map(template) do
    Map.get(template, :sandbox, :none) in [:prototype, :docker] or
      Map.get(template, :composer_private, false) == true
  end

  @doc """
  False when the template forbids external (MCP) tools — i.e. it is
  `composer_private?/1` (sandboxed **or** explicitly composer-private). The MCP
  `Consumer` short-circuits such a template's tool set to `[]` on this, at attach
  and every reconcile tick. An unknown template (`"main"`) is not private, so
  `external_tools?/1` is `true`.
  """
  @spec external_tools?(String.t()) :: boolean()
  def external_tools?(name), do: not composer_private?(name)

  @doc """
  Validate + normalize an executor binding — a full `:executor` term plus its
  `executor_config` — against a resolved base template. The shared hydration
  entry BOTH config-sourced binding overlays reach: the `.jido/config.yaml`
  `review:` knob (item 7 PR-3, via `JidoClaw.Orchestration.ReviewIndependence`,
  which owns the YAML string-key boundary and wraps its closed-parsed vendor
  kind as `{:forge, kind}`) and the per-stage catalog `executor:` override
  (PR-4, camus OQ-1(b)).

  `:in_process` returns `{:ok, {:in_process, %{}}}` — the config is dropped
  (the in-process worker has no executor-config surface). A `{:forge, _}`
  term runs the same private validators template hydration runs (vendor
  defaults written back, the key whitelist, the write⇒docker invariant), but
  converts the hydration `ArgumentError` into an operator-facing
  `{:error, message}` — a config error refuses the run/step, never crashes
  the resolver. Any other term is an `{:error, _}` — bare vendor kinds must
  be wrapped by the caller. `base_template` is the ACTUAL hydrated template
  the binding will overlay — passed so `refuse_forge_sandbox_combo!/2` reads
  the real `:sandbox` value (a synthetic sandbox-less base would make that
  refusal vacuous). Returns `{:ok, {executor, normalized_config}}`.
  """
  @spec hydrate_executor_binding(term(), map(), map()) ::
          {:ok, {:in_process | {:forge, atom()}, map()}} | {:error, String.t()}
  def hydrate_executor_binding(:in_process, _config, base_template)
      when is_map(base_template) do
    {:ok, {:in_process, %{}}}
  end

  def hydrate_executor_binding({:forge, _kind} = executor, config, base_template)
      when is_map(base_template) do
    validate_executor_config!(config, base_template)
    {:ok, {executor, normalize_executor_config!(executor, config, base_template)}}
  rescue
    e in ArgumentError ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      {:error, Exception.message(e)}
  end

  def hydrate_executor_binding(executor, _config, _base_template) do
    {:error,
     "invalid executor #{inspect(executor)}: expected :in_process or " <>
       "{:forge, :fake | :shell | :codex | :claude_code | :custom}"}
  end

  defp hydrate_template(template) do
    template
    |> ensure_max_iterations()
    |> ensure_forward_context()
    |> ensure_require_approval()
    |> ensure_sandbox()
    |> ensure_composer_private()
    |> ensure_executor()
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

  defp ensure_sandbox(%{sandbox: s} = t), do: Map.put(t, :sandbox, validate_sandbox(s, t))
  defp ensure_sandbox(t), do: Map.put(t, :sandbox, :none)

  # Normalize `:composer_private` to a strict boolean (default `false`): only a
  # literal `true` is private (the AR-8c system workers). Reading the hydrated key
  # keeps `composer_private?/1` a single field read. An absent flag — every
  # non-system template — is `false`; sandboxed templates are still caught by the
  # `sandbox/1` arm of `composer_private?/1`, so this flag is the *additional*
  # `sandbox: :none`-but-private channel, not the sandbox channel.
  defp ensure_composer_private(%{composer_private: true} = t),
    do: Map.put(t, :composer_private, true)

  defp ensure_composer_private(t), do: Map.put(t, :composer_private, false)

  defp validate_sandbox(s, _t) when s in [:none, :prototype, :docker], do: s

  # Fail CLOSED to the most-restrictive value: a malformed *present* value
  # sandboxes harder (`:prototype`), never weaker — a static-registry typo can
  # only over-isolate, and that template's own tests catch it. (Contrast
  # `require_approval`, which fails to the global floor; here the safe failure
  # is *more* isolation, since `:prototype` strips capabilities rather than
  # adding gated ones.)
  defp validate_sandbox(other, t), do: warn_sandbox(other, t)

  defp warn_sandbox(bad, t) do
    Logger.warning(
      "[Templates] invalid :sandbox #{inspect(bad)} for " <>
        "#{inspect(Map.get(t, :module))}; failing closed to :prototype"
    )

    :prototype
  end

  # Item 7 (camus C1-1): the executor seam. Runs LAST in the hydration
  # pipeline (after `ensure_sandbox`, so the combo check reads the validated
  # `:sandbox` key). Malformed values RAISE — see the moduledoc for why this is
  # the `:max_iterations` loud posture, not the fc/ra/sandbox fail-closed one.
  # PR-2 (P2a): validators return the (possibly normalized) config and THAT is
  # written back — how the vendor `workspace: :repo` default actually lands in
  # the hydrated map; all other kinds return the config unchanged
  # (byte-identity preserved).
  defp ensure_executor(template) do
    executor = Map.get(template, :executor, :in_process)
    config = Map.get(template, :executor_config, %{})

    validate_executor_config!(config, template)
    normalized = normalize_executor_config!(executor, config, template)

    template
    |> Map.put(:executor, executor)
    |> Map.put(:executor_config, normalized)
  end

  # `:executor_config` must be a map for EVERY executor kind (later PRs must
  # not inherit ambiguous shapes), even `:in_process` (which ignores it).
  defp validate_executor_config!(config, _template) when is_map(config), do: :ok

  defp validate_executor_config!(config, t) do
    raise ArgumentError,
          "invalid :executor_config #{inspect(config)} for " <>
            "#{inspect(Map.get(t, :module))}: must be a map"
  end

  defp normalize_executor_config!(:in_process, config, t) do
    refuse_workspace_key!(:in_process, config, t)
    config
  end

  # A command-less shell template fails closed at hydration — the stage task is
  # never the command (AgentStep appends produces-instructions to tasks, and
  # `Runners.Shell` would silently default to `echo 'no command'`: exactly the
  # silent green this forecloses). A whitespace-only command is the same silent
  # green (`sh -c "   "` exits 0, empty output), so blank is rejected too;
  # `String.trim/1` is not guard-safe, hence the check lives in the body.
  defp normalize_executor_config!({:forge, :shell} = executor, config, t) do
    refuse_forge_sandbox_combo!(executor, t)
    refuse_workspace_key!(executor, config, t)

    command = Map.get(config, :command)

    if is_binary(command) and String.trim(command) != "" do
      config
    else
      raise ArgumentError,
            "executor {:forge, :shell} for #{inspect(Map.get(t, :module))} requires " <>
              ":executor_config %{command: <non-blank binary>}, got command: #{inspect(command)}"
    end
  end

  # PR-2/PR-4 vendor kinds: default `workspace: :repo` + `access: :read_only`
  # + `session_sandbox: :local` INTO the config (the self-describing hydrated
  # map — PR-1's ensure-default pattern, which also defeats present-nil reader
  # defaults), then validate the full vendor key surface.
  defp normalize_executor_config!({:forge, kind} = executor, config, t)
       when kind in [:codex, :claude_code] do
    refuse_forge_sandbox_combo!(executor, t)

    config =
      config
      |> Map.put_new(:workspace, :repo)
      |> Map.put_new(:access, :read_only)
      |> Map.put_new(:session_sandbox, :local)

    validate_vendor_config!(executor, config, t)
    config
  end

  # `:fake` hydrates freely; `:custom` hydrates but stays refused at dispatch
  # — the camus review.sh unknown-backend fail-closed discipline.
  defp normalize_executor_config!({:forge, kind} = executor, config, t)
       when kind in [:fake, :custom] do
    refuse_forge_sandbox_combo!(executor, t)
    refuse_workspace_key!(executor, config, t)
    config
  end

  defp normalize_executor_config!(other, _config, t) do
    raise ArgumentError,
          "invalid :executor #{inspect(other)} for #{inspect(Map.get(t, :module))}: expected " <>
            ":in_process or {:forge, :fake | :shell | :codex | :claude_code | :custom}"
  end

  # The vendor `executor_config` surface: the workspace / access /
  # session_sandbox enums (PR-4 named `:session_sandbox`, NOT `:sandbox` — the
  # template-policy `:sandbox` key is the in-process VFS-jail axis, refused by
  # `refuse_forge_sandbox_combo!/2`) + optional model / thinking_effort /
  # max_turns / timeout_ms, and NOTHING else.
  @vendor_config_keys [
    :workspace,
    :access,
    :session_sandbox,
    :model,
    :max_turns,
    :timeout_ms,
    :thinking_effort
  ]

  defp validate_vendor_config!(executor, config, t) do
    case Map.keys(config) -- @vendor_config_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown :executor_config keys #{inspect(unknown)} for #{inspect(executor)} on " <>
                "#{inspect(Map.get(t, :module))}: allowed keys are #{inspect(@vendor_config_keys)}"
    end

    # The three enum keys are always present here (`Map.fetch!` — the
    # normalize clause writes the defaults in before validating).
    validate_vendor_workspace!(executor, Map.fetch!(config, :workspace), t)
    validate_vendor_access!(executor, Map.fetch!(config, :access), t)
    validate_vendor_session_sandbox!(executor, Map.fetch!(config, :session_sandbox), t)
    validate_write_requires_sandbox!(executor, config, t)
    validate_vendor_binary!(executor, config, :model, t)
    validate_vendor_binary!(executor, config, :thinking_effort, t)
    validate_vendor_pos_int!(executor, config, :max_turns, t)
    validate_vendor_pos_int!(executor, config, :timeout_ms, t)
    :ok
  end

  defp validate_vendor_workspace!(_executor, workspace, _t)
       when workspace in [:repo, :scratch, :none],
       do: :ok

  defp validate_vendor_workspace!(executor, workspace, t) do
    raise ArgumentError,
          "invalid :executor_config workspace #{inspect(workspace)} for #{inspect(executor)} " <>
            "on #{inspect(Map.get(t, :module))}: expected :repo | :scratch | :none"
  end

  defp validate_vendor_access!(_executor, access, _t) when access in [:read_only, :write],
    do: :ok

  defp validate_vendor_access!(executor, access, t) do
    raise ArgumentError,
          "invalid :executor_config access #{inspect(access)} for #{inspect(executor)} " <>
            "on #{inspect(Map.get(t, :module))}: expected :read_only | :write"
  end

  defp validate_vendor_session_sandbox!(_executor, sandbox, _t) when sandbox in [:local, :docker],
    do: :ok

  defp validate_vendor_session_sandbox!(executor, sandbox, t) do
    raise ArgumentError,
          "invalid :executor_config session_sandbox #{inspect(sandbox)} for #{inspect(executor)} " <>
            "on #{inspect(Map.get(t, :module))}: expected :local | :docker"
  end

  # PR-4's write⇒sandbox invariant (camus C1-1 sketch (d)): a write-capable
  # vendor session must be docker-backed — `{:write, :local}` refuses at
  # hydration (both keys are always present; the defaults were written in).
  defp validate_write_requires_sandbox!(executor, config, t) do
    case {Map.fetch!(config, :access), Map.fetch!(config, :session_sandbox)} do
      {:write, :local} ->
        raise ArgumentError,
              "access: :write requires session_sandbox: :docker for #{inspect(executor)} on " <>
                "#{inspect(Map.get(t, :module))} — a write-capable vendor session must be " <>
                "docker-backed"

      _valid_combo ->
        :ok
    end
  end

  # Optional keys are strict when PRESENT: a present-nil / blank / wrong-typed
  # value raises rather than silently riding into the runner config.
  defp validate_vendor_binary!(executor, config, key, t) do
    case Map.fetch(config, key) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      {:ok, value} ->
        raise ArgumentError,
              "invalid :executor_config #{key} #{inspect(value)} for #{inspect(executor)} on " <>
                "#{inspect(Map.get(t, :module))}: expected a non-blank binary"
    end
  end

  defp validate_vendor_pos_int!(executor, config, key, t) do
    case Map.fetch(config, key) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value > 0 ->
        :ok

      {:ok, value} ->
        raise ArgumentError,
              "invalid :executor_config #{key} #{inspect(value)} for #{inspect(executor)} on " <>
                "#{inspect(Map.get(t, :module))}: expected a positive integer"
    end
  end

  defp refuse_workspace_key!(executor, config, t) do
    if Map.has_key?(config, :workspace) do
      raise ArgumentError,
            ":executor_config workspace for #{inspect(Map.get(t, :module))} is only valid on " <>
              "{:forge, :codex | :claude_code}, got it on #{inspect(executor)}"
    end

    :ok
  end

  # A `{:forge, _}` executor with a `:prototype`/`:docker` sandbox policy would
  # leave the in-process VFS-jail axis silently dead on a forge session — refuse
  # the combo. The forge-session axis is `:executor_config` `session_sandbox:`.
  defp refuse_forge_sandbox_combo!(executor, t) do
    case Map.get(t, :sandbox, :none) do
      :none ->
        :ok

      tier ->
        raise ArgumentError,
              "executor #{inspect(executor)} for #{inspect(Map.get(t, :module))} cannot " <>
                "combine with sandbox: #{inspect(tier)} — the in-process VFS-jail axis " <>
                "does not apply to a forge session"
    end
  end

  defp module_max_iterations(module) do
    Keyword.fetch!(module.strategy_opts(), :max_iterations)
  end
end
