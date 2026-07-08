defmodule JidoClaw.Cluster.PollHelpers do
  @moduledoc """
  Test-node DB-poll composables for the WS6 cluster proofs, built on
  `PeerHarness.await/2` (bounded poll, never bare sleeps). Every helper flunks
  on timeout WITH the state seen at flunk time (a fresh read — the run row,
  the event kinds), so a red run is diagnosable from the failure message
  alone.

  Deliberately NOT imported by `ClusterCase`'s `using` block: Elixir warns per
  `{name, arity}` on unused `only:` imports (the Phase 1 deviation-log trap),
  so proof modules import what they use locally.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias JidoClaw.Cluster.PeerHarness
  alias JidoClaw.Orchestration.LeaseHelpers
  alias JidoClaw.Orchestration.ReclaimPooler
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Repo

  @doc """
  Poll the run row (global reload) until `pred` holds. Flunks with the final
  row on timeout.
  """
  @spec await_run!(String.t(), (WorkflowRun.t() -> boolean()), non_neg_integer()) :: :ok
  def await_run!(run_id, pred, timeout \\ 20_000) do
    case PeerHarness.await(fn -> pred.(LeaseHelpers.reload_global(run_id)) end, timeout) do
      :ok ->
        :ok

      {:error, :timeout} ->
        flunk("""
        run #{run_id} never satisfied the predicate within #{timeout}ms;
        final row: #{inspect(LeaseHelpers.reload_global(run_id))}
        """)
    end
  end

  @doc """
  Poll the run's durable event log until `kind` appears. Flunks with the
  kinds seen on timeout.
  """
  @spec await_kind!(String.t(), atom(), map(), non_neg_integer()) :: :ok
  def await_kind!(run_id, kind, ctx, timeout \\ 20_000) do
    case PeerHarness.await(fn -> kind in LeaseHelpers.kinds(run_id, ctx) end, timeout) do
      :ok ->
        :ok

      {:error, :timeout} ->
        flunk("""
        run #{run_id} never logged #{inspect(kind)} within #{timeout}ms;
        kinds seen: #{inspect(LeaseHelpers.kinds(run_id, ctx))}
        """)
    end
  end

  @doc """
  Poll until `node` has NO live executor registered for `run_id`
  (`RunExecution.lookup/1` returns `:error` on the peer).
  """
  @spec await_executor_gone!(node(), String.t(), non_neg_integer()) :: :ok
  def await_executor_gone!(node, run_id, timeout \\ 15_000) do
    probe = fn -> PeerHarness.call(node, RunExecution, :lookup, [run_id]) == :error end

    case PeerHarness.await(probe, timeout) do
      :ok ->
        :ok

      {:error, :timeout} ->
        flunk("""
        executor for run #{run_id} still registered on #{node} after #{timeout}ms:
        #{inspect(PeerHarness.call(node, RunExecution, :lookup, [run_id]))}
        """)
    end
  end

  @doc """
  Poll the shared DB's clock until it passes `instant` (`SELECT now() > $1`) —
  the wall-clock-free way to prove "a full lease window elapsed" (Proof 3's
  healthy-lease window): every lease comparison in production is against the
  DB's `now()`, so the proof's clock must be the same one, never the test
  BEAM's. Flunks with both clocks on timeout.
  """
  @spec await_db_clock_past!(DateTime.t(), non_neg_integer()) :: :ok
  def await_db_clock_past!(%DateTime{} = instant, timeout \\ 30_000) do
    probe = fn ->
      %{rows: [[past?]]} = Repo.query!("SELECT now() > $1", [instant])
      past?
    end

    case PeerHarness.await(probe, timeout) do
      :ok ->
        :ok

      {:error, :timeout} ->
        %{rows: [[db_now]]} = Repo.query!("SELECT now()", [])

        flunk("""
        the DB clock never passed #{inspect(instant)} within #{timeout}ms;
        DB now(): #{inspect(db_now)}
        """)
    end
  end

  @doc """
  Drive `ReclaimPooler.reclaim_once/0` on `node` until it drains EXACTLY one
  run (`0` before real lease expiry — the `:claimable` read defers to the DB
  clock, so the loop re-asks the DB each iteration; no app-vs-DB skew, no
  sleeps). A count above 1 flunks immediately: a stray claimable row
  contaminated the test, and a `>=` acceptance would hide it. On timeout,
  flunks with the run's current row so a non-expired lease is diagnosable.
  """
  @spec await_reclaim!(node(), String.t(), non_neg_integer()) :: :ok
  def await_reclaim!(node, run_id, timeout \\ 30_000) do
    drain = fn ->
      case PeerHarness.call(node, ReclaimPooler, :reclaim_once, [], 30_000) do
        0 ->
          false

        1 ->
          true

        n ->
          flunk("""
          reclaim_once on #{node} drained #{n} runs — expected exactly 1 for
          #{run_id}; a stray claimable row contaminated the test
          """)
      end
    end

    case PeerHarness.await(drain, timeout) do
      :ok ->
        :ok

      {:error, :timeout} ->
        flunk("""
        reclaim_once on #{node} never drained run #{run_id} within #{timeout}ms;
        current row: #{inspect(LeaseHelpers.reload_global(run_id))}
        """)
    end
  end
end
