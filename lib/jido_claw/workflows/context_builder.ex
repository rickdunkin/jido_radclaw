defmodule JidoClaw.Workflows.ContextBuilder do
  @moduledoc """
  Pure functions for formatting prior step results into context strings
  that downstream workflow steps can consume.

  All functions return `""` for nil/empty inputs (backward-compatible).
  All accept a `max_chars` option (default 4000) to truncate individual
  results, appending `\\n[truncated]` when exceeded.
  """

  alias JidoClaw.Workflows.StepResult

  @default_max_chars 4000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Format results from dependency steps only.

  Filters `prior_results` to those whose `.name` appears in `depends_on`,
  then formats as structured markdown sections. Used by PlanWorkflow.
  """
  @spec format_for_deps([StepResult.t()], [String.t()], keyword()) :: String.t()
  def format_for_deps(prior_results, depends_on, opts \\ [])
  def format_for_deps(_prior_results, nil, _opts), do: ""
  def format_for_deps(_prior_results, [], _opts), do: ""
  def format_for_deps([], _depends_on, _opts), do: ""

  def format_for_deps(prior_results, depends_on, opts) do
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    dep_set = MapSet.new(depends_on)

    prior_results
    |> Enum.filter(fn %StepResult{name: name} -> MapSet.member?(dep_set, name) end)
    |> format_results("Prior step results (dependencies)", max_chars)
  end

  @doc """
  Format ALL prior results in chronological order.

  Since workflow accumulators prepend with `[new | rest]`, this reverses
  the list to present results oldest-first. Used by SkillWorkflow.
  """
  @spec format_preceding_all([StepResult.t()], keyword()) :: String.t()
  def format_preceding_all(results, opts \\ [])
  def format_preceding_all([], _opts), do: ""

  def format_preceding_all(results, opts) do
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)

    results
    |> Enum.reverse()
    |> format_results("Prior step results", max_chars)
  end

  @doc """
  Format all results as-is (no reversal).

  Used by IterativeWorkflow where results are already in the desired order.
  """
  @spec format_all([StepResult.t()], keyword()) :: String.t()
  def format_all(results, opts \\ [])
  def format_all([], _opts), do: ""

  def format_all(results, opts) do
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    format_results(results, "Results", max_chars)
  end

  @doc """
  Format artifact context for a consuming step.

  Merges static `produces` metadata from YAML steps with dynamic `artifacts`
  from `%StepResult{}`. Returns formatted markdown or `""` if no artifacts.
  """
  @spec format_artifact_context(map(), [map()], [StepResult.t()]) :: String.t()
  def format_artifact_context(step, all_steps, prior_results) do
    consumes = Map.get(step, :consumes) || []

    if consumes == [] do
      ""
    else
      sections =
        Enum.flat_map(consumes, fn producer_name ->
          producer_step = Enum.find(all_steps, fn s -> s.name == producer_name end)
          producer_result = Enum.find(prior_results, fn r -> r.name == producer_name end)

          static = if producer_step, do: Map.get(producer_step, :produces) || %{}, else: %{}

          dynamic =
            if producer_result, do: Map.get(producer_result, :artifacts) || %{}, else: %{}

          merged = Map.merge(normalize_produces(static), dynamic)

          if map_size(merged) > 0 do
            lines =
              Enum.map(merged, fn {k, v} -> "- **#{k}**: #{v}" end)
              |> Enum.join("\n")

            ["### Artifacts from #{producer_name}\n#{lines}"]
          else
            []
          end
        end)

      if sections == [] do
        ""
      else
        "## Artifact Context\n\n#{Enum.join(sections, "\n\n")}"
      end
    end
  end

  @doc """
  Assemble a full task prompt from parts, rejecting empty strings.

  Extracted so task assembly is unit-testable without spawning agents.
  """
  @spec build_task(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def build_task(task, extra_context, dep_context, artifact_context) do
    [task, extra_context, dep_context, artifact_context]
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.join("\n\n")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp format_results(results, heading, max_chars) do
    sections =
      Enum.map(results, fn %StepResult{name: name, template: template, result: result} ->
        label = if template, do: "#{name} (#{template})", else: to_string(name)
        truncated = truncate(result || "", max_chars)
        "### #{label}\n#{truncated}"
      end)

    if sections == [] do
      ""
    else
      "## #{heading}\n\n#{Enum.join(sections, "\n\n")}"
    end
  end

  defp truncate(text, max_chars) when byte_size(text) <= max_chars, do: text

  defp truncate(text, max_chars) do
    String.slice(text, 0, max_chars) <> "\n[truncated]"
  end

  defp normalize_produces(produces) when is_map(produces) do
    Enum.reduce(produces, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), format_produces_value(v))
    end)
  end

  defp normalize_produces(_), do: %{}

  defp format_produces_value(v) when is_list(v), do: Enum.join(v, ", ")
  defp format_produces_value(v), do: to_string(v)
end
