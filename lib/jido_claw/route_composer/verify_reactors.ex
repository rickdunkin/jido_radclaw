defmodule JidoClaw.RouteComposer.VerifyReactors do
  @moduledoc """
  The closed seam mapping a catalog verify name → its verify-stage reactor
  module (next-ten item 5) — the `JidoClaw.RouteComposer.GateReactors` shape
  for the `{:verify, name}` unit.

  A verify stage's `name` is **catalog-sourced** (it round-trips through JSONB
  at recovery), so it must never reach `String.to_atom/1`. This fixed
  compile-time map bounds verify dispatch to our own reactors — a typo'd or
  hostile verify name resolves to `nil` (a clean wave failure) rather than
  minting an atom or dispatching an arbitrary module.

  Unlike a gate, a verify reactor never halts/parks, so there is no paired
  approval signal here — the stage's verdict signals derive from its `lens`
  (`clean:<lens>` / `findings:<lens>`), declared in the catalog like any
  reviewer's.

  `known?/1` mirrors `GateReactors.known?/1`: the
  `JidoClaw.RouteComposer.Catalog` compile-time guard asserts every
  `{:verify, _}` unit resolves here.
  """

  alias JidoClaw.Orchestration.Reactors.VerifyStage

  @verifies %{"default" => VerifyStage}

  @doc "Resolve a verify name to its reactor module, or `nil` when unknown."
  @spec resolve(String.t()) :: module() | nil
  def resolve(name) when is_binary(name), do: Map.get(@verifies, name)
  def resolve(_name), do: nil

  @doc "True when `name` names a known verify reactor."
  @spec known?(String.t()) :: boolean()
  def known?(name) when is_binary(name), do: Map.has_key?(@verifies, name)
  def known?(_name), do: false
end
