defmodule JidoClaw.RouteComposer.SignalMatch do
  @moduledoc """
  The composer's **one-directional** family-prefix signal matcher — single-sourced
  (AR-4) so the router's trigger/lock logic and the AR-4 self-heal helpers cannot
  drift.

  `matches?(sub, topics)` is true when `sub` is satisfied by some topic in
  `topics`: an exact match, or a qualified family member of `sub`
  (`code-written` ← `code-written`, `findings` ← `findings:quality`). It is
  **one-directional**: a subscription on the family base `findings` matches a
  published `findings:quality`, but a subscription on the *qualified*
  `findings:security` does NOT match a bare `findings` (the qualified subscriber
  wants exactly that lens).

  Deliberately distinct from `JidoClaw.RouteComposer.CatalogValidator.family_match?/2`,
  which is **bidirectional** (it also matches a qualified `sub` against a base
  `pub`) — the two are not interchangeable, so they are not shared.
  """

  @doc """
  True when subscription `sub` is satisfied by any topic in `topics` — an exact
  match or a qualified member of `sub`'s family. One-directional (see the
  moduledoc); `topics` may be any enumerable of strings (a `MapSet` of live
  signals, a list of fixer-emitted signals).
  """
  @spec matches?(String.t(), Enumerable.t()) :: boolean()
  def matches?(sub, topics) do
    Enum.any?(topics, fn topic -> topic == sub or String.starts_with?(topic, sub <> ":") end)
  end
end
