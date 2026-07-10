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
      guarded to pending/running or a checkpoint-less awaiting gate. Reached by the execution winner
      via `Middleware.init/1` (a same-node duplicate never registers; a cross-
      node duplicate loses the CAS and aborts).
    * `renew/2` — a **fenced** heartbeat (`WHERE claim_token = $token AND
      status IN (nonterminal...)`), additionally refusing an established gate
      park (awaiting + checkpoint): a rotated/terminal-cleared token or parked
      executor renews 0 rows, so a superseded/cancelled owner cannot stay live
      or restore the park's released expiry.
    * `claim_resume/3` — the approved-gate preclaim: only a parked/expired lease
      can become live, and a second contender cannot rotate that fresh lease.
    * `claim_next/1` — the oldest-first reclaim primitive (`FOR UPDATE SKIP
      LOCKED` over the `:claimable` set); `claim_run/1` — the by-id variant that
      re-checks the full `:claimable` predicate under a `FOR UPDATE` lock before
      rotating (the composer reclaim child-step's TOCTOU-safe inline claim). Both
      CAS-rotate the token via the shared locked-claim core (`claim_one`), and
      that rotation is what fences a surviving zombie. **WS3** ships the
      production caller (`ReclaimPooler` → `WorkflowRecovery.reclaim/1`).
    * `release_with_cooldown/3` — a token-fenced short-interval `renew` used when
      a composer reclaim **defers** restart, pushing the parent's expiry to
      `now() + poll_interval` (re-claimable on the next poll, never within the
      same drain — see `JidoClaw.Orchestration.WorkflowRecovery`).
    * `fence_decision/3` — the pure, **fail-closed** renew-result interpreter
      the `Sidecar` runs.
    * `start_sidecar/4` — a **synchronous readiness handshake** that arms the
      heartbeat process before the executor proceeds (readiness is part of the
      claim — a dead sidecar fails the claim under clustering).
    * `stop_sidecar/2` — a token-checked graceful handshake used immediately
      before an owner writes its own terminal event. External terminals do not
      call it, so cancellation/reclaim still make a live sidecar kill its
      executor when renewal is refused.

  ## Clocks & encoding

  DB clock throughout (`now() + interval`) — never app time — so a lease's
  expiry is computed and compared on one authority. Raw SQL via `Repo.query/2`
  (no `import Ecto.Query`): the `id`/token UUIDs are `Ecto.UUID.dump!`-ed to
  their 16-byte binary form, and the `expected` token is nil-safe for the
  genesis (never-claimed) case.

  ## Projection-ownership invariant (must not break)

  `WorkflowRun.status` is written **only** by the projection's `:set_status`
  in the append transaction. `stamp`/`renew`/`claim_resume` are raw `UPDATE`s
  touching only `claimed_by` / `claim_expires_at` / `claim_token` — never
  `status`. The terminal projection clears token+expiry in its status
  transaction while retaining `claimed_by` provenance.
  """

  require Ash.Query
  require Logger

  alias Ash.Query
  alias JidoClaw.Cluster
  alias JidoClaw.Orchestration.WorkflowLease.Sidecar
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Repo

  @task_supervisor JidoClaw.Orchestration.LeaseTaskSupervisor
  @registry JidoClaw.Orchestration.LeaseRegistry

  # Bounded transient-retry interval (ms) when `renew/2` hits a DB error but the
  # lease has NOT yet expired — short enough to retry several times inside one
  # lease window (60s lease / 15s renew ⇒ ~30 attempts) before failing closed.
  @retry_ms 2_000

  # Readiness-handshake deadline (ms): how long `start_sidecar/4` waits for the
  # sidecar to register + arm its monitor before treating the claim as failed.
  @ready_timeout_ms 5_000

  # The CAS row-claim. Compare-and-swap on the prior token (`IS NOT DISTINCT
  # FROM` is nil-safe for the genesis case) AND a status guard so a cancel/
  # recovery terminal — or an established park — landing before `Middleware.init/1` makes the
  # late executor's stamp a no-op (`:lost`) rather than re-stamping a terminal
  # row. `now() + interval` stamps expiry on the DB clock.
  @stamp_sql """
  UPDATE workflow_runs
     SET claimed_by = $1, claim_token = $2,
         claim_expires_at = now() + ($3 || ' seconds')::interval
   WHERE id = $4 AND claim_token IS NOT DISTINCT FROM $5
     AND (
       status IN ('pending', 'running') OR
       (status = 'awaiting_approval' AND encrypted_resume_checkpoint IS NULL)
     )
  """

  # Gate-resume preclaim. A parked gate releases its expiry to NULL when the
  # checkpoint is persisted. After `approval_resolved` flips it back to
  # `running`, exactly one resumer can turn that parked token into a live lease.
  # The expiry predicate is the second fence: a contender that reloads after the
  # winner's token rotation still cannot rotate the winner again while its lease
  # is live. Expired supports recovery of legacy/previous-version checkpoints.
  @resume_claim_sql """
  UPDATE workflow_runs
     SET claimed_by = $1, claim_token = $2,
         claim_expires_at = now() + ($3 || ' seconds')::interval
   WHERE id = $4 AND claim_token IS NOT DISTINCT FROM $5
     AND status = 'running'
     AND (claim_expires_at IS NULL OR claim_expires_at < now())
  """

  # The fenced heartbeat. Only the current token-holder of a NON-TERMINAL run
  # renews; a rotated/cleared token OR terminal status renews 0 rows (the caller
  # fails closed). `:awaiting_approval` is included because there is a small,
  # legitimate gate-flip→executor-halt window in which the sidecar may tick before
  # the checkpoint is durably written. Once that encrypted checkpoint exists,
  # renewal is refused: a tick already waiting on the checkpoint transaction's
  # row lock cannot restore a future expiry after the park released it to NULL.
  # Touches expiry only — never status.
  @renew_sql """
  UPDATE workflow_runs
     SET claim_expires_at = now() + ($1 || ' seconds')::interval
   WHERE id = $2 AND claim_token = $3
     AND status IN ('pending', 'running', 'awaiting_approval')
     AND (status <> 'awaiting_approval' OR encrypted_resume_checkpoint IS NULL)
  """

  # Suspend a held claim's expiry: NULL `claim_expires_at` on the held token,
  # KEEPING `claimed_by`/`claim_token`. A `:claimable`-clause-1 match needs
  # `claim_expires_at IS NOT NULL`, so a NULL expiry makes a `:running` row
  # unreclaimable (clause 2 needs `:pending`) — a single-node degrade leaves an
  # unleased-but-unstealable row that only boot recovery can adopt. Token-fenced
  # like `@renew_sql` so a reclaimer that already rotated the token suspends 0 rows.
  @suspend_claim_sql """
  UPDATE workflow_runs
     SET claim_expires_at = NULL
   WHERE id = $1 AND claim_token = $2
  """

  @typedoc "Outcome of a CAS row-claim."
  @type stamp_result :: {:ok, :claimed} | {:ok, :lost} | {:error, term()}

  @doc "This node's claim identity (`to_string(Cluster.local_node())`)."
  @spec node_identity() :: String.t()
  def node_identity, do: to_string(Cluster.local_node())

  @doc "Lease duration in seconds (config `:workflow_lease[:lease_seconds]`, default 60)."
  @spec lease_seconds() :: pos_integer()
  def lease_seconds, do: config(:lease_seconds, 60)

  @doc "Heartbeat interval in seconds (config `:workflow_lease[:renew_seconds]`, default 15)."
  @spec renew_seconds() :: pos_integer()
  def renew_seconds, do: config(:renew_seconds, 15)

  @doc """
  Genesis-orphan grace in seconds (config `:workflow_lease[:pending_grace_seconds]`,
  default `lease_seconds/0`). A never-claimed `:pending` row is reclaimable only
  once it has aged past this grace — long enough for `Lease.Middleware` to stamp a
  legitimately just-created run, so the always-on Pooler cannot steal it in the
  create→stamp gap (WS3 Component 2, the "no fresh-pending steal" guard).
  """
  @spec pending_grace_seconds() :: pos_integer()
  def pending_grace_seconds, do: config(:pending_grace_seconds, lease_seconds())

  defp config(key, default) do
    Keyword.get(Application.get_env(:jido_claw, :workflow_lease, []), key, default)
  end

  @doc """
  Compare-and-swap row-claim of `run_id` for this node with `new_token`,
  succeeding only when the row's current token equals `expected_token` (nil for
  the genesis case) **and** the run is still pending/running or is an
  `:awaiting_approval` gate whose checkpoint was never established. The latter
  is the clustered crash window reclaimed after its lease expires; a real park
  (checkpoint present) remains unclaimable.

  Returns `{:ok, :claimed}` (1 row), `{:ok, :lost}` (0 rows — fenced, CAS-lost,
  or terminal/parked), or `{:error, term()}` on a DB error. `opts` is reserved
  (the by-id update is global; the token is the fence).
  """
  @spec stamp(String.t(), String.t(), String.t() | nil, keyword()) :: stamp_result()
  def stamp(run_id, new_token, expected_token, _opts \\ []) do
    execute_claim(@stamp_sql, claim_params(run_id, new_token, expected_token))
  end

  @doc """
  Claim an approved parked gate for resume.

  Unlike the ordinary execution `stamp/4`, this requires the row's prior lease
  to be parked (`claim_expires_at IS NULL`) or expired. It prevents a second
  resumer that observes the first resumer's fresh token from rotating it again.
  Returns the same `stamp_result/0` contract as `stamp/4`.
  """
  @spec claim_resume(String.t(), String.t(), String.t() | nil) :: stamp_result()
  def claim_resume(run_id, new_token, expected_token) do
    execute_claim(@resume_claim_sql, claim_params(run_id, new_token, expected_token))
  end

  defp claim_params(run_id, new_token, expected_token) do
    [
      node_identity(),
      Ecto.UUID.dump!(new_token),
      to_string(lease_seconds()),
      Ecto.UUID.dump!(run_id),
      dump_or_nil(expected_token)
    ]
  end

  defp execute_claim(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{num_rows: 1}} -> {:ok, :claimed}
      {:ok, %{num_rows: 0}} -> {:ok, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fenced lease renewal: extend `run_id`'s expiry iff its current token is
  `token`, its status remains non-terminal, and it is not a fully-established
  gate park. Returns `{:ok, rows_affected}` (`1` = renewed, `0` =
  fenced/rotated/terminal/parked) or `{:error, term()}` on a DB error.
  """
  @spec renew(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def renew(run_id, token), do: renew_for(run_id, token, lease_seconds())

  @doc """
  Fenced **cooldown release** of a held lease: set `run_id`'s expiry to
  `now() + cooldown_seconds` iff its current token is `token` — the `@renew_sql`
  write with a caller-supplied interval. Used when a composer reclaim **defers**
  restart (a non-claimable child remains): the cooldown (NOT `now()`) is
  load-bearing — expiring to `now()` would make the parent re-claimable within the
  SAME `reclaim_once/0` drain (claim→defer→claim hot-loop), whereas a
  `poll_interval` cooldown makes it re-claimable on the NEXT poll (convergence
  ~`poll_interval`, no spin).

  Returns `{:ok, 1}` (released on the held token), `{:ok, 0}` (fenced/rotated — a
  reclaimer already took it), or `{:error, term()}`.
  """
  @spec release_with_cooldown(String.t(), String.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def release_with_cooldown(run_id, token, cooldown_seconds),
    do: renew_for(run_id, token, cooldown_seconds)

  @doc """
  The reclaim cooldown in seconds — the `ReclaimPooler`'s poll cadence (config
  `:reclaim_pooler[:poll_interval_ms]`, default 15_000), floored at 1s. Read here
  (the module that owns `release_with_cooldown/3`) so both the lease middleware's
  stamp-error re-arm and `WorkflowRecovery`'s release-on-defer share one source —
  no module dependency on the Pooler, no clone-gate duplication.
  """
  @spec reclaim_cooldown_seconds() :: pos_integer()
  def reclaim_cooldown_seconds do
    ms = Application.get_env(:jido_claw, :reclaim_pooler, [])[:poll_interval_ms] || 15_000
    max(div(ms, 1000), 1)
  end

  @doc """
  Best-effort token-fenced re-arm for reclaim: push `token`'s expiry to
  `now() + reclaim_cooldown_seconds/0` so the always-on `ReclaimPooler` re-claims
  this held-token row on the NEXT poll (never the same drain — the cooldown, not
  `now()`, is the anti-hot-loop, since this can itself run inside a Pooler
  `reclaim → GateResume` drain). Always returns `:ok`: a `{:ok, 0}` (token already
  rotated) or `{:error, _}` (DB blip) is swallowed — the `claim_next/1` lease window
  still bounds re-claim. Single-sourced with `WorkflowRecovery.release_on_defer/1`.
  """
  @spec release_for_reclaim(String.t(), String.t()) :: :ok
  def release_for_reclaim(run_id, token) do
    case release_with_cooldown(run_id, token, reclaim_cooldown_seconds()) do
      {:ok, _rows} ->
        :ok

      {:error, reason} ->
        Logger.warning("[WorkflowLease] reclaim re-arm failed for #{run_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp renew_for(run_id, token, interval_seconds) do
    params = [to_string(interval_seconds), Ecto.UUID.dump!(run_id), Ecto.UUID.dump!(token)]

    case Repo.query(@renew_sql, params) do
      {:ok, %{num_rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Suspend a held lease's expiry: NULL `run_id`'s `claim_expires_at` iff its current
  token is `token`, KEEPING `claimed_by`/`claim_token`. `{:ok, 1}` suspended,
  `{:ok, 0}` fenced/rotated (a reclaimer already took it), `{:error, term()}`.
  """
  @spec suspend_claim(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def suspend_claim(run_id, token) do
    params = [Ecto.UUID.dump!(run_id), Ecto.UUID.dump!(token)]

    case Repo.query(@suspend_claim_sql, params) do
      {:ok, %{num_rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Single-node degrade gate — single-sourced so the reactor middleware and the
  route-composer parent cannot diverge. Suspends the held claim and reports whether
  the caller may proceed degraded: `:degrade` **iff the suspend took** (`{:ok, 1}`);
  `:fail_closed` on a lost/failed suspend (`{:ok, 0}` / `{:error, _}`), where the
  unsafe stamped-but-unrenewed state persists so the caller MUST abort/stop and
  leave the row for reclaim/boot. Returns a decision (never fire-and-forget) so a
  caller cannot ignore a failed suspend and keep running.
  """
  @spec degrade_gate(String.t(), String.t()) :: :degrade | :fail_closed
  def degrade_gate(run_id, token) do
    case suspend_claim(run_id, token) do
      {:ok, 1} -> :degrade
      _ -> :fail_closed
    end
  end

  @doc """
  Claim the oldest reclaimable run (a system-level, cross-tenant scan), rotate its
  token, and return the reloaded run.

  `FOR UPDATE SKIP LOCKED` + `LIMIT 1` over the `:claimable` set (oldest first)
  picks one unlocked candidate; the CAS is redundant under the held row lock but
  kept uniform. Returns `{:ok, run, prior_owner}` (`prior_owner` = the pre-rotation
  `claimed_by`, the fenced zombie's node or `nil` — C-H1 kill-cast input), `:none`
  (nothing claimable), or `{:error, term()}`. The WS3 `ReclaimPooler` drains this
  to `:none` each poll.
  """
  @spec claim_next(keyword()) ::
          {:ok, WorkflowRun.t(), String.t() | nil} | :none | {:error, term()}
  def claim_next(_opts \\ []), do: claim_locked(&read_claimable/0, :none)

  @doc """
  Claim ONE specific run by id IF it is currently `:claimable`, rotating its token.

  The by-id sibling of `claim_next/1` for the composer reclaim child-step: lock the
  row `FOR UPDATE`, re-check the **full** `:claimable` predicate under the lock
  (expired lease, expired checkpoint-less gate, **or** aged never-claimed
  `:pending`), and only on a match
  CAS-rotate + reload. Returns `{:ok, run, prior_owner}` (rotated — a zombie owner
  is now fenced; `prior_owner` is the pre-rotation `claimed_by` for the C-H1
  kill-cast), `:lost` (not claimable — live lease, fresh-pending within grace,
  parked leaseless gate, terminal, or skipped), or `{:error, term()}`.

  The under-lock predicate re-check is the TOCTOU fence: `stamp/4` alone guards
  token+status but **not expiry**, so a bare CAS would steal a child that *renewed*
  between the parent's child-load and this claim (`renew/2` keeps the token, so the
  CAS would still match). The expiry re-check under the lock rejects it (`:lost`).
  """
  @spec claim_run(String.t()) ::
          {:ok, WorkflowRun.t(), String.t() | nil} | :lost | {:error, term()}
  def claim_run(run_id), do: claim_locked(fn -> read_claimable_by_id(run_id) end, :lost)

  # The shared locked-claim core. Run `select` inside a transaction; on a single
  # locked claimable run, CAS-rotate its token + reload (the rotation that fences a
  # surviving zombie); on the empty set return `empty` (`:none` for the oldest-first
  # scan, `:lost` for the by-id reclaim). The CAS-rotate (`claim_one`) lives here
  # ONCE for both `claim_next` and `claim_run` (clone gate).
  defp claim_locked(select, empty) do
    case Repo.transaction(fn ->
           case select.() do
             {:ok, [run]} -> claim_one(run)
             {:ok, []} -> empty
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {%WorkflowRun{} = run, prior_owner}} -> {:ok, run, prior_owner}
      {:ok, ^empty} -> empty
      {:error, reason} -> {:error, reason}
    end
  end

  # `query_to_claimable/1` is the Ash-generated builder for the `:claimable` read
  # (the `query_to_*` code-interface helper), now arg-bearing — the genesis-orphan
  # clause needs the runtime age cutoff (WS3 Component 2). Clock authority (C-M5):
  # the expired-lease clause compares `claim_expires_at` against the DB clock via a
  # raw `fragment("? < now()", ...)` (workflow_run.ex `:claimable`), and lease
  # expiry is itself stamped on the DB clock (`@stamp_sql`/`@renew_sql` use SQL
  # `now() + interval`), so eligibility is DB-clock on both sides — no cross-node
  # skew band remains. Only the genesis `:pending_cutoff` arg stays app-clock
  # (matched to app-written `inserted_at`). Double-run safety was never the clock's
  # job anyway: the fence is the clock-free token CAS (`stamp/4`) + renew-fence
  # (`renew/2`). No actor: the action is policy-bypassed + `multitenancy(:bypass)`
  # (a system scan, like `list_non_terminal_global`).
  defp read_claimable do
    pending_cutoff()
    |> WorkflowRun.query_to_claimable()
    # Exact upper-case literal: ash_postgres clause-matches the string to emit
    # SKIP LOCKED (the `:for_update` atom form emits none) — the trace_run.ex
    # retention-sweep precedent.
    |> Query.lock("FOR UPDATE SKIP LOCKED")
    |> Query.limit(1)
    |> Ash.read()
  end

  # The by-id variant of `read_claimable/0` for `claim_run/1`: the SAME `:claimable`
  # predicate, narrowed to one row and locked `FOR UPDATE` (blocking, NOT SKIP
  # LOCKED — a targeted reclaim WAITS through a brief append lock then re-checks
  # under it, where the oldest-first SCAN skips contended rows and moves on). Driving
  # *every* non-terminal child through this FULL predicate — not a pre-filter to
  # expired-lease only — is what lets an aged `:pending`+nil-token wave child (one
  # that crashed before `Middleware` stamped it) be claimed+failed rather than
  # skipped and permanently blocking `restartable?/3`.
  defp read_claimable_by_id(run_id) do
    pending_cutoff()
    |> WorkflowRun.query_to_claimable()
    |> Query.filter(id == ^run_id)
    |> Query.lock("FOR UPDATE")
    |> Query.limit(1)
    |> Ash.read()
  end

  # The genesis-orphan age cutoff passed as the `:claimable` arg: a never-claimed
  # `:pending` row is reclaimable only once `inserted_at < now() - grace`. App-clock
  # `utc_now` (matched to the app-clock `now()` Ash compiles the expired-lease clause
  # to). Computed per scan so each poll uses a fresh cutoff.
  defp pending_cutoff, do: DateTime.add(DateTime.utc_now(), -pending_grace_seconds(), :second)

  # Under the held FOR UPDATE the row can't change beneath us, so a `:lost`/error
  # here is a genuine fault — roll the whole claim back rather than return a
  # half-claimed run. Returns `{reloaded_run, prior_owner}`: `prior_owner` is the
  # PRE-rotation `claimed_by` (the fenced zombie's node, or `nil` for a
  # never-claimed genesis orphan), captured here off the locked SELECT before the
  # CAS rotates the token — C-H1 threads it out so a reclaimer can best-effort
  # kill-cast the old executor after driving the run terminal.
  defp claim_one(run) do
    case stamp(run.id, Ash.UUID.generate(), run.claim_token, tenant: run.tenant_id) do
      {:ok, :claimed} -> {reload_claimed(run), run.claimed_by}
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
  Classify a `fence_decision/3` `:kill` by its raw `renew/2` result — the
  `fenced_out` telemetry reason. `:stolen` = the token was rotated away
  (`{:ok, 0}`); `:lapsed` = a renew error past the lease window.

  In the sidecar's `:kill` branch the raw result is only ever `{:ok, 0}` or
  `{:error, _}` (`{:ok, n >= 1}` is `:renewed`) — the clauses match exactly
  that precondition, deliberately with no catch-all, so an impossible input
  fails loud rather than being silently classified.
  """
  @spec fenced_reason({:ok, 0} | {:error, term()}) :: :stolen | :lapsed
  def fenced_reason({:ok, 0}), do: :stolen
  def fenced_reason({:error, _}), do: :lapsed

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

  @doc """
  Gracefully stop the local heartbeat owned by `token` before that owner writes
  its own terminal event.

  A missing sidecar is a valid single-node degraded/already-stopped shape. A
  different/foreign registry owner is deliberately left untouched and treated
  as a no-op; the authoritative DB terminal-append token fence then decides
  ownership. The acknowledgement is correlated and sent only by the matching
  sidecar, so once that branch returns `:ok` no later heartbeat can mistake the
  owner's terminal token revocation for an external fence and kill the finishing
  executor.
  """
  @spec stop_sidecar(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def stop_sidecar(_run_id, nil), do: :ok

  def stop_sidecar(run_id, token) when is_binary(run_id) and is_binary(token) do
    case Registry.lookup(@registry, run_id) do
      [] ->
        :ok

      [{pid, %{token: ^token}}] ->
        ref = Process.monitor(pid)
        correlation = make_ref()
        send(pid, {:lease_stop, self(), correlation, token})

        receive do
          {:lease_stopped, ^correlation, ^run_id, ^token} ->
            Process.demonitor(ref, [:flush])
            :ok

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:error, {:sidecar_down, reason}}
        after
          @ready_timeout_ms ->
            # A sidecar can be stuck inside its DB renew query and unable to
            # consume the stop message. This owner is already in terminal
            # middleware (no more steps can launch), so retire that exact,
            # token-matched sidecar untrappably and let the terminal append's
            # DB token fence arbitrate any concurrent cancellation/reclaim.
            Logger.warning("[WorkflowLease] forcing stuck sidecar stop for #{run_id}")
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^ref, :process, ^pid, _reason} ->
                :ok
            after
              1_000 ->
                Process.demonitor(ref, [:flush])
                {:error, :sidecar_force_stop_timeout}
            end
        end

      [{_pid, _metadata}] ->
        :ok
    end
  end

  @doc """
  Retire the matching local sidecar before a terminal append, without letting
  teardown failure suppress the terminal authority.

  Both strict `stop_sidecar/2` error returns mean the matching sidecar is
  already dead or has been untrappably killed. The terminal append's durable
  claim-token fence remains the ownership authority, so callers must continue
  to that append while this helper records the teardown anomaly.
  """
  @spec stop_sidecar_best_effort(String.t(), String.t() | nil) :: :ok
  def stop_sidecar_best_effort(run_id, token) do
    case stop_sidecar(run_id, token) do
      :ok -> :ok
      {:error, reason} -> report_sidecar_stop_failure(run_id, reason)
    end
  rescue
    # Terminal durability outranks a cleanup exception. Keep the open failure
    # set observable, but never let it suppress the token-fenced append.
    # reach:disable-next-line bare_rescue
    error -> report_sidecar_stop_failure(run_id, {:exception, Exception.message(error)})
  catch
    kind, reason -> report_sidecar_stop_failure(run_id, {kind, reason})
  end

  defp report_sidecar_stop_failure(run_id, reason) do
    Logger.warning(
      "[WorkflowLease] sidecar stop failed for #{run_id}; continuing to terminal append: " <>
        inspect(reason)
    )

    :telemetry.execute(
      [:jido_claw, :orchestration, :sidecar_stop_failed],
      %{count: 1},
      %{run_id: run_id, reason: sidecar_stop_reason(reason)}
    )

    :ok
  end

  defp sidecar_stop_reason({:sidecar_down, _reason}), do: :sidecar_down
  defp sidecar_stop_reason(:sidecar_force_stop_timeout), do: :force_stop_timeout
  defp sidecar_stop_reason({:exception, _message}), do: :exception
  defp sidecar_stop_reason({kind, _reason}) when is_atom(kind), do: kind
  defp sidecar_stop_reason(_reason), do: :error

  defp dump_or_nil(nil), do: nil
  defp dump_or_nil(token), do: Ecto.UUID.dump!(token)
end
