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

  ## v0.6.4 — insert-then-fallback for race-safe audit

  `:start` no longer upserts. The `unique_external` identity enforces
  uniqueness at the DB; on conflict we look up the existing row and
  call `:touch` to bump `last_active_at`. The audit `:session_start`
  emit lives in the `:start` action's after_action so it fires
  exactly-once per session — only when the insert actually wins the
  race.

  ## Frozen-snapshot prompt persistence

  When the resolved session is non-`:cron` and has no
  `metadata["prompt_snapshot"]` yet, build the frozen snapshot from
  `Prompt.build_snapshot/2` and persist it via
  `:set_prompt_snapshot`. The snapshot is best-effort — failures
  surface as `Logger.warning` and the session is returned unchanged
  so an unhealthy Memory subsystem can never block session creation.
  """

  require Logger

  alias JidoClaw.Agent.Prompt
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Memory.Scope

  @spec ensure_session(String.t(), Ecto.UUID.t(), atom(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def ensure_session(tenant_id, workspace_id, kind, external_id, opts \\ [])
      when is_binary(tenant_id) and is_binary(workspace_id) and is_atom(kind) and
             is_binary(external_id) and is_list(opts) do
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

    attrs = %{
      workspace_id: workspace_id,
      kind: kind,
      external_id: external_id,
      user_id: Keyword.get(opts, :user_id),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
      idle_timeout_seconds: Keyword.get(opts, :idle_timeout_seconds, 300),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    case Session.start(attrs, tenant: tenant_id, actor: actor) do
      {:ok, session} ->
        maybe_persist_snapshot(session, opts, actor)

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        if Enum.any?(errors, &unique_external_violation?/1) do
          fallback_to_existing(tenant_id, workspace_id, kind, external_id, opts, actor)
        else
          err
        end
    end
  end

  defp fallback_to_existing(tenant_id, workspace_id, kind, external_id, opts, actor) do
    with {:ok, existing} <-
           Session.by_external(workspace_id, kind, external_id,
             tenant: tenant_id,
             actor: actor
           ),
         {:ok, touched} <- Session.touch(existing, tenant: tenant_id, actor: actor) do
      maybe_persist_snapshot(touched, opts, actor)
    end
  end

  # Detect the unique_external duplicate-key error shape. We accept
  # multiple shapes since Ash's exact error type varies by Postgrex
  # vs Ash-level identity violations.
  defp unique_external_violation?(err) do
    str = inspect(err)
    String.contains?(str, "unique_external") or String.contains?(str, "23505")
  end

  defp maybe_persist_snapshot(%Session{kind: :cron} = s, _opts, _actor), do: {:ok, s}

  defp maybe_persist_snapshot(%Session{metadata: %{"prompt_snapshot" => snap}} = s, _opts, _actor)
       when is_binary(snap) and snap != "" do
    {:ok, s}
  end

  defp maybe_persist_snapshot(%Session{} = s, opts, actor) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    with {:ok, scope} <- Scope.resolve(scope_ctx(s)),
         snap = Prompt.build_snapshot(project_dir, scope),
         {:ok, updated} <- Session.set_prompt_snapshot(s, snap, tenant: s.tenant_id, actor: actor) do
      {:ok, updated}
    else
      {:error, reason} ->
        Logger.warning("[Conversations.Resolver] snapshot persistence failed: #{inspect(reason)}")
        {:ok, s}

      _ ->
        {:ok, s}
    end

    # Best-effort snapshot persistence — an unhealthy Memory/Prompt subsystem
    # must never block session creation, so swallow + log + return the session.
  rescue
    # reach:disable-next-line bare_rescue
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
