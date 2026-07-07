defmodule JidoClaw.Orchestration.ReviewIndependence do
  @moduledoc """
  Cross-vendor review configuration + the "no agent grades its own work"
  invariant (next-ten item 7 PR-3 — camus C1-1's borrowable invariant,
  enforced at resolution rather than camus's hardcoded Claude→Codex
  topology).

  ## The knob (`.jido/config.yaml`)

      review:
        executor: codex            # or claude_code
        executor_config:           # optional — the PR-1/PR-2 vendor surface
          workspace: repo
          model: gpt-5.2
        independence: strict       # default; `degraded` opts into
                                   # same-vendor review

  The `review:` section binds ONLY the `"reviewer"` template (the code-route
  lens stages) to a vendor executor — template-name-keyed, never per-stage
  (the pinned non-goal). Two consumers read it through this module:

    * the composer at launch (`check_route/2` in `RouteComposer.init/1`) —
      the invariant: a review-lens stage whose effective executor is a vendor
      CLI sharing a producer's provider identity is HELD (fail closed, the
      camus `review.sh` unknown-backend posture) unless the operator opted
      into `independence: degraded`;
    * `AgentRunner` at dispatch (`apply_executor/3`) — the overlay that
      actually routes a `"reviewer"` step to the configured vendor.

  Absent section ⇒ byte-identical to today at both seams.

  ## Parsing posture (the `Verify.Config` precedent)

  Strict at the YAML boundary: a non-map `review:` section, an unknown
  top-level key, `executor_config` without `executor`, an unknown executor
  value, a non-map `executor_config`, or an unknown `executor_config` key all
  refuse LOUDLY — never a silent fall-through to today's in-process default
  (a typo must not read as "unconfigured"). The `executor` value goes through
  a CLOSED string parser and `executor_config` keys through a closed literal
  translation map — never `String.to_atom/1` on config input. A malformed
  `independence:` is a loud error too, deliberately in BOTH directions: a
  silent `:strict` would produce a hold whose remedy says "set the thing you
  think you already set", and the error can never silently enable
  same-vendor review. The section validates as a WHOLE at every entry point
  (`validate_section/1` inside `load_review`): the binding read refuses a
  malformed `independence:` too, so the dispatch seam never honors a partial
  section. Full PR-1 hydration validation happens at the call sites via
  `JidoClaw.Agent.Templates.hydrate_review_binding/3` (against the resolved
  base template, so the forge/sandbox combo check is real).

  Strictness is FILE-level too: config reads go through the fail-closed
  `JidoClaw.Config.read_user_config/1`, so an unreadable or unparseable
  `.jido/config.yaml` refuses loudly at both seams — only a missing file
  (`:enoent`) reads as "nothing configured" (`JidoClaw.Config.load/1` keeps
  its tolerant collapse for boot/wizard surfaces). And present-null ≠ absent
  (the ToolContext trap, YAML edition): a blank key parses present-nil
  (`review:` alone ⇒ `%{"review" => nil}`), so all four — the `review:`
  section itself, `executor:`, `executor_config:`, `independence:` — are
  read via `Map.fetch` and a present-null value refuses loudly rather than
  silently reading as unconfigured.

  ## Vendor identity

  `vendor_of/2` maps an executor binding to an EXPLICIT provider identity —
  never a closed atom set, so `ollama:`/`openrouter:` in-process producers
  are determinate and non-colliding: `{:forge, :codex}` →
  `{:provider, "openai"}`, `{:forge, :claude_code}` →
  `{:provider, "anthropic"}`, `{:forge, :shell | :fake | :custom}` → `:none`
  (non-LLM/test executors never collide). `:in_process` resolves its model
  tier through `Jido.AI.resolve_model/1` — only a binary `"provider:model"`
  spec yields `{:provider, prefix}`; an unknown alias (rescued
  `ArgumentError`) or a non-binary alias target (tuple/map/LLMDB specs are
  legal `:jido_ai, :model_aliases` values) is `:indeterminate`, which the
  invariant treats as a collision (cannot prove independence — fail closed).
  Comparison is provider-identity equality; a proxy provider (openrouter
  fronting anthropic) reads as its own vendor — the documented
  provider-prefix approximation, operator-owned.

  ## Whole-catalog scope

  `check_route/2` walks EVERY review-lens `{:worker_template, _}` stage in
  the catalog (the `{:verify, _}` stage is deterministic — no vendor): the
  check runs at launch, where recovery cannot yet see `live` routes, and a
  globally-broken review knob surfacing on the next launch of ANY route is a
  feature. Because that means a talk/sketch/system request can be refused by
  a code-route pairing, the refusal's `details.scope` is `:catalog` and the
  remedy says so explicitly.

  ## Nil-safety (the byte-identical guarantee)

  Every config-reading entry point treats a nil/blank/non-binary project dir
  as "no config available": knob absent, mode `:strict`, NO
  `JidoClaw.Config.read_user_config/1` call (whose `Path.join` would crash
  on nil — the composer's restored context can be fallback-empty, the
  `verify_project_dir/1` precedent). Deliberately NOT a `File.cwd!()`
  fallback: cwd-dependent config would break test determinism. The invariant
  still evaluates template/override-resolved executors on such runs — only
  the config knob read is skipped.

  ## Test-seam precedence

  When `:agent_templates_override` (the documented test-only seam) contains
  a template name, the knob does NOT overlay — the override map is
  authoritative including its executor, in both `apply_executor/3` and
  `check_route/2`'s effective-executor resolution. This keeps an operator's
  local `.jido/config.yaml` `review:` section from hijacking test
  determinism (`composer_vendor_case_test` arms its own reviewer binding
  with `project_dir: File.cwd!()`).

  Documented residuals: mid-run `.jido/config.yaml` edits are not re-checked
  (camus C2-7 class — the `verify_cmd` precedent); boot recovery of a
  deterministically-held catalog leaves the parent `:running` and retries
  next boot (the existing invalid-catalog behavior).
  """

  require Logger

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Config, as: AppConfig
  alias JidoClaw.RouteComposer.Graph
  alias JidoClaw.RouteComposer.Stage

  # The single template the knob binds (operator decision 1 — reviewer-only;
  # the INVARIANT is lens-scoped regardless, so a test/future vendor binding
  # on sketch_reviewer/system_verifier is caught too).
  @knob_template "reviewer"

  @vendor_kinds [:codex, :claude_code]

  @section_keys ~w(executor executor_config independence)
  @executor_kinds %{"codex" => :codex, "claude_code" => :claude_code}

  # The closed string→atom key translation for `executor_config` — mirrors the
  # PR-1 validators' atom `@vendor_config_keys` surface exactly (they compare
  # against ATOM keys, so untranslated YAML strings would reject valid config).
  @config_key_map %{
    "workspace" => :workspace,
    "model" => :model,
    "max_turns" => :max_turns,
    "timeout_ms" => :timeout_ms,
    "thinking_effort" => :thinking_effort
  }

  # The workspace VALUE coercion; unknown values pass through as-is so the
  # PR-1 validator rejects them with its own enum message.
  @workspace_values %{"repo" => :repo, "scratch" => :scratch, "none" => :none}

  @remedy "catalog-level review-independence config refusal — every route on this " <>
            "project is held until `review: executor:` points at a different vendor " <>
            "than the implementing stages (or `review: independence: degraded` accepts " <>
            "same-vendor review); this is not a failure of the requested route"

  @type provider :: {:provider, String.t()} | :none | :indeterminate

  # ---------------------------------------------------------------------------
  # Config reads (the YAML boundary)
  # ---------------------------------------------------------------------------

  @doc """
  The independence mode from `review: independence:` — `:strict` when the
  section/key is absent (or no project dir is available), `:degraded` on the
  explicit opt-in, and a LOUD error on any other value (never silently
  strict).
  """
  @spec mode(term()) :: {:ok, :strict | :degraded} | {:error, term()}
  def mode(project_dir) do
    with {:ok, section} <- load_review(project_dir) do
      mode_from(section)
    end
  end

  @doc """
  The configured reviewer executor binding from the `review:` section —
  `{:ok, :default}` when the section/`executor` key is absent (or no project
  dir is available), `{:ok, {kind, config}}` with the closed-parsed vendor
  kind and the string-whitelisted, key-translated, workspace-coerced
  `executor_config` map, or a loud `{:error, _}` on any shape violation.

  Shape-validates the section ONLY (no template knowledge) — full PR-1
  hydration validation happens at the call sites via
  `Templates.hydrate_review_binding/3`, where the resolved base template is
  known.
  """
  @spec configured_reviewer_binding(term()) ::
          {:ok, :default | {:codex | :claude_code, map()}} | {:error, term()}
  def configured_reviewer_binding(project_dir) do
    with {:ok, section} <- load_review(project_dir) do
      binding_from(section)
    end
  end

  # Nil-safety is load-bearing: `AppConfig.read_user_config/1` does
  # `Path.join([project_dir, ".jido", "config.yaml"])`, so a nil/blank dir
  # must short-circuit to "no config" here, never reach the reader. The
  # reader itself carries the file-level strictness: an unreadable or
  # unparseable config.yaml is a loud refusal (only :enoent reads as
  # absent), and the RAW unmerged map keeps present-null keys
  # distinguishable from absent ones.
  defp load_review(project_dir) when is_binary(project_dir) and project_dir != "" do
    case AppConfig.read_user_config(project_dir) do
      {:ok, config} ->
        review_section(config)

      {:error, msg} ->
        {:error, {:invalid_review_config, "review config fails closed — " <> msg}}
    end
  end

  defp load_review(_no_project_dir), do: {:ok, nil}

  # Present-nil ≠ absent: a bare `review:` parses as `%{"review" => nil}` —
  # `Map.fetch` keeps that distinct from a missing key, and the present-null
  # falls into the non-map refusal (null is non-map).
  defp review_section(config) do
    case Map.fetch(config, "review") do
      :error ->
        {:ok, nil}

      {:ok, section} when is_map(section) ->
        validate_section(section)

      {:ok, other} ->
        {:error,
         {:invalid_review_config,
          "review: must be a map (executor/executor_config/independence), " <>
            "got: #{inspect(other)}"}}
    end
  end

  # The section validates as a WHOLE here, so every load_review consumer
  # inherits every check: the binding read (the dispatch seam) must refuse a
  # malformed `independence:` too — never an applied executor with the mode
  # ignored — even though dispatch itself never reads the mode.
  defp validate_section(section) do
    case Map.keys(section) -- @section_keys do
      [] ->
        with {:ok, section} <- require_executor_with_config(section),
             {:ok, _mode} <- mode_from(section) do
          {:ok, section}
        end

      unknown ->
        {:error,
         {:invalid_review_config,
          "unknown review: keys #{inspect(unknown)} — allowed keys are #{inspect(@section_keys)}"}}
    end
  end

  # `executor_config` without `executor` is almost certainly a typo — it must
  # not silently read as :default.
  defp require_executor_with_config(section) do
    if Map.has_key?(section, "executor_config") and not Map.has_key?(section, "executor") do
      {:error,
       {:invalid_review_config,
        "review: has executor_config without executor — name the vendor (codex | claude_code)"}}
    else
      {:ok, section}
    end
  end

  # `Map.fetch` on every key below: only a truly ABSENT key defaults; a
  # present-null (`independence:` left blank) rides the loud-error clause.
  defp mode_from(nil), do: {:ok, :strict}

  defp mode_from(section) do
    case Map.fetch(section, "independence") do
      :error ->
        {:ok, :strict}

      {:ok, "strict"} ->
        {:ok, :strict}

      {:ok, "degraded"} ->
        {:ok, :degraded}

      {:ok, other} ->
        {:error,
         {:invalid_review_config,
          "invalid review: independence #{inspect(other)} — expected strict | degraded " <>
            "(refusing loudly: a typo must not silently pick a mode)"}}
    end
  end

  defp binding_from(nil), do: {:ok, :default}

  defp binding_from(section) do
    case Map.fetch(section, "executor") do
      # A present-null executor flows to parse_kind(nil) → the loud
      # invalid_kind refusal, never silently :default.
      {:ok, executor} -> parse_binding(executor, Map.fetch(section, "executor_config"))
      :error -> {:ok, :default}
    end
  end

  defp parse_binding(executor, config_fetch) do
    with {:ok, kind} <- parse_kind(executor),
         {:ok, config} <- translate_config(config_fetch) do
      {:ok, {kind, config}}
    end
  end

  # The CLOSED executor parser — never `String.to_atom/1` on config input.
  defp parse_kind(executor) when is_binary(executor) do
    case Map.fetch(@executor_kinds, executor) do
      {:ok, kind} -> {:ok, kind}
      :error -> invalid_kind(executor)
    end
  end

  defp parse_kind(executor), do: invalid_kind(executor)

  defp invalid_kind(executor) do
    {:error,
     {:invalid_review_config,
      "invalid review: executor #{inspect(executor)} — expected codex | claude_code"}}
  end

  # Keyed on the `Map.fetch` result: an ABSENT executor_config is %{}, while
  # a present-null one (blank `executor_config:` key) refuses loudly below.
  defp translate_config(:error), do: {:ok, %{}}

  defp translate_config({:ok, %{} = raw}) do
    case Map.keys(raw) -- Map.keys(@config_key_map) do
      [] ->
        {:ok,
         Map.new(raw, fn {key, value} ->
           {Map.fetch!(@config_key_map, key), coerce_value(key, value)}
         end)}

      unknown ->
        {:error,
         {:invalid_review_config,
          "unknown review: executor_config keys #{inspect(unknown)} — allowed keys are " <>
            "#{inspect(Map.keys(@config_key_map))}"}}
    end
  end

  defp translate_config({:ok, other}) do
    {:error,
     {:invalid_review_config, "review: executor_config must be a map, got: #{inspect(other)}"}}
  end

  defp coerce_value("workspace", value) when is_binary(value),
    do: Map.get(@workspace_values, value, value)

  defp coerce_value(_key, value), do: value

  # ---------------------------------------------------------------------------
  # Dispatch overlay (AgentRunner)
  # ---------------------------------------------------------------------------

  @doc """
  Overlay the configured reviewer binding onto a resolved template at
  dispatch: for `"#{@knob_template}"` with a configured knob, replace
  `:executor`/`:executor_config` with the hydration-validated binding; every
  other template returns unchanged BEFORE any config read. An invalid or
  unreadable knob is an `{:error, _}` — the step fails closed (a lens cohort
  rides Lane-B infra), never a silent fall-through to `:in_process`.

  Honors the test-seam precedence (an `:agent_templates_override` entry for
  the template is authoritative, knob skipped) and the nil-safety rule
  (`context[:project_dir]` read guarded against the ToolContext present-nil
  trap; nil/blank ⇒ no config read, template unchanged).
  """
  @spec apply_executor(map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def apply_executor(template, @knob_template = template_name, context) do
    if overridden?(template_name) do
      {:ok, template}
    else
      overlay_binding(template, context_project_dir(context))
    end
  end

  def apply_executor(template, _template_name, _context), do: {:ok, template}

  defp overlay_binding(template, project_dir) do
    case configured_reviewer_binding(project_dir) do
      {:ok, :default} ->
        {:ok, template}

      {:ok, {kind, raw_config}} ->
        case Templates.hydrate_review_binding(kind, raw_config, template) do
          {:ok, {executor, config}} ->
            {:ok, Map.merge(template, %{executor: executor, executor_config: config})}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  # The ToolContext present-nil trap: a present-nil `:project_dir` must read
  # as absent (the `ForgeExecutor.resolve_workspace_dir/3` pattern).
  defp context_project_dir(context) when is_map(context) do
    case context[:project_dir] do
      pd when is_binary(pd) and pd != "" -> pd
      _absent -> nil
    end
  end

  defp context_project_dir(_context), do: nil

  defp overridden?(template_name) do
    :jido_claw
    |> Application.get_env(:agent_templates_override, %{})
    |> Map.has_key?(template_name)
  end

  # ---------------------------------------------------------------------------
  # Vendor identity
  # ---------------------------------------------------------------------------

  @doc """
  Identity is EXPLICIT provider strings, never a closed atom set, so
  third-party in-process providers (`ollama:`/`openrouter:`) stay determinate
  and non-colliding with the vendor CLIs (see the moduledoc). `tier` is the
  model tier `:in_process` resolves (`stage.model || template.model`);
  vendor/forge kinds ignore it. Total: anything unrecognized is
  `:indeterminate` (fail closed).
  """
  @spec vendor_of(term(), term()) :: provider()
  def vendor_of({:forge, :codex}, _tier), do: {:provider, "openai"}
  def vendor_of({:forge, :claude_code}, _tier), do: {:provider, "anthropic"}
  def vendor_of({:forge, kind}, _tier) when kind in [:shell, :fake, :custom], do: :none
  def vendor_of(:in_process, tier), do: in_process_provider(tier)
  def vendor_of(_other, _tier), do: :indeterminate

  # Only a binary "provider:model" spec resolves; a rescued ArgumentError
  # (unknown alias / invalid alias spec) and non-binary alias targets
  # (tuple/map/LLMDB specs are legal alias values) are :indeterminate.
  defp in_process_provider(tier) do
    case Jido.AI.resolve_model(tier) do
      spec when is_binary(spec) -> provider_prefix(spec)
      _non_binary_spec -> :indeterminate
    end
  rescue
    ArgumentError ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      :indeterminate
  end

  defp provider_prefix(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, _model] when provider != "" -> {:provider, provider}
      _no_prefix -> :indeterminate
    end
  end

  # ---------------------------------------------------------------------------
  # The invariant (composer launch)
  # ---------------------------------------------------------------------------

  @doc """
  The launch-time invariant over a whole catalog (see the moduledoc): `:ok`
  when every ACTIVE review-lens stage (effective executor a vendor CLI kind)
  is provider-independent of all its `{:worker_template, _}` producers;
  `{:error, {:review_independence_held, details}}` on a strict-mode collision
  (same provider identity, or an `:indeterminate` producer — cannot prove
  independence); `:ok` + a warning + telemetry on a degraded-mode collision;
  and a distinct `{:error, config_reason}` on any malformed `review:` section
  (the run refuses loudly either way — never a verdict).

  `details` is bounded: stage names + provider identities + the fixed remedy
  string (redaction posture — no config values ride the durable terminal).
  """
  @spec check_route(map(), term()) :: :ok | {:error, term()}
  def check_route(catalog, project_dir) when is_map(catalog) do
    with {:ok, section} <- load_review(project_dir),
         {:ok, mode} <- mode_from(section),
         {:ok, binding} <- binding_from(section),
         {:ok, violations} <- collect_violations(catalog, binding) do
      resolve_violations(violations, mode)
    end
  end

  defp resolve_violations([], _mode), do: :ok

  defp resolve_violations(violations, :strict) do
    JidoClaw.Telemetry.emit_review_independence(:held)

    {:error,
     {:review_independence_held, %{scope: :catalog, violations: violations, remedy: @remedy}}}
  end

  defp resolve_violations(violations, :degraded) do
    JidoClaw.Telemetry.emit_review_independence(:degraded_pass)

    pairs = Enum.map(violations, &{&1.stage, &1.producer})

    Logger.warning(
      "[ReviewIndependence] degraded independence accepted: " <>
        "#{length(violations)} same-vendor/indeterminate review pairing(s) " <>
        "#{inspect(pairs)} — review: independence: degraded is set in .jido/config.yaml"
    )

    :ok
  end

  # Stages sorted by name so the violation list (and therefore the durable
  # refusal detail) is deterministic across map orderings.
  defp collect_violations(catalog, binding) do
    producers = Graph.producers(catalog, MapSet.new(Map.keys(catalog)))

    catalog
    |> Enum.sort_by(fn {name, _stage} -> name end)
    |> Enum.reduce_while({:ok, []}, fn {name, stage}, {:ok, acc} ->
      case stage_violations(name, stage, catalog, producers, binding) do
        {:ok, violations} -> {:cont, {:ok, [violations | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> flatten_collected()
  end

  # Prepend-then-reverse/concat keeps the reduce O(n) while preserving the
  # sorted outer order and within-chunk order.
  defp flatten_collected({:ok, chunks}), do: {:ok, Enum.concat(Enum.reverse(chunks))}
  defp flatten_collected({:error, _reason} = error), do: error

  # The invariant is scoped to review-LENS worker stages (a `{:verify, _}`
  # stage is the deterministic engine — no vendor) and ACTIVATES only when
  # the stage's effective executor is a vendor CLI kind: default in-process
  # routes and `{:forge, :fake}`/`{:forge, :shell}` routes are untouched.
  defp stage_violations(
         name,
         %Stage{unit: {:worker_template, template_name}, lens: lens} = stage,
         catalog,
         producers,
         binding
       )
       when is_binary(lens) do
    case effective_executor(template_name, binding) do
      {:ok, {{:forge, kind} = executor, _template}} when kind in @vendor_kinds ->
        producer_collisions(name, stage, catalog, producers, binding, vendor_of(executor, nil))

      {:ok, _inactive_executor} ->
        {:ok, []}

      # An unresolvable review template cannot dispatch to ANY executor — its
      # wave fails loudly on its own; the invariant stays inactive so a
      # catalog typo doesn't newly refuse unrelated routes at launch.
      :unresolved ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp stage_violations(_name, _stage, _catalog, _producers, _binding), do: {:ok, []}

  defp producer_collisions(name, stage, catalog, producers, binding, reviewer_vendor) do
    stage
    |> producer_stage_names(producers, name)
    |> Enum.reduce_while({:ok, []}, fn producer_name, {:ok, acc} ->
      case collision_for(producer_name, catalog, binding, reviewer_vendor, name) do
        {:ok, collisions} -> {:cont, {:ok, [collisions | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> flatten_collected()
  end

  # Required AND optional inputs both create review edges (the fixer is an
  # optional-input producer on the code route).
  defp producer_stage_names(%Stage{input: %{required: req, optional: opt}}, producers, name) do
    (req ++ opt)
    |> Enum.flat_map(&MapSet.to_list(Map.get(producers, &1, MapSet.new())))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == name))
    |> Enum.sort()
  end

  defp collision_for(producer_name, catalog, binding, {:provider, reviewer_provider}, stage_name) do
    case Map.fetch!(catalog, producer_name) do
      %Stage{unit: {:worker_template, producer_template}} = producer_stage ->
        case producer_vendor(producer_template, producer_stage, binding) do
          {:error, _reason} = error ->
            error

          {:provider, ^reviewer_provider} ->
            {:ok, [violation(stage_name, producer_name, reviewer_provider, reviewer_provider)]}

          :indeterminate ->
            {:ok, [violation(stage_name, producer_name, reviewer_provider, :indeterminate)]}

          _independent_or_none ->
            {:ok, []}
        end

      _non_worker_unit ->
        {:ok, []}
    end
  end

  # The producer's OWN tier — `stage.model || template.model`, never the
  # reviewer's (the AR-9 stage tier can point one stage at a different alias).
  defp producer_vendor(producer_template, producer_stage, binding) do
    case effective_executor(producer_template, binding) do
      {:ok, {executor, template}} ->
        vendor_of(executor, producer_stage.model || Map.get(template, :model))

      # Cannot prove independence for a producer that does not resolve —
      # collision (fail closed, the camus posture).
      :unresolved ->
        :indeterminate

      {:error, _reason} = error ->
        error
    end
  end

  defp violation(stage_name, producer_name, reviewer_provider, producer_provider) do
    %{
      stage: stage_name,
      producer: producer_name,
      reviewer_provider: reviewer_provider,
      producer_provider: producer_provider
    }
  end

  # The single effective-executor resolution BOTH consumers' semantics reduce
  # to: the test override is authoritative when present (including its
  # executor); else the knob overlays the `"reviewer"` template; else the
  # hydrated template's own binding.
  defp effective_executor(template_name, binding) do
    case Templates.get(template_name) do
      {:ok, template} -> resolve_executor(template_name, template, binding)
      {:error, _unknown_template} -> :unresolved
    end
  end

  defp resolve_executor(template_name, template, binding) do
    cond do
      overridden?(template_name) ->
        {:ok, {template.executor, template}}

      template_name == @knob_template and binding != :default ->
        {kind, raw_config} = binding

        case Templates.hydrate_review_binding(kind, raw_config, template) do
          {:ok, {executor, _config}} -> {:ok, {executor, template}}
          {:error, _reason} = error -> error
        end

      true ->
        {:ok, {template.executor, template}}
    end
  end
end
