defmodule JidoClaw.Orchestration.AgentCaseEvent.Changes.Allocate do
  @moduledoc """
  The `AgentCaseEvent.:append` change — sole per-case `seq` allocator and
  payload redactor, mirroring `WorkflowEvent.Changes.Allocate` (minus the
  status projection: `AgentCase.status` is written by the case's own guarded
  decision actions, in the same transaction as this append).

  ## before_action

    1. Lock + read the parent case (`FOR UPDATE`) so concurrent appends for
       one case serialize. A missing case (or a tenant mismatch the
       multitenancy filter drops) becomes a clean changeset error.
    2. Allocate `seq = max(existing) + 1` (after the lock) and redact the
       persisted `data`. The unique `(agent_case_id, seq)` index is the
       backstop.
  """

  use Ash.Resource.Change

  require Ash.Query, as: Query

  alias Ash.Changeset
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Security.Redaction.Transcript

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &allocate/1)
  end

  defp allocate(changeset) do
    case_id = Changeset.get_attribute(changeset, :agent_case_id)
    tenant = changeset.tenant

    case lock_case(case_id, tenant) do
      {:ok, _agent_case} ->
        raw_data = Changeset.get_attribute(changeset, :data) || %{}

        changeset
        |> Changeset.force_change_attribute(:seq, next_seq(case_id, tenant))
        |> Changeset.force_change_attribute(:data, Transcript.redact(raw_data))

      :error ->
        Changeset.add_error(changeset,
          field: :agent_case_id,
          message: "agent case not found for tenant"
        )
    end
  end

  # FOR UPDATE on the parent case row: concurrent appends for one case block
  # here until the prior append commits, so seq allocation is gap-free and
  # strictly increasing in commit order.
  defp lock_case(case_id, tenant) do
    AgentCase
    |> Query.filter(id == ^case_id)
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, %AgentCase{} = agent_case} -> {:ok, agent_case}
      _ -> :error
    end
  end

  defp next_seq(case_id, tenant) do
    AgentCaseEvent
    |> Query.filter(agent_case_id == ^case_id)
    |> Query.sort(seq: :desc)
    |> Query.limit(1)
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, %AgentCaseEvent{seq: seq}} -> seq + 1
      _ -> 1
    end
  end
end
