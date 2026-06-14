defmodule JidoClaw.Reasoning.PipelineStore do
  @moduledoc """
  Cached registry of user-defined pipelines loaded from
  `.jido/pipelines/*.yaml`.

  Each YAML file declares a named pipeline with a required non-empty
  `stages:` list. Stages are normalized + validated at load time using
  `JidoClaw.Reasoning.PipelineValidator`, so a YAML-loaded pipeline is
  byte-for-byte equivalent to an inline one at execution time.

  ## Schema

      name: plan_then_summarize
      description: CoT plan → CoD summary
      stages:
        - strategy: cot
        - strategy: cod
          context_mode: accumulate
          prompt_override: "Summarize the above…"

  `name` is required (non-empty, no `/`). `description` is optional.

  ## Lookup

  `JidoClaw.Tools.RunPipeline` calls `get/1` with a `pipeline_ref:` param.
  Inline `stages` always win over `pipeline_ref`; the store is only
  consulted when the caller didn't supply inline stages.

  ## Lenient skipping

  Malformed YAML, missing `name`/`stages`, invalid stages, collisions —
  all log a warning and the offending file is skipped. The process never
  crashes. User-vs-user name collisions resolve to the
  lexicographically-first filename (files are sorted before parsing).

  The cached-registry GenServer machinery (client API, server callbacks,
  disk loading) is provided by `JidoClaw.Reasoning.YamlStore`; only the
  pipeline-specific struct and `validate/1` live here.
  """

  use JidoClaw.Reasoning.YamlStore, subdir: "pipelines", label: "PipelineStore"

  alias JidoClaw.Reasoning.{PipelineValidator, YamlStore}

  defstruct [:name, :description, :stages, :max_context_bytes]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          stages: [map()],
          max_context_bytes: pos_integer() | nil
        }

  # ---------------------------------------------------------------------------
  # Private — validation
  # ---------------------------------------------------------------------------

  defp validate(data) do
    with {:ok, name} <- YamlStore.fetch_name(data),
         {:ok, max_context_bytes} <- fetch_max_context_bytes(data),
         {:ok, raw_stages} <- fetch_stages(data),
         {:ok, normalized} <- PipelineValidator.normalize_stages(raw_stages),
         :ok <- PipelineValidator.validate_stages(normalized) do
      {:ok,
       %__MODULE__{
         name: name,
         description: stringish(Map.get(data, "description"), ""),
         stages: normalized,
         max_context_bytes: max_context_bytes
       }}
    end
  end

  defp fetch_max_context_bytes(data) do
    raw = Map.get(data, "max_context_bytes")

    if PipelineValidator.valid_max_context_bytes?(raw) do
      {:ok, raw}
    else
      {:error, "max_context_bytes must be a positive integer (got: #{inspect(raw)})"}
    end
  end

  defp fetch_stages(data) do
    case Map.get(data, "stages") do
      stages when is_list(stages) and stages != [] -> {:ok, stages}
      [] -> {:error, "stages must be a non-empty list"}
      nil -> {:error, "missing `stages` key"}
      _ -> {:error, "stages must be a list"}
    end
  end

  defp stringish(v, _default) when is_binary(v), do: v
  defp stringish(_, default), do: default
end
