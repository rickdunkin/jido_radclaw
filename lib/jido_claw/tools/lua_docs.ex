defmodule JidoClaw.Tools.LuaDocs do
  # The {code, message, details} map is the LLM-facing wire-error contract
  # (shared with JidoClaw.Tools.Error) — an explicit API surface, not
  # incidental duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  Discovery companion to `lua_query`: the binding catalog (rendered from
  `JidoClaw.Tools.Lua.Bindings` — the single source, so docs and
  behavior cannot drift), the effective policy caps, and Lua language
  notes. Tenant-agnostic and static — no reads, no scope requirement.
  """

  use JidoClaw.Tools.Action,
    name: "lua_docs",
    description:
      "Describe the lua_query sandbox: the jido.* binding catalog (signatures, params, " <>
        "examples), the execution caps (policy), and Lua language notes. Pass `binding` " <>
        "to drill into one entry. Call this before writing a lua_query script.",
    category: "introspection",
    tags: ["lua", "read"],
    output_schema: [],
    schema: [
      binding: [
        type: :string,
        required: false,
        doc: ~s|Drill into one binding by name, e.g. "jido.runs".|
      ]
    ]

  alias JidoClaw.Tools.Lua.Bindings
  alias JidoClaw.Tools.Lua.Policy

  @impl Jido.Action
  def run(params, _context) do
    policy = Policy.public(Policy.resolve([]))

    case Map.get(params, :binding) do
      nil ->
        {:ok, %{bindings: Bindings.docs(), policy: policy, language_notes: language_notes()}}

      name when is_binary(name) ->
        case Enum.find(Bindings.docs(), &(&1["name"] == name)) do
          nil ->
            available = Enum.map_join(Bindings.docs(), ", ", & &1["name"])

            {:error,
             %{
               code: :unknown_binding,
               message: "unknown lua_query binding #{inspect(name)}; available: #{available}",
               details: %{retry: false, available: available}
             }}

          doc ->
            {:ok, %{binding: doc, policy: policy, language_notes: language_notes()}}
        end
    end
  end

  defp language_notes do
    %{
      "results" =>
        "End the script with `return <value>`; multiple return values become a results " <>
          "array. String-keyed tables become JSON objects, numeric-keyed tables become arrays.",
      "print" =>
        "print is disabled (sandboxed) — return values instead; nothing can write to host IO.",
      "errors" =>
        "Host bindings raise Lua errors on bad arguments — recoverable in-script with " <>
          "pcall(...). Budget refusals are NOT swallowable: exceeding max_calls fails the " <>
          "whole eval even under pcall.",
      "limits" =>
        "Every eval is bounded by the policy caps shown here; the final result must fit " <>
          "max_result_bytes — filter/aggregate in-script and page with after_seq " <>
          "(jido.events) or offset (jido.output) instead of returning whole datasets.",
      "sandbox" =>
        "io, file, os.*, package, require, load, dofile, print, and debug are unavailable."
    }
  end
end
