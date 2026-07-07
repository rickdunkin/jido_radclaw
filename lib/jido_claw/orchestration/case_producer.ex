defmodule JidoClaw.Orchestration.CaseProducer do
  @moduledoc """
  Shared primitives for the fingerprint-keyed `AgentCase` producers —
  `JidoClaw.Orchestration.ToolApprovals` (kind `:tool_call`) and
  `JidoClaw.Orchestration.NeedsInput` (kind `:needs_input`).

  Two pieces both producers' transactions are built on:

    * `lock_by_fingerprint/3` — the FOR-UPDATE read of a fingerprint's case
      rows (the house reload-and-recheck idiom, `Cases.lock_run/3`'s sibling).
      Called INSIDE each producer's transaction, it is the real concurrency
      fence: open/claim races serialize on the row locks, so exactly one
      caller consumes a decided case and the loser re-reads the winner's
      committed state.
    * `resolve_session_id/3` — the Session-FK resolution: the
      `AgentCase.session_id` column stores the `Conversations.Session` UUID
      (never the runtime external session id), and a stray/half-written
      session id degrades to nil rather than failing the producer closed on
      an FK violation.
  """

  require Ash.Query, as: Query

  alias JidoClaw.Conversations.Session
  alias JidoClaw.Orchestration.AgentCase

  @doc "FOR-UPDATE read of `fingerprint`'s case rows, newest first."
  @spec lock_by_fingerprint(String.t(), String.t(), term()) ::
          {:ok, [AgentCase.t()]} | {:error, term()}
  def lock_by_fingerprint(fingerprint, tenant_id, actor) do
    AgentCase
    |> Query.filter(fingerprint == ^fingerprint)
    |> Query.sort(inserted_at: :desc)
    |> Query.lock("FOR UPDATE")
    |> Ash.read(tenant: tenant_id, actor: actor)
  end

  @doc "Resolve a session uuid to the Session UUID FK; nil on any miss."
  @spec resolve_session_id(term(), String.t(), term()) :: Ecto.UUID.t() | nil
  def resolve_session_id(uuid, tenant_id, actor) when is_binary(uuid) and uuid != "" do
    case Session.by_id(uuid, tenant: tenant_id, actor: actor) do
      {:ok, %Session{id: id}} -> id
      _ -> nil
    end
  end

  def resolve_session_id(_uuid, _tenant_id, _actor), do: nil
end
