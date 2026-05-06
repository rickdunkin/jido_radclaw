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

  ## Frozen-snapshot prompt persistence

  When the resolved session is non-`:cron` and has no
  `metadata["prompt_snapshot"]` yet, build the frozen snapshot from
  `JidoClaw.Agent.Prompt.build_snapshot/2` and persist it via
  `:set_prompt_snapshot`. The snapshot is best-effort — failures
  surface as `Logger.warning` and the session is returned unchanged
  so an unhealthy Memory subsystem can never block session creation.
  """

  require Logger

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

    with {:ok, session} <-
           Session
           |> Ash.Changeset.for_create(:start, attrs)
           |> Ash.create(upsert?: true, upsert_identity: :unique_external) do
      maybe_persist_snapshot(session, opts)
    end
  end

  defp maybe_persist_snapshot(%Session{kind: :cron} = s, _opts), do: {:ok, s}

  defp maybe_persist_snapshot(%Session{metadata: %{"prompt_snapshot" => snap}} = s, _opts)
       when is_binary(snap) and snap != "" do
    {:ok, s}
  end

  defp maybe_persist_snapshot(%Session{} = s, opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    with {:ok, scope} <- JidoClaw.Memory.Scope.resolve(scope_ctx(s)),
         snap = JidoClaw.Agent.Prompt.build_snapshot(project_dir, scope),
         {:ok, updated} <- Session.set_prompt_snapshot(s, snap) do
      {:ok, updated}
    else
      {:error, reason} ->
        Logger.warning("[Conversations.Resolver] snapshot persistence failed: #{inspect(reason)}")
        {:ok, s}

      _ ->
        {:ok, s}
    end
  rescue
    e ->
      Logger.warning("[Conversations.Resolver] snapshot persistence raised: #{inspect(e)}")
      {:ok, s}
  end

  # Memory.Scope.resolve/1 expects tool-context shaped keys
  # (`:workspace_uuid`, `:session_uuid`, etc.), not Session column names.
  defp scope_ctx(%Session{} = s) do
    %{
      tenant_id: s.tenant_id,
      user_id: s.user_id,
      workspace_uuid: s.workspace_id,
      session_uuid: s.id
    }
  end
end
