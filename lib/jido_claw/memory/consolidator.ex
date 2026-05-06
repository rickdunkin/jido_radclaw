defmodule JidoClaw.Memory.Consolidator do
  @moduledoc """
  Public façade for the v0.6.3 memory consolidator.

  Two entry points:
    * `tick/0` — fanned out from the `"system"` cron tenant on the
      configured cadence; finds eligible scopes (watermark-anchored)
      and dispatches per-scope `run_now/2` calls under a
      `Task.Supervisor.async_stream_nolink`.
    * `run_now/2` — programmatic / CLI trigger for a single scope.
      Accepts either a resolved scope record or a tool-context-shaped
      map.

  Result shape:
    * `{:ok, %ConsolidationRun{status: :succeeded}}` on a successful
      publish.
    * `{:error, error_string}` on `:skipped` and `:failed`. The
      `ConsolidationRun` row is still written when
      `write_skip_rows: true` (operator visibility); the API
      surface just hides it from the success path so CLI/test code
      reads naturally.

  ## Temp-file durability

  `Process.exit(pid, :kill)` skips `terminate/2`, leaving
  `/tmp/consolidator-<run_id>.json` behind. OS-level `/tmp` cleanup
  reaps these — out of scope for 3b.
  """

  require Logger

  alias JidoClaw.Memory.Scope
  alias JidoClaw.Memory.Consolidator.RunServer

  @doc """
  Run the consolidator for one scope synchronously.

  Accepts:
    * A resolved scope record (from `Memory.Scope.resolve/1`).
    * A tool-context-shaped map / keyword list — will be normalised
      via `Memory.Scope.resolve/1`.

  Options:
    * `:await_ms` — overall await timeout (default 30 minutes).
    * `:override_min_input_count` — bypass the per-scope min-input
      pre-flight (used by `/memory consolidate`).
    * `:fake_proposals` — when `harness: :fake`, the list of
      `{tool_name, args}` tuples the runner will issue.
    * `:harness` — per-call override for the configured harness
      (`:claude_code | :codex | :fake`). Defaults to the
      `:harness` key in app env. Anything model/timeout/sandbox
      related stays app-env only.
  """
  @spec run_now(map() | keyword() | Scope.scope_record(), keyword()) ::
          {:ok, map()} | {:error, String.t() | term()}
  def run_now(scope_or_opts, opts \\ []) do
    with {:ok, scope} <- normalize_scope(scope_or_opts),
         {:ok, pid} <- start_run_server(scope) do
      timeout = Keyword.get(opts, :await_ms, default_await_timeout())

      try do
        GenServer.call(pid, {:await_and_start, opts}, timeout)
      catch
        :exit, {:noproc, _} -> {:error, "run_server_terminated"}
        :exit, reason -> {:error, "run_server_exit: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Periodic system-job entry point. Discovers eligible scopes,
  fans out per-scope runs through a Task.Supervisor, and returns
  `:ok` (the cron worker only cares about success/failure).
  """
  @spec tick() :: :ok
  def tick do
    config = Application.get_env(:jido_claw, JidoClaw.Memory.Consolidator, [])
    max_concurrency = Keyword.get(config, :max_concurrent_scopes, 4)
    max_candidates = Keyword.get(config, :max_candidates_per_tick, 100)

    candidates = candidate_scopes(max_candidates)

    Task.Supervisor.async_stream_nolink(
      JidoClaw.Memory.Consolidator.TaskSupervisor,
      candidates,
      fn scope -> run_now(scope) end,
      max_concurrency: max_concurrency,
      on_timeout: :kill_task,
      timeout: default_await_timeout() + 5_000,
      ordered: false
    )
    |> Stream.run()

    :ok
  rescue
    e ->
      Logger.warning("[Consolidator.tick] failed: #{inspect(e)}")
      :ok
  end

  # -- internals --------------------------------------------------------------

  defp normalize_scope(%{scope_kind: kind} = scope) when is_atom(kind), do: {:ok, scope}

  defp normalize_scope(opts) when is_list(opts) do
    Scope.resolve(Map.new(opts))
  end

  defp normalize_scope(opts) when is_map(opts), do: Scope.resolve(opts)

  defp start_run_server(scope) do
    case RunServer.start_link(scope) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_await_timeout do
    config = Application.get_env(:jido_claw, JidoClaw.Memory.Consolidator, [])

    config
    |> Keyword.get(:harness_options, [])
    |> Keyword.get(:timeout_ms, 600_000)
    # Add a buffer for cluster + publish + cleanup phases.
    |> Kernel.+(60_000)
  end

  # Phase 3b candidate discovery fans out across every scope kind
  # (`:workspace`, `:user`, `:project`, `:session`) reachable from
  # workspaces with a non-`:disabled` consolidation policy. The
  # PolicyResolver inside the per-scope RunServer filters opted-out
  # scopes at run time, and the min-input-count gate (now comparing
  # facts + messages against the watermark-anchored loaders)
  # short-circuits empty scopes. Watermark-anchored optimisation at
  # the discovery layer is deferred — its absence costs operator
  # noise (skip rows for stale scopes), not correctness.
  defp candidate_scopes(max_candidates) do
    workspaces = read_workspaces()
    workspace_scopes = Enum.map(workspaces, &workspace_scope/1)
    user_scopes = unique_user_scopes(workspaces)
    project_scopes = unique_project_scopes(workspaces)
    session_scopes = active_session_scopes(workspaces)

    (workspace_scopes ++ user_scopes ++ project_scopes ++ session_scopes)
    # Tenant-scoped dedup: same scope_kind + fk under different
    # tenants must NOT collapse to a single candidate.
    |> Enum.uniq_by(fn s -> {s.tenant_id, s.scope_kind, Scope.primary_fk(s)} end)
    |> Enum.take(max_candidates)
  rescue
    _ -> []
  end

  defp read_workspaces do
    require Ash.Query

    JidoClaw.Workspaces.Workspace
    |> Ash.Query.filter(consolidation_policy != :disabled)
    |> Ash.read!(domain: JidoClaw.Workspaces)
  end

  defp workspace_scope(ws) do
    %{
      tenant_id: ws.tenant_id,
      scope_kind: :workspace,
      user_id: ws.user_id,
      workspace_id: ws.id,
      project_id: ws.project_id,
      session_id: nil
    }
  end

  defp unique_user_scopes(workspaces) do
    workspaces
    |> Enum.filter(& &1.user_id)
    |> Enum.uniq_by(fn ws -> {ws.tenant_id, ws.user_id} end)
    |> Enum.map(fn ws ->
      %{
        tenant_id: ws.tenant_id,
        scope_kind: :user,
        user_id: ws.user_id,
        workspace_id: nil,
        project_id: nil,
        session_id: nil
      }
    end)
  end

  defp unique_project_scopes(workspaces) do
    workspaces
    |> Enum.filter(& &1.project_id)
    |> Enum.uniq_by(fn ws -> {ws.tenant_id, ws.project_id} end)
    |> Enum.map(fn ws ->
      %{
        tenant_id: ws.tenant_id,
        scope_kind: :project,
        user_id: nil,
        workspace_id: nil,
        project_id: ws.project_id,
        session_id: nil
      }
    end)
  end

  defp active_session_scopes([]), do: []

  defp active_session_scopes(workspaces) do
    require Ash.Query
    workspace_ids = Enum.map(workspaces, & &1.id)
    workspace_index = Map.new(workspaces, fn ws -> {ws.id, ws} end)

    JidoClaw.Conversations.Session
    |> Ash.Query.filter(workspace_id in ^workspace_ids and is_nil(closed_at))
    |> Ash.read!(domain: JidoClaw.Conversations)
    |> Enum.map(fn session ->
      ws = Map.get(workspace_index, session.workspace_id)

      %{
        tenant_id: session.tenant_id,
        scope_kind: :session,
        user_id: session.user_id || (ws && ws.user_id),
        workspace_id: session.workspace_id,
        project_id: ws && ws.project_id,
        session_id: session.id
      }
    end)
  rescue
    _ -> []
  end
end
