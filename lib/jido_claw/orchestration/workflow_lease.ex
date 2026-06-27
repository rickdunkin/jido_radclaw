defmodule JidoClaw.Orchestration.WorkflowLease do
  @moduledoc """
  The durable owner-lease primitives for a `WorkflowRun` (§4.11, WS1).

  A run's owner is made **durable and fenced** so two executors can never
  silently double-run it: the process that wins execution stamps the run's
  `claimed_by` / `claim_expires_at` / `claim_token` columns under a
  compare-and-swap, renews the lease on a heartbeat, and a fenced ("zombie")
  executor is killed before it can write a terminal.

  ## What WS1 ships (mechanism only)

    * `stamp/4` — a **compare-and-swap** row claim on the prior token, status-
      guarded to `('pending','running')`. Reached only by the execution winner
      via `Middleware.init/1` (a same-node duplicate never registers; a cross-
      node duplicate loses the CAS and aborts).
    * `renew/2` — a **fenced** heartbeat (`WHERE claim_token = $token`): a
      rotated token renews 0 rows, so a superseded owner learns it lost.
    * `claim_next/1` — the oldest-first reclaim primitive (`FOR UPDATE SKIP
      LOCKED` over the `:claimable` set). **Unit-tested but not production-
      triggered until WS3** (no Pooler ships here): there is no general
      "reconstruct a reactor from a stored run" seam, so a claimed orphan can't
      yet be dispatched.
    * `fence_decision/3` — the pure, **fail-closed** renew-result interpreter
      the `Sidecar` runs.
    * `start_sidecar/4` — a **synchronous readiness handshake** that arms the
      heartbeat process before the executor proceeds (readiness is part of the
      claim — a dead sidecar fails the claim under clustering).

  ## Clocks & encoding

  DB clock throughout (`now() + interval`) — never app time — so a lease's
  expiry is computed and compared on one authority. Raw SQL via `Repo.query/2`
  (no `import Ecto.Query`): the `id`/token UUIDs are `Ecto.UUID.dump!`-ed to
  their 16-byte binary form, and the `expected` token is nil-safe for the
  genesis (never-claimed) case.

  ## Projection-ownership invariant (must not break)

  `WorkflowRun.status` is written **only** by the projection's `:set_status`
  in the append transaction. `stamp`/`renew` are raw `UPDATE`s touching only
  `claimed_by` / `claim_expires_at` / `claim_token` — never `status`.
  """

  alias JidoClaw.Cluster
  alias JidoClaw.Orchestration.WorkflowLease.Sidecar
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Repo

  @task_supervisor JidoClaw.Orchestration.LeaseTaskSupervisor

  # Bounded transient-retry interval (ms) when `renew/2` hits a DB error but the
  # lease has NOT yet expired — short enough to retry several times inside one
  # lease window (60s lease / 15s renew ⇒ ~30 attempts) before failing closed.
  @retry_ms 2_000

  # Readiness-handshake deadline (ms): how long `start_sidecar/4` waits for the
  # sidecar to register + arm its monitor before treating the claim as failed.
  @ready_timeout_ms 5_000

  # The CAS row-claim. Compare-and-swap on the prior token (`IS NOT DISTINCT
  # FROM` is nil-safe for the genesis case) AND a status guard so a cancel/
  # recovery terminal — or a park — landing before `Middleware.init/1` makes the
  # late executor's stamp a no-op (`:lost`) rather than re-stamping a terminal
  # row. `now() + interval` stamps expiry on the DB clock.
  @stamp_sql """
  UPDATE workflow_runs
     SET claimed_by = $1, claim_token = $2,
         claim_expires_at = now() + ($3 || ' seconds')::interval
   WHERE id = $4 AND claim_token IS NOT DISTINCT FROM $5
     AND status IN ('pending', 'running')
  """

  # The fenced heartbeat. Only the current token-holder renews; a rotated token
  # renews 0 rows (the caller fails closed). Touches expiry only — never status.
  @renew_sql """
  UPDATE workflow_runs
     SET claim_expires_at = now() + ($1 || ' seconds')::interval
   WHERE id = $2 AND claim_token = $3
  """

  @typedoc "Outcome of a CAS row-claim."
  @type stamp_result :: {:ok, :claimed} | {:ok, :lost} | {:error, term()}

  @doc "This node's claim identity (`to_string(Node.self())`)."
  @spec node_identity() :: String.t()
  def node_identity, do: to_string(Cluster.local_node())

  @doc "Lease duration in seconds (config `:workflow_lease[:lease_seconds]`, default 60)."
  @spec lease_seconds() :: pos_integer()
  def lease_seconds, do: config(:lease_seconds, 60)

  @doc "Heartbeat interval in seconds (config `:workflow_lease[:renew_seconds]`, default 15)."
  @spec renew_seconds() :: pos_integer()
  def renew_seconds, do: config(:renew_seconds, 15)

  defp config(key, default) do
    Keyword.get(Application.get_env(:jido_claw, :workflow_lease, []), key, default)
  end

  @doc """
  Compare-and-swap row-claim of `run_id` for this node with `new_token`,
  succeeding only when the row's current token equals `expected_token` (nil for
  the genesis case) **and** the run is still `:pending`/`:running`.

  Returns `{:ok, :claimed}` (1 row), `{:ok, :lost}` (0 rows — fenced, CAS-lost,
  or terminal/parked), or `{:error, term()}` on a DB error. `opts` is reserved
  (the by-id update is global; the token is the fence).
  """
  @spec stamp(String.t(), String.t(), String.t() | nil, keyword()) :: stamp_result()
  def stamp(run_id, new_token, expected_token, _opts \\ []) do
    params = [
      node_identity(),
      Ecto.UUID.dump!(new_token),
      to_string(lease_seconds()),
      Ecto.UUID.dump!(run_id),
      dump_or_nil(expected_token)
    ]

    case Repo.query(@stamp_sql, params) do
      {:ok, %{num_rows: 1}} -> {:ok, :claimed}
      {:ok, %{num_rows: 0}} -> {:ok, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fenced lease renewal: extend `run_id`'s expiry iff its current token is
  `token`. Returns `{:ok, rows_affected}` (`1` = renewed, `0` = fenced/rotated)
  or `{:error, term()}` on a DB error.
  """
  @spec renew(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def renew(run_id, token) do
    params = [to_string(lease_seconds()), Ecto.UUID.dump!(run_id), Ecto.UUID.dump!(token)]

    case Repo.query(@renew_sql, params) do
      {:ok, %{num_rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Claim the oldest reclaimable run (a system-level, cross-tenant scan), stamp a
  fresh token, and return the reloaded run.

  `FOR UPDATE SKIP LOCKED` + `LIMIT 1` over the `:claimable` set (oldest first)
  picks one unlocked candidate; the CAS is redundant under the held row lock but
  kept uniform. Returns `{:ok, run}`, `:none` (nothing claimable), or
  `{:error, term()}`.

  **WS1 ships this unit-tested but not production-triggered** — no caller scans
  yet (the reclaim-dispatch Pooler is WS3, gated on a reactor-reconstruction
  seam that does not exist here).
  """
  @spec claim_next(keyword()) :: {:ok, WorkflowRun.t()} | :none | {:error, term()}
  def claim_next(_opts \\ []) do
    case Repo.transaction(fn ->
           case read_claimable() do
             {:ok, [run]} -> claim_one(run)
             {:ok, []} -> :none
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :none} -> :none
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  # `query_to_claimable/0` is the Ash-generated builder for the `:claimable`
  # read (the `query_to_*` code-interface helper). NOTE: Ash compiles the
  # action's `now()` filter to an APP-clock bound parameter (not SQL `now()`),
  # so this eligibility scan is app-clock — acceptable because the *time*
  # comparison is only reclaim-eligibility (WS3-triggered), while the actual
  # double-run safety is the clock-free token CAS (`stamp/4`) + renew-fence
  # (`renew/2`); the lease *expiry* is stamped on the DB clock. No actor: the
  # action is policy-bypassed + `multitenancy(:bypass)` (a system scan, like
  # `list_non_terminal_global`).
  defp read_claimable do
    WorkflowRun.query_to_claimable()
    # Exact upper-case literal: ash_postgres clause-matches the string to emit
    # SKIP LOCKED (the `:for_update` atom form emits none) — the trace_run.ex
    # retention-sweep precedent.
    |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
    |> Ash.Query.limit(1)
    |> Ash.read()
  end

  # Under the held FOR UPDATE the row can't change beneath us, so a `:lost`/error
  # here is a genuine fault — roll the whole claim back rather than return a
  # half-claimed run.
  defp claim_one(run) do
    case stamp(run.id, Ash.UUID.generate(), run.claim_token, tenant: run.tenant_id) do
      {:ok, :claimed} -> reload_claimed(run)
      {:ok, :lost} -> Repo.rollback(:claim_lost)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reload_claimed(run) do
    case WorkflowRun.by_id_global(run.id) do
      {:ok, %WorkflowRun{} = reloaded} -> reloaded
      _ -> Repo.rollback(:reload_failed)
    end
  end

  @doc """
  Pure interpretation of a `renew/2` result into a fence action — **fail-closed**.

    * `{:ok, n}` with `n >= 1` → `:renewed`.
    * `{:ok, 0}` → `:kill` (the token was rotated — another owner fenced us).
    * `{:error, _}` and `ms_since_ok >= lease_ms` → `:kill` (the lease may have
      lapsed; assume we no longer own it).
    * `{:error, _}` and still inside the lease window → `{:retry, ms}`.
  """
  @spec fence_decision(
          {:ok, non_neg_integer()} | {:error, term()},
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :renewed | :kill | {:retry, pos_integer()}
  def fence_decision({:ok, n}, _ms_since_ok, _lease_ms) when n >= 1, do: :renewed
  def fence_decision({:ok, 0}, _ms_since_ok, _lease_ms), do: :kill
  def fence_decision({:error, _}, ms_since_ok, lease_ms) when ms_since_ok >= lease_ms, do: :kill
  def fence_decision({:error, _}, _ms_since_ok, _lease_ms), do: {:retry, @retry_ms}

  @doc """
  Start the heartbeat `Sidecar` for `executor_pid` and **block until it is
  armed** (a synchronous readiness handshake), so a claim is only "held" once
  the renew loop is monitoring the executor.

  Captures the caller (`self/0`, who awaits ready) separately from
  `executor_pid` (what the sidecar monitors), so the helper isn't coupled to
  being invoked from the executor. Returns `:ok` once ready, or `{:error,
  term()}` (sidecar failed to start, died before ready, or timed out) — which
  the middleware treats as a claim failure (fail-closed under clustering).
  """
  @spec start_sidecar(pid(), String.t(), term(), String.t()) :: :ok | {:error, term()}
  def start_sidecar(executor_pid, run_id, tenant_id, token) do
    caller = self()

    case Task.Supervisor.start_child(@task_supervisor, fn ->
           Sidecar.run(caller, executor_pid, run_id, tenant_id, token)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:lease_ready, ^run_id} ->
            Process.demonitor(ref, [:flush])
            :ok

          {:DOWN, ^ref, _type, _pid, reason} ->
            {:error, {:sidecar_down, reason}}
        after
          @ready_timeout_ms ->
            Process.demonitor(ref, [:flush])
            {:error, :sidecar_timeout}
        end

      {:error, reason} ->
        {:error, {:sidecar_start, reason}}
    end
  end

  defp dump_or_nil(nil), do: nil
  defp dump_or_nil(token), do: Ecto.UUID.dump!(token)
end
