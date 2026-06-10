defmodule JidoClaw.Skills.Compiler do
  @moduledoc """
  Compile an LLM-authored YAML skill (`%JidoClaw.Skills{}`) to a runnable
  `%Reactor{}` struct via `Reactor.Builder`.

  This is the second front-end of the single workflow engine: developer-authored
  `Ash.Reactor` modules ship as-is, while skills are compiled to reactors at
  runtime and run through the same `JidoClaw.Orchestration.ReactorRunner`
  envelope (durable `WorkflowRun` + event log + recovery).

  ## Internal atom ids

  Skill step names are **strings by design** (LLM-authored YAML). Reactor step
  and argument names must be **atoms**, and the planner raises for a
  `from_result` to a non-existent step. So the compiler generates positional
  atom ids (`:step_1`, …, `:step_N`) for all Reactor names/arguments and
  **never** calls `String.to_atom/1` on YAML (atom-table leak). Each step keeps
  its YAML string name as display/dependency metadata in the step options; a
  `%{yaml_name => :step_id}` index resolves `depends_on`/`consumes`.

  ## Modes

  `JidoClaw.Skills.execution_mode/1` selects the construction:

    * `:sequential` — step N takes a `from_result` arg for every prior step
      (feeds full preceding history *and* forces linear order). No `consumes`.
    * `:dag` — wires `from_result` args for `depends_on ∪ consumes` (a
      `consumes` target is a data-dependency edge, ordering the consumer after
      its producer); Reactor derives topology + concurrency.
    * `:iterative` — a single `IterativeStep` (the generator/evaluator loop).

  Every agent step runs `async?: true` (preserving parallel-phase behavior).
  A terminal `CollectStep` depends on **every** agent step and produces the
  run's JSON-safe result map. The compiler does **not** add
  `ReactorMiddleware` — `ReactorRunner` is the sole wirer.

  ## Per-step `retry:` / `compensate:` / `irreversible:`

  A YAML step may declare `retry: N` (non-negative integer retry budget),
  `compensate: "cleanup task"` (run via `AgentRunner` on terminal failure /
  saga unwind), and `irreversible: true` (the step's effects cannot be
  undone). `retry:` threads into the Reactor step's `max_retries`, but the
  actual retry *decision* lives in `AgentStep.compensate/4` — Reactor only
  retries on a `:retry` return, never on a bare `{:error, _}`. The flags ride
  in the impl options; `AgentStep.can?/2` derives the step's
  compensate/undo capability from them. For an `:iterative` skill the
  generator's `retry:` budget applies to the whole loop step. `irreversible:`
  additionally rides into the `step_*` event payloads as durable metadata.

  ## Per-step / top-level `deadline:` (T2-1)

  A YAML step may declare `deadline: %{within: secs, due_soon: secs,
  escalate_after: secs}` (`JidoClaw.Orchestration.Deadline.parse/1` rules) —
  pure lateness evidence for the dashboard, never an execution change. The
  normalized policy rides the impl options like `irreversible:` and is
  middleware-copied into `step_*` payloads. For an `:iterative` skill the
  deadline is **loop-level only**: declared on the generator step (it anchors
  the single loop step); any other role declaring one is a compile error. The
  top-level `skill.deadline` (run-level policy) is validated here too, then
  threaded into `WorkflowRun.config["deadline"]` by the launch sites.

  ## Validation

  Rejects duplicate non-nil YAML step names, missing `depends_on`/`consumes`
  targets, cycles, malformed `retry:`/`compensate:`/`irreversible:`/`deadline:`
  values, and graph skills above the step cap up front — a clean `{:error, _}`
  from `compile/1` instead of a raw `Reactor.Planner` `PlanError` (or a
  silently inert option) at run time.
  """

  alias JidoClaw.Orchestration.Deadline
  alias JidoClaw.Skills
  alias JidoClaw.Skills.Steps.AgentStep
  alias JidoClaw.Skills.Steps.CollectStep
  alias JidoClaw.Skills.Steps.IterativeStep
  alias JidoClaw.Workflows.StepNormalizer
  alias Reactor.Argument
  alias Reactor.Builder

  @collect_id :__collect__

  # Hard cap on graph-skill steps. Step ids come from this compile-time
  # table so compiling LLM-authored YAML never mints atoms at runtime;
  # `validate/3` rejects larger skills up front.
  @max_steps 256
  @step_ids List.to_tuple(Enum.map(1..@max_steps, &:"step_#{&1}"))

  @doc """
  Compile `skill` to a runnable `%Reactor{}` struct, or return `{:error, _}`
  for an empty/invalid skill (duplicate names, missing deps, cycles, or — for
  iterative skills — a missing generator/evaluator).
  """
  @spec compile(Skills.t()) :: {:ok, Reactor.t()} | {:error, term()}
  def compile(%Skills{} = skill) do
    steps = StepNormalizer.normalize(skill.steps)
    mode = Skills.execution_mode(skill)

    with :ok <- validate_skill_deadline(skill),
         :ok <- validate_step_metadata(steps),
         :ok <- validate(skill, steps, mode) do
      build(skill, steps, mode)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  # The top-level `deadline:` (run-level policy) bypasses per-step validation
  # — it is parsed by `Skills.parse_skill_file/1`, not a step key — so it gets
  # its own up-front check with the same error shape.
  defp validate_skill_deadline(%Skills{deadline: nil}), do: :ok

  defp validate_skill_deadline(%Skills{deadline: deadline}) do
    if valid_deadline?(deadline) do
      :ok
    else
      {:error, "Skill deadline #{deadline_requirements()}, got: #{inspect(deadline)}"}
    end
  end

  # Per-step saga metadata, validated for every mode (graph AND iterative —
  # the iterative generator/evaluator are steps too). Without the up-front
  # rejection a malformed value would either crash the planner or, worse,
  # silently disable the feature it claims to configure.
  defp validate_step_metadata(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case step_metadata_error(step) do
        nil -> {:cont, :ok}
        message -> {:halt, {:error, message}}
      end
    end)
  end

  defp step_metadata_error(step) when is_map(step) do
    label = Map.get(step, :name) || "(unnamed)"

    cond do
      not valid_retry?(Map.get(step, :retry)) ->
        "Step '#{label}': retry must be a non-negative integer, got: #{inspect(Map.get(step, :retry))}"

      not valid_compensate?(Map.get(step, :compensate)) ->
        "Step '#{label}': compensate must be a non-empty task string, got: #{inspect(Map.get(step, :compensate))}"

      not valid_irreversible?(Map.get(step, :irreversible)) ->
        "Step '#{label}': irreversible must be a boolean, got: #{inspect(Map.get(step, :irreversible))}"

      not valid_deadline?(Map.get(step, :deadline)) ->
        "Step '#{label}': deadline #{deadline_requirements()}, got: #{inspect(Map.get(step, :deadline))}"

      true ->
        nil
    end
  end

  defp step_metadata_error(_step), do: nil

  # Deliberately integers only — no :infinity through YAML (it would arrive as
  # the string "infinity", and unbounded retries on LLM steps are a spend
  # footgun regardless).
  defp valid_retry?(nil), do: true
  defp valid_retry?(retry), do: is_integer(retry) and retry >= 0

  defp valid_compensate?(nil), do: true
  defp valid_compensate?(task), do: is_binary(task) and String.trim(task) != ""

  defp valid_irreversible?(nil), do: true
  defp valid_irreversible?(flag), do: is_boolean(flag)

  # Absent is fine; a declared policy must pass `Deadline.parse/1`
  # (Squidie-faithful rules — see that module's doc).
  defp valid_deadline?(nil), do: true
  defp valid_deadline?(deadline), do: match?({:ok, _}, Deadline.parse(deadline))

  defp deadline_requirements do
    "must declare within (positive integer seconds), optionally due_soon " <>
      "(non-negative integer < within) and escalate_after (non-negative integer)"
  end

  defp validate(skill, [], _mode), do: {:error, "Skill '#{skill.name}' has no steps"}

  defp validate(skill, steps, :iterative) do
    case IterativeStep.extract_roles(skill) do
      {:ok, _gen, _eval} -> validate_iterative_deadlines(steps)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate(skill, steps, _graph_mode) do
    named =
      Enum.map(steps, fn step ->
        %{name: Map.get(step, :name), depends_on: step_deps(step), consumes: step_consumes(step)}
      end)

    with :ok <- validate_step_count(skill, steps),
         :ok <- validate_unique_names(named),
         :ok <- validate_targets_exist(named) do
      validate_no_cycles(named)
    end
  end

  # Iterative deadlines are loop-level only: the single projected step IS the
  # loop, anchored on the generator's declaration. Declared on any other
  # role, a deadline would be silently inert — reject it instead.
  defp validate_iterative_deadlines(steps) do
    steps
    |> Enum.reject(&(Map.get(&1, :role) == "generator"))
    |> Enum.find(&Map.get(&1, :deadline))
    |> case do
      nil ->
        :ok

      step ->
        label = Map.get(step, :name) || "(unnamed)"

        {:error,
         "Step '#{label}': iterative deadlines are loop-level; " <>
           "declare the deadline on the generator step"}
    end
  end

  defp validate_step_count(skill, steps) do
    if Enum.count_until(steps, @max_steps + 1) > @max_steps do
      {:error, "Skill '#{skill.name}' has more than #{@max_steps} steps"}
    else
      :ok
    end
  end

  defp validate_unique_names(named) do
    names =
      named
      |> Enum.map(& &1.name)
      |> Enum.reject(&is_nil/1)

    dups = Enum.uniq(names -- Enum.uniq(names))

    case dups do
      [] -> :ok
      d -> {:error, "Duplicate step names: #{Enum.join(d, ", ")}"}
    end
  end

  defp validate_targets_exist(named) do
    known =
      named
      |> Enum.map(& &1.name)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    missing =
      for step <- named,
          target <- Enum.uniq(step.depends_on ++ step.consumes),
          not MapSet.member?(known, target),
          do: {step.name || "(unnamed)", target}

    case missing do
      [] ->
        :ok

      list ->
        desc = Enum.map_join(list, ", ", fn {step, target} -> "#{step} -> #{target}" end)
        {:error, "Undefined dependencies: #{desc}"}
    end
  end

  defp validate_no_cycles(named) do
    edge_map = for step <- named, name = step.name, into: %{}, do: {name, edges(step)}

    Enum.reduce_while(Map.keys(edge_map), :ok, fn name, :ok ->
      case detect_cycle(name, edge_map, []) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp edges(step), do: Enum.uniq(step.depends_on ++ step.consumes)

  defp detect_cycle(name, edge_map, path) do
    cond do
      name in path ->
        cycle =
          [name | path]
          |> Enum.reverse()
          |> Enum.join(" -> ")

        {:error, "Cyclic dependency detected: #{cycle}"}

      targets = Map.get(edge_map, name) ->
        Enum.reduce_while(targets, :ok, fn target, :ok ->
          case detect_cycle(target, edge_map, [name | path]) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Build
  # ---------------------------------------------------------------------------

  defp build(skill, steps, :iterative), do: build_iterative(skill, steps)
  defp build(skill, steps, mode), do: build_graph(skill, steps, mode)

  defp build_iterative(skill, steps) do
    with {:ok, gen, eval} <- IterativeStep.extract_roles(skill),
         {:ok, reactor} <- new_with_input(),
         {:ok, reactor} <-
           Builder.add_step(
             reactor,
             :step_1,
             {IterativeStep,
              [
                generator: gen,
                evaluator: eval,
                max_iterations: skill.max_iterations,
                # The generator's retry budget governs the whole loop step:
                # IterativeStep.compensate/4 returns :retry against it.
                retry: step_retry(gen),
                # The loop step is the only execution-tracked unit — re-running
                # it repeats every member step's effects, so it is irreversible
                # iff ANY role step is.
                irreversible: gen.irreversible or eval.irreversible,
                # Loop-level deadline (T2-1), anchored on the generator's
                # declaration. Read from the NORMALIZED raw steps, never the
                # extract_roles/1 maps — role normalization drops unknown keys.
                deadline: generator_deadline(steps)
              ]},
             [input_arg()],
             async?: true,
             max_retries: step_retry(gen)
           ),
         {:ok, reactor} <- add_collect(reactor, skill, [{nil, 1}], :iterative) do
      Builder.return(reactor, @collect_id)
    end
  end

  defp generator_deadline(steps) do
    steps
    |> Enum.find(%{}, &(Map.get(&1, :role) == "generator"))
    |> step_deadline()
  end

  defp build_graph(skill, steps, mode) do
    indexed = Enum.with_index(steps, 1)
    index = build_index(indexed)

    with {:ok, reactor} <- new_with_input(),
         {:ok, reactor} <- add_agent_steps(reactor, indexed, index, mode),
         {:ok, reactor} <- add_collect(reactor, skill, indexed, mode) do
      Builder.return(reactor, @collect_id)
    end
  end

  defp new_with_input, do: Builder.add_input(Builder.new(), :extra_context)

  # `%{yaml_name => :step_id}` for the named steps only (unnamed steps are never
  # depended upon).
  defp build_index(indexed) do
    for {step, idx} <- indexed, name = Map.get(step, :name), into: %{}, do: {name, step_id(idx)}
  end

  defp add_agent_steps(reactor, indexed, index, mode) do
    Enum.reduce_while(indexed, {:ok, reactor}, fn {step, idx}, {:ok, acc} ->
      case add_agent_step(acc, step, idx, indexed, index, mode) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp add_agent_step(reactor, step, idx, indexed, _index, :sequential) do
    # Every prior step is an upstream dependency: feeds full preceding history
    # and forces linear order.
    upstream = for {_s, prior_idx} <- indexed, prior_idx < idx, do: {step_id(prior_idx), nil}
    args = [input_arg() | Enum.map(upstream, fn {id, _} -> Argument.from_result(id, id) end)]

    options =
      step_options(step,
        context_format: :preceding,
        upstream: upstream,
        consumes: []
      )

    add_step(reactor, step_id(idx), {AgentStep, options}, args, step_retry(step))
  end

  defp add_agent_step(reactor, step, idx, indexed, index, :dag) do
    depends = step_deps(step)
    consumes = step_consumes(step)

    upstream = for name <- depends, do: {resolve_id!(index, name), name}

    consumes_tuples =
      for name <- consumes, do: {resolve_id!(index, name), name, producer_produces(name, indexed)}

    # Wire a from_result arg for each edge (depends_on ∪ consumes). Derive the
    # ids from upstream/consumes_tuples (already resolved) rather than re-fetching.
    upstream_ids = Enum.map(upstream, fn {id, _name} -> id end)
    consumes_ids = Enum.map(consumes_tuples, fn {id, _name, _produces} -> id end)
    edge_ids = Enum.uniq(upstream_ids ++ consumes_ids)

    args = [input_arg() | Enum.map(edge_ids, &result_arg/1)]

    options =
      step_options(step,
        context_format: :deps,
        upstream: upstream,
        consumes: consumes_tuples,
        # Durable edge metadata (T3-1): the same depends_on ∪ consumes union
        # wired above (validated names), middleware-stamped into step_*
        # payloads for the dashboard graph. Sequential steps deliberately
        # don't stamp — unnamed steps would leave partial edges; the graph
        # adapter falls back to their sequence chain.
        depends_on: Enum.uniq(depends ++ consumes)
      )

    add_step(reactor, step_id(idx), {AgentStep, options}, args, step_retry(step))
  end

  defp step_options(step, extra) do
    [
      template: Map.get(step, :template),
      task: Map.get(step, :task),
      produces: step_produces(step),
      step_name: Map.get(step, :name),
      # Saga metadata (validated up front): AgentStep.compensate/4 reads
      # :retry/:compensate, can?/2 derives capability from all three, and the
      # middleware copies :irreversible into step_* event payloads.
      retry: step_retry(step),
      compensate: Map.get(step, :compensate),
      irreversible: Map.get(step, :irreversible, false),
      # Lateness policy (T2-1), middleware-copied into step_* payloads and
      # projected onto the WorkflowStep row.
      deadline: step_deadline(step)
    ] ++ extra
  end

  # Validated up front; thread the NORMALIZED `Deadline.parse/1` policy
  # (atom-keyed), matching `ReactorRunner.run_config/4`'s convention for the
  # run-level policy — stable shape across atom/string-keyed YAML/test inputs.
  defp step_deadline(step) do
    case Deadline.parse(Map.get(step, :deadline)) do
      {:ok, policy} -> policy
      :none -> nil
    end
  end

  defp add_collect(reactor, skill, indexed, mode) do
    args = Enum.map(indexed, fn {_step, idx} -> result_arg(step_id(idx)) end)
    order = Enum.map(indexed, fn {step, idx} -> {step_id(idx), step_display_name(step)} end)

    add_step(
      reactor,
      @collect_id,
      {CollectStep,
       [
         order: order,
         skill_name: skill.name,
         synthesis: skill.synthesis,
         depends_on: collect_deps(order, mode)
       ]},
      args
    )
  end

  # Durable edge metadata only — the collect's execution wiring (args/order)
  # is identical in every mode. In :dag mode the collect edges to every
  # NAMED step (nil display names filtered: unnamed steps have no
  # projectable identity), matching the agent steps' stamped edges, so the
  # synthetic collect never renders isolated. Every other mode stamps
  # NOTHING: agent steps don't stamp there, and a lone non-empty collect
  # list would count as a declared edge and disable the graph adapter's
  # sequence-chain fallback. Today non-dag modes are unnamed by construction
  # (`Skills.has_dag_steps?` routes any named step to :dag), so the
  # nil-filter alone would already yield [] — the mode gate pins fallback
  # eligibility explicitly instead of leaving it an accident of that routing.
  defp collect_deps(order, :dag) do
    order
    |> Enum.map(fn {_id, display} -> display end)
    |> Enum.reject(&is_nil/1)
  end

  defp collect_deps(_order, _mode), do: []

  # `max_retries` caps the attempts Reactor will allow; the retry *decision*
  # is the step's compensate/4 policy (a bare {:error, _} stays terminal).
  # The synthetic collect step never retries.
  defp add_step(reactor, name, impl, args, max_retries \\ 0) do
    Builder.add_step(reactor, name, impl, args, async?: true, max_retries: max_retries)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp step_id(idx) when is_integer(idx) and idx >= 1 and idx <= @max_steps,
    do: elem(@step_ids, idx - 1)

  defp input_arg, do: Argument.from_input(:extra_context, :extra_context)

  defp result_arg(step_id), do: Argument.from_result(step_id, step_id)

  # Graph steps carry their YAML name (or nil); the iterative step has no name.
  # The display name is metadata only — `CollectStep` orders by step_id.
  defp step_display_name(nil), do: nil
  defp step_display_name(step) when is_map(step), do: Map.get(step, :name)

  defp resolve_id!(index, name), do: Map.fetch!(index, name)

  defp producer_produces(name, indexed) do
    case Enum.find(indexed, fn {step, _idx} -> Map.get(step, :name) == name end) do
      {step, _idx} -> step_produces(step)
      nil -> nil
    end
  end

  defp step_produces(step) do
    case Map.get(step, :produces) do
      v when is_map(v) -> v
      _ -> nil
    end
  end

  # Validated up front (`validate_step_metadata/1`); absent -> 0 (no retry).
  defp step_retry(step) do
    case Map.get(step, :retry) do
      retry when is_integer(retry) and retry >= 0 -> retry
      _ -> 0
    end
  end

  defp step_deps(step), do: normalize_list(Map.get(step, :depends_on))

  defp step_consumes(step), do: normalize_list(Map.get(step, :consumes))

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(value), do: [to_string(value)]
end
