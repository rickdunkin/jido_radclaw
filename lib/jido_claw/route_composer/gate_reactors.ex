defmodule JidoClaw.RouteComposer.GateReactors do
  @moduledoc """
  The closed seam mapping a catalog gate name → its gate-producer reactor module
  and the approval signal that reactor publishes (AR-2 §9; §14 Phase 4a).

  A `{:gate, name}` stage's `name` is **catalog-sourced** (it round-trips through
  JSONB at recovery), so it must never reach `String.to_atom/1`. This fixed
  compile-time map bounds gate dispatch to our own reactors — mirroring
  `JidoClaw.Orchestration.GateResume`'s `@allowed_module_prefix` allowlist on the
  resume side — so a typo'd or hostile gate name resolves to `nil` (a clean wave
  failure) rather than minting an atom or dispatching an arbitrary module.

  The approval **signal** lives here, not as `hd(stage.publishes)` — a gate's
  `publishes` carries `scope-shift` (and the synthesized `plan-rejected` /
  `plan-abandoned`, Phase 4a) alongside the approval signal, so the contract
  must name it explicitly.

  `known?/1` mirrors `JidoClaw.Agent.Templates.exists?/1`: the
  `JidoClaw.RouteComposer.Catalog` compile-time guard asserts every `{:gate, _}`
  unit resolves here, the parallel of the worker-template existence guard.
  """

  alias JidoClaw.Orchestration.Reactors.PlanGate

  # gate-name → {gate-producer reactor module, approval signal it publishes}.
  @gates %{"plan" => {PlanGate, "plan-approved"}}

  @doc """
  Resolve a gate name to `{module, approval_signal}`, or `nil` when unknown.
  """
  @spec resolve(String.t()) :: {module(), String.t()} | nil
  def resolve(name) when is_binary(name), do: Map.get(@gates, name)
  def resolve(_name), do: nil

  @doc """
  The approval signal a gate publishes (`"plan-approved"` for `"plan"`), or
  `nil` when the gate is unknown.
  """
  @spec signal(String.t()) :: String.t() | nil
  def signal(name) do
    case resolve(name) do
      {_module, signal} -> signal
      nil -> nil
    end
  end

  @doc "True when `name` names a known gate reactor."
  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name), do: Map.has_key?(@gates, name)
  def known?(_name), do: false
end
