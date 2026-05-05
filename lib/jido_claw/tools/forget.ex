defmodule JidoClaw.Tools.Forget do
  @moduledoc """
  Invalidate a memory the agent previously saved.

  v0.6.3 introduces this tool so the model can prune memories that
  turned out to be wrong (or stale beyond a session's horizon). The
  scope is hard-restricted to `source: :model_remember` —
  `:user_save` and `:consolidator_promoted` rows are intentionally
  out-of-reach so the model can't paper over user-saved knowledge.
  Pass `id` (preferred) for the exact row, or `label` to invalidate
  the active model-saved row at that label.
  """

  use Jido.Action,
    name: "forget",
    description:
      "Invalidate a memory you previously saved with `remember`. Pass `id` for an " <>
        "exact row, or `label` for the currently active model-saved row at that label. " <>
        "Cannot invalidate user-saved memories — those are pruned via /memory forget.",
    category: "memory",
    tags: ["memory", "write"],
    output_schema: [
      status: [type: :string, required: true],
      target: [type: :string, required: true]
    ],
    schema: [
      id: [
        type: :string,
        required: false,
        doc: "UUID of the specific memory row to invalidate (preferred over label)"
      ],
      label: [
        type: :string,
        required: false,
        doc:
          "Label of the active model-saved memory to invalidate. Used when `id` is not supplied."
      ]
    ]

  @impl true
  def run(params, context) do
    tool_context = Map.get(context, :tool_context, %{})

    cond do
      is_binary(params[:id]) ->
        invalidate_by_id(params.id, tool_context)

      is_binary(params[:label]) ->
        invalidate_by_label(params.label, tool_context)

      true ->
        {:error, :id_or_label_required}
    end
  end

  defp invalidate_by_id(id, _tool_context) do
    case Ash.get(JidoClaw.Memory.Fact, id, domain: JidoClaw.Memory.Domain) do
      {:ok, %{source: :model_remember} = fact} ->
        case JidoClaw.Memory.Fact.invalidate_by_id(fact, %{reason: "model_forget"}) do
          {:ok, _} -> {:ok, %{status: "invalidated", target: id}}
          {:error, err} -> {:error, err}
        end

      {:ok, %{source: source}} ->
        {:error, {:source_not_invalidatable, source}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp invalidate_by_label(label, tool_context) do
    JidoClaw.Memory.forget(label, tool_context: tool_context, source: :model_remember)
    {:ok, %{status: "invalidated", target: label}}
  end
end
