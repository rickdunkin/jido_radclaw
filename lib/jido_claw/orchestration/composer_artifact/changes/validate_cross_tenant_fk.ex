defmodule JidoClaw.Orchestration.ComposerArtifact.Changes.ValidateCrossTenantFk do
  @moduledoc """
  Cross-tenant + lineage guard for a `JidoClaw.Orchestration.ComposerArtifact`
  create (AR-2 Phase 2b).

  Both `parent_run_id` and `child_run_id` are writable FKs onto
  tenant-scoped `WorkflowRun` rows, so without this a confused internal
  caller could attach an artifact to another tenant's run. Runs the repo's
  shared `CrossTenantFk.validate/2` over **both** FKs in a `before_action`
  (the `WorkflowRun.Changes.ValidateCrossTenant` precedent), then asserts the
  composer lineage: the child wave (`child_run_id`) must belong to the
  supplied composer parent (`child.parent_run_id == parent_run_id`).

  The lineage assertion always holds for a correct producer — `WaveCollect`
  reads `child_run_id` from `context.workflow_run`, whose `parent_run_id` FK
  *is* the composer parent — so it only ever catches a confused caller. A
  focused `child_wave_parent_mismatch` error, not a generic FK mismatch.

  A **seed** row (Phase 2d) has no producing wave (`child_run_id: nil`), so the
  lineage assertion is skipped for it — `CrossTenantFk` already skips the nil FK
  (the parent-tenant guard still runs), and without the skip the nil child would
  be rejected `child_run_not_found` (the `by_id_global` lookup is `allow_nil?:
  false`).

  Extracted to its own module per `AshCredo.Check.Refactor.LargeResource` and
  to keep the hand-rolled `ComposerArtifact` resource lean.
  """
  use Ash.Resource.Change

  alias Ash.Changeset
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Security.CrossTenantFk

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn cs ->
      cs
      |> CrossTenantFk.validate([
        {:parent_run_id, WorkflowRun, JidoClaw.Orchestration},
        {:child_run_id, WorkflowRun, JidoClaw.Orchestration}
      ])
      |> assert_lineage()
    end)
  end

  # Skip once a cross-tenant check already faulted (mirrors
  # `RequestCorrelation`'s `validate_workspace` short-circuit) — the FK rows
  # may not even exist, so a lineage read would be noise.
  defp assert_lineage(%{errors: errors} = cs) when errors != [], do: cs

  defp assert_lineage(cs) do
    parent_run_id = Changeset.get_attribute(cs, :parent_run_id)
    child_run_id = Changeset.get_attribute(cs, :child_run_id)
    assert_child_lineage(cs, parent_run_id, child_run_id)
  end

  # A **seed** row (Phase 2d) carries `child_run_id: nil` — there is no producing
  # wave to lineage-check, so skip it. `CrossTenantFk.validate/2` already skips a
  # nil FK (so the parent-tenant guard is unaffected); without this head the nil
  # child would fall to the `_not_found` arm below and be wrongly rejected with
  # `child_run_not_found` (`by_id_global` has `allow_nil?: false`).
  defp assert_child_lineage(cs, _parent_run_id, nil), do: cs

  defp assert_child_lineage(cs, parent_run_id, child_run_id) do
    case WorkflowRun.by_id_global(child_run_id) do
      {:ok, %WorkflowRun{parent_run_id: ^parent_run_id}} ->
        cs

      {:ok, %WorkflowRun{parent_run_id: actual_parent}} ->
        Changeset.add_error(cs,
          field: :child_run_id,
          message: "child_wave_parent_mismatch",
          vars: [supplied_parent: parent_run_id, child_parent: actual_parent]
        )

      _not_found ->
        # CrossTenantFk already adds `parent_not_found` when the child FK
        # misses, so this is belt-and-suspenders for a nil/garbage id.
        Changeset.add_error(cs, field: :child_run_id, message: "child_run_not_found")
    end
  end
end
