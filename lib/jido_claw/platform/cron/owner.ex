defmodule JidoClaw.Cron.Owner do
  # Best-effort reconcile boundary: a transient DB/registry error or a slow
  # Tenant.Manager call must become a log + retry-next-tick, never crash the
  # cluster-wide owner (a deterministic crash would trip the root supervisor's
  # restart intensity). Mirrors Cron.Worker / Tenant.Manager.
  # reach:disable-for-this-file bare_rescue
  @moduledoc """
  Cluster-wide owner of persisted *user* cron jobs (WS4a).

  WS4 made the always-on-tree `:system_job` tick leader-gated. WS4a closes the
  orthogonal gap: persisted **user** jobs (`mode: :main | :isolated`, `target:
  :agent | :workflow | :mfa`) had no single owner under clustering — two CLI
  nodes each booted a worker for the same row (multi-fire), and a gateway-only
  node ran none (no-fire). The `cron_jobs` row is now the **source of truth for
  scheduling**, and exactly one node — the leader — owns every non-disabled row
  for every active tenant. Followers run no user workers.

  ## Hybrid reconcile (boot + leader_changed + periodic)

  An idempotent `reconcile/0` converges the running user-cron workers to the
  desired DB state, driven by three triggers:

    * **boot** (`handle_continue(:boot, …)`),
    * the **`[:jido_claw, :cluster, :leader_changed]`** telemetry event
      (prompt failover — WS4a is its first subscriber), and
    * a **periodic tick** (`:interval`, default 30s).

  The tick is **load-bearing, not insurance**: the root supervisor is
  `:one_for_one` and `cluster_children()` (the `Cluster.Leader`) starts *after*
  `core_children()` (this Owner), so a clustered node's boot reconcile sees
  `Cluster.leader?/0` fail closed to `false` (Leader not up yet) — and
  `leader_changed` never fires for the *initial* election. The periodic re-check
  is what lets a leader that booted first eventually load. (Single-node has no
  race: `leader?/0` is trivially `true` with no process.)

  ## Desired vs running — never prune on an unknown desired set

  Leader: enumerate tenants (`JidoClaw.Tenants.Tenant.list/0`, all statuses,
  rejecting the reserved `"system"` tenant), then per tenant read the
  non-disabled rows (`Cron.Job.for_tenant`) and `converge/2` the worker set —
  add missing, restart config-changed (`Scheduler.changed?/2`), prune absent.
  A tenant that is not `:active` has an **empty** desired set, so its workers are
  pruned (a tenant suspended *after* it had cron still gets cleaned up).

  Reads are fail-safe: a tenant-enumeration or per-tenant read error **leaves
  workers running** (unknown desired ≠ empty), so `converge/2` is only ever
  called with a *known* desired set. Only an *intentional* empty set
  (follower/inactive tenant) prunes.

  The Owner manages **user jobs only**: `mode == :system_job` rows are filtered
  from both the desired set and the running set, so a stray `:system_job` row
  under a non-`"system"` tenant is skipped (system jobs are owned by the
  always-on tree + WS4's worker gate), and the symmetric filter avoids
  reschedule-every-tick churn.

  Follower: `drop_local_user_workers/0` prunes every locally-running user worker
  straight from the registry — **no Postgres dependency** — so a demoted leader
  sheds its workers even if the DB is unreachable.

  ## notify_changed / trigger — DB-write-then-notify

  Write tools/commands mutate the row then call `notify_changed/1`. On the
  leader (incl. single-node) that *synchronously* reconciles the tenant; on a
  follower it casts to the leader node and starts no local worker. The periodic
  reconcile is the lost-cast backstop.

  `trigger/2` reconciles the tenant **before** firing, so the outcome is
  row-driven: an enabled job fires, a disabled/absent job returns
  `{:error, :not_found}`, and a desired-state read failure returns
  `{:error, :desired_unknown}` and **does not fire** (fail closed — never fire a
  possibly-stale worker).

  ## Gating

  Self-gates to `:ignore` in `:mcp` serve mode (stdio is reserved for JSON-RPC)
  or when `config :jido_claw, :cron_owner, enabled?: false` (the test gate — the
  suite starts its own under `start_supervised!` with `enabled?: true`). The
  pure `start?/2` predicate keeps the supervision-level gate testable.

  ## Testability

  The three reads are dependency-injection seams (`:tenants_fun`,
  `:tenant_fun`, `:jobs_fun` opts), so read-failure and leader/follower behavior
  are exercised single-BEAM through the `:cluster_leader_module` stub. The
  cross-BEAM `:peer` failover proof is WS6.
  """

  use GenServer

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Cluster
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager
  alias JidoClaw.Tenants.Tenant

  @handler_id "jido-claw-cron-owner"
  @default_interval_ms 30_000
  @reconcile_tenant_timeout 5_000
  @trigger_timeout 5_000

  defstruct [:interval, :timer_ref, :tenants_fun, :tenant_fun, :jobs_fun]

  @type t :: %__MODULE__{
          interval: pos_integer(),
          timer_ref: reference() | nil,
          tenants_fun: (-> {:ok, [Tenant.t()]} | {:error, term()}),
          tenant_fun: (String.t() -> {:ok, Tenant.t()} | {:error, term()}),
          jobs_fun: (String.t() -> {:ok, [Job.t()]} | {:error, term()})
        }

  # -- Child gating (pure, so the serve-mode/test gate is testable) --

  @doc """
  Whether the Owner should be supervised, given the runtime flags. Absent in MCP
  serve mode (stdio is JSON-RPC) and when explicitly disabled (the test gate).
  """
  @spec start?(atom() | nil, boolean()) :: boolean()
  def start?(serve_mode, enabled?) do
    serve_mode != :mcp and enabled? != false
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- Public API --

  @doc "Synchronous full reconcile (boot, periodic, telemetry, and tests)."
  @spec reconcile() :: :ok
  def reconcile, do: GenServer.call(__MODULE__, :reconcile)

  @doc """
  Notify the owner that tenant `tenant_id`'s rows changed. On the leader (incl.
  single-node) reconciles that tenant synchronously; on a follower casts to the
  leader node (fire-and-forget — the durable row + periodic reconcile is the
  guarantee, not synchronous cross-node scheduling).
  """
  @spec notify_changed(String.t()) :: :ok
  def notify_changed(tenant_id) when is_binary(tenant_id) do
    if Cluster.leader?() do
      case GenServer.whereis(__MODULE__) do
        nil ->
          Logger.debug("[Cron.Owner] not running; row persisted, reconcile deferred")
          :ok

        _pid ->
          try do
            GenServer.call(__MODULE__, {:reconcile_tenant, tenant_id}, @reconcile_tenant_timeout)
          catch
            :exit, _ ->
              # Row is durable; the periodic reconcile backstops a busy/slow/dead
              # Owner. Never crash the user-facing tool/command after the DB write.
              Logger.debug(
                "[Cron.Owner] reconcile_tenant call exited; reconcile deferred to tick"
              )

              :ok
          end
      end
    else
      case Cluster.leader() do
        nil -> :ok
        node -> GenServer.cast({__MODULE__, node}, {:reconcile_tenant, tenant_id})
      end
    end
  end

  @doc """
  Manually fire job `job_id` for `tenant_id` via the leader. A bounded call (no
  reconcile backstop), so a dropped message must never masquerade as success.
  Returns `:ok`, `{:error, :not_found}` (no enabled worker after reconcile),
  `{:error, :desired_unknown}` (leader couldn't confirm desired state — fail
  closed), `{:error, :not_leader}` (leadership moved between routing and handling
  — fail closed), `{:error, :no_leader}`, or `{:error, :unavailable}`.
  """
  @spec trigger(String.t(), String.t()) :: :ok | {:error, term()}
  def trigger(tenant_id, job_id) when is_binary(tenant_id) and is_binary(job_id) do
    case Cluster.leader() do
      nil ->
        {:error, :no_leader}

      node ->
        try do
          GenServer.call({__MODULE__, node}, {:trigger, tenant_id, job_id}, @trigger_timeout)
        catch
          :exit, _ -> {:error, :unavailable}
        end
    end
  end

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    if start?(serve_mode(), owner_enabled?(opts)) do
      # Detach-first tolerates a restart that skipped terminate/2; a named module
      # fn avoids telemetry's local-handler performance warning.
      :telemetry.detach(@handler_id)

      :telemetry.attach(
        @handler_id,
        [:jido_claw, :cluster, :leader_changed],
        &__MODULE__.handle_leader_changed/4,
        nil
      )

      state = %__MODULE__{
        interval: Keyword.get(opts, :interval, @default_interval_ms),
        timer_ref: nil,
        tenants_fun: Keyword.get(opts, :tenants_fun, &default_list_tenants/0),
        tenant_fun: Keyword.get(opts, :tenant_fun, &default_get_tenant/1),
        jobs_fun: Keyword.get(opts, :jobs_fun, &default_list_jobs/1)
      }

      {:ok, state, {:continue, :boot}}
    else
      :ignore
    end
  end

  @impl GenServer
  def handle_continue(:boot, state) do
    # Preserve today's synchronous single-node load for the primary tenant:
    # Tenant.Manager creates the "default" Postgres row asynchronously, so ensure
    # it before the first leader reconcile to avoid a cold-start gap. Tenants
    # created concurrently with boot load on the next tick / notify_changed.
    ensure_default_tenant()
    do_reconcile(state)
    {:noreply, arm_timer(state)}
  end

  @impl GenServer
  def handle_info(:reconcile_tick, state) do
    do_reconcile(state)
    {:noreply, arm_timer(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast(:reconcile, state) do
    do_reconcile(state)
    {:noreply, state}
  end

  # Remote follower→leader path: ignore if leadership moved since the cast was
  # sent (the periodic reconcile backstops a genuinely lost cast).
  def handle_cast({:reconcile_tenant, tenant_id}, state) do
    if Cluster.leader?(), do: reconcile_tenant(tenant_id, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:reconcile, _from, state) do
    do_reconcile(state)
    {:reply, :ok, state}
  end

  # Leader-local sync per-tenant reconcile (what notify_changed/1 calls on the
  # leader) — preserves single-node "worker exists on return". Re-check
  # leadership: it may have moved between notify_changed/1's leader?/0 check and
  # this call landing. A demoted node must not schedule workers (the new leader
  # owns them; this node's own workers are pruned by the leader_changed-driven
  # do_reconcile), so skip the work and still reply :ok — consistent with the
  # cast clause; the new leader's periodic reconcile backstops the dropped notify.
  def handle_call({:reconcile_tenant, tenant_id}, _from, state) do
    if Cluster.leader?(), do: reconcile_tenant(tenant_id, state)
    {:reply, :ok, state}
  end

  # Reconcile-then-trigger: when desired state is known the worker set matches
  # the enabled set exactly, so an enabled job fires and a disabled/absent one is
  # :not_found. When the desired-state read FAILED, refuse to fire a possibly
  # stale worker (fail closed). A node demoted between routing and handling fails
  # closed with {:error, :not_leader} rather than firing a job it no longer owns.
  def handle_call({:trigger, tenant_id, job_id}, _from, state) do
    if Cluster.leader?() do
      case reconcile_tenant(tenant_id, state) do
        :ok -> {:reply, Scheduler.trigger(tenant_id, job_id), state}
        {:error, :desired_unknown} = err -> {:reply, err, state}
      end
    else
      {:reply, {:error, :not_leader}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  @spec handle_leader_changed(term(), term(), term(), term()) :: :ok
  def handle_leader_changed(_event, _measurements, _metadata, _config) do
    # Guard against the Owner-terminating-while-leader-changes race (a cast to an
    # unregistered name would raise and detach this handler).
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :reconcile)
    end
  end

  # -- Reconcile core --

  defp do_reconcile(state) do
    if Cluster.leader?() do
      reconcile_all_tenants(state)
    else
      drop_local_user_workers()
    end

    :ok
  rescue
    e ->
      Logger.warning("[Cron.Owner] reconcile raised: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("[Cron.Owner] reconcile #{kind}: #{inspect(reason)}")
      :ok
  end

  defp reconcile_all_tenants(state) do
    case state.tenants_fun.() do
      {:ok, tenants} ->
        tenants
        |> Enum.reject(&(&1.id == "system"))
        |> Enum.each(&reconcile_row(&1, state))

      {:error, reason} ->
        # Can't enumerate → unknown desired ≠ empty → leave every worker running.
        Logger.warning(
          "[Cron.Owner] tenant enumeration failed: #{inspect(reason)}; leaving local workers"
        )
    end
  end

  # Per-tenant entry for notify_changed/1 and trigger/2 (which carry a tenant_id
  # string). Returns :ok | {:error, :desired_unknown}; a tenant-row read error is
  # also :desired_unknown so trigger fails closed on an unknown/unreadable tenant.
  defp reconcile_tenant("system", _state), do: :ok

  defp reconcile_tenant(tenant_id, state) do
    case state.tenant_fun.(tenant_id) do
      {:ok, row} -> reconcile_row(row, state)
      {:error, _reason} -> {:error, :desired_unknown}
    end
  rescue
    e ->
      Logger.warning("[Cron.Owner] reconcile_tenant raised: #{Exception.message(e)}")
      {:error, :desired_unknown}
  catch
    kind, reason ->
      Logger.warning("[Cron.Owner] reconcile_tenant #{kind}: #{inspect(reason)}")
      {:error, :desired_unknown}
  end

  # Leader-only. Returns :ok (desired set known → converged) or
  # {:error, :desired_unknown} (job read failed → workers left running).
  defp reconcile_row(row, state) do
    desired =
      if row.status == :active do
        case state.jobs_fun.(row.id) do
          {:ok, jobs} -> {:ok, Enum.reject(jobs, &(&1.mode == :system_job))}
          {:error, reason} -> {:error, reason}
        end
      else
        # Inactive tenant: an intentional empty desired set prunes all its workers.
        {:ok, []}
      end

    case desired do
      {:ok, jobs} ->
        converge(row.id, jobs)
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Cron.Owner] desired-jobs read failed for #{row.id}: #{inspect(reason)}; leaving workers"
        )

        {:error, :desired_unknown}
    end
  end

  defp converge(tenant_id, desired_jobs) do
    running =
      tenant_id
      |> Scheduler.list_jobs()
      |> Enum.reject(&(&1.mode == :system_job))

    # Only force a tenant instance when there's something to schedule — dormant
    # tenants get no instance forced.
    if desired_jobs != [], do: Manager.ensure_tenant(tenant_id)

    Enum.each(desired_jobs, &converge_job(tenant_id, &1, running))

    desired_ids = MapSet.new(desired_jobs, & &1.job_id)

    Enum.each(running, fn ws ->
      unless MapSet.member?(desired_ids, ws.id), do: Scheduler.unschedule(tenant_id, ws.id)
    end)
  end

  defp converge_job(tenant_id, job, running) do
    case Enum.find(running, &(&1.id == job.job_id)) do
      nil ->
        Scheduler.schedule_persisted(tenant_id, job)

      worker ->
        restart_if_changed(tenant_id, job, worker)
    end
  end

  defp restart_if_changed(tenant_id, job, worker) do
    case Scheduler.changed?(job, worker) do
      {:ok, true} ->
        Scheduler.unschedule(tenant_id, job.job_id)
        Scheduler.schedule_persisted(tenant_id, job)

      {:ok, false} ->
        :ok

      {:error, reason} ->
        # The row is now unbuildable — KEEP the working worker rather than drop it
        # before a reschedule that would fail.
        Logger.warning(
          "[Cron.Owner] keeping worker #{job.job_id}; fingerprint failed: #{inspect(reason)}"
        )
    end
  end

  defp drop_local_user_workers do
    Enum.each(Scheduler.local_user_cron_workers(), fn {tenant_id, job_id} ->
      Scheduler.unschedule(tenant_id, job_id)
    end)
  end

  defp ensure_default_tenant do
    Manager.ensure_tenant("default")
  rescue
    e -> Logger.warning("[Cron.Owner] ensure default tenant raised: #{Exception.message(e)}")
  catch
    kind, reason ->
      Logger.warning("[Cron.Owner] ensure default tenant #{kind}: #{inspect(reason)}")
  end

  # -- Timer --

  defp arm_timer(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: Process.send_after(self(), :reconcile_tick, state.interval)}
  end

  # -- Default read seams --

  defp default_list_tenants, do: Tenant.list()
  defp default_get_tenant(tenant_id), do: Tenant.by_id(tenant_id)

  defp default_list_jobs(tenant_id) do
    Job.for_tenant(tenant: tenant_id, actor: Actor.system(tenant_id))
  end

  # -- Config --

  defp serve_mode, do: Application.get_env(:jido_claw, :serve_mode)

  defp owner_enabled?(opts) do
    Keyword.get_lazy(opts, :enabled?, fn ->
      :jido_claw
      |> Application.get_env(:cron_owner, [])
      |> Keyword.get(:enabled?, true)
    end)
  end
end
