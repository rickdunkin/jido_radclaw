defmodule JidoClaw.Orchestration.WorkflowLeaseTest.OkStep do
  @moduledoc false
  use Reactor.Step

  @impl Reactor.Step
  def run(_args, _context, _opts), do: {:ok, :done}
end

defmodule JidoClaw.Orchestration.WorkflowLeaseTest.OkReactor do
  @moduledoc false
  use Reactor

  step(:only, JidoClaw.Orchestration.WorkflowLeaseTest.OkStep)
  return(:only)
end

defmodule JidoClaw.Orchestration.WorkflowLeaseTest do
  @moduledoc """
  WS1 lease core: the stamp/renew/claim_next primitives, the `Lease.Middleware`
  + `Sidecar`, self-claim on launch, and the two fences (runner-side A,
  append-side B).

  `async: false` + the shared sandbox (`JidoClaw.TenantCase`) so the executor
  task and its lease sidecar — both off the test process — share the sandbox
  connection. Expired leases / rotated tokens are seeded via raw `Repo.query!`
  (the `retention_sweeper_test` backdating precedent); the production auto-renew
  timer is parked by `renew_seconds: 86_400` in test config, so tests drive the
  sidecar through the `{:lease_tick, from}` seam.
  """
  use JidoClaw.TenantCase, async: false

  import JidoClaw.Orchestration.LeaseHelpers

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.GateStep
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLease.Middleware, as: LeaseMiddleware
  alias JidoClaw.Orchestration.WorkflowLeaseTest.OkReactor
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Repo
  alias Reactor.Builder

  @lease_registry JidoClaw.Orchestration.LeaseRegistry

  setup do
    tenant = seed_tenant("lease")

    # Backstop: kill any executor/sidecar leaked by an assertion failure before
    # a per-launch on_exit tracked it. Safe only because the file is async:
    # false (no other test's tasks are on these singletons).
    on_exit(fn ->
      for sup <- [
            JidoClaw.Orchestration.RunTaskSupervisor,
            JidoClaw.Orchestration.LeaseTaskSupervisor
          ],
          pid <- Task.Supervisor.children(sup) do
        Process.exit(pid, :kill)
      end
    end)

    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  # ── 1. claim_next: lock pin + selection ────────────────────────────────────

  describe "claim_next/1 lock + selection" do
    test "the :claimable query carries FOR UPDATE SKIP LOCKED down to the SQL" do
      query =
        DateTime.utc_now()
        |> WorkflowRun.query_to_claimable()
        |> Ash.Query.limit(1)
        |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")

      assert query.lock == "FOR UPDATE SKIP LOCKED"

      %{query: ecto_query} = Ash.data_layer_query!(query)
      {sql, _params} = Repo.to_sql(:all, ecto_query)
      assert sql =~ "FOR UPDATE"
      assert sql =~ "SKIP LOCKED"
    end

    test "selects oldest-first, stamps once, exhausts to :none; claimed/future skipped", ctx do
      # Three pending-unclaimed runs (claimable), backdated for a deterministic
      # oldest-first order.
      oldest = seed_run(ctx, "oldest")
      mid = seed_run(ctx, "mid")
      newest = seed_run(ctx, "newest")
      backdate_inserted!(oldest.id, 180)
      backdate_inserted!(mid.id, 120)
      backdate_inserted!(newest.id, 60)

      # A future-expiry claimed run and a terminal run — both NON-claimable.
      future = seed_run(ctx, "future")
      set_claim!(future.id, Ash.UUID.generate(), 600)
      terminal = seed_run(ctx, "terminal")
      set_status!(terminal.id, "failed")

      assert {:ok, %WorkflowRun{} = a} = WorkflowLease.claim_next()
      assert {:ok, %WorkflowRun{} = b} = WorkflowLease.claim_next()
      assert {:ok, %WorkflowRun{} = c} = WorkflowLease.claim_next()
      assert :none = WorkflowLease.claim_next()

      assert [a.id, b.id, c.id] == [oldest.id, mid.id, newest.id]
      assert Enum.all?([a, b, c], &is_binary(&1.claim_token))
      # The non-claimable rows were never touched.
      assert is_nil(reload_global(future.id).claim_token) == false
      assert reload_global(terminal.id).status == :failed
    end
  end

  # ── 2. fence: renew/2 ───────────────────────────────────────────────────────

  describe "renew/2 fence" do
    test "renews on the current token, fails (0) on a rotated one", ctx do
      run = seed_run(ctx)
      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)

      assert {:ok, 1} = WorkflowLease.renew(run.id, token)

      rotated = Ash.UUID.generate()
      rotate_token!(run.id, rotated)

      assert {:ok, 0} = WorkflowLease.renew(run.id, token)
      assert {:ok, 1} = WorkflowLease.renew(run.id, rotated)
    end
  end

  # ── 2b. suspend_claim/2 + degrade_gate/2 (WS3 P1 single-node degrade) ────────

  describe "suspend_claim/2" do
    test "NULLs the expiry on the held token (keeping token/claimed_by) → unreclaimable", ctx do
      run = seed_run(ctx)
      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)

      before = reload_global(run.id)
      refute is_nil(before.claim_expires_at)
      assert before.claim_token == token

      assert {:ok, 1} = WorkflowLease.suspend_claim(run.id, token)

      after_suspend = reload_global(run.id)
      assert is_nil(after_suspend.claim_expires_at)
      # Token + owner retained — the durable fences + restart preflight still match.
      assert after_suspend.claim_token == token
      assert after_suspend.claimed_by == before.claimed_by

      # A NULL expiry + non-nil token is selected by neither :claimable clause.
      assert :none = WorkflowLease.claim_next()
    end

    test "is token-fenced: a rotated token suspends 0 rows + leaves the expiry untouched", ctx do
      run = seed_run(ctx)
      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)

      rotated = Ash.UUID.generate()
      rotate_token!(run.id, rotated)
      before = reload_global(run.id)

      # The held (now-stale) token's CAS matches 0 rows.
      assert {:ok, 0} = WorkflowLease.suspend_claim(run.id, token)

      after_attempt = reload_global(run.id)
      assert after_attempt.claim_token == rotated
      refute is_nil(after_attempt.claim_expires_at)
      assert after_attempt.claim_expires_at == before.claim_expires_at
    end
  end

  describe "degrade_gate/2" do
    test "matching token → :degrade + the expiry is NULLed", ctx do
      run = seed_run(ctx, "degrade-ok")
      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)

      assert :degrade = WorkflowLease.degrade_gate(run.id, token)
      assert is_nil(reload_global(run.id).claim_expires_at)
    end

    test "rotated token (suspend 0) → :fail_closed + the row is unchanged", ctx do
      run = seed_run(ctx, "degrade-lost")
      held = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, held, nil)

      rotated = Ash.UUID.generate()
      rotate_token!(run.id, rotated)
      before = reload_global(run.id)

      # The suspend lost the CAS, so the gate refuses to let the caller proceed —
      # guarding "degrade proceeds ONLY when the suspend succeeds" at the single
      # source both call sites branch on.
      assert :fail_closed = WorkflowLease.degrade_gate(run.id, held)

      after_gate = reload_global(run.id)
      assert after_gate.claim_token == rotated
      assert after_gate.claim_expires_at == before.claim_expires_at
    end
  end

  # ── 3. Lease middleware halt (fence A via the sidecar kill) ─────────────────

  describe "lease middleware halt (fence A)" do
    test "a rotated token fences the live executor: kill → {:error, :fenced}, no terminal", ctx do
      {launcher, run_id, _executor} = launch_blocking(ctx)

      original = reload_global(run_id)
      assert is_binary(original.claim_token)

      # A reclaimer rotates the token out from under the live owner.
      reclaimer_token = Ash.UUID.generate()
      rotate_token!(run_id, reclaimer_token)

      # Drive the sidecar's heartbeat manually (prod timer is parked in test).
      assert [{sidecar, _meta}] = Registry.lookup(@lease_registry, run_id)
      send(sidecar, {:lease_tick, self()})
      # The renew with the stale token renews 0 rows → fence_decision → kill.
      assert_receive {:lease_ticked, {:ok, 0}}, 5_000

      # The kill surfaces as the clean fenced stop, with NO terminal written.
      assert {:error, :fenced, %WorkflowRun{status: :running} = run} = Task.await(launcher, 5_000)
      assert run.claim_token == reclaimer_token

      run_kinds = kinds(run_id, ctx)
      refute :run_failed in run_kinds
      refute :run_completed in run_kinds
    end
  end

  # ── 4. reclaim selection (expired-claimed re-stamped; future skipped) ───────

  describe "reclaim selection" do
    test "an expired-claimed run is reclaimed + re-stamped; a future-expiry one is skipped",
         ctx do
      expired = seed_run(ctx, "expired")
      set_status!(expired.id, "running")
      old_token = Ash.UUID.generate()
      set_claim!(expired.id, old_token, -120)

      fresh = seed_run(ctx, "fresh")
      set_status!(fresh.id, "running")
      fresh_token = Ash.UUID.generate()
      set_claim!(fresh.id, fresh_token, 600)

      assert {:ok, %WorkflowRun{} = claimed} = WorkflowLease.claim_next()
      assert claimed.id == expired.id
      assert is_binary(claimed.claim_token) and claimed.claim_token != old_token

      # The future-expiry run was never a candidate — nothing left claimable.
      assert :none = WorkflowLease.claim_next()
      assert reload_global(fresh.id).claim_token == fresh_token
    end
  end

  # ── 5. status untouched by claim ops ────────────────────────────────────────

  describe "projection-ownership invariant" do
    test "stamp/renew never write status; the projection still flips it", ctx do
      run = seed_run(ctx)
      token = Ash.UUID.generate()

      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)
      assert {:ok, 1} = WorkflowLease.renew(run.id, token)
      assert reload_global(run.id).status == :pending

      assert {:ok, _event} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))
      assert reload_global(run.id).status == :running
    end
  end

  # ── 6. single-node identity (byte-identical + self-claimed) ─────────────────

  describe "single-node self-claim" do
    test "a module reactor completes with the usual events and is self-claimed", ctx do
      assert {:ok, :done, run} = ReactorRunner.run(OkReactor, %{}, scope(ctx))
      assert run.status == :completed

      # Self-claimed: the execution winner stamped its identity + token, and the
      # terminal leaves the claim columns intact (only the checkpoint is cleared).
      reloaded = reload_global(run.id)
      assert is_binary(reloaded.claim_token)
      assert reloaded.claimed_by == to_string(Node.self())

      # The lease middleware emits no events — the timeline is byte-identical.
      assert kinds(run.id, ctx) ==
               [:run_started, :step_started, :step_completed, :run_completed]
    end
  end

  # ── 7. terminal-append fence (fence B) ──────────────────────────────────────

  describe "terminal-append fence (fence B)" do
    test "a stale-token terminal is rejected in-transaction; the current token succeeds", ctx do
      run = seed_run(ctx)
      assert {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))

      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)
      rotated = Ash.UUID.generate()
      rotate_token!(run.id, rotated)

      # Stale fence token (the old owner) → rejected, run stays :running.
      assert {:error, _} =
               WorkflowLog.append(
                 run,
                 :run_completed,
                 %{},
                 Keyword.put(scope(ctx), :claim_fence_token, token)
               )

      assert reload_global(run.id).status == :running

      # The current owner's token → the terminal lands.
      assert {:ok, _} =
               WorkflowLog.append(
                 run,
                 :run_completed,
                 %{},
                 Keyword.put(scope(ctx), :claim_fence_token, rotated)
               )

      assert reload_global(run.id).status == :completed
    end
  end

  # ── 8. same-node duplicate (loser never reaches Lease.init) ─────────────────

  describe "same-node duplicate" do
    test "a duplicate run_killable returns {:duplicate, _} and never re-stamps", ctx do
      {_launcher, run_id, _executor} = launch_blocking(ctx)
      original = reload_global(run_id)
      assert is_binary(original.claim_token)

      # A second executor for the same run id loses RunRegistry registration and
      # returns the conflict sentinel without running the reactor — so Lease.init
      # (and the stamp) is never reached.
      assert {:duplicate, _pid} =
               RunExecution.run_killable(OkReactor, %{}, %{},
                 run_id: run_id,
                 tenant_id: ctx.tenant
               )

      assert reload_global(run_id).claim_token == original.claim_token
    end
  end

  # ── 9. CAS / cross-node duplicate ───────────────────────────────────────────

  describe "stamp/4 compare-and-swap" do
    test "claims on a matching expected token, loses on a stale one (nil-safe)", ctx do
      run = seed_run(ctx)

      # nil expected on a never-claimed row → claimed (genesis).
      t1 = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, t1, nil)

      # A stale expected → lost, no mutation.
      assert {:ok, :lost} = WorkflowLease.stamp(run.id, Ash.UUID.generate(), Ash.UUID.generate())
      assert reload_global(run.id).claim_token == t1

      # The matching current token → claimed (rotates to t2).
      t2 = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, t2, t1)
      assert reload_global(run.id).claim_token == t2

      # nil expected on a now-non-nil row → lost.
      assert {:ok, :lost} = WorkflowLease.stamp(run.id, Ash.UUID.generate(), nil)
    end
  end

  # ── 10 & 16. middleware ordering / resume normalization ─────────────────────

  describe "normalize_middleware/1" do
    test "prepends [WorkflowLease.Middleware, ReactorMiddleware] when ReactorMiddleware is declared" do
      {:ok, base} =
        Builder.add_middleware(Builder.new(), JidoClaw.Orchestration.ReactorMiddleware)

      assert {:ok, normalized} = ReactorRunner.normalize_middleware(base)

      assert [
               JidoClaw.Orchestration.WorkflowLease.Middleware,
               JidoClaw.Orchestration.ReactorMiddleware
             ] = normalized.middleware
    end

    test "re-establishes the lease on a reactor whose middleware lacks it (resume path)" do
      base = Builder.new()
      assert base.middleware == []

      assert {:ok, normalized} = ReactorRunner.normalize_middleware(base)

      assert [
               JidoClaw.Orchestration.WorkflowLease.Middleware,
               JidoClaw.Orchestration.ReactorMiddleware
             ] = normalized.middleware
    end
  end

  # ── 11. expired *claimed* :pending is selectable ────────────────────────────

  describe "claimable shapes" do
    test "an expired claimed :pending run (crash-after-stamp shape) is claimable", ctx do
      run = seed_run(ctx)
      # :pending + a non-nil but expired claim — the crash-after-stamp shape.
      set_claim!(run.id, Ash.UUID.generate(), -90)

      assert {:ok, claimable} = WorkflowLease.claim_next()
      assert claimable.id == run.id
    end
  end

  # ── 12. sidecar readiness fail-closed vs degrade ────────────────────────────

  describe "sidecar readiness" do
    @tag :capture_log
    test "a sidecar that can't arm fails closed under clustering; single-node suspends + degrades",
         ctx do
      # Inject a start failure by pre-owning the run-id key so the sidecar's
      # Registry.register loses and it exits before signalling ready. WS2: a
      # PERMANENT blocker is never freed, so the sidecar exhausts its bounded
      # registration retries (~500 ms, still < the 5 s readiness deadline) before
      # exiting — the outcome below is unchanged (just slightly slower).
      run_a = seed_run(ctx, "fail-closed")
      {:ok, _} = Registry.register(@lease_registry, run_a.id, :blocker)
      token_a = Ash.UUID.generate()
      ctx_a = %{claim_token: token_a, workflow_run: run_a}

      with_cluster_enabled(true, fn ->
        assert {:error, {:lease_sidecar, _reason}} = LeaseMiddleware.init(ctx_a)
      end)

      # Cluster: the stamped row is LEFT stamped (no suspend) so the runner's
      # finalize + WS3 reclaim handle it.
      reloaded_a = reload_global(run_a.id)
      assert reloaded_a.claim_token == token_a
      refute is_nil(reloaded_a.claim_expires_at)

      run_b = seed_run(ctx, "degrade")
      {:ok, _} = Registry.register(@lease_registry, run_b.id, :blocker)
      token_b = Ash.UUID.generate()
      ctx_b = %{claim_token: token_b, workflow_run: run_b}

      with_cluster_enabled(false, fn ->
        assert {:ok, ^ctx_b} = LeaseMiddleware.init(ctx_b)
      end)

      # Single-node: degrade SUSPENDED the just-stamped claim (NULL expiry, token
      # kept) so the always-on Pooler cannot reclaim this live, unleased executor.
      reloaded_b = reload_global(run_b.id)
      assert reloaded_b.claim_token == token_b
      assert is_nil(reloaded_b.claim_expires_at)
    end
  end

  # ── 12b. sidecar registration retry (WS2 lease-handoff race) ────────────────

  describe "sidecar registration retry" do
    test "start_sidecar retries on :already_registered until the prior owner frees the key",
         ctx do
      # The lease-handoff race WS2's restart hits: a TEMPORARY blocker pre-owns the
      # `:unique` key (the prior sidecar mid-`:DOWN`) then frees it shortly after, so
      # the new sidecar's first Registry.register loses but a bounded retry wins.
      run = seed_run(ctx, "register-retry")
      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)

      test_pid = self()

      blocker =
        spawn(fn ->
          {:ok, _} = Registry.register(@lease_registry, run.id, :blocker)
          send(test_pid, :blocker_registered)
          Process.sleep(100)
          Registry.unregister(@lease_registry, run.id)
          send(test_pid, :blocker_unregistered)
        end)

      assert_receive :blocker_registered, 1_000

      # start_sidecar consumes the readiness handshake internally; the sidecar retries
      # registration (~50 ms cadence, < the 5 s readiness deadline) until the blocker
      # frees the key, then arms its monitor + signals ready.
      assert :ok = WorkflowLease.start_sidecar(self(), run.id, ctx.tenant, token)

      # The retry won the key — the sidecar (not the blocker) now owns it.
      assert [{sidecar, %{token: ^token}}] = Registry.lookup(@lease_registry, run.id)
      assert is_pid(sidecar)
      assert sidecar != blocker
      assert_receive :blocker_unregistered, 1_000
    end
  end

  # ── 13. fail-closed renew (pure fence_decision) ─────────────────────────────

  describe "fence_decision/3" do
    test "is pure and fails closed" do
      lease_ms = 60_000

      assert :renewed = WorkflowLease.fence_decision({:ok, 1}, 0, lease_ms)
      assert :kill = WorkflowLease.fence_decision({:ok, 0}, 0, lease_ms)
      # DB error past the lease window → kill (fail-closed).
      assert :kill = WorkflowLease.fence_decision({:error, :boom}, lease_ms, lease_ms)
      assert :kill = WorkflowLease.fence_decision({:error, :boom}, lease_ms + 1, lease_ms)
      # DB error still inside the window → bounded retry.
      assert {:retry, ms} = WorkflowLease.fence_decision({:error, :boom}, 0, lease_ms)
      assert ms > 0
    end
  end

  # ── 14. raw-SQL UUID binding round-trip ─────────────────────────────────────

  describe "raw-SQL UUID binding" do
    test "stamp + renew round-trip the dumped id/token", ctx do
      run = seed_run(ctx)
      token = Ash.UUID.generate()

      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)

      reloaded = reload_global(run.id)
      assert reloaded.claim_token == token
      assert %DateTime{} = reloaded.claim_expires_at

      # renew matches the dumped token exactly (binary binding is consistent).
      assert {:ok, 1} = WorkflowLease.renew(run.id, token)
    end
  end

  # ── 15. cancel before Lease.init ────────────────────────────────────────────

  describe "cancel before Lease.init" do
    test "a terminal landing first makes the late stamp a no-op → no terminal, no registry",
         ctx do
      run = seed_run(ctx)
      assert {:ok, _} = WorkflowLog.append(run, :run_cancelled, %{}, scope(ctx))
      cancelled = reload_global(run.id)
      assert cancelled.status == :cancelled

      token = Ash.UUID.generate()
      context = %{claim_token: token, workflow_run: cancelled}

      # The status-guarded stamp returns {:ok, :lost} (cancelled ∉ pending/running).
      assert {:error, {:lease_lost, _id}} = LeaseMiddleware.init(context)

      # Nothing was claimed, nothing registered, status untouched.
      assert is_nil(reload_global(run.id).claim_token)
      assert Registry.lookup(@lease_registry, run.id) == []
      assert reload_global(run.id).status == :cancelled

      # The runner maps the abort to the clean cancellation envelope.
      opts = Keyword.put(scope(ctx), :claim_token, token)

      assert {:error, :cancelled, %WorkflowRun{status: :cancelled}} =
               ReactorRunner.finalize({:error, {:lease_lost, run.id}}, cancelled, opts)
    end
  end

  # ── 17. status-guarded CAS on a non-cancel terminal ─────────────────────────

  describe "status-guarded CAS" do
    test "a matching-token stamp on a :failed/:completed row is a no-op (not just cancel-shaped)",
         ctx do
      for status <- ["failed", "completed"] do
        run = seed_run(ctx, "terminal-#{status}")
        token = Ash.UUID.generate()
        assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)
        before = reload_global(run.id)
        set_status!(run.id, status)

        # Even with the MATCHING expected token, the status guard refuses.
        assert {:ok, :lost} = WorkflowLease.stamp(run.id, Ash.UUID.generate(), token)

        after_guard = reload_global(run.id)
        assert after_guard.claim_token == before.claim_token
        assert after_guard.claimed_by == before.claimed_by
      end
    end
  end

  # ── 18. gate-halt fence (fence B gate flip + fence A halt) ──────────────────

  describe "gate-halt fence" do
    test "fence B rejects a stale approval_requested; the current token flips the gate", ctx do
      run = seed_run(ctx)
      assert {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))

      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)
      rotated = Ash.UUID.generate()
      rotate_token!(run.id, rotated)

      payload = %{agent_case_id: Ash.UUID.generate()}

      # Stale fence token (the old owner) → rejected in-txn, run stays :running.
      assert {:error, _} =
               WorkflowLog.append(
                 run,
                 :approval_requested,
                 payload,
                 Keyword.put(scope(ctx), :claim_fence_token, token)
               )

      assert reload_global(run.id).status == :running

      # The current owner's token → the gate flip lands.
      assert {:ok, _} =
               WorkflowLog.append(
                 run,
                 :approval_requested,
                 payload,
                 Keyword.put(scope(ctx), :claim_fence_token, rotated)
               )

      assert reload_global(run.id).status == :awaiting_approval
    end

    test "fence A on a rotated-token halt writes no checkpoint", ctx do
      run = seed_run(ctx)
      assert {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))

      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)

      # A legit gate flip under the held token T parks the run at the gate.
      assert {:ok, _} =
               WorkflowLog.append(
                 run,
                 :approval_requested,
                 %{agent_case_id: Ash.UUID.generate()},
                 Keyword.put(scope(ctx), :claim_fence_token, token)
               )

      reloaded = reload_global(run.id)
      assert reloaded.status == :awaiting_approval

      # A reclaimer rotates the token AFTER approval_requested commits but BEFORE
      # the checkpoint write (the append→checkpoint TOCTOU).
      rotated = Ash.UUID.generate()
      rotate_token!(run.id, rotated)

      # scope(ctx) tenant/actor are REQUIRED: finalize's reload reads
      # WorkflowRun.by_id(tenant:, actor:) and, on a nil-tenant miss, falls back
      # to the stale in-memory run — which carries the pre-rotation token and
      # would defeat the fence.
      opts = Keyword.merge(scope(ctx), claim_token: token, inputs: %{}, reactor_module: nil)

      # The reactor arg is inert: the fence short-circuits before handle_gate_pause.
      assert {:error, :fenced, %WorkflowRun{}} =
               ReactorRunner.finalize({:halted, Builder.new()}, reloaded, opts)

      assert is_nil(reload_global(run.id).encrypted_resume_checkpoint)
    end

    test "GateStep.run/3 threads the held token; a stale owner's gate open rolls back", ctx do
      run = seed_run(ctx)
      assert {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))
      running = reload_global(run.id)

      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)
      rotated = Ash.UUID.generate()
      rotate_token!(run.id, rotated)

      assert {:error, _} =
               GateStep.run(
                 %{},
                 %{workflow_run: running, actor: ctx.actor, claim_token: token},
                 gate_module: TestIrreversibleWrite,
                 step_name: "gate",
                 details: %{}
               )

      # The whole gate_open transaction rolled back: no flip, no AgentCase.
      assert reload_global(run.id).status == :running
      assert {:ok, []} = AgentCase.pending_for_run(run.id, scope(ctx))
    end
  end

  # ── 19. stamp-error fail-close (claim-aware) ────────────────────────────────

  describe "stamp-error fail-close (claim-aware)" do
    @tag :capture_log
    test "genesis (nil prior) single-node degrades: {:ok, ctx}, row left unstamped", ctx do
      run = seed_run(ctx, "genesis-degrade")
      ctx_in = %{claim_token: Ash.UUID.generate(), workflow_run: run}

      with_forced_stamp_error(fn ->
        with_cluster_enabled(false, fn ->
          assert {:ok, ^ctx_in} = LeaseMiddleware.init(ctx_in)
        end)
      end)

      # Nothing was ever stamped — byte-identical to the pre-lease world.
      reloaded = reload_global(run.id)
      assert is_nil(reloaded.claim_token)
      assert is_nil(reloaded.claim_expires_at)
    end

    @tag :capture_log
    test "genesis (nil prior) cluster fails closed: {:error, {:lease_claim, :forced}}", ctx do
      run = seed_run(ctx, "genesis-cluster")
      ctx_in = %{claim_token: Ash.UUID.generate(), workflow_run: run}

      with_forced_stamp_error(fn ->
        with_cluster_enabled(true, fn ->
          assert {:error, {:lease_claim, :forced}} = LeaseMiddleware.init(ctx_in)
        end)
      end)

      assert is_nil(reload_global(run.id).claim_token)
    end

    @tag :capture_log
    test "already-claimed + NULL prior expiry: fails closed single-node + re-arms for reclaim",
         ctx do
      # Seed the sidecar-degrade residual shape: {prior token, NULL expiry, :running}.
      run = seed_run(ctx, "reclaim-rearm")
      set_status!(run.id, "running")
      prior = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, prior, nil)
      assert {:ok, 1} = WorkflowLease.suspend_claim(run.id, prior)
      assert is_nil(reload_global(run.id).claim_expires_at)

      # A GateResume/recovery re-stamp puts a FRESH token in ctx on a row that still
      # holds the PRIOR token. The forced stamp error never rotates it.
      fresh = Ash.UUID.generate()
      ctx_in = %{claim_token: fresh, workflow_run: reload_global(run.id)}

      with_forced_stamp_error(fn ->
        with_cluster_enabled(false, fn ->
          assert {:error, {:lease_claim, :forced}} = LeaseMiddleware.init(ctx_in)
        end)
      end)

      # Fail closed (no degrade): the row still holds the PRIOR token, but the re-arm
      # pushed its NULL expiry NON-NULL so the always-on Pooler can reclaim it.
      after_init = reload_global(run.id)
      assert after_init.claim_token == prior
      refute is_nil(after_init.claim_expires_at)

      # Backdate the re-armed expiry and prove claim_next/0 actually claims it — the
      # residual is now Pooler-reclaimable, not boot-recovery-only.
      set_claim!(run.id, prior, -1)
      assert {:ok, claimed} = WorkflowLease.claim_next()
      assert claimed.id == run.id
    end

    @tag :capture_log
    test "already-claimed cluster also fails closed (re-stamp branch is mode-independent)", ctx do
      run = seed_run(ctx, "reclaim-cluster")
      set_status!(run.id, "running")
      prior = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, prior, nil)

      ctx_in = %{claim_token: Ash.UUID.generate(), workflow_run: reload_global(run.id)}

      with_forced_stamp_error(fn ->
        with_cluster_enabled(true, fn ->
          assert {:error, {:lease_claim, :forced}} = LeaseMiddleware.init(ctx_in)
        end)
      end)

      # The failed CAS did not rotate — the row stays on the prior token.
      assert reload_global(run.id).claim_token == prior
    end

    @tag :capture_log
    test "finalize on a re-stamp lease_claim error is fenced (no terminal), re-resumable", ctx do
      run = seed_run(ctx, "finalize-fenced")
      assert {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))
      prior = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, prior, nil)
      running = reload_global(run.id)
      assert running.status == :running
      assert running.claim_token == prior

      # The resume holds a FRESH token; the row is still on the PRIOR one → fence A.
      opts = Keyword.put(scope(ctx), :claim_token, Ash.UUID.generate())

      assert {:error, :fenced, %WorkflowRun{status: :running}} =
               ReactorRunner.finalize({:error, {:lease_claim, :forced}}, running, opts)

      # No terminal written — the run is left :running, re-resumable by reclaim/boot.
      refute :run_failed in kinds(run.id, ctx)
    end

    @tag :capture_log
    test "release_for_reclaim/2 re-arms a held token (rotated = no-op); cooldown floors at 1s",
         ctx do
      run = seed_run(ctx, "rearm-unit")
      token = Ash.UUID.generate()
      assert {:ok, :claimed} = WorkflowLease.stamp(run.id, token, nil)
      assert {:ok, 1} = WorkflowLease.suspend_claim(run.id, token)
      assert is_nil(reload_global(run.id).claim_expires_at)

      # Held token → re-armed to a non-NULL expiry (~now()+cooldown), token kept.
      assert :ok = WorkflowLease.release_for_reclaim(run.id, token)
      rearmed = reload_global(run.id)
      refute is_nil(rearmed.claim_expires_at)
      assert rearmed.claim_token == token

      # Rotated token → token-fenced no-op (0 rows), still :ok, expiry untouched.
      rotated = Ash.UUID.generate()
      rotate_token!(run.id, rotated)
      before = reload_global(run.id)
      assert :ok = WorkflowLease.release_for_reclaim(run.id, token)
      after_attempt = reload_global(run.id)
      assert after_attempt.claim_token == rotated
      assert after_attempt.claim_expires_at == before.claim_expires_at

      # The cooldown floors at 1s even with a sub-second poll interval.
      prev = Application.get_env(:jido_claw, :reclaim_pooler, [])
      Application.put_env(:jido_claw, :reclaim_pooler, Keyword.put(prev, :poll_interval_ms, 500))

      try do
        assert WorkflowLease.reclaim_cooldown_seconds() == 1
      after
        Application.put_env(:jido_claw, :reclaim_pooler, prev)
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp scope(%{tenant: tenant, actor: actor}), do: [tenant: tenant, actor: actor]
end
