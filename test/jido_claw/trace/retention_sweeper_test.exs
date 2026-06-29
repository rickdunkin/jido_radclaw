defmodule JidoClaw.Trace.RetentionSweeperTest do
  @moduledoc """
  Pins the M7 retention sweep: `TraceRun.sweep_expired/1` (selection on
  `updated_at`, single-transaction locked event→run delete, batch/`more?`
  semantics) and the `RetentionSweeper` tick path (config-driven cutoff,
  disabled no-op).

  Rows are backdated via raw SQL — `updated_at` is an Ash-managed
  `update_timestamp`, so the only way to age a row is to mutate it directly
  (same precedent as `persistence_test.exs`'s NULL `schema_version` UPDATE).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Repo
  alias JidoClaw.Trace.Resources.{TraceEvent, TraceRun}
  alias JidoClaw.Trace.RetentionSweeper

  setup do
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    previous = Application.get_env(:jido_claw, :trace)

    on_exit(fn ->
      if previous do
        Application.put_env(:jido_claw, :trace, previous)
      else
        Application.delete_env(:jido_claw, :trace)
      end
    end)

    {:ok, previous_trace_cfg: previous}
  end

  describe "TraceRun.sweep_expired/1" do
    test "deletes an expired run with its events; fresh rows survive" do
      expired = seed_trace!("exp-#{unique()}")
      fresh = seed_trace!("fresh-#{unique()}")
      backdate_run!(expired, 60)

      assert {:ok, 1, false} = TraceRun.sweep_expired(cutoff_days_ago(30))

      assert run_count(expired) == 0
      assert event_count(expired) == 0
      assert run_count(fresh) == 1
      assert event_count(fresh) == 2
    end

    test "an old-but-active trace survives: retention keys on updated_at, not inserted_at" do
      active = seed_trace!("active-#{unique()}")
      # Old inserted_at, untouched (fresh) updated_at — a long-lived trace
      # that Persistence keeps upserting.
      Repo.query!(
        "UPDATE trace_runs SET inserted_at = now() - make_interval(days => 60) WHERE trace_id = $1",
        [active]
      )

      assert {:ok, 0, false} = TraceRun.sweep_expired(cutoff_days_ago(30))
      assert run_count(active) == 1
      assert event_count(active) == 2
    end

    test "a backlog larger than one batch reports more? only on the full cleanly-deleted batch" do
      prefix = "drain-#{unique()}"
      seed_expired_runs_sql!(prefix, 1_001)

      cutoff = cutoff_days_ago(30)

      assert {:ok, 1_000, true} = TraceRun.sweep_expired(cutoff)
      assert {:ok, 1, false} = TraceRun.sweep_expired(cutoff)
      assert {:ok, 0, false} = TraceRun.sweep_expired(cutoff)

      assert prefix_run_count(prefix) == 0
    end

    # A true cross-connection concurrency test (writer racing the sweep) is
    # impossible under the SQL sandbox: sandbox rows are uncommitted, hence
    # invisible and unlockable from a second connection. The two pins below
    # cover what IS testable — the lock reaches the SQL, and the batch is
    # atomic.

    test "the expired-batch query carries FOR UPDATE SKIP LOCKED down to the SQL" do
      query = TraceRun.expired_batch_query(cutoff_days_ago(30))
      assert query.lock == "FOR UPDATE SKIP LOCKED"

      %{query: ecto_query} = Ash.data_layer_query!(query)
      {sql, _} = Repo.to_sql(:all, ecto_query)
      assert sql =~ "FOR UPDATE OF"
      assert sql =~ "SKIP LOCKED"
    end

    @tag :capture_log
    test "a failed run delete rolls back the already-executed event delete" do
      expired = seed_trace!("atomic-#{unique()}")
      backdate_run!(expired, 60)

      # Sandbox-local trigger that raises only on trace_runs DELETE; the DDL
      # is transactional, so the sandbox rollback auto-reverts it. Idempotent
      # (CREATE OR REPLACE / DROP IF EXISTS) so a rerun after an interrupted
      # local session that leaked the objects stays boring.
      Repo.query!(
        "CREATE OR REPLACE FUNCTION sweep_test_block() RETURNS trigger AS " <>
          "$$ BEGIN RAISE EXCEPTION 'sweep_test'; END; $$ LANGUAGE plpgsql"
      )

      Repo.query!("DROP TRIGGER IF EXISTS sweep_test_block ON trace_runs")

      Repo.query!(
        "CREATE TRIGGER sweep_test_block BEFORE DELETE ON trace_runs " <>
          "FOR EACH ROW EXECUTE FUNCTION sweep_test_block()"
      )

      assert {:ok, 0, false} = TraceRun.sweep_expired(cutoff_days_ago(30))

      # Under the old two-phase code the events were already gone here —
      # the exact orphan the single transaction prevents.
      assert run_count(expired) == 1
      assert event_count(expired) == 2
    end
  end

  describe "RetentionSweeper tick path" do
    test "a :sweep tick prunes per the configured retention window", ctx do
      put_retention!(ctx.previous_trace_cfg, 30)
      expired = seed_trace!("tick-#{unique()}")
      backdate_run!(expired, 60)

      tick_sweeper!()

      assert run_count(expired) == 0
      assert event_count(expired) == 0
    end

    test "disabled retention (nil) makes the tick a no-op", ctx do
      put_retention!(ctx.previous_trace_cfg, nil)
      expired = seed_trace!("off-#{unique()}")
      backdate_run!(expired, 60)

      tick_sweeper!()

      assert run_count(expired) == 1
      assert event_count(expired) == 2
    end
  end

  describe "leader gate (WS4)" do
    setup do
      saved = Application.fetch_env(:jido_claw, :cluster_leader_module)
      Application.put_env(:jido_claw, :cluster_leader_module, JidoClaw.ClusterLeaderStub)

      on_exit(fn ->
        restore_env(:cluster_leader_module, saved)
        Application.delete_env(:jido_claw, :cluster_leader_stub_result)
      end)

      :ok
    end

    test "off-leader: the :sweep tick is a no-op even with retention configured", ctx do
      Application.put_env(:jido_claw, :cluster_leader_stub_result, false)
      put_retention!(ctx.previous_trace_cfg, 30)
      expired = seed_trace!("gate-off-#{unique()}")
      backdate_run!(expired, 60)

      tick_sweeper!()

      # The follower skips the prune — the expired row survives for the leader.
      assert run_count(expired) == 1
      assert event_count(expired) == 2
    end

    test "on-leader: the :sweep tick prunes", ctx do
      Application.put_env(:jido_claw, :cluster_leader_stub_result, true)
      put_retention!(ctx.previous_trace_cfg, 30)
      expired = seed_trace!("gate-on-#{unique()}")
      backdate_run!(expired, 60)

      tick_sweeper!()

      assert run_count(expired) == 0
      assert event_count(expired) == 0
    end
  end

  # -- Helpers --

  defp unique, do: System.unique_integer([:positive])

  defp restore_env(key, :error), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)

  # Pin the nested trace config by merging over the baseline, never replacing
  # the whole keyword list.
  defp put_retention!(previous, days) do
    Application.put_env(:jido_claw, :trace, Keyword.merge(previous || [], retention_days: days))
  end

  # `send` + `:sys.get_state` barrier: the mailbox is FIFO, so by the time
  # get_state returns the :sweep has been fully handled.
  defp tick_sweeper! do
    pid = Process.whereis(RetentionSweeper)
    assert is_pid(pid)
    send(pid, :sweep)
    :sys.get_state(pid)
    :ok
  end

  defp cutoff_days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp seed_trace!(suffix) do
    tenant_id = "sweep-tenant-#{suffix}"
    trace_id = "sweep-trace-#{suffix}"

    {:ok, _} =
      TraceRun.upsert_run(
        %{trace_id: trace_id, tenant_id: tenant_id, status: "completed", incoming_last_seq: 2},
        tenant: tenant_id
      )

    for seq <- 1..2 do
      {:ok, _} =
        TraceEvent.append_event(
          %{
            tenant_id: tenant_id,
            trace_id: trace_id,
            seq: seq,
            at_ms: seq * 100,
            source: "jido_claw",
            category: "request",
            event: "e#{seq}"
          },
          tenant: tenant_id
        )
    end

    trace_id
  end

  defp backdate_run!(trace_id, days) do
    Repo.query!(
      "UPDATE trace_runs SET updated_at = now() - make_interval(days => $2)," <>
        " inserted_at = now() - make_interval(days => $2) WHERE trace_id = $1",
      [trace_id, days]
    )
  end

  # Bulk-seed expired runs without 1k+ Ash round-trips. No events on purpose:
  # the event phase's zero-row bulk destroy is still a clean :success.
  defp seed_expired_runs_sql!(prefix, count) do
    Repo.query!(
      "INSERT INTO trace_runs (id, trace_id, last_seq, summary, inserted_at, updated_at) " <>
        "SELECT gen_random_uuid(), $1 || '-' || g, 0, '{}'::jsonb, " <>
        "now() - make_interval(days => 60), now() - make_interval(days => 60) " <>
        "FROM generate_series(1, $2::int) AS g",
      [prefix, count]
    )
  end

  defp run_count(trace_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM trace_runs WHERE trace_id = $1", [trace_id])

    n
  end

  defp prefix_run_count(prefix) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM trace_runs WHERE trace_id LIKE $1 || '%'", [prefix])

    n
  end

  defp event_count(trace_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM trace_events WHERE trace_id = $1", [trace_id])

    n
  end
end
