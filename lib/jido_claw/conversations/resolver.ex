defmodule JidoClaw.Conversations.Resolver do
  @moduledoc """
  Lazy upserter for `JidoClaw.Conversations.Session` rows.

  Every surface that opens a conversation (REPL, web controller, RPC
  channel, Discord/Telegram adapter, cron worker) calls
  `ensure_session/5` immediately after resolving the parent Workspace.
  The Session resource's `:start` action runs a cross-tenant FK check
  inside the create transaction so this resolver doesn't need to
  pre-validate the parent — a mismatch surfaces as an
  `Ash.Error.Changes.InvalidAttribute`.

  ## Closed-session reuse

  `:start`'s `upsert_fields` deliberately excludes `:closed_at`. A repeat
  call against a previously closed `(tenant, workspace, kind, external_id)`
  returns the existing closed row unchanged. Surfaces that need to
  bump `last_active_at` use the `:touch` action; surfaces that need
  explicit reopen semantics should add a dedicated `:reopen` action
  rather than ever folding `:closed_at` into the upsert field set.
  """

  alias JidoClaw.Conversations.Session

  @spec ensure_session(String.t(), Ecto.UUID.t(), atom(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def ensure_session(tenant_id, workspace_id, kind, external_id, opts \\ [])
      when is_binary(tenant_id) and is_binary(workspace_id) and is_atom(kind) and
             is_binary(external_id) and is_list(opts) do
    attrs = %{
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      kind: kind,
      external_id: external_id,
      user_id: Keyword.get(opts, :user_id),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
      idle_timeout_seconds: Keyword.get(opts, :idle_timeout_seconds, 300),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    Session
    |> Ash.Changeset.for_create(:start, attrs)
    |> Ash.create(upsert?: true, upsert_identity: :unique_external)
  end
end
