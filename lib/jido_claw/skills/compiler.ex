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

  ## Validation

  Rejects duplicate non-nil YAML step names, missing `depends_on`/`consumes`
  targets, cycles, and malformed `retry:`/`compensate:`/`irreversible:` values
  up front — a clean `{:error, _}` from `compile/1` instead of a raw
  `Reactor.Planner` `PlanError` (or a silently inert option) at run time.
  """

  alias JidoClaw.Skills
  alias JidoClaw.Skills.Steps.AgentStep
  alias JidoClaw.Skills.Steps.CollectStep
  alias JidoClaw.Skills.Steps.IterativeStep
  alias JidoClaw.Workflows.StepNormalizer
  alias Reactor.Argument
  alias Reactor.Builder

  @collect_id :__collect__

  @doc """
  Compile `skill` to a runnable `%Reactor{}` struct, or return `{:error, _}`
  for an empty/invalid skill (duplicate names, missing deps, cycles, or — for
  iterative skills — a missing generator/evaluator).
  """
  @spec compile(Skills.t()) :: {:ok, Reactor.t()} | {:error, term()}
  def compile(%Skills{} = skill) do
    steps = StepNormalizer.normalize(skill.steps)
    mode = Skills.execution_mode(skill)

    with :ok <- validate_step_metadata(steps),
         :ok <- validate(skill, steps, mode) do
      build(skill, steps, mode)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

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

  defp validate(skill, [], _mode), do: {:error, "Skill '#{skill.name}' has no steps"}

  defp validate(skill, _steps, :iterative) do
    case IterativeStep.extract_roles(skill) do
      {:ok, _gen, _eval} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate(_skill, steps, _graph_mode) do
    named =
      Enum.map(steps, fn step ->
        %{name: Map.get(step, :name), depends_on: step_deps(step), consumes: step_consumes(step)}
      end)

    with :ok <- validate_unique_names(named),
         :ok <- validate_targets_exist(named) do
      validate_no_cycles(named)
    end
  end

  defp validate_unique_names(named) do
    names = named |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1)
    dups = (names -- Enum.uniq(names)) |> Enum.uniq()

    case dups do
      [] -> :ok
      d -> {:error, "Duplicate step names: #{Enum.join(d, ", ")}"}
    end
  end

  defp validate_targets_exist(named) do
    known = named |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> MapSet.new()

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
        cycle = [name | path] |> Enum.reverse() |> Enum.join(" -> ")
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

  defp build(skill, _steps, :iterative), do: build_iterative(skill)
  defp build(skill, steps, mode), do: build_graph(skill, steps, mode)

  defp build_iterative(skill) do
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
                irreversible: gen.irreversible or eval.irreversible
              ]},
             [input_arg()],
             async?: true,
             max_retries: step_retry(gen)
           ),
         {:ok, reactor} <- add_collect(reactor, skill, [{nil, 1}]),
         {:ok, reactor} <- Builder.return(reactor, @collect_id) do
      {:ok, reactor}
    end
  end

  defp build_graph(skill, steps, mode) do
    indexed = Enum.with_index(steps, 1)
    index = build_index(indexed)

    with {:ok, reactor} <- new_with_input(),
         {:ok, reactor} <- add_agent_steps(reactor, indexed, index, mode),
         {:ok, reactor} <- add_collect(reactor, skill, indexed),
         {:ok, reactor} <- Builder.return(reactor, @collect_id) do
      {:ok, reactor}
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
    edge_ids =
      (Enum.map(upstream, fn {id, _name} -> id end) ++
         Enum.map(consumes_tuples, fn {id, _name, _produces} -> id end))
      |> Enum.uniq()

    args = [input_arg() | Enum.map(edge_ids, &result_arg/1)]

    options =
      step_options(step,
        context_format: :deps,
        upstream: upstream,
        consumes: consumes_tuples
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
      irreversible: Map.get(step, :irreversible, false)
    ] ++ extra
  end

  defp add_collect(reactor, skill, indexed) do
    args = Enum.map(indexed, fn {_step, idx} -> result_arg(step_id(idx)) end)
    order = Enum.map(indexed, fn {step, idx} -> {step_id(idx), step_display_name(step)} end)

    add_step(
      reactor,
      @collect_id,
      {CollectStep, [order: order, skill_name: skill.name, synthesis: skill.synthesis]},
      args
    )
  end

  # `max_retries` caps the attempts Reactor will allow; the retry *decision*
  # is the step's compensate/4 policy (a bare {:error, _} stays terminal).
  # The synthetic collect step never retries.
  defp add_step(reactor, name, impl, args, max_retries \\ 0) do
    Builder.add_step(reactor, name, impl, args, async?: true, max_retries: max_retries)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp step_id(idx), do: :"step_#{idx}"

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
