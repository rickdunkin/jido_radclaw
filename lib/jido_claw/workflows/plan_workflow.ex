defmodule JidoClaw.Workflows.PlanWorkflow do
  @moduledoc """
  Execute skills as DAGs with parallel phase execution.

  Reads `name` and `depends_on` fields from skill steps to build an execution
  graph. Steps within the same phase (no unresolved dependencies on each other)
  run concurrently via `Task.async_stream`. Phases execute sequentially in
  topological order.

  Falls back to the original `SkillWorkflow` for skills without any `depends_on`
  annotations to preserve backward compatibility.

  ## Phase execution model

  Given steps:
      run_tests   (no deps)
      review_code (no deps)
      synthesize  (depends_on: [run_tests, review_code])

  Phases:
      Phase 1: [run_tests, review_code]  — parallel
      Phase 2: [synthesize]              — sequential (waits for phase 1)
  """

  alias JidoClaw.Workflows.{ContextBuilder, StepResult}
  require Logger

  @step_timeout_ms 300_000

  @doc """
  Execute a skill using DAG-based parallel phase execution.

  Returns `{:ok, results}` where results is a list of `%StepResult{}`
  structs in dependency-resolved order, or `{:error, reason}`.
  """
  @spec run(JidoClaw.Skills.t(), String.t(), String.t(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def run(skill, extra_context \\ "", project_dir \\ File.cwd!(), opts \\ []) do
    steps = skill.steps
    workspace_id = Keyword.get(opts, :workspace_id)

    if Enum.empty?(steps) do
      {:error, "Skill '#{skill.name}' has no steps"}
    else
      with {:ok, named_steps} <- assign_step_names(steps),
           :ok <- validate_no_cycles(named_steps),
           {:ok, phases} <- compute_phases(named_steps) do
        execute_phases(phases, named_steps, extra_context, project_dir, workspace_id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Step normalisation
  # ---------------------------------------------------------------------------

  # Assign a unique string name to each step. Uses the `name` field from YAML
  # if present, otherwise generates "step_1", "step_2", ...
  # All names are kept as strings to avoid atom table leaks from user YAML.
  defp assign_step_names(steps) do
    named =
      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {step, idx} ->
        name =
          case Map.get(step, "name") || Map.get(step, :name) do
            nil -> "step_#{idx}"
            n when is_binary(n) -> n
            n when is_atom(n) -> Atom.to_string(n)
          end

        deps =
          case Map.get(step, "depends_on") || Map.get(step, :depends_on) do
            nil -> []
            deps when is_list(deps) -> Enum.map(deps, &to_string/1)
            dep -> [to_string(dep)]
          end

        produces = normalize_yaml_map(step, "produces")
        consumes = normalize_yaml_list(step, "consumes")

        %{
          name: name,
          template: Map.get(step, "template") || Map.get(step, :template),
          task: Map.get(step, "task") || Map.get(step, :task),
          role: Map.get(step, "role") || Map.get(step, :role),
          depends_on: deps,
          produces: produces,
          consumes: consumes
        }
      end)

    {:ok, named}
  end

  defp normalize_yaml_map(step, key) do
    case Map.get(step, key) || Map.get(step, String.to_existing_atom(key)) do
      v when is_map(v) -> v
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp normalize_yaml_list(step, key) do
    case Map.get(step, key) || Map.get(step, String.to_existing_atom(key)) do
      v when is_list(v) -> Enum.map(v, &to_string/1)
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  # ---------------------------------------------------------------------------
  # Cycle detection
  # ---------------------------------------------------------------------------

  defp validate_no_cycles(named_steps) do
    step_map = Map.new(named_steps, &{&1.name, &1})

    Enum.reduce_while(named_steps, :ok, fn step, :ok ->
      case detect_cycle(step.name, step_map, []) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp detect_cycle(name, step_map, path) do
    if name in path do
      cycle = Enum.reverse([name | path]) |> Enum.join(" -> ")
      {:error, "Cyclic dependency detected: #{cycle}"}
    else
      step = Map.get(step_map, name)

      if step do
        Enum.reduce_while(step.depends_on, :ok, fn dep, :ok ->
          case detect_cycle(dep, step_map, [name | path]) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)
      else
        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Topological sort / phase computation
  # ---------------------------------------------------------------------------

  # Returns a list of phases, each phase being a list of step names.
  # Steps in the same phase have no dependency on each other and can run in
  # parallel. Phases themselves must execute sequentially.
  defp compute_phases(named_steps) do
    step_map = Map.new(named_steps, &{&1.name, &1})

    # Validate all declared dependencies exist
    with :ok <- validate_deps(named_steps, step_map) do
      phases = topo_phases(named_steps, step_map)
      {:ok, phases}
    end
  end

  defp validate_deps(named_steps, step_map) do
    missing =
      Enum.flat_map(named_steps, fn step ->
        Enum.flat_map(step.depends_on, fn dep ->
          if Map.has_key?(step_map, dep), do: [], else: [{step.name, dep}]
        end)
      end)

    if missing == [] do
      :ok
    else
      desc =
        Enum.map_join(missing, ", ", fn {step, dep} -> "#{step} -> #{dep}" end)

      {:error, "Undefined dependencies: #{desc}"}
    end
  end

  # Kahn-style grouping: assign each step a depth = 1 + max(depth of deps).
  # Steps with depth 0 have no deps and form phase 0.
  defp topo_phases(named_steps, step_map) do
    depths =
      Enum.reduce(named_steps, %{}, fn step, acc ->
        depth = step_depth(step, step_map, acc, MapSet.new())
        Map.put(acc, step.name, depth)
      end)

    depths
    |> Enum.group_by(fn {_name, depth} -> depth end, fn {name, _depth} -> name end)
    |> Enum.sort_by(fn {depth, _} -> depth end)
    |> Enum.map(fn {_depth, names} -> names end)
  end

  defp step_depth(step, step_map, known_depths, visiting) do
    if MapSet.member?(visiting, step.name) do
      # Cycle — return 0 (cycle validation is done separately)
      0
    else
      case Map.get(known_depths, step.name) do
        nil ->
          visiting = MapSet.put(visiting, step.name)

          dep_depth =
            step.depends_on
            |> Enum.map(fn dep ->
              dep_step = Map.fetch!(step_map, dep)
              step_depth(dep_step, step_map, known_depths, visiting)
            end)
            |> then(fn depths -> if depths == [], do: -1, else: Enum.max(depths) end)

          dep_depth + 1

        known ->
          known
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Phase execution
  # ---------------------------------------------------------------------------

  defp execute_phases(phases, named_steps, extra_context, project_dir, workspace_id) do
    step_map = Map.new(named_steps, &{&1.name, &1})

    Enum.reduce_while(phases, {:ok, []}, fn phase_names, {:ok, acc_results} ->
      phase_steps = Enum.map(phase_names, &Map.fetch!(step_map, &1))

      case execute_phase(
             phase_steps,
             acc_results,
             named_steps,
             extra_context,
             project_dir,
             workspace_id
           ) do
        {:ok, phase_results} ->
          {:cont, {:ok, acc_results ++ phase_results}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp execute_phase(steps, prior_results, named_steps, extra_context, project_dir, workspace_id) do
    concurrency = max(1, length(steps))

    print_phase_banner(steps)

    results =
      steps
      |> Task.async_stream(
        fn step ->
          execute_step(
            step,
            prior_results,
            named_steps,
            extra_context,
            project_dir,
            workspace_id
          )
        end,
        max_concurrency: concurrency,
        timeout: @step_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while([], fn
        {:ok, {:ok, result}}, acc -> {:cont, [result | acc]}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
        {:exit, :timeout}, _acc -> {:halt, {:error, "Step timed out"}}
        {:exit, reason}, _acc -> {:halt, {:error, "Step crashed: #{inspect(reason)}"}}
      end)

    case results do
      {:error, _} = err -> err
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp execute_step(step, prior_results, named_steps, extra_context, project_dir, workspace_id) do
    template_name = step.template
    task = step.task

    # Build context from dependency results
    dep_context = ContextBuilder.format_for_deps(prior_results, step.depends_on)
    artifact_context = ContextBuilder.format_artifact_context(step, named_steps, prior_results)

    # Inject ARTIFACTS output contract if step has produces
    task = JidoClaw.Workflows.StepAction.inject_produces_instruction(task, step.produces)

    full_task = ContextBuilder.build_task(task, extra_context, dep_context, artifact_context)

    IO.puts(
      "  \e[2m  [parallel] #{step.name} (#{template_name}) — #{String.slice(task, 0, 55)}...\e[0m"
    )

    params =
      %{
        template: template_name,
        task: full_task,
        project_dir: project_dir,
        name: step.name
      }
      |> maybe_put(:workspace_id, workspace_id)

    case JidoClaw.Workflows.StepAction.run(params, %{}) do
      {:ok, %StepResult{} = step_result} ->
        {:ok, step_result}

      {:error, reason} ->
        Logger.warning("[PlanWorkflow] Step #{step.name} (#{template_name}) failed: #{reason}")
        {:error, "Step #{step.name} (#{template_name}) failed: #{reason}"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp print_phase_banner(steps) do
    names = Enum.map_join(steps, ", ", & &1.name)

    if length(steps) > 1 do
      IO.puts("  \e[36m  ⟳ parallel phase: #{names}\e[0m")
    else
      IO.puts("  \e[2m  step: #{names}\e[0m")
    end
  end
end
