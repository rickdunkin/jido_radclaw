defmodule JidoClaw.Orchestration.WorkflowRun.Changes.ValidateCrossTenant do
  @moduledoc """
  Refuses a `WorkflowRun` whose composer-lineage `parent_run_id` points at a
  parent in another tenant.

  `parent_run_id` is a writable FK on a tenant-scoped resource (AR-2 Phase 2a),
  so without this a child run in tenant A could be created pointing at a parent
  in tenant B. Runs the repo's shared `CrossTenantFk.validate/2` in a
  `before_action` (the `Memory.Block` precedent); nil FKs (a root composer
  parent) pass. Extracted to its own module both per
  `AshCredo.Check.Refactor.LargeResource`'s guidance and to keep the hand-rolled
  `WorkflowRun` resource under the line cap.
  """
  use Ash.Resource.Change

  alias JidoClaw.Security.CrossTenantFk

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      CrossTenantFk.validate(cs, [
        {:parent_run_id, JidoClaw.Orchestration.WorkflowRun, JidoClaw.Orchestration}
      ])
    end)
  end
end
