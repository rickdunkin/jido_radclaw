defmodule JidoClaw.Orchestration.ComposerArtifact.Validations.RequireState do
  @moduledoc """
  Single-transition precondition for a `JidoClaw.Orchestration.ComposerArtifact`
  lifecycle update (AR-2 Phase 2b, P3).

  `set_active` / `tombstone_active` are bare `set_attribute(:state, …)` updates
  with no guard, so without this a `:pending` row could be tombstoned or a
  `:tombstoned` row reactivated. This validation asserts the row's CURRENT state
  (`changeset.data.state` — the **loaded** prior value, read before the change
  applies, so it is order-independent w.r.t. the sibling `set_attribute` change)
  equals `opts[:expected]`.

  `init/1` validates the wiring at compile time: `expected:` must be one of the
  three lifecycle states, so a typo fails the build rather than every runtime
  request.

  Extracted to its own file (the `Changes.ValidateCrossTenantFk` sibling
  pattern) to keep the hand-rolled resource lean (`AshCredo … LargeResource`).
  """
  use Ash.Resource.Validation

  @states [:pending, :active, :tombstoned]

  @impl Ash.Resource.Validation
  def init(opts) do
    case opts[:expected] do
      state when state in @states ->
        {:ok, opts}

      other ->
        {:error, "expected: must be one of #{inspect(@states)}, got: #{inspect(other)}"}
    end
  end

  @impl Ash.Resource.Validation
  def validate(changeset, opts, _context) do
    expected = opts[:expected]

    case changeset.data.state do
      ^expected ->
        :ok

      actual ->
        {:error,
         field: :state,
         message: "illegal transition from %{actual}",
         vars: [actual: actual, expected: expected]}
    end
  end
end
